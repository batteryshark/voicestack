import Foundation
#if canImport(OSLog)
import OSLog
#endif

@MainActor public extension UtteranceOutcomeLog {
    convenience init(stages: StageDiagnostics) {
        self.init(callToken: { stages.playbackCallToken }, write: { value, call in
            stages.record(.utterance, .complete, callBank: call, utteranceOutcome: value)
        }, segment: { count, call in
            stages.record(.utterance, .complete, audio: CaptureSnapshot([.segmentRollover: Double(count)]),
                callBank: call, segmentEndReason: .durationLimit)
        })
    }
}

public enum DiagnosticStage: String, Codable, Sendable {
    case pushEnrollment, pushSettings, pushReceipt, pushLookup, notificationRoute
    case echo, discard, route, playback, voiceEnded
    case credential, credentialRead, credentialWrite, pairing, health, chief, selection, history, state, events, voices, asr, tts, capture, startUI, captureBuffer, startup, prompt, interrupt, liveProjection, call, probe, utterance, other
}
public enum DiagnosticCategory: String, Codable, Sendable { case begin, ready, complete, failed, malformed, suspended, cancelled, policyGate }
public enum NetworkCloseReason: String, Codable, Sendable { case cleanEnd, cancelled, transport, idleTimeout, pingTimeout, sendLimit, utteranceTimeout, abnormalClose }
public enum NetworkCloseInitiator: String, Codable, Sendable { case client, peer, watchdog }
public enum StreamCancellationCause: String, Codable, Sendable { case pathChange, watchdog, selection, background, explicit, ownerChanged, lifecycle, consumer }
public struct DiagnosticEntry: Codable, Sendable {
    public let time: Date
    public let stage: DiagnosticStage
    public let category: DiagnosticCategory
    public let elapsedMs: Int
    public let status: Int?
    public let protectedData: Bool
    public let audio: CaptureSnapshot?
    public let build: Int?
    public var attempt: UUID?
    public var initiator: NetworkCloseInitiator?
    public var reason: NetworkCloseReason?
    public var cancellationCause: StreamCancellationCause?
    public var turnEndReason: TurnEndReason?
    public var segmentEndReason: RecognitionSegmentEndReason?
    public var routePhase: NotificationRoutePhase?
    public var routeFailure: NotificationRouteFailure?
    public var callEvent: CallDiagnosticEvent?
    public var callEndInitiator: CallEndInitiator?
    public var callEndReason: CallTerminationReason?
    public var reportedRinging: Bool?
    public var reportFailure: IncomingReportFailure?
    public var audioRoute: RouteDiagnostic?
    public var callAuthority: CallAuthorityDiagnostic?
    public var diagnosticCall: Int?
    public var elidedCount: Int?
    public var playbackEvent: PlaybackEvent?
    public var utteranceOutcome: UtteranceOutcomeDiagnostic?
    public var voiceEnded: VoiceEndedDiagnostic?
}

/// Closed numeric schema: never accept device names, UIDs, errors, text or URLs.
public enum CaptureField: String, Sendable {
    case discardCountdown, discardHeld, discardLive
    case segmentRollover
    case epoch, cancelled, engine, tap, activation, permission, interrupted, voiceProcessing
    case category, mode, inputPort, outputPort, sessionRate, inputChannels, outputChannels
    case inputRate, inputCount, inputCommon, inputInterleaved
    case outputRate, outputCount, outputCommon, outputInterleaved
    case requestedRate, requestedCount, requestedCommon, requestedInterleaved
    case actualRate, actualCount, actualCommon, actualInterleaved
    case callbacks, hardwareCallbacks, validBuffers, inputFrames, convertedFrames, conversionErrors, formatChanges, rms, failure
    case configurationChanges, restarts
    case callState, callActivation, callMuted, callEpoch, networkConnected, appActive, chiefSelection
    case streamBytes, streamIdleSeconds
    case providerInstance, coordinatorInstance, deadlineDelayMs, reportErrorCode
    case pushReplay, pushCapacity, pushPolicyAllowed, processID
    case micRMS, mixRMS, playerIdle, speakerRoute, vadOnsets, bargeIns, echoPhase, inputToOutput
    case routeReason, categoryOptions
    case graphGeneration, recoveryBudget
    case activationPending
    case grantGeneration, activeGrantGeneration, pendingGrantGeneration, releasedGrantGeneration
    case bytesReceived, chunksReceived, firstByteMs, requestTotalMs, chunkGapMaxMs, chunkGapP95Ms, chunkGapSamples, chunkGapClipped, chunkGapBucketMs
    case streaming, fullyBuffered, queueDepth, bufferFrames, bufferMs, pendingPCMBytes, sourceFinished
    case playbackPositionFrames, retainedPCMBytes, positionKnown
    case routeHandoffGapMs, routeHandoffGeneration, sourceSilenceCount, dropoutCount, dropoutMaxMs, renderAlignmentUnknown
    case routeHandoffDropped
    case skippedUpToMs
    case starvationCount, starvationMaxMs, gapDurationMs, renderGapCount, renderGapMaxMs, renderFloor, renderThresholdMs
    case playbackActive, sourceRate, playerRate, mixerRate, hardwareRate, vpOutputEnabled, vpBypassed, vpAGC, vpDucking, vpAdvancedDucking, stopCause, utteranceOrdinal
    case diagnosticsDropped
    case renderInvalidBuffers
    case startLatencyMs
}
public struct CaptureSnapshot: Codable, Sendable {
    public let values: [String: Double]
    public init(_ fields: [CaptureField: Double]) { values = Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value.isFinite ? $0.value : 0) }) }
}

/// Only closed enums/numeric codes enter this log. No arbitrary error descriptions, URLs,
/// headers, session identifiers, audio, conversation or tool values can be serialized.
public final class StageDiagnostics: @unchecked Sendable {
    public static let shared = StageDiagnostics()
    private let lock = NSLock()
    private var entries: [DiagnosticEntry] = []
    private struct CallBank {
        let call: Int
        var entries: [DiagnosticEntry] = []
        var sizes: [Int] = []
        var bytes = 0
        var elided = 0
        var elidedAt: Date?
        var markerBuild: Int?
        var markerProtected = true
        var marker: DiagnosticEntry? {
            guard elided > 0 else { return nil }
            return DiagnosticEntry(time: elidedAt ?? Date(), stage: .call, category: .complete, elapsedMs: 0,
                status: nil, protectedData: markerProtected, audio: nil, build: markerBuild,
                callEvent: .elided, diagnosticCall: call, elidedCount: elided)
        }
        var retained: [DiagnosticEntry] { entries + (marker.map { [$0] } ?? []) }
        mutating func append(_ entry: DiagnosticEntry) {
            if entry.callEvent == .elided, let count = entry.elidedCount, count > 0 {
                elided += min(count, Int.max - elided)
                elidedAt = elidedAt ?? entry.time
                markerBuild = entry.build; markerProtected = entry.protectedData
            } else {
                entries.append(entry)
                let size = ((try? JSONEncoder().encode(entry).count) ?? 4096) + 1
                sizes.append(size); bytes += size
            }
            while !entries.isEmpty {
                let markerBytes = marker.flatMap { try? JSONEncoder().encode($0).count }.map { $0 + 1 } ?? 0
                let limit = call == 0 ? 256 : 5000
                if entries.count + (elided > 0 ? 1 : 0) <= limit && bytes + markerBytes + 2 <= 1_048_576 { break }
                // Real closed records fit the protected first200. The fallback
                // also bounds oversized legacy input rather than exceeding cap.
                let index = min(200, entries.count - 1)
                let removed = entries.remove(at: index)
                bytes -= sizes.remove(at: index)
                elided = min(elided, Int.max - 1) + 1
                elidedAt = elidedAt ?? removed.time
                markerBuild = removed.build; markerProtected = removed.protectedData
            }
        }
    }
    // Current + previous call, independent of noise; each bank bounded by both
    // 5000 records and1MiB encoded bytes, protecting first200 + newest + marker.
    private var callCritical: [Int: CallBank] = [0: CallBank(call: 0)]
    private var diagnosticCall = 0
    private let playbackTagLock = NSLock()
    private var playbackTag = 0, playbackDropped = 0
    private let playbackQueue = DispatchQueue(label: "org.example.playback-diagnostics", qos: .utility)
    private let playbackSlots = DispatchSemaphore(value: 128)
    private var destination: URL?
    private var protectedData = true
    private var build: Int?
    public init() {}
    public func configure(file: URL, build: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        destination = file
        self.build = build
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let size = attributes[.size] as? NSNumber,
           size.intValue <= 8 * 1024 * 1024, // Bounded migration input; newly written capped files are far smaller.
           let data = try? Data(contentsOf: file),
           let old = try? JSONDecoder().decode([DiagnosticEntry].self, from: data) {
            entries = Array(old.filter { !Self.isCallCritical($0) || $0.utteranceOutcome != nil }.suffix(256))
            let critical = old.filter(Self.isCallCritical)
            let calls = Set(critical.map { $0.diagnosticCall ?? 0 }).sorted().suffix(2)
            diagnosticCall = calls.last ?? 0
            callCritical = Dictionary(uniqueKeysWithValues: calls.map { call in
                var bank = CallBank(call: call)
                for entry in critical where (entry.diagnosticCall ?? 0) == call { bank.append(entry) }
                return (call, bank)
            })
            if callCritical.isEmpty { callCritical[diagnosticCall] = CallBank(call: diagnosticCall) }
            entries.removeAll { $0.utteranceOutcome != nil && callCritical[$0.diagnosticCall ?? 0] == nil }
            playbackTagLock.lock(); playbackTag = diagnosticCall; playbackTagLock.unlock()
        }
    }
    /// Admission, not late provider-created callbacks or duplicate/rejected
    /// pushes, rotates the two-call history. Integer grouping is local, not an ID.
    public func beginCall() {
        lock.lock()
        diagnosticCall += 1
        playbackTagLock.lock(); playbackTag = diagnosticCall; playbackTagLock.unlock()
        callCritical[diagnosticCall] = CallBank(call: diagnosticCall)
        for call in callCritical.keys.sorted().dropLast(2) { callCritical.removeValue(forKey: call) }
        entries.removeAll { $0.utteranceOutcome != nil && callCritical[$0.diagnosticCall ?? 0] == nil }
        lock.unlock()
        record(.call, .begin, callEvent: .callAdmitted)
    }
    private static func isCallCritical(_ entry: DiagnosticEntry) -> Bool {
        entry.stage == .call || entry.stage == .route || entry.stage == .tts || entry.stage == .playback || entry.callEvent != nil || entry.audioRoute != nil || entry.callAuthority != nil || entry.utteranceOutcome != nil || entry.segmentEndReason != nil
    }
    private func retainedEntries() -> [DiagnosticEntry] {
        // Outcomes live in BOTH bounded stores; export the authoritative bank
        // copy once, without bypassing call-bank elision/rotation limits.
        let general = entries.filter { $0.utteranceOutcome == nil || callCritical[$0.diagnosticCall ?? 0] == nil }
        return (general + callCritical.keys.sorted().flatMap { callCritical[$0]?.retained ?? [] }).sorted { $0.time < $1.time }
    }
    public func availability(_ value: Bool) { lock.lock(); protectedData = value; lock.unlock() }
    public var playbackCallToken: Int { playbackTagLock.lock(); defer { playbackTagLock.unlock() }; return playbackTag }
    /// Never serialize/persist on the player refill path. Bounded pending work;
    /// event time and call ownership are captured now, not when the worker drains.
    public func recordPlayback(_ event: PlaybackEvent, fields: [CaptureField: Double], attempt: UUID? = nil,
                               category: DiagnosticCategory = .complete, callToken: Int? = nil) {
        guard playbackSlots.wait(timeout: .now()) == .success else {
            playbackTagLock.lock(); playbackDropped += 1; playbackTagLock.unlock(); return
        }
        let observed = Date()
        playbackTagLock.lock()
        let call = callToken ?? playbackTag, dropped = playbackDropped; playbackDropped = 0
        playbackTagLock.unlock()
        var values = fields; values[.diagnosticsDropped] = Double(dropped)
        let snapshot = CaptureSnapshot(values)
        playbackQueue.async { [self] in
            defer { playbackSlots.signal() }
            record(.playback, category, audio: snapshot, attempt: attempt, playbackEvent: event, callBank: call, observedAt: observed)
        }
    }
    /// Offline tests/export handoff only; never call from the render/refill path.
    public func flushPlaybackDiagnostics() { playbackQueue.sync {} }
    public func record(_ stage: DiagnosticStage, _ category: DiagnosticCategory, since: Date = Date(), status: Int? = nil, audio: CaptureSnapshot? = nil, attempt: UUID? = nil, initiator: NetworkCloseInitiator? = nil, reason: NetworkCloseReason? = nil, cancellationCause: StreamCancellationCause? = nil, turnEndReason: TurnEndReason? = nil, routePhase: NotificationRoutePhase? = nil, routeFailure: NotificationRouteFailure? = nil, callEvent: CallDiagnosticEvent? = nil, callEndInitiator: CallEndInitiator? = nil, callEndReason: CallTerminationReason? = nil, reportedRinging: Bool? = nil, reportFailure: IncomingReportFailure? = nil, audioRoute: RouteDiagnostic? = nil, callAuthority: CallAuthorityDiagnostic? = nil, playbackEvent: PlaybackEvent? = nil, callBank: Int? = nil, observedAt: Date? = nil, utteranceOutcome: UtteranceOutcomeDiagnostic? = nil, voiceEnded: VoiceEndedDiagnostic? = nil, segmentEndReason: RecognitionSegmentEndReason? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let callBank, callCritical[callBank] == nil { return } // Never resurrect a third/expired bank.
        var entry = DiagnosticEntry(time: observedAt ?? Date(), stage: stage, category: category,
            elapsedMs: max(0, Int(Date().timeIntervalSince(since) * 1000)), status: status, protectedData: protectedData, audio: audio, build: build, attempt: attempt, initiator: initiator, reason: reason, cancellationCause: cancellationCause, turnEndReason: turnEndReason, routePhase: routePhase, routeFailure: routeFailure, callEvent: callEvent, callEndInitiator: callEndInitiator, callEndReason: callEndReason, reportedRinging: reportedRinging, reportFailure: reportFailure, audioRoute: audioRoute, callAuthority: callAuthority, playbackEvent: playbackEvent)
        entry.utteranceOutcome = utteranceOutcome
        entry.voiceEnded = voiceEnded
        entry.segmentEndReason = segmentEndReason
        if Self.isCallCritical(entry) {
            let call = callBank ?? diagnosticCall
            entry.diagnosticCall = call
            callCritical[call, default: CallBank(call: call)].append(entry)
            if utteranceOutcome != nil { entries.append(entry) }
        } else { entries.append(entry) }
#if os(iOS)
        // Closed, sanitized metadata only: never error text, credentials, URLs or conversation.
        Logger(subsystem: "org.example.voicestack", category: "Stages").notice("build=\(self.build ?? 0) stage=\(stage.rawValue, privacy: .public) category=\(category.rawValue, privacy: .public) status=\(status ?? 0) protectedData=\(self.protectedData)")
#endif
        // This bound applies ONLY to the noisy/general ring. Whole-call banks
        // above are separate and cannot be evicted by events/state/credentialRead.
        if entries.count > 256 {
            let critical: (DiagnosticEntry) -> Bool = { entry in
                entry.category == .failed || entry.category == .malformed || entry.category == .suspended ||
                [.startUI, .capture, .captureBuffer, .asr, .prompt, .tts, .startup, .events, .call, .route, .utterance, .discard, .notificationRoute].contains(entry.stage)
            }
            if entries.filter(critical).count <= 128, let index = entries.firstIndex(where: { !critical($0) }) { entries.remove(at: index) }
            else { entries.removeFirst() }
        }
        if let destination, let bytes = try? JSONEncoder().encode(retainedEntries()) {
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bytes.write(to: destination, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
#if os(iOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
#endif
        }
    }
    public func export() -> String {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(retainedEntries())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    public func exportGeneral() -> String {
        lock.lock(); defer { lock.unlock() }
        return (try? JSONEncoder().encode(entries)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    public static func code(_ error: Error) -> Int {
        if let failure = error as? CredentialFailure { return Int(failure.status) }
        if case let HTTPError.status(status, _) = error { return status }
        return (error as NSError).code
    }
    public static func stage(_ path: String) -> DiagnosticStage {
        if path == "/v1/push/enrollment" { return .pushEnrollment }
        if path == "/v1/push/settings" { return .pushSettings }
        if path == "/v1/push/events" { return .pushReceipt }
        if path.hasPrefix("/v1/push/reachouts/") { return .pushLookup }
        if path == "/v1/pair" || path == "/v1/pair/ack" { return .pairing }
        if path == "/v1/health" { return .health }
        if path == "/v1/chief" { return .chief }
        if path == "/v1/selection" { return .selection }
        if path.contains("/messages?") { return .history }
        if path.hasSuffix("/state") { return .state }
        if path.hasSuffix("/events") { return .events }
        if path.hasSuffix("/prompt") { return .prompt }
        if path.hasSuffix("/interrupt") { return .interrupt }
        if path == "/tts/v1/voices" { return .voices }
        return .other
    }
}
