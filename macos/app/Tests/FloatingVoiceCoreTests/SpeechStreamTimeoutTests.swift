import Foundation
import Testing
@testable import FloatingVoiceCore

/// Drives the real HTTPChunkStream delegate path, including its inactivity timer, without a listener or network.
private final class TimedSpeechProtocol: URLProtocol {
    private var work: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        work = Task {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "audio/pcm", "X-Sample-Rate": "24000"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            do {
                if request.url!.host == "first-stall" {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
                client?.urlProtocol(self, didLoad: Data([1, 2]))
                if request.url!.host == "mid-stall" {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
                // 0.5 s active stream: longer than the injected 0.2 s cold budget, but every gap is < idle 0.15 s.
                for _ in 0..<10 {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    client?.urlProtocol(self, didLoad: Data([3, 4]))
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch { /* cancellation stops delivery, exactly as a cancelled data task would */ }
        }
    }
    override func stopLoading() { work?.cancel() }
}

@MainActor @Suite struct SpeechStreamTimeoutTests {
    private func ticket(_ scenario: String, warmup: SpeechWarmup) -> SpeechTicket {
        var config = VoiceConfig()
        config.ttsUrl = "http://\(scenario):8444/v1/audio/speech"
        config.ttsStream = true
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [TimedSpeechProtocol.self]
        let synth = HealthCheckedSynthesizer(config: { config }, warmup: warmup,
                                            probe: { _, _ in .unloaded }, coldBudget: 0.2,
                                            make: { text, cfg, cold in
            HTTPSpeechTicket(text: text, config: cfg, cold: cold, coldBudget: 0.2,
                             streamIdleTimeout: 0.15, configuration: sessionConfig)
        })
        return synth.prepare("test")
    }

    @Test func activeColdStreamOutlivesFirstAudioBudget() async throws {
        var warming = false
        let warmup = SpeechWarmup(); warmup.onChange = { warming = $0 }
        let request = ticket("active", warmup: warmup)
        defer { request.cancel() }
        let began = Date()
        let audio = try await request.audio()
        #expect(!warming)
        var bytes = Data()
        for try await chunk in audio.chunks { bytes.append(chunk) }
        #expect(Date().timeIntervalSince(began) > 0.2)
        #expect(bytes.count == 22)
        #expect(!warming)
    }

    @Test func headersWithoutFirstAudioStillHitColdDeadline() async {
        var warming = false
        let warmup = SpeechWarmup(); warmup.onChange = { warming = $0 }
        let request = ticket("first-stall", warmup: warmup)
        defer { request.cancel() }
        do { _ = try await request.audio(); Issue.record("First-audio stall succeeded") }
        catch {
            #expect(error.localizedDescription.contains("did not warm up within 60 s. Try again."))
            #expect(!error.localizedDescription.contains("isn't running"))
        }
        #expect(!warming)
    }

    @Test func midstreamStallUsesOrdinaryInactivityAndAccurateError() async throws {
        var warming = false
        let warmup = SpeechWarmup(); warmup.onChange = { warming = $0 }
        let request = ticket("mid-stall", warmup: warmup)
        defer { request.cancel() }
        let audio = try await request.audio()
        #expect(!warming)
        var received = Data()
        do {
            for try await chunk in audio.chunks { received.append(chunk) }
            Issue.record("Midstream stall succeeded")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Speech service at mid-stall:8444"))
            #expect(message.contains("stream stalled") && message.contains("0.15"))
            #expect(!message.contains("warm up") && !message.contains("isn't running"))
        }
        #expect(received == Data([1, 2]) && !warming)
    }

    @Test func nativeMidstreamTimeoutIsNotWarmupOrListenerOutage() {
        let message = SpeechServiceError.describeStream(url: "http://fake:8444/x", error: URLError(.timedOut))
        #expect(message.contains("audio stream stalled (timed out)"))
        #expect(!message.contains("warm up") && !message.contains("isn't running"))
        #expect(SpeechServiceError.describeStream(url: "http://fake:8444/x", error: URLError(.cannotConnectToHost))
                == "Speech service at fake:8444 isn't running")
    }
}
