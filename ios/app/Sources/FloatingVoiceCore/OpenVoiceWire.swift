import Foundation

/// Closed JSON value domain. No Any payloads or production fixture dependency.
public enum OpenVoiceJSON: Codable, Equatable {
    case object([String: OpenVoiceJSON]), array([OpenVoiceJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([OpenVoiceJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: OpenVoiceJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> OpenVoiceJSON { object?[key] ?? .null }
    public var object: [String: OpenVoiceJSON]? { if case .object(let v) = self { return v }; return nil }
    public var array: [OpenVoiceJSON]? { if case .array(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public static func text(_ s: String) -> Self { .string(s) }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    /// Swift String equality is canonically equivalent Unicode equality. The wire's
    /// canonical item contract is exact scalar equality, never NFC/NFD normalization.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs,rhs) {
        case (.string(let a),.string(let b)): return a.unicodeScalars.elementsEqual(b.unicodeScalars)
        case (.number(let a),.number(let b)): return a == b
        case (.bool(let a),.bool(let b)): return a == b
        case (.null,.null): return true
        case (.array(let a),.array(let b)): return a == b
        case (.object(let a),.object(let b)): return a == b
        default: return false
        }
    }
}

public struct OpenVoiceFailure: Error, Equatable, CustomStringConvertible {
    public let code: String
    public init(_ code: String = "invalid_request") { self.code = code }
    public var description: String { OpenVoiceWire.errorMessages[code] ?? "Local processing failed." }
}

public enum OpenVoiceEventKind: String, Codable {
    case sessionUpdate = "session.update", sessionCreated = "session.created", sessionUpdated = "session.updated"
    case append = "input_audio_buffer.append", commit = "input_audio_buffer.commit", clear = "input_audio_buffer.clear"
    case committed = "input_audio_buffer.committed", cleared = "input_audio_buffer.cleared"
    case itemCreate = "conversation.item.create", itemAdded = "conversation.item.added", itemDone = "conversation.item.done"
    case truncate = "conversation.item.truncate", truncated = "conversation.item.truncated"
    case transcriptionCompleted = "conversation.item.input_audio_transcription.completed"
    case transcriptionFailed = "conversation.item.input_audio_transcription.failed"
    case responseCreate = "response.create", responseCancel = "response.cancel"
    case responseCreated = "response.created", responseDone = "response.done"
    case outputItemAdded = "response.output_item.added", outputItemDone = "response.output_item.done"
    case partAdded = "response.content_part.added", partDone = "response.content_part.done"
    case audioDelta = "response.output_audio.delta", audioDone = "response.output_audio.done"
    case transcriptDelta = "response.output_audio_transcript.delta", transcriptDone = "response.output_audio_transcript.done"
    case textDelta = "response.output_text.delta", textDone = "response.output_text.done"
    case flow = "vs.flow", playback = "vs.playback", error
}

/// Constructible only after closed-profile validation. Item content and response parts
/// remain distinct tagged unions in the validated JSON (output_audio vs audio).
public struct OpenVoiceEvent: Equatable {
    public let kind: OpenVoiceEventKind
    public let body: OpenVoiceJSON
    public let effect: String
    public subscript(_ key: String) -> OpenVoiceJSON { body[key] }
    public var session: OpenVoiceEffectiveSession? {
        guard kind == .sessionCreated || kind == .sessionUpdated else { return nil }
        return OpenVoiceEffectiveSession(validated: body["session"])
    }
    public var response: OpenVoiceResponse? {
        guard kind == .responseCreated || kind == .responseDone else { return nil }
        return OpenVoiceResponse(validated: body["response"])
    }
    public var coordinates: OpenVoiceCoordinates? {
        guard let response = body["response_id"].string, let item = body["item_id"].string,
              body["output_index"] == .number(0), body["content_index"] == .number(0) else { return nil }
        return OpenVoiceCoordinates(responseID: response, itemID: item)
    }
    public var contentPart: OpenVoiceContentPart? {
        guard kind == .partAdded || kind == .partDone else { return nil }
        let p = body["part"]
        return p["type"] == .string("audio") ? .audio(transcript: p["transcript"].string!) : .text(p["text"].string!)
    }
}

public enum OpenVoiceModality: String { case audio, text }
public struct OpenVoicePCMFormat: Equatable {
    public let rate = 24_000, channels = 1, bytesPerSample = 2
    public let littleEndian = true, signed = true
}
public struct OpenVoiceEffectiveSession: Equatable {
    public let json: OpenVoiceJSON
    fileprivate init(validated: OpenVoiceJSON) { json = validated }
    public var id: String { json["id"].string! }
    public var modality: OpenVoiceModality { OpenVoiceModality(rawValue: json["output_modalities"].array![0].string!)! }
    public var format: OpenVoicePCMFormat { OpenVoicePCMFormat() }
}
public struct OpenVoiceCoordinates: Equatable {
    public let responseID: String, itemID: String
    public let outputIndex = 0, contentIndex = 0
}
/// GA content parts deliberately do NOT use the item tags output_audio/output_text.
public enum OpenVoiceContentPart: Equatable { case audio(transcript: String), text(String) }
public enum OpenVoiceResponseStatus: String { case inProgress = "in_progress", completed, cancelled, failed, incomplete }
public struct OpenVoiceResponse: Equatable {
    public let json: OpenVoiceJSON
    fileprivate init(validated: OpenVoiceJSON) { json = validated }
    public var id: String { json["id"].string! }
    public var status: OpenVoiceResponseStatus { OpenVoiceResponseStatus(rawValue: json["status"].string!)! }
    public var operationID: UUID { UUID(uuidString: json["metadata"]["operation_id"].string!)! }
    // No delivery/heard flag: completed is generation only.
}
public struct OpenVoiceCanonicalItem: Equatable {
    public let id: String, text: String
    public init(id: String, text: String) throws {
        self.id = id; self.text = text; try OpenVoiceWire.userItem(json)
    }
    public var json: OpenVoiceJSON {
        .object(["id":.string(id),"type":.string("message"),"role":.string("user"),
            "content":.array([.object(["type":.string("input_text"),"text":.string(text)])])])
    }
    public var createEvent: OpenVoiceJSON { .object(["type":.string("conversation.item.create"),"item":json]) }
    /// Sole response-local context, identical object; does not append again or promise
    /// OpenAI-server deduplication. Durable admission belongs to the bridge control owner.
    public func responseEvent(operationID: UUID, modality: OpenVoiceModality = .audio) -> OpenVoiceJSON {
        .object(["type":.string("response.create"),"response":.object(["input":.array([json]),
            "metadata":.object(["operation_id":.string(operationID.uuidString.lowercased())]),"output_modalities":.array([.string(modality.rawValue)])])])
    }
    public static func == (a: Self, b: Self) -> Bool { a.json == b.json }
}

public enum OpenVoiceWire {
    public static let profile = "open-voice-m1-ga-ws/1"
    public static let sampleRate = 24_000, maxFrameBytes = 4_800, maxMessageBytes = 65_536
    public static let maxQueueBytes = 96_000, maxAggregateBytes = 524_288, maxWritableBytes = 262_144
    public static let windowSamples = 48_000, maxSegmentSamples = 2_160_000
    public static let errorMessages = [
        "invalid_json":"Invalid JSON message.", "invalid_request":"Invalid profile request.",
        "unsupported_feature":"Unsupported profile feature.", "message_too_large":"Message exceeds profile limit.",
        "invalid_audio":"Invalid PCM frame.", "context_required":"Required state snapshot is missing.",
        "empty_buffer":"Input buffer is empty.", "response_in_progress":"A response is already active.",
        "no_active_response":"No matching active response.", "item_mismatch":"Input does not match the composed item.",
        "operation_conflict":"Operation payload conflicts.", "invalid_position":"Invalid media position.",
        "local_failure":"Local processing failed."]
    public static let defaultConfig: OpenVoiceJSON = .object([
        "type":.string("realtime"), "model":.string("local-chain-m1"), "output_modalities":.array([.string("audio")]),
        "tools":.array([]), "tool_choice":.string("none"), "instructions":.string(""),
        "audio":.object(["input":.object(["format":.object(["type":.string("audio/pcm"),"rate":.number(24000)]),
            "noise_reduction":.null,"turn_detection":.null,"transcription":.object(["model":.string("local-stt")])]),
            "output":.object(["format":.object(["type":.string("audio/pcm"),"rate":.number(24000)]),
                "voice":.string("local-default"),"speed":.number(1)])])])
    static func check(_ condition: Bool, _ code: String = "invalid_request") throws { if !condition { throw OpenVoiceFailure(code) } }
    static func keys(_ v: OpenVoiceJSON, _ allowed: [String], _ required: [String]? = nil) throws {
        guard let o = v.object else { throw OpenVoiceFailure() }
        try check(o.keys.allSatisfy { allowed.contains($0) }, "unsupported_feature")
        try check((required ?? allowed).allSatisfy { o[$0] != nil })
    }
    static func id(_ v: OpenVoiceJSON) throws {
        try check(v.string?.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil)
    }
    static func uint(_ v: OpenVoiceJSON) throws {
        guard let n = v.number else { throw OpenVoiceFailure() }
        try check(n.isFinite && n >= 0 && n <= 9_007_199_254_740_991 && n.rounded() == n)
    }
    static func zero(_ v: OpenVoiceJSON) throws { try check(v == .number(0), "invalid_position") }
    static func text(_ v: OpenVoiceJSON, empty: Bool = true) throws {
        guard let s = v.string else { throw OpenVoiceFailure() }
        try check(s.unicodeScalars.count <= 16_000 && !s.unicodeScalars.contains { (0...8).contains($0.value) || $0.value == 11 || $0.value == 12 || (14...31).contains($0.value) || $0.value == 127 })
        // ECMAScript \s, as in the shared profile; never trim or normalize text.
        let whitespace: Set<UInt32> = [9,10,11,12,13,32,160,5760,8232,8233,8239,8287,12288,65279]
        try check(empty || s.unicodeScalars.contains { !whitespace.contains($0.value) && !(8192...8202).contains($0.value) })
    }
    static func modalities(_ v: OpenVoiceJSON) throws {
        try check(v == .array([.string("audio")]) || v == .array([.string("text")]), "unsupported_feature")
    }
    public static func pcm(_ v: OpenVoiceJSON) throws -> Data {
        guard let s = v.string, !s.isEmpty, s.utf8.count <= 6400, let d = Data(base64Encoded: s) else { throw OpenVoiceFailure("invalid_audio") }
        try check(d.base64EncodedString() == s && d.count % 2 == 0 && d.count <= maxFrameBytes, "invalid_audio")
        try check(!["RIFF","RF64","OggS","fLaC","ID3"].contains { d.starts(with: $0.utf8) }, "invalid_audio")
        let a = [UInt8](d.prefix(4))
        if a.count == 4 {
            let mpeg = a[0] == 255 && a[1] & 224 == 224 && (a[1] >> 3) & 3 != 1 && (a[1] >> 1) & 3 != 0 && a[2] >> 4 != 0 && a[2] >> 4 != 15 && (a[2] >> 2) & 3 != 3
            try check(!mpeg, "invalid_audio")
        }
        return d
    }
    public static func createSession(_ id: String) throws -> OpenVoiceJSON {
        try self.id(.string(id)); var s = defaultConfig.object!; s["id"] = .string(id); s["object"] = .string("realtime.session"); return .object(s)
    }
    static func effective(_ s: OpenVoiceJSON) throws {
        try keys(s, ["id","object"] + Array(defaultConfig.object!.keys)); try id(s["id"])
        try check(s["object"] == .string("realtime.session") && s["model"] == defaultConfig["model"])
        try modalities(s["output_modalities"])
        var expected = try createSession(s["id"].string! ).object!; expected["output_modalities"] = s["output_modalities"]
        try check(s == .object(expected), "unsupported_feature")
    }
    static func patch(_ p: OpenVoiceJSON, template: OpenVoiceJSON = defaultConfig, root: Bool = true) throws {
        try keys(p, Array(template.object!.keys), [])
        for (k,v) in p.object! {
            if root && k == "model" { throw OpenVoiceFailure("unsupported_feature") }
            if root && k == "output_modalities" { try modalities(v) }
            else if template[k].object != nil { try patch(v, template: template[k], root: false) }
            else { try check(v == template[k], "unsupported_feature") }
        }
    }
    static func merge(_ a: OpenVoiceJSON, _ b: OpenVoiceJSON) -> OpenVoiceJSON {
        var o = a.object!; for (k,v) in b.object! { o[k] = o[k]?.object != nil ? merge(o[k]!, v) : v }; return .object(o)
    }
    public static func applySessionUpdate(_ current: OpenVoiceJSON, _ update: OpenVoiceJSON, context: OpenVoiceJSON = .object([:])) throws -> OpenVoiceJSON {
        try effective(current); try patch(update)
        try check(context["activeResponseId"] == .null, "response_in_progress")
        return merge(current, update)
    }
    static func userItem(_ i: OpenVoiceJSON) throws {
        try keys(i, ["id","type","role","content"]); try id(i["id"])
        try check(i["type"] == .string("message") && i["role"] == .string("user"), "unsupported_feature")
        try check(i["content"].array?.count == 1)
        let c = i["content"].array![0]; try keys(c, ["type","text"])
        try check(c["type"] == .string("input_text"), "unsupported_feature"); try text(c["text"], empty: false)
    }
    static func metadata(_ m: OpenVoiceJSON) throws {
        try keys(m, ["operation_id"])
        try check(m["operation_id"].string?.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: [.regularExpression,.caseInsensitive]) != nil)
    }
    public static func client(_ e: OpenVoiceJSON, context c: OpenVoiceJSON = .object([:])) throws -> OpenVoiceEvent {
        try bounded(e)
        try keys(e, ["type","event_id","session","audio","item","response","response_id","item_id","content_index","audio_end_ms","media_epoch","playback_epoch","rendered_samples","state"], ["type"])
        if e.object?["event_id"] != nil { try id(e["event_id"]) }
        guard let k = OpenVoiceEventKind(rawValue: e["type"].string ?? "") else { throw OpenVoiceFailure("unsupported_feature") }
        var fields: [String] = [], effect = "validate_only"
        switch k {
        case .sessionUpdate:
            fields = ["session"]; try check(e["session"]["type"] == .string("realtime"), "unsupported_feature")
            try check(c["effectiveSession"] != .null, "context_required")
            _ = try applySessionUpdate(c["effectiveSession"], e["session"], context: c); effect = "session_update"
        case .append: fields = ["audio"]; _ = try pcm(e["audio"]); effect = "append"
        case .commit:
            guard let n = c["bufferSamples"].number, n >= 0, n <= Double(maxSegmentSamples), n.rounded() == n else { throw OpenVoiceFailure("context_required") }
            try check(n > 0, "empty_buffer"); effect = "commit_input_only"
        case .clear: effect = "clear_uncommitted_only"
        case .itemCreate:
            fields = ["item"]; try userItem(e["item"])
            if c["canonicalItem"]["id"] == e["item"]["id"] { try userItem(c["canonicalItem"]); try check(c["canonicalItem"] == e["item"], "item_mismatch") }
            effect = "compose_only"
        case .responseCreate:
            fields = ["response"]; let r = e["response"]; try keys(r, ["input","metadata","output_modalities"])
            try check(r["input"].array?.count == 1); let i = r["input"].array![0]
            try userItem(i); try metadata(r["metadata"]); try modalities(r["output_modalities"])
            try check(c["canonicalItem"] != .null, "context_required"); try userItem(c["canonicalItem"])
            try check(i == c["canonicalItem"], "item_mismatch")
            if let prior = c["priorOperation"]["operation_id"].string, prior.lowercased() == r["metadata"]["operation_id"].string?.lowercased() { try check(c["priorOperation"]["item"] == i, "operation_conflict") }
            try check(c["activeResponseId"] == .null, "response_in_progress"); effect = "explicit_response_request"
        case .responseCancel:
            if e.object?["response_id"] != nil { fields = ["response_id"]; try id(e["response_id"]) }
            try check(c["activeResponseId"] != .null && (fields.isEmpty || e["response_id"] == c["activeResponseId"]), "no_active_response"); effect = "cancel_narration_only"
        case .truncate:
            fields = ["item_id","content_index","audio_end_ms"]; try id(e["item_id"]); try zero(e["content_index"]); try uint(e["audio_end_ms"])
            guard let n = c["truncateTarget"]["generatedSamples"].number, n >= 0, n.rounded() == n else { throw OpenVoiceFailure("context_required") }
            try check(e["item_id"] == c["truncateTarget"]["item_id"] && e["audio_end_ms"].number! <= floor(n / 24), "invalid_position"); effect = "truncate_media_only"
        case .playback:
            fields = ["media_epoch","response_id","item_id","content_index","playback_epoch","rendered_samples","state"]
            for f in ["media_epoch","response_id","item_id","playback_epoch"] { try id(e[f]) }
            try zero(e["content_index"]); try uint(e["rendered_samples"])
            try check(["playing","paused","stopped","completed","unknown"].contains(e["state"].string ?? ""))
        default: throw OpenVoiceFailure("unsupported_feature")
        }
        try keys(e, ["type","event_id"] + fields, ["type"] + fields)
        return OpenVoiceEvent(kind: k, body: e, effect: effect)
    }
    static func serverItem(_ i: OpenVoiceJSON) throws {
        try keys(i, ["id","object","type","role","status","content"]); try id(i["id"])
        try check(i["object"] == .string("realtime.item") && i["type"] == .string("message"))
        try check(["user","assistant"].contains(i["role"].string ?? "") && ["in_progress","completed","incomplete"].contains(i["status"].string ?? ""))
        guard let a = i["content"].array, a.count <= 1 else { throw OpenVoiceFailure() }
        for c in a {
            let isText = ["input_text","output_text"].contains(c["type"].string ?? "")
            let key = isText ? "text" : "transcript"; try keys(c, ["type",key]); try text(c[key])
            let tag = (i["role"] == .string("user") ? "input_" : "output_") + (isText ? "text" : "audio")
            try check(c["type"] == .string(tag))
        }
    }
    static func wireError(_ e: OpenVoiceJSON, correlation: Bool = false) throws {
        try keys(e, ["type","code","message","param"] + (correlation ? ["event_id"] : []), ["type","code","message","param"])
        try check(["invalid_request_error","server_error"].contains(e["type"].string ?? "") && e["param"] == .null)
        guard let code = e["code"].string, let message = errorMessages[code] else { throw OpenVoiceFailure() }
        try check(e["message"] == .string(message)); if e.object?["event_id"] != nil { try id(e["event_id"]) }
    }
    static func response(_ r: OpenVoiceJSON, done: Bool) throws {
        try keys(r, ["id","object","status","status_details","output","metadata"]); try id(r["id"]); try metadata(r["metadata"])
        try check(r["object"] == .string("realtime.response"))
        let s = r["status"].string ?? ""; try check((done ? ["completed","cancelled","failed","incomplete"] : ["in_progress"]).contains(s))
        let d = r["status_details"]
        if s == "completed" || s == "in_progress" { try check(d == .null) }
        else if s == "failed" {
            try keys(d, ["type","error"]); try check(d["type"] == .string("failed")); try keys(d["error"], ["type","code","message"])
            try check(d["error"] == .object(["type":.string("server_error"),"code":.string("local_failure"),"message":.string(errorMessages["local_failure"]!)]))
        } else {
            try keys(d, ["type","reason"]); try check(d["type"] == .string(s))
            try check((s == "cancelled" ? ["client_cancelled"] : ["max_output_tokens","content_filter"]).contains(d["reason"].string ?? ""))
        }
        guard let a = r["output"].array, a.count <= 1 else { throw OpenVoiceFailure() }
        for i in a { try serverItem(i); try check(i["role"] == .string("assistant")) }
    }
    public static func server(_ e: OpenVoiceJSON) throws -> OpenVoiceEvent {
        try bounded(e); try id(e["event_id"])
        guard let k = OpenVoiceEventKind(rawValue: e["type"].string ?? "") else { throw OpenVoiceFailure("unsupported_feature") }
        var fields: [String]
        switch k {
        case .sessionCreated,.sessionUpdated: fields = ["session"]; try effective(e["session"])
        case .responseCreated,.responseDone: fields = ["response"]; try response(e["response"], done: k == .responseDone)
        case .itemAdded,.itemDone:
            fields = ["previous_item_id","item"]; if e["previous_item_id"] != .null { try id(e["previous_item_id"]) }; try serverItem(e["item"])
        case .committed: fields = ["item_id","previous_item_id"]; try id(e["item_id"]); if e["previous_item_id"] != .null { try id(e["previous_item_id"]) }
        case .cleared: fields = []
        case .truncated: fields = ["item_id","content_index","audio_end_ms"]; try id(e["item_id"]); try zero(e["content_index"]); try uint(e["audio_end_ms"])
        case .error: fields = ["error"]; try wireError(e["error"], correlation: true)
        case .flow: fields = ["media_epoch","input_consumed_samples"]; try id(e["media_epoch"]); try uint(e["input_consumed_samples"])
        case .transcriptionCompleted,.transcriptionFailed:
            fields = ["item_id","content_index"]; try id(e["item_id"]); try zero(e["content_index"])
            if k == .transcriptionCompleted {
                fields += ["transcript","usage"]; try text(e["transcript"]); try keys(e["usage"], ["type","seconds"])
                try check(e["usage"]["type"] == .string("duration")); guard let n = e["usage"]["seconds"].number else { throw OpenVoiceFailure() }; try check(n >= 0 && n <= 90)
            } else { fields += ["error"]; try wireError(e["error"]) }
        case .outputItemAdded,.outputItemDone:
            fields = ["response_id","output_index","item"]; try id(e["response_id"]); try zero(e["output_index"]); try serverItem(e["item"]); try check(e["item"]["role"] == .string("assistant"))
        case .partAdded,.partDone,.audioDelta,.audioDone,.transcriptDelta,.transcriptDone,.textDelta,.textDone:
            fields = ["response_id","item_id","output_index","content_index"]; try id(e["response_id"]); try id(e["item_id"]); try zero(e["output_index"]); try zero(e["content_index"])
            if k == .partAdded || k == .partDone {
                fields += ["part"]; let p = e["part"]; try check(["audio","text"].contains(p["type"].string ?? ""))
                let key = p["type"] == .string("audio") ? "transcript" : "text"; try keys(p, ["type",key]); try text(p[key])
            } else if [.audioDelta,.transcriptDelta,.textDelta].contains(k) {
                fields += ["delta"]; if k == .audioDelta { _ = try pcm(e["delta"]) } else { try text(e["delta"]) }
            } else if k != .audioDone {
                let key = k == .textDone ? "text" : "transcript"; fields += [key]; try text(e[key])
            }
        default: throw OpenVoiceFailure("unsupported_feature")
        }
        try keys(e, ["event_id","type"] + fields)
        return OpenVoiceEvent(kind: k, body: e, effect: "validate_only")
    }
    static func bounded(_ v: OpenVoiceJSON, depth: Int = 0) throws {
        try check(depth <= 16)
        if depth == 0 { try check(try v.encoded().count <= maxMessageBytes, "message_too_large") }
        if let n = v.number { try check(n.isFinite) }
        if let o = v.object {
            for (k,x) in o { try check(!["__proto__","constructor","prototype"].contains(k)); try bounded(x, depth: depth + 1) }
        }
        if let a = v.array { for x in a { try bounded(x, depth: depth + 1) } }
    }
    /// JSONDecoder alone silently accepts duplicate keys. Scan structure first, including escaped keys.
    public static func parse(_ data: Data) throws -> OpenVoiceJSON {
        try check(data.count <= maxMessageBytes, "message_too_large")
        guard let s = String(data: data, encoding: .utf8) else { throw OpenVoiceFailure("invalid_json") }
        let bytes = Array(s.utf8); var i = 0
        func space() { while i < bytes.count && [9,10,13,32].contains(bytes[i]) { i += 1 } }
        func token() throws -> String {
            let start = i; i += 1
            while i < bytes.count {
                if bytes[i] == 92 { i += 2; continue }
                if bytes[i] == 34 {
                    i += 1
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<i])) }
                    catch { throw OpenVoiceFailure("invalid_request") }
                }
                i += 1
            }
            throw OpenVoiceFailure("invalid_json")
        }
        func scan(_ depth: Int) throws {
            try check(depth <= 16); space(); guard i < bytes.count else { throw OpenVoiceFailure("invalid_json") }
            if bytes[i] == 34 { _ = try token(); return }
            if bytes[i] == 123 || bytes[i] == 91 {
                let object = bytes[i] == 123; let end: UInt8 = object ? 125 : 93; i += 1; space(); var seen = Set<String>()
                if i < bytes.count && bytes[i] == end { i += 1; return }
                while i < bytes.count {
                    if object {
                        try check(bytes[i] == 34, "invalid_json"); let key = try token()
                        try check(seen.insert(key).inserted, "invalid_json"); space(); try check(i < bytes.count && bytes[i] == 58, "invalid_json"); i += 1
                    }
                    try scan(depth + 1); space(); try check(i < bytes.count, "invalid_json")
                    if bytes[i] == end { i += 1; return }
                    try check(bytes[i] == 44, "invalid_json"); i += 1; space()
                }
                throw OpenVoiceFailure("invalid_json")
            }
            while i < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[i]) { i += 1 }
        }
        try scan(0); space(); try check(i == bytes.count, "invalid_json")
        do { let v = try JSONDecoder().decode(OpenVoiceJSON.self, from: data); try bounded(v); return v }
        catch let e as OpenVoiceFailure { throw e }
        catch { throw OpenVoiceFailure("invalid_json") }
    }
}
