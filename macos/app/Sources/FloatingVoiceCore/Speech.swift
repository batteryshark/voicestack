import Foundation

/// Mono s16le PCM for one sentence. Chunks arrive while the speech server is still generating.
public struct SpeechAudio {
    public let sampleRate: Int
    public let chunks: AsyncThrowingStream<Data, Error>
    public init(sampleRate: Int, chunks: AsyncThrowingStream<Data, Error>) { self.sampleRate = sampleRate; self.chunks = chunks }

    public static func whole(_ pcm: Data, sampleRate: Int) -> SpeechAudio {
        SpeechAudio(sampleRate: sampleRate, chunks: AsyncThrowingStream { c in c.yield(pcm); c.finish() })
    }
}

/// A sentence whose synthesis has started (prefetch). Cancelling aborts the request.
public protocol SpeechTicket: AnyObject {
    var text: String { get }
    func audio() async throws -> SpeechAudio
    func cancel()
}

public protocol SpeechSynthesizer: AnyObject {
    func prepare(_ text: String) -> SpeechTicket
}

/// OpenAI-compatible `/v1/audio/speech` (Breeze TTS 2 locally). With ttsStream it requests raw PCM
/// (`response_format: "pcm"`, rate in `x-sample-rate`) and plays it as it arrives; otherwise WAV.
/// Reads config through a closure so a voice change applies from the next sentence.
public final class HTTPSpeechSynthesizer: SpeechSynthesizer {
    let config: () -> VoiceConfig
    public init(config: @escaping () -> VoiceConfig) { self.config = config }

    public func prepare(_ text: String) -> SpeechTicket { HTTPSpeechTicket(text: text, config: config()) }

    /// Voices listed beside the speech route (…/v1/audio/speech -> …/v1/voices): (name, label) pairs and the
    /// server default (GET /v1/voices on the local speech server). Nil when the URL has no voice-list route;
    /// a service that cannot be reached throws the plain wording (see SpeechServiceError).
    public static func listVoices(_ config: VoiceConfig) async throws -> (voices: [(name: String, label: String)], serverDefault: String?)? {
        guard config.ttsUrl.range(of: "/audio/speech/?$", options: .regularExpression) != nil,
              let url = URL(string: config.ttsUrl.replacingOccurrences(of: "/audio/speech/?$", with: "/voices", options: .regularExpression)) else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 3
        if let key = config.ttsApiKey { r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: r)
        } catch {
            throw ClientError(SpeechServiceError.describe(url: config.ttsUrl, error: error))
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let host = SpeechServiceError.hostPort(config.ttsUrl)
            throw ClientError("Speech service at \(host) returned \((response as? HTTPURLResponse)?.statusCode ?? 0) for the voice list")
        }
        guard let body = try? JSONSerialization.jsonObject(with: data) else {
            throw ClientError("Speech service at \(SpeechServiceError.hostPort(config.ttsUrl)): the voice list was not JSON")
        }
        return parseVoices(body)
    }

    public static func parseVoices(_ body: Any) -> (voices: [(name: String, label: String)], serverDefault: String?) {
        let list = (body as? [Any]) ?? ((body as? [String: Any])?["voices"] as? [Any]) ?? []
        let voices = list.compactMap { v -> (name: String, label: String)? in
            if let s = v as? String { return (s, s) }
            guard let o = v as? [String: Any], let name = (o["name"] as? String) ?? (o["id"] as? String) else { return nil }
            return (name, (o["label"] as? String) ?? name)
        }
        return (voices, (body as? [String: Any])?["default"] as? String)
    }
}

final class HTTPSpeechTicket: SpeechTicket {
    let text: String
    private let urlString: String
    private let stream: HTTPChunkStream?
    private let streaming: Bool
    private let setupError: Error?
    private let cold: Bool

    init(text: String, config: VoiceConfig, cold: Bool = false, coldBudget: TimeInterval = SpeechHealth.coldBudget,
         streamIdleTimeout: TimeInterval = 30, configuration: URLSessionConfiguration? = nil) {
        self.cold = cold
        self.text = text
        urlString = config.ttsUrl
        streaming = config.ttsStream
        guard let url = URL(string: config.ttsUrl), !config.ttsUrl.isEmpty else {
            stream = nil
            setupError = ClientError("Set \"ttsUrl\" in agent-voice.json (or the app's settings).")
            return
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.ttsApiKey { r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": config.ttsModel, "voice": config.voice, "input": text, "response_format": config.ttsStream ? "pcm" : "wav"])
        // Startup is bounded separately by the caller's first-audio deadline. Once bytes arrive, reset the
        // ordinary inactivity watchdog on every chunk; never cap a cold request's entire download at 60 s.
        stream = HTTPChunkStream(r, idleTimeout: cold ? coldBudget : streamIdleTimeout,
                                 streamIdleTimeout: streamIdleTimeout, configuration: configuration)
        setupError = nil
    }

    func audio() async throws -> SpeechAudio {
        if let setupError { throw setupError }
        guard let stream else { throw ClientError("No speech request") }
        let host = SpeechServiceError.hostPort(urlString)
        let head: HTTPURLResponse
        do { head = try await stream.headers() }
        catch {
            if cold && (error as? URLError)?.code == .timedOut { throw ClientError(SpeechHealth.retryMessage(urlString)) }
            throw ClientError(SpeechServiceError.describe(url: urlString, error: error))
        }
        guard (200..<300).contains(head.statusCode) else {
            let body = (try? await stream.collect(limit: 4096)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw ClientError("Speech service at \(host) returned \(head.statusCode): \(body.prefix(200))")
        }
        if streaming {
            let type = head.value(forHTTPHeaderField: "Content-Type") ?? ""
            if type.range(of: "wav|mpeg|json|text", options: [.regularExpression, .caseInsensitive]) != nil {
                stream.cancel()
                throw ClientError("Speech service at \(host) sent \(type), not raw PCM; set \"ttsStream\": false.")
            }
            let rate = Int(head.value(forHTTPHeaderField: "X-Sample-Rate") ?? "") ?? 24000
            return SpeechAudio(sampleRate: rate, chunks: stream.chunks)
        }
        do {
            let wav = try await stream.collect()
            let (pcm, rate) = try WAV.decodeToS16Mono(wav)
            return .whole(pcm, sampleRate: rate)
        } catch {
            throw ClientError(SpeechServiceError.describeStream(url: urlString, error: error))
        }
    }

    func cancel() { stream?.cancel() }
}

public enum WAV {
    /// Decode a RIFF WAV (PCM 16-bit or float 32-bit, any channel count) to mono s16le.
    public static func decodeToS16Mono(_ data: Data) throws -> (Data, Int) {
        let b = [UInt8](data)
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        guard b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF", String(bytes: b[8..<12], encoding: .ascii) == "WAVE" else {
            throw ClientError("Speech audio is not WAV")
        }
        var i = 12, format = 0, channels = 1, rate = 24000, bits = 16
        while i + 8 <= b.count {
            let id = String(bytes: b[i..<i + 4], encoding: .ascii) ?? ""
            var size = u32(i + 4)
            if id == "fmt " {
                format = u16(i + 8); channels = max(1, u16(i + 10)); rate = u32(i + 12); bits = u16(i + 22)
                if format == 0xFFFE && size >= 26 { format = u16(i + 32) }
            } else if id == "data" {
                if size == 0 || i + 8 + size > b.count { size = b.count - i - 8 }
                let body = Array(b[(i + 8)..<(i + 8 + size)])
                return (try toMono(body, format: format, bits: bits, channels: channels), rate)
            }
            i += 8 + size + (size & 1)
        }
        throw ClientError("WAV has no data chunk")
    }

    static func toMono(_ body: [UInt8], format: Int, bits: Int, channels: Int) throws -> Data {
        var out = Data()
        if format == 1 && bits == 16 {
            let frames = body.count / (2 * channels)
            out.reserveCapacity(frames * 2)
            for f in 0..<frames {
                var sum = 0
                for c in 0..<channels { let j = (f * channels + c) * 2; sum += Int(Int16(bitPattern: UInt16(body[j]) | UInt16(body[j + 1]) << 8)) }
                let v = Int16(clamping: sum / channels)
                out.append(UInt8(truncatingIfNeeded: v)); out.append(UInt8(truncatingIfNeeded: v >> 8))
            }
        } else if format == 3 && bits == 32 {
            let frames = body.count / (4 * channels)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels {
                    let j = (f * channels + c) * 4
                    sum += Float(bitPattern: UInt32(body[j]) | UInt32(body[j + 1]) << 8 | UInt32(body[j + 2]) << 16 | UInt32(body[j + 3]) << 24)
                }
                let v = Int16(clamping: Int((sum / Float(channels) * 32767).rounded()))
                out.append(UInt8(truncatingIfNeeded: v)); out.append(UInt8(truncatingIfNeeded: v >> 8))
            }
        } else { throw ClientError("Unsupported WAV format \(format)/\(bits)-bit") }
        return out
    }

    /// Mono s16le PCM wrapped in a WAV header.
    public static func encode(_ pcm: Data, sampleRate: Int) -> Data {
        var d = Data()
        func put32(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)]) }
        func put16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + pcm.count); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1); put32(sampleRate); put32(sampleRate * 2); put16(2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(pcm.count); d.append(pcm)
        return d
    }
}

/// Resample mono s16le PCM by linear interpolation (test utterances: 24 kHz speech to 16 kHz mic input).
public func resampleS16(_ pcm: Data, from: Int, to: Int) -> Data {
    guard from != to, pcm.count >= 4 else { return pcm }
    let input: [Int16] = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    let count = Int(Double(input.count) * Double(to) / Double(from))
    var out = [Int16](repeating: 0, count: count)
    let step = Double(from) / Double(to)
    for i in 0..<count {
        let x = Double(i) * step, j = Int(x), t = x - Double(j)
        let a = Double(input[min(j, input.count - 1)]), b = Double(input[min(j + 1, input.count - 1)])
        out[i] = Int16(clamping: Int((a + (b - a) * t).rounded()))
    }
    return out.withUnsafeBufferPointer { Data(buffer: $0) }
}
