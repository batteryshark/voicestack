import AVFoundation
import Foundation
import UIKit

/// Small tap-safe provenance latch. No audio, text or actor references cross it.
private final class CaptureOriginLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var rendering = false, safe = false
    func setRendering(_ value: Bool) { lock.lock(); rendering = value; lock.unlock() }
    func setSafe(_ value: Bool) { lock.lock(); safe = value; lock.unlock() }
    func snapshot() -> (Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (rendering, safe) }
}

/// Only armed after the quiet real-mic phase; the hardware tap remains the sole producer.
private final class VoiceProbeFixtureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fixture: TapSpeechFixture?
    private var roomFixture: VoiceProbeRoomFixture?
    func arm(_ format: AVAudioFormat) throws {
        if ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnMidThought") {
            let room = try VoiceProbeRoomFixture(format: format)
            for name in ["voice-turn-first.wav", "voice-turn-second.wav"] {
                try? FileManager.default.removeItem(at: URL.documentsDirectory.appendingPathComponent(name))
            }
            lock.lock(); defer { lock.unlock() }; roomFixture = room
            return
        }
        let fixture = try TapSpeechFixture(format: format)
        try? FileManager.default.removeItem(at: URL.documentsDirectory.appendingPathComponent("phone-loop.wav"))
        lock.lock(); defer { lock.unlock() }; self.fixture = fixture
    }
    func replace(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }; fixture?.replace(buffer); roomFixture?.replace(buffer)
    }
}

/// Substitutes speech only; the 2.5s thinking gap preserves the real VP input
/// sample-for-sample, including buffers straddling either phrase boundary.
private final class VoiceProbeRoomFixture {
    private let first: [Float], second: [Float], schedule: SpeechGapSchedule
    private let format: AVAudioFormat
    private let digital = ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnDigitalGap")
    private var offset: Int
    private var gapCount = 0
    init(format: AVAudioFormat) throws {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw ClientError("Probe requires float noninterleaved tap") }
        self.format = format
        func samples(_ name: String) throws -> [Float] {
            let data = try Data(contentsOf: URL.documentsDirectory.appendingPathComponent(name))
            let (pcm, rate) = try WAV.decodeToS16Mono(data)
            return resampleS16(pcm, from: rate, to: Int(format.sampleRate)).withUnsafeBytes {
                $0.bindMemory(to: Int16.self).map { Float($0) / 32768 }
            }
        }
        first = try samples("voice-turn-first.wav"); second = try samples("voice-turn-second.wav")
        schedule = SpeechGapSchedule(firstFrames: first.count, gapFrames: Int(format.sampleRate * 2.5), secondFrames: second.count)
        offset = -Int(format.sampleRate) // first second is real microphone too
    }
    func replace(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.isEqual(format), let channels = buffer.floatChannelData else { return }
        for i in 0..<Int(buffer.frameLength) {
            switch schedule.source(at: offset) {
            case .first(let index):
                for c in 0..<Int(format.channelCount) { channels[c][i] = first[index] }
            case .second(let index):
                for c in 0..<Int(format.channelCount) { channels[c][i] = second[index] }
            case .gap:
                if gapCount == 0 { VoiceTrace.shared.event("fixture.gap.begin", ["source": digital ? "digitalSilence" : "realMicrophone", "rate": String(format.sampleRate)]) }
                // Intentionally do not write any channel in the real-room case.
                if digital { for c in 0..<Int(format.channelCount) { channels[c][i] = 0 } }
                gapCount += 1
                if gapCount == schedule.gapFrames {
                    VoiceTrace.shared.event("fixture.gap.end", ["source": digital ? "digitalSilence" : "realMicrophone", "frames": String(gapCount), "rate": String(format.sampleRate)])
                }
            case .finished: break // real microphone before/after the two phrases
            }
            offset += 1
        }
    }
}

/// CallKit is the only activation authority in call mode. Standalone is probe-only.
@MainActor
final class AudioSessionCoordinator {
    private var routing = LiveRouteSwitch(defaultSpeaker: SpeakerRoutePreference.load())
    private var routeAttempt = 0
    private var pendingRoute: PhoneAudioRoute?
    private var routeRecovery = RouteRecoveryTracker()
    var onRouteRecovery: ((RouteRecoveryContext, UInt) -> Void)?
    var onRouteError: ((String) -> Void)?
    /// Setter is a deliberate in-app built-in choice, never a system-route observation.
    var speaker: Bool {
        get { routing.policy.defaultSpeaker }
        set {
            routing.policy.chooseSpeaker(newValue)
            let probeFlags = ["-FVVoiceTurnProbe", "-FVSpeakerEchoProbe", "-FVDeviceProbe", "-FVSimulatorProof"]
            if !PhoneLoopProbe.enabled && !ProcessInfo.processInfo.arguments.contains(where: probeFlags.contains) {
                SpeakerRoutePreference.save(newValue)
            }
        }
    }
    var onRecovery: ((NativeAudioEvent) -> Void)?
    private(set) var active = false
    private(set) var interrupted = false
    var call: CallLifecycle?
    var onRoute: (() -> Void)?
    var onDuplexRouteChange: (() -> Void)?
    var mayRunMedia: Bool { call.map { $0.mayRunMedia && !interrupted } ?? true }
    private var observers: [NSObjectProtocol] = []
    init() {
        if ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnProbe") {
            speaker = !ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnReceiver")
            PhoneLoopProbe.install()
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            let resume = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0) & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0
            Task { @MainActor in self?.interrupted = !ended; self?.onRecovery?(ended ? .interruptionEnded(resume: resume) : .interruptionBegan) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                let current = self.currentPhoneRoute
                let context = self.routeRecovery.notification(route: current, reason: reason, now: ProcessInfo.processInfo.systemUptime)
                self.recordRoute(RouteDiagnostic(event: .notification, before: current, after: current), reason: reason, context: context)
                // No output override here: .override can be the SYSTEM call UI's
                // speaker/receiver choice, not ours. Observe it before recovery.
                let systemSelection = reason == AVAudioSession.RouteChangeReason.override.rawValue
                    || reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
                    || reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                    || reason == AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue
                    || context.deliberate // Includes a proved reason-3 built-in override clear.
                // A user override/external selection before the first grant or
                // during Hold must also consume the saved one-shot preference.
                let pendingHumanChoice = self.call?.hasCall == true &&
                    (reason == AVAudioSession.RouteChangeReason.override.rawValue || context.deliberate || !current.isBuiltIn)
                if (self.active && self.mayRunMedia && (systemSelection || !current.isBuiltIn)) || pendingHumanChoice {
                    self.routing.observe(current, systemSelection: systemSelection)
                    if let expected = self.pendingRoute, current != expected {
                        self.routeAttempt += 1; self.pendingRoute = nil // system choice supersedes our verifier
                    }
                }
                self.onDuplexRouteChange?(); self.onRoute?(); self.onRouteRecovery?(context, reason)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.onRecovery?(.mediaReset) } })
    }
    func permission() async throws {
        let session = AVAudioSession.sharedInstance()
        var allowed = session.recordPermission == .granted
        if session.recordPermission == .undetermined { allowed = await withCheckedContinuation { c in session.requestRecordPermission { c.resume(returning: $0) } } }
        guard allowed else { throw ClientError("Microphone access denied or restricted. Allow it in iPhone Settings; conversation remains available.") }
    }
    func configure() throws {
        let session = AVAudioSession.sharedInstance()
        // HFP gives AirPods their own microphone. A2DP + built-in mic is not
        // duplex-safe; voiceChat must not opt into that output-only profile.
        let options: AVAudioSession.CategoryOptions = [.allowBluetooth]
        if session.category != .playAndRecord || session.mode != .voiceChat || session.categoryOptions != options {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        }
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(0.02)
    }
    func activate() throws {
        if call != nil {
            guard mayRunMedia else { throw CancellationError() }
            return
        }
        // The only non-CallKit path: explicitly requested device/simulator fixture probes.
        guard DeviceAudioProbe.enabled || ProcessInfo.processInfo.arguments.contains("-FVSimulatorProof") else { throw ClientError("CallKit activation required") }
        beginCallRoute()
        try configure()
        try AVAudioSession.sharedInstance().setActive(true)
        active = true
        applyInitialSpeakerPreference() // Standalone probe's explicit activation only; normal calls returned above.
    }
    var currentPhoneRoute: PhoneAudioRoute {
#if DEBUG && targetEnvironment(simulator)
        // Offline screenshot fixture only; never activates or changes an audio route.
        if PolishPreview.enabled { return PolishPreview.mode == "main-phone" || PolishPreview.mode == "chief-phone" ? .phone : .speaker }
#endif
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        if outputs.contains(where: { [.bluetoothHFP, .bluetoothLE, .bluetoothA2DP].contains($0) }) { return .bluetooth }
        if outputs.contains(where: { [.headphones, .usbAudio, .lineOut].contains($0) }) { return .headphones }
        if outputs.contains(.builtInSpeaker) { return .speaker }
        if outputs.contains(.builtInReceiver) { return .phone }
        return .external
    }
    var currentDuplexSafe: Bool {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        return currentPhoneRoute.duplexSafe(hasInput: !inputs.isEmpty,
                                           inputIsBuiltIn: inputs.contains { $0.portType == .builtInMic })
    }
    func beginCallRoute() {
        routeAttempt += 1; pendingRoute = nil; routing.policy.begin()
        routeRecovery.begin(route: currentPhoneRoute)
    }
    func engineRecoveryContext() -> RouteRecoveryContext {
        routeRecovery.engine(route: currentPhoneRoute, now: ProcessInfo.processInfo.systemUptime)
    }
    func retryRecoveryContext() -> RouteRecoveryContext {
        let current = currentPhoneRoute
        routing.policy.observe(current) // Retry follows the user's current system-selected route.
        return routeRecovery.retry(route: current, now: ProcessInfo.processInfo.systemUptime)
    }
    func toggleLiveRoute() throws {
        routeAttempt += 1
        let owner = routeAttempt
        var transaction = routing
        let current = currentPhoneRoute
        let context = LiveRouteSwitch.gate(active: active, mayRunMedia: mayRunMedia, current: current) == .allowed
            ? routeRecovery.expect(current == .speaker ? .phone : .speaker, now: ProcessInfo.processInfo.systemUptime) : nil
        let expected: PhoneAudioRoute
        do { expected = try transaction.toggle(active: active, mayRunMedia: mayRunMedia, current: { self.currentPhoneRoute }, apply: { speaker in
            let session = AVAudioSession.sharedInstance()
            // Live Speaker is a CLEARABLE override, never .defaultToSpeaker.
            // Otherwise iOS call-screen .none still resolves to Speaker.
            let options: AVAudioSession.CategoryOptions = [.allowBluetooth]
            if session.category != .playAndRecord || session.mode != .voiceChat || session.categoryOptions != options {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            }
            try session.overrideOutputAudioPort(speaker ? .speaker : .none)
        }, diagnostic: { self.recordRoute($0, context: context) }) }
        catch { if let context { routeRecovery.cancel(context) }; throw error }
        routing = transaction
        pendingRoute = expected
        onDuplexRouteChange?(); onRoute?()
        // One bounded observation, never a retry or route reassertion. The label
        // always reads hardware. Failure remains visible without ending the call.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            let current = self.currentPhoneRoute
            let superseded = self.routeAttempt != owner || !self.active || !self.mayRunMedia
            let result: RouteResult = superseded ? .superseded : current == expected ? .confirmed : .notChanged
            self.recordRoute(RouteDiagnostic(event: .toggle, before: expected, after: current,
                action: expected == .speaker ? .speaker : .receiver, result: result), context: context)
            if self.routeAttempt == owner { self.pendingRoute = nil }
            if result == .notChanged { self.onRouteError?(RouteSwitchError.failed.localizedDescription) }
            self.onRoute?()
        }
    }
    func refreshProximity(activeCall: Bool) {
        UIDevice.current.isProximityMonitoringEnabled = activeCall && active && mayRunMedia && currentPhoneRoute == .phone
    }
    func activationObserved(_ granted: Bool) {
        active = granted
        if granted { interrupted = false }
        else { routeAttempt += 1; pendingRoute = nil }
        if granted, mayRunMedia { applyInitialSpeakerPreference() }
        let current = currentPhoneRoute
        recordRoute(RouteDiagnostic(event: .activation, gate: granted ? .allowed : .inactive, before: current, after: current))
        onDuplexRouteChange?(); onRoute?()
    }
    private func applyInitialSpeakerPreference() {
        guard active, mayRunMedia else { return }
        let before = currentPhoneRoute
        guard routing.policy.activationOverride(current: before) == true else { return }
        let context = routeRecovery.expect(.speaker, now: ProcessInfo.processInfo.systemUptime, source: .initialPreference)
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            recordRoute(RouteDiagnostic(event: .activation, before: before, after: currentPhoneRoute, action: .speaker, result: .applied), context: context)
        } catch {
            routeRecovery.cancel(context)
            recordRoute(RouteDiagnostic(event: .activation, before: before, after: currentPhoneRoute, action: .speaker, result: .failed), context: context)
        } // Optional preference failure is not a call/media failure and is never retried.
    }
    func prepareEngineRoute() throws {
        guard active, mayRunMedia else { throw RouteSwitchError.unavailable }
        let session = AVAudioSession.sharedInstance(), current = currentPhoneRoute
        if current.isBuiltIn {
            let options: AVAudioSession.CategoryOptions = [.allowBluetooth]
            if session.category != .playAndRecord || session.mode != .voiceChat || session.categoryOptions != options {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            }
        }
        recordRoute(RouteDiagnostic(event: .engine, before: current, after: currentPhoneRoute))
    }
    private func recordRoute(_ value: RouteDiagnostic, reason: UInt? = nil, context: RouteRecoveryContext? = nil) {
        let session = AVAudioSession.sharedInstance()
        let known: [AVAudioSession.Port] = [.builtInMic, .builtInSpeaker, .builtInReceiver, .headphones, .headsetMic, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .usbAudio, .airPlay, .lineIn, .lineOut]
        let outputs = session.currentRoute.outputs.reduce(0) { bits, port in
            bits | (known.firstIndex(of: port.portType).map { 1 << $0 } ?? (1 << 15))
        }
        var fields: [CaptureField: Double] = [.activation: active ? 1 : 0,
            .callActivation: call?.activationGranted == true ? 1 : 0, .interrupted: interrupted ? 1 : 0,
            .outputPort: Double(outputs), .categoryOptions: Double(session.categoryOptions.rawValue)]
        if let reason { fields[.routeReason] = Double(reason) }
        var entry = value; entry.recovery = context
        StageDiagnostics.shared.record(.route, [.failed, .rejected, .notChanged].contains(value.result) ? .failed : .complete,
            audio: CaptureSnapshot(fields), audioRoute: entry)
    }
    func deactivate() {
        guard call == nil else { return } // relinquish graph ownership, never deactivate a CallKit session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); active = false
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Bounded owned-fixture evidence only. Device builds do not contain this type or its paths.
@MainActor final class SimulatorAudioProof {
    static let shared = SimulatorAudioProof()
    private var active = false
    private var trace = Data(), output = Data()
    private var inputFrames = 0, renderFrames = 0, rate = 0, callbacks = 0, entries = 0
    private var began = Date()
    private var testSession: String?
    func identity(_ keychain: KeychainCredential) throws -> String {
        if let testSession { return testSession }
        let url = URL.documentsDirectory.appendingPathComponent("proof-auth.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let config = object as? [String: String], Set(config.keys) == ["sessionID", "credential"],
              let session = config["sessionID"], session.range(of: "^ses_[a-zA-Z0-9]{1,100}$", options: .regularExpression) != nil,
              let credential = config["credential"], credential.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw ClientError("Isolated Simulator identity required; chief fallback forbidden")
        }
        // A fresh owned Simulator has its own Keychain, never the phone's identity.
        // Staging is permitted only after the external controller creates a session-scoped record.
        try keychain.save(credential)
        try FileManager.default.removeItem(at: url)
        testSession = session
        return session
    }
    func begin() throws {
        trace = Data(); output = Data(); inputFrames = 0; renderFrames = 0
        callbacks = 0; rate = 0; entries = 0; began = Date(); active = true
        event("fixture.begin")
        try converterChecks()
    }
    /// Execute real production conversion on the installed iOS runtime, no microphone/network.
    private func converterChecks() throws {
        for channels: AVAudioChannelCount in [1, 2] {
            for interleaved in [false, true] {
                let ingress = CaptureIngress()
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: channels, interleaved: interleaved)!
                var zeroFrames = 0, signalFrames = 0
                for section in 0..<2 {
                    for _ in 0..<20 {
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
                        buffer.frameLength = 960
                        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                            let values = audio.mData!.assumingMemoryBound(to: Float.self)
                            for i in 0..<Int(audio.mDataByteSize)/4 { values[i] = section == 0 ? 0 : Float(sin(Double(i) * 0.07) * 0.2) }
                        }
                        for frame in try ingress.consume(buffer, hardware: false) {
                            if section == 0 {
                                guard TurnTaker.rms(frame) == 0 else { throw ClientError("Converter zero regression") }
                                zeroFrames += 1
                            } else if TurnTaker.rms(frame) > 0.01 { signalFrames += 1 }
                        }
                    }
                    guard ingress.snapshot().ready else { throw ClientError("Converter quiet readiness regression") }
                }
                guard zeroFrames >= 18, signalFrames >= 18 else { throw ClientError("Converter framing regression") }
                event("converter.verified", ["rate": 48000, "channels": Double(channels), "interleaved": interleaved ? 1 : 0,
                      "zeroFrames": Double(zeroFrames), "signalFrames": Double(signalFrames), "rms": ingress.snapshot().rms])
            }
        }
    }
    func event(_ stage: String, _ metrics: [String: Double] = [:]) {
        guard active, entries < 4000 else { return }
        let row: [String: Any] = ["stage": stage, "unixMs": Date().timeIntervalSince1970 * 1000,
                                  "elapsedMs": Date().timeIntervalSince(began) * 1000, "metrics": metrics]
        if let bytes = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys) {
            trace.append(bytes); trace.append(10); entries += 1
        }
    }
    func input(_ pcm: Data) {
        guard active else { return }
        inputFrames += 1
        if inputFrames == 1 || inputFrames % 10 == 0 {
            event("capture.framed", ["frames20ms": Double(inputFrames), "rms": TurnTaker.rms(pcm)])
        }
    }
    nonisolated static func monoPCM(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let samples = buffer.floatChannelData, buffer.format.channelCount > 0 else { return Data() }
        let channels = Int(buffer.format.channelCount)
        var values = [Int16](repeating: 0, count: Int(buffer.frameLength))
        for i in values.indices {
            var sum: Float = 0
            for channel in 0..<channels { sum += samples[channel][i] }
            let x = sum / Float(channels)
            values[i] = x.isFinite ? Int16(clamping: Int(max(-1, min(1, x)) * 32767)).littleEndian : 0
        }
        return values.withUnsafeBytes { Data($0) }
    }
    func render(_ pcm: Data, rate: Int, rms: Double) {
        guard active, Date().timeIntervalSince(began) <= 180 else { return }
        guard self.rate == 0 || self.rate == rate else { event("render.rateChanged"); return }
        if self.rate == 0 { event("render.begin", ["rate": Double(rate)]) }
        self.rate = rate
        guard output.count + pcm.count <= rate * 2 * 180 else { return }
        output.append(pcm); renderFrames += pcm.count / 2
        if rms > 0.002 { event("render.nonzero", ["samples": Double(renderFrames), "rms": rms]) }
    }
    func played() { callbacks += 1; event("player.dataPlayedBack", ["callbacks": Double(callbacks)]) }
    func finish() {
        guard active else { return }
        event("fixture.end", ["inputFrames20ms": Double(inputFrames), "renderSamples": Double(renderFrames), "playedCallbacks": Double(callbacks)])
        active = false
        let root = URL.documentsDirectory
        let files: [(String, Data)] = [("proof-trace.jsonl", trace),
            ("proof-rendered.wav", WAV.encode(output, sampleRate: max(1, rate))),
            ("proof-stages.json", Data(StageDiagnostics.shared.export().utf8))]
        for (name, data) in files {
            let url = root.appendingPathComponent(name)
            do { try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            catch { /* Evidence absence fails the external proof gate, never voice lifecycle. */ }
        }
        output = Data(); trace = Data()
    }
}
#endif

@MainActor private final class PlayerDiagnosticObservation {
    var queue = PlaybackQueueCounter()
    var moreExpected = true
    var completed = false
}

@MainActor
final class IOSAudio: AudioInput, AudioOutput, LevelReporting, PlaybackRepairReporting, VoiceTurnProbeInput, DuplexReporting, CaptureOriginReporting {
    private var latestMicRMS = 0.0
    var onCaptureState: ((VoiceCaptureState) -> Void)?
    var onDuplexChange: (() -> Void)?
    private let captureOrigin = CaptureOriginLatch()
    private(set) var lastCaptureRendered = false
    private(set) var lastCaptureDuplexSafe = false
    private let voiceProbeFixture = VoiceProbeFixtureBox()
    func probeInterjection() throws {
        guard ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnProbe"), let format = requestedFormat else { throw ClientError("Probe not enabled") }
        try voiceProbeFixture.arm(format)
    }
    var onPlaybackRepair: (() -> Void)?
    var onPCM: ((Data) -> Void)?
    func discardPendingAudio() { ingressState?.discardPendingAudio() }
    var onFailure: ((Error) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onRecoveryRequest: ((NativeAudioEvent) -> Void)?
    var duplexSafe: Bool { !usingFixture && coordinator.currentDuplexSafe }
    private var graphAdmission = CaptureGraphAdmission()
    var captureGraphReady: Bool { graphAdmission.ready }
    private var voiceProcessingReady = false
    let coordinator: AudioSessionCoordinator
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let capture = CaptureLifecycle()
    private var capturing: Bool { capture.capturing }
    private var tapInstalled = false
    private var outputTapInstalled = false
    private var playerAttached = false
    private var epoch = 0
    private var recoverableEpochs: Set<Int> = []
    private var playbackQueue = PlaybackBufferScheduler()
    private var playbackContinuity: PlaybackContinuity?
    private var playbackObservation: PlayerDiagnosticObservation?
    private var resumeRetainedPlayback: (() throws -> Void)?
    private var installedIO: [RouteIOFormat] = []
    private var observedRoute: PhoneAudioRoute = .external
    private var scheduled: Int { playbackQueue.depth }
    private var playbackActive = false
    private var playbackAttempt: UUID?
    private var playbackOrdinal = 0
    private let renderDropouts = RenderDropoutMeter()
    private let sourceSignals = PlaybackSignalMeter()
    private var lastVPFields: [CaptureField: Double] = [:]
    private var lastVPSample = -Double.infinity
    private var ingressState: CaptureIngress?
    private var requestedFormat: AVAudioFormat?
    private var capturedFrames = 0
    var onProbeEvent: ((String) -> Void)?
    private var configurationObserver: NSObjectProtocol?
    private(set) var configurationChanges = 0
    private(set) var restartCount = 0
    private var recoveryTask: Task<Void, Never>?
    private var recoveryJob = 0
    private var recoveryBudget = RouteRecoveryBudget()
    private var recoveryCallEpoch: Int?
    private var pendingRecovery: RouteRecoveryContext?
    var onRoutePaused: (() -> Void)?
    var routeRecoveryPaused: Bool { recoveryBudget.paused }
    private var repairRequired = false
    private var graphGeneration = 0
    private var inputHandler: ((AVAudioPCMBuffer) -> Void)?
    private var renderHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var usingFixture = false
    /// Device-probe-only fault injection into the real engine/notification recovery path.
    func probeConfigurationChange() {
        guard DeviceAudioProbe.enabled else { return }
        recordPlayback(.engineStop, [.stopCause: Double(PlaybackStopCause.probe.rawValue)])
        engine.stop()
        onProbeEvent?("forcedEngineStop")
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }
    func recordLiveness() { snapshot(.complete) }
    func probeMetrics() -> [String: Any] {
        let s = AVAudioSession.sharedInstance(), c = ingressState?.snapshot() ?? CaptureIngress.Counts()
        let f = engine.inputNode.outputFormat(forBus: 0)
        return ["engine": engine.isRunning, "callbacks": c.callbacks, "hardwareCallbacks": c.hardwareCallbacks,
                "rms": c.rms, "ready": c.ready, "rate": f.sampleRate, "channels": f.channelCount,
                "inputPorts": s.currentRoute.inputs.map { $0.portType.rawValue },
                "outputPorts": s.currentRoute.outputs.map { $0.portType.rawValue },
                "voiceProcessing": engine.inputNode.isVoiceProcessingEnabled,
                "configurationChanges": configurationChanges, "restarts": restartCount]
    }
#if DEBUG && targetEnvironment(simulator)
    private var fixtureTask: Task<Void, Never>?
    private let proof = SimulatorAudioProof.shared
#endif
    init(coordinator: AudioSessionCoordinator) {
        self.coordinator = coordinator
        coordinator.onDuplexRouteChange = { [weak self] in
            guard let self else { return }
            self.captureOrigin.setSafe(self.duplexSafe)
            self.onDuplexChange?()
        }
        coordinator.onRecovery = { [weak self] resume in
            guard let self else { return }
            // Controller owns ASR/draft lifecycle. A reset cannot splice discontinuous audio into it.
            if case .routeChanged = resume {
                self.scheduleRecovery(self.capture.generation)
            } else { self.onRecoveryRequest?(resume) }
        }
        coordinator.onRouteRecovery = { [weak self] context, reason in
            guard let self else { return }
            if self.playbackActive { self.recordPlayback(.routeDuringPlayback, [.graphGeneration: Double(context.generation)]) }
            self.recordVoiceProcessing(force: true)
            let current = self.coordinator.currentPhoneRoute
            let rebuild = RouteContinuity.needsRebuild(before: self.installedIO, after: self.ioFormats,
                previous: self.observedRoute, current: current, reason: reason,
                configurationChanged: false, running: self.engine.isRunning,
                active: self.coordinator.active && self.coordinator.mayRunMedia)
            if self.playbackActive, current != self.observedRoute {
                self.sourceSignals.beginHandoff(generation: context.generation,
                    now: ProcessInfo.processInfo.systemUptime)
            }
            self.observedRoute = current
            if rebuild { self.scheduleRecovery(self.capture.generation, context: context) }
            // Same-format built-in changes keep taps, generation and player intact.
            else { self.recordRecovery(context, .confirmed) }
        }
    }
    private var ioFormats: [RouteIOFormat] {
        [engine.inputNode.inputFormat(forBus: 0), engine.inputNode.outputFormat(forBus: 0),
         engine.outputNode.inputFormat(forBus: 0), engine.outputNode.outputFormat(forBus: 0)].map {
            RouteIOFormat(rate: $0.sampleRate, channels: $0.channelCount,
                          common: $0.commonFormat.rawValue, interleaved: $0.isInterleaved)
        }
    }
    func start() async throws {
        guard coordinator.mayRunMedia else { throw CancellationError() }
        if !capturing { onCaptureState?(.starting) }
        if recoveryCallEpoch != coordinator.call?.epoch {
            recoveryBudget = RouteRecoveryBudget(); recoveryCallEpoch = coordinator.call?.epoch
        }
        guard !recoveryBudget.paused else { throw ClientError(RouteRecoveryNotice.paused) }
        if !capturing { configurationChanges = 0; restartCount = 0 }
        try await capture.start(permission: { try await self.coordinator.permission() },
            activate: { try self.coordinator.activate() }, open: { owner in try self.open(owner) },
            close: { self.close() }, deactivate: { self.coordinator.deactivate() }, ready: { owner in
                // Permission + running engine + valid converted frame flow, even in quiet.
                // Signal amplitude belongs to RMS/VAD, never device readiness.
                let deadline = Date().addingTimeInterval(5)
                while self.capture.admits(owner) && !Task.isCancelled {
                    if self.engine.isRunning && self.ingressState?.snapshot().ready == true && self.graphAdmission.ready {
                        self.snapshot(.ready); self.onCaptureState?(.running); return
                    }
                    guard Date() < deadline else {
                        self.snapshot(.failed)
                        throw ClientError(self.ingressState?.snapshot().failureMessage ?? "Microphone capture was cancelled")
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                throw CancellationError()
            })
    }
    private func open(_ owner: Int) throws {
        graphAdmission.installed(graphGeneration)
        engine = AVAudioEngine(); player = AVAudioPlayerNode()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.capture.generation == owner else { return }
                self.configurationChanges += 1
                // Own player connections can also post a configuration notice.
                // A still-running engine with identical installed I/O is intact.
                if self.engine.isRunning && self.installedIO == self.ioFormats { return }
                self.onProbeEvent?("configurationChange")
                self.snapshot(.begin)
                self.scheduleRecovery(owner, forceRepair: true)
            }
        }
        ingressState = CaptureIngress()
        capturedFrames = 0
        engine.attach(player)
        playerAttached = true
        var fixture: AVAudioFile?
#if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-FVSimulatorProof") {
            // Fixed sandbox path: no argv secret, no room microphone, no prepared transcript.
            fixture = try AVAudioFile(forReading: URL.documentsDirectory.appendingPathComponent("proof-input.wav"))
            try proof.begin()
        }
#endif
        usingFixture = fixture != nil
        captureOrigin.setSafe(duplexSafe)
        if fixture == nil {
            try coordinator.prepareEngineRoute()
            do {
                // Enabling VP on the IO node enables both sides of this engine.
                // Player -> mixer -> VP output is the AEC render reference;
                // the input-node tap below reads the VP-processed microphone.
                try engine.inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingReady = engine.inputNode.isVoiceProcessingEnabled && engine.outputNode.isVoiceProcessingEnabled
            }
            catch { voiceProcessingReady = false }
        } else { voiceProcessingReady = false }
        recordVoiceProcessing(force: true)
        let input = engine.inputNode
        let hardware = fixture?.processingFormat ?? input.outputFormat(forBus: 0)
#if DEBUG && targetEnvironment(simulator)
        proof.event("capture.format", ["sampleRate": hardware.sampleRate, "channels": Double(hardware.channelCount), "generation": Double(owner), "interleaved": hardware.isInterleaved ? 1 : 0])
#endif
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw ClientError("Unsupported microphone hardware format") }
        requestedFormat = hardware
        if PhoneLoopProbe.enabled && fixture == nil { try PhoneLoopProbe.shared.loadFixture(hardware) }
        if voiceProcessingReady { engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardware) }
        installInputHandler(owner, hardware: fixture == nil)
        let ingress = inputHandler!
        if fixture == nil {
            input.installTap(onBus: 0, bufferSize: 960, format: hardware) { buffer, _ in ingress(buffer) }
            tapInstalled = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        installRenderHandler(owner)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: renderHandler!)
        outputTapInstalled = true
        if voiceProcessingReady { engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardware) }
        engine.prepare()
        try engine.start()
        installedIO = ioFormats; observedRoute = coordinator.currentPhoneRoute
        recordPlayback(.engineStart)
        if engine.isRunning { player.play() }
        snapshot(.begin)
        onProbeEvent?("engineStarted")
        if PhoneLoopProbe.enabled || ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnProbe") {
            let session = AVAudioSession.sharedInstance()
            VoiceTrace.shared.event("audio.started", ["inputPorts": session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ","),
                "outputPorts": session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","), "rate": String(hardware.sampleRate),
                "voiceProcessing": String(voiceProcessingReady), "duplexSafe": String(duplexSafe), "engine": String(engine.isRunning)])
        }
        if DeviceAudioProbe.enabled && ProcessInfo.processInfo.arguments.contains("-FVRecovery") {
            probeConfigurationChange()
        }
#if DEBUG && targetEnvironment(simulator)
        if let fixture {
            fixtureTask = Task { @MainActor [weak self] in
                do {
                    // Wall-clock pacing preserves the production pause/noise/endpoint semantics.
                    let began = Date()
                    while let self, self.capture.admits(owner), !Task.isCancelled,
                          Date().timeIntervalSince(began) < 175 {
                        let buffer = try CaptureConversion.fixtureBuffer(fixture)
                        ingress(buffer)
                        try await Task.sleep(nanoseconds: UInt64(Double(buffer.frameLength) / hardware.sampleRate * 1_000_000_000))
                    }
                } catch is CancellationError {} catch { self?.onFailure?(error) }
            }
        }
#endif
    }
    private func installInputHandler(_ owner: Int, hardware isHardware: Bool) {
        let framing = ingressState!
        let substitution = PhoneLoopProbe.enabled && isHardware ? PhoneLoopProbe.shared.fixture : nil
        let graph = graphGeneration
        let callEpoch = coordinator.call?.epoch
        let provenance = captureOrigin
        // EXACT shared ingress for the real input tap and Simulator-only recorded buffers.
        // A source has one serial producer; the stateful Mac-derived converter is never shared
        // concurrently between a hardware tap and a fixture.
        inputHandler = { [weak self] buffer in
            let speech = framing.speechGeneration
            do {
                let origin = provenance.snapshot()
                substitution?.replace(buffer)
                self?.voiceProbeFixture.replace(buffer)
                let frames = try framing.consume(buffer, hardware: isHardware, speechGeneration: speech)
                Task { @MainActor in
                    guard let self, self.coordinator.mayRunMedia, self.capture.admits(owner), self.graphGeneration == graph,
                          framing.admitsSpeech(speech) else { return }
                    if self.engine.isRunning && framing.snapshot().ready {
                        let wasReady = self.graphAdmission.ready
                        self.graphAdmission.delivered(graph)
                        if !wasReady && self.graphAdmission.ready { self.onDuplexChange?() }
                    }
                    for frame in frames {
                        guard framing.admitsSpeech(speech) else { return }
                        self.latestMicRMS = TurnTaker.rms(frame)
                        self.lastCaptureRendered = origin.0
                        self.lastCaptureDuplexSafe = origin.1
                        self.capturedFrames += 1
                        if ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnProbe") {
                            VoiceTrace.shared.event("voiceprobe.input", ["rms": String(TurnTaker.rms(frame))])
                        }
                        if self.capturedFrames == 1 || self.capturedFrames % 250 == 0 {
                            if self.capturedFrames == 1 { self.onProbeEvent?("firstFrame") }
                            StageDiagnostics.shared.record(.captureBuffer, .complete, status: Int(TurnTaker.rms(frame) * 1_000_000))
                            self.snapshot(.complete)
                        }
#if DEBUG && targetEnvironment(simulator)
                        self.proof.input(frame)
#endif
                        self.onPCM?(frame)
                    }
                }
            } catch { Task { @MainActor in
                guard let self, self.capture.admits(owner), self.graphGeneration == graph, framing.admitsSpeech(speech) else { return }
                CaptureFailureDelivery.deliver(capture: self.capture.admits(owner), graph: self.graphGeneration == graph,
                    call: self.coordinator.call?.epoch == callEpoch, media: self.coordinator.mayRunMedia, callOwned: callEpoch != nil,
                    pause: { self.pauseRouteCapture(self.pendingRecovery ?? self.coordinator.engineRecoveryContext()) },
                    fail: { self.snapshot(.failed); self.onFailure?(error) })
            } }
        }
    }
    private func installRenderHandler(_ owner: Int) {
        let graph = graphGeneration
        let dropoutMeter = renderDropouts
        let sourceMeter = sourceSignals, renderPlayer = player
        // Meter the render path, not downloaded/scheduled TTS chunks (which can be 0.8 s ahead).
        renderHandler = { [weak self] buffer, _ in
            var sum = 0.0
            var validSamples = false
            let count = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
            if let samples = buffer.floatChannelData, count > 0, channels > 0 {
                validSamples = true
                for channel in 0..<channels {
                    for frame in 0..<count { let value = Double(samples[channel][frame]); sum += value * value }
                }
            }
            let rms = count > 0 && channels > 0 ? sqrt(sum / Double(count * channels)) : 0
            dropoutMeter.consume(rms: rms, frames: count, rate: buffer.format.sampleRate, graph: graph, valid: validSamples)
            let signalRevision = sourceMeter.renderRevision
            let playerFrame = renderPlayer.lastRenderTime.flatMap { renderPlayer.playerTime(forNodeTime: $0) }.map { Int($0.sampleTime) }
            let handoffs = sourceMeter.render(rms: rms, frames: count, renderRate: buffer.format.sampleRate,
                sourceFrame: playerFrame, graph: graph, now: ProcessInfo.processInfo.systemUptime, revision: signalRevision)
#if DEBUG && targetEnvironment(simulator)
            // Copy render samples before the tap returns. Never substitute scheduled TTS bytes.
            let rendered = SimulatorAudioProof.monoPCM(buffer)
            let renderRate = Int(buffer.format.sampleRate)
#endif
            Task { @MainActor in
                for handoff in handoffs {
                    StageDiagnostics.shared.recordPlayback(.routeHandoff,
                        fields: [.routeHandoffGapMs: handoff.gapMs, .routeHandoffGeneration: Double(handoff.generation),
                            .positionKnown: handoff.positionKnown ? 1 : 0, .skippedUpToMs: handoff.skippedUpToMs,
                            .utteranceOrdinal: Double(handoff.ordinal), .graphGeneration: Double(graph)],
                        attempt: handoff.attempt, callToken: handoff.callToken)
                }
                guard let self, self.capture.admits(owner), self.graphGeneration == graph else { return }
                self.recordVoiceProcessing()
                self.onLevel?(self.player.isPlaying && rms.isFinite ? rms : 0)
                if SpeakerEchoProbe.enabled {
                    let linked = self.engine.outputConnectionPoints(for: self.engine.inputNode, outputBus: 0).contains { $0.node === self.engine.mainMixerNode || $0.node === self.engine.outputNode }
                    SpeakerEchoProbe.shared.sample(mic: self.latestMicRMS, mix: rms, idle: self.scheduled == 0, voiceProcessing: self.voiceProcessingReady, speaker: self.coordinator.currentPhoneRoute == .speaker, micLinkedToOutput: linked)
                }
                if (PhoneLoopProbe.enabled || ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnProbe")) && self.player.isPlaying && rms > 0.001 {
                    VoiceTrace.shared.event("render.rms", ["rms": String(rms)])
                }
#if DEBUG && targetEnvironment(simulator)
                self.proof.render(rendered, rate: renderRate, rms: rms)
#endif
            }
        }
    }
    /// Coalesce route/config notifications; never grant a new controller or capture owner.
    /// Only unexpected repairs spend the 3/10s budget. Deliberate route tickets
    /// must match an observed route before a repair can carry their generation.
    private func scheduleRecovery(_ owner: Int, forceRepair: Bool = false, context: RouteRecoveryContext? = nil) {
        repairRequired = repairRequired || forceRepair
        guard !recoveryBudget.paused else { return }
        pendingRecovery = context ?? coordinator.engineRecoveryContext()
        // A synchronous configuration notification can arrive before open() returns and
        // CaptureLifecycle marks capturing. Re-check full admission after the debounce.
        guard coordinator.mayRunMedia, capture.generation == owner, playerAttached, !usingFixture, recoveryTask == nil else { return }
        if playbackActive, let pendingRecovery {
            sourceSignals.beginHandoff(generation: pendingRecovery.generation,
                now: ProcessInfo.processInfo.systemUptime)
        }
        let debounce: UInt64 = playbackActive ? 0 : 150_000_000
        suspendPlaybackForRouteRepair()
        // Close admission BEFORE the 150ms debounce. Old taps cannot make this
        // gate ready; only frames from the installed replacement generation can.
        graphAdmission.beginRepair()
        renderDropouts.suspend()
        // Fence queued old-tap PCM AND errors before debounce. Invalidation uses
        // ingress' lock (and composes with CaptureEpoch's conversion admission).
        graphGeneration += 1
        ingressState?.invalidate()
        onDuplexChange?()
        let callEpoch = coordinator.call?.epoch
        recoveryJob += 1
        let job = recoveryJob
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: debounce)
            guard let self, !Task.isCancelled, self.capture.admits(owner), self.coordinator.mayRunMedia,
                  self.coordinator.call?.epoch == callEpoch, self.recoveryJob == job else { return }
            defer {
                if self.recoveryJob == job { self.recoveryTask = nil; self.repairRequired = false; self.pendingRecovery = nil }
            }
            // voice-turns closed graph admission before debounce. Install a fresh
            // generation even when the format is unchanged; old taps cannot reopen it.
            let cause = self.pendingRecovery ?? self.coordinator.engineRecoveryContext()
            guard self.recoveryBudget.admit(cause, now: ProcessInfo.processInfo.systemUptime) else {
                self.pauseRouteCapture(cause); return
            }
            self.restartCount += 1
            do {
                self.onCaptureState?(.repairing)
                self.recordPlayback(.engineStop, [.stopCause: Double(PlaybackStopCause.routeRecovery.rawValue)])
                self.engine.stop(); self.player.stop() // PCM/utterance/HTTP ownership survives this graph repair.
                try self.coordinator.prepareEngineRoute()
                self.recordRecovery(cause, .requested)
                self.graphAdmission.installed(self.graphGeneration)
                if self.tapInstalled { self.engine.inputNode.removeTap(onBus: 0); self.tapInstalled = false }
                if self.outputTapInstalled { self.engine.mainMixerNode.removeTap(onBus: 0); self.outputTapInstalled = false }
                let format = self.engine.inputNode.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw ClientError("Audio route has no usable microphone") }
                self.requestedFormat = format
                self.ingressState = CaptureIngress()
                self.installInputHandler(owner, hardware: true)
                let handler = self.inputHandler!
                self.engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: format) { buffer, _ in handler(buffer) }
                self.tapInstalled = true
                if self.voiceProcessingReady { self.engine.connect(self.engine.mainMixerNode, to: self.engine.outputNode, format: format) }
                self.installRenderHandler(owner)
                self.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: self.renderHandler!)
                self.outputTapInstalled = true
                self.engine.prepare(); try self.engine.start()
                self.installedIO = self.ioFormats; self.observedRoute = self.coordinator.currentPhoneRoute
                try self.resumeRetainedPlayback?()
                self.playbackContinuity?.startRetainedRun {
                    self.player.play()
                    self.sourceSignals.start(token: self.playbackOrdinal)
                }
                self.recordPlayback(.engineStart, [.stopCause: Double(PlaybackStopCause.routeRecovery.rawValue)])
                self.recordVoiceProcessing(force: true)
                let deadline = Date().addingTimeInterval(3)
                self.snapshot(.begin); self.onProbeEvent?("restarted")
                // Keep the task alive to detect a restarted engine that never supplies frames.
                while self.capture.admits(owner), !Task.isCancelled, self.coordinator.mayRunMedia, self.coordinator.call?.epoch == callEpoch {
                    if self.engine.isRunning && self.ingressState?.snapshot().ready == true {
                        self.recordRecovery(cause, .recovered); self.onCaptureState?(.running); return
                    }
                    guard Date() < deadline else { throw ClientError("Microphone did not recover after route change") }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            } catch {
                guard self.capture.admits(owner), !Task.isCancelled else { return }
                self.pauseRouteCapture(cause)
            }
        }
    }
    private func recordRecovery(_ context: RouteRecoveryContext, _ result: RouteResult) {
        let current = coordinator.currentPhoneRoute
        var value = RouteDiagnostic(event: .recovery, before: context.route, after: current, result: result)
        value.recovery = context
        StageDiagnostics.shared.record(.route, result == .paused ? .suspended : .complete,
            audio: CaptureSnapshot([.epoch: Double(capture.generation), .graphGeneration: Double(graphGeneration),
                .recoveryBudget: Double(recoveryBudget.unexpected.count),
                .categoryOptions: Double(AVAudioSession.sharedInstance().categoryOptions.rawValue)]), audioRoute: value)
    }
    private func pauseRouteCapture(_ context: RouteRecoveryContext) {
        recoveryBudget.suspend()
        recordRecovery(context, .paused)
        // Do NOT invoke onFailure: that generic path ends the CallKit call.
        // Pause/quarantine words through the existing call-media seam instead.
        if let onRoutePaused { onRoutePaused() } else { pauseForCall() }
        onCaptureState?(.failed)
    }
    func retryRouteCapture() {
        recoveryBudget.retry()
        var value = RouteDiagnostic(event: .retry, before: coordinator.currentPhoneRoute, after: coordinator.currentPhoneRoute, result: .requested)
        value.recovery = coordinator.retryRecoveryContext()
        StageDiagnostics.shared.record(.route, .begin,
            audio: CaptureSnapshot([.categoryOptions: Double(AVAudioSession.sharedInstance().categoryOptions.rawValue)]), audioRoute: value)
    }
    func stop() {
        capture.stop(close: { self.close() }, deactivate: { self.coordinator.deactivate() })
        onCaptureState?(.off)
    }
    /// Called before graph close on hold/deactivation, preserving the current sentence.
    func pauseForCall() { interruptPlayback(cause: .callPause); stop() }
    private func close() {
        graphAdmission.beginRepair(); onDuplexChange?()
        if ProcessInfo.processInfo.arguments.contains("-FVVoiceTurnProbe") {
            for name in ["phone-loop.wav", "voice-turn-first.wav", "voice-turn-second.wav"] {
                try? FileManager.default.removeItem(at: URL.documentsDirectory.appendingPathComponent(name))
            }
        }
        recoveryJob += 1
        recoveryTask?.cancel(); recoveryTask = nil
        repairRequired = false
        graphGeneration += 1
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        ingressState?.invalidate()
#if DEBUG && targetEnvironment(simulator)
        fixtureTask?.cancel(); fixtureTask = nil
        proof.finish()
#endif
        stopPlayback(cause: .graphClose)
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if outputTapInstalled { engine.mainMixerNode.removeTap(onBus: 0); outputTapInstalled = false }
        recordPlayback(.engineStop, [.stopCause: Double(PlaybackStopCause.graphClose.rawValue)])
        engine.stop()
        if engine.inputNode.isVoiceProcessingEnabled { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        recordVoiceProcessing(force: true)
        if playerAttached { engine.detach(player); playerAttached = false }
        engine.reset()
        voiceProcessingReady = false
        snapshot(.cancelled)
    }
    private func snapshot(_ category: DiagnosticCategory) {
        let session = AVAudioSession.sharedInstance(), counts = ingressState?.snapshot() ?? CaptureIngress.Counts()
        // Port types only, encoded as a closed numeric bitset (no route names/UIDs).
        func ports(_ values: [AVAudioSessionPortDescription]) -> Double {
            let known: [AVAudioSession.Port] = [.builtInMic, .builtInSpeaker, .builtInReceiver, .headphones, .headsetMic, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .usbAudio, .airPlay, .lineIn, .lineOut]
            return Double(values.reduce(0) { bits, port in bits | (known.firstIndex(of: port.portType).map { 1 << $0 } ?? (1 << 15)) })
        }
        var fields: [CaptureField: Double] = [
            .epoch: Double(capture.generation), .cancelled: category == .cancelled ? 1 : 0,
            .engine: engine.isRunning ? 1 : 0, .tap: tapInstalled ? 1 : 0,
            .activation: coordinator.active ? 1 : 0, .permission: session.recordPermission == .granted ? 1 : 0,
            .interrupted: coordinator.interrupted ? 1 : 0, .voiceProcessing: engine.inputNode.isVoiceProcessingEnabled ? 1 : 0,
            .category: session.category == .playAndRecord ? 1 : 0, .mode: session.mode == .voiceChat ? 1 : 0,
            .inputPort: ports(session.currentRoute.inputs), .outputPort: ports(session.currentRoute.outputs),
            .sessionRate: session.sampleRate, .inputChannels: Double(session.inputNumberOfChannels), .outputChannels: Double(session.outputNumberOfChannels),
            .callbacks: Double(counts.callbacks), .hardwareCallbacks: Double(counts.hardwareCallbacks), .validBuffers: Double(counts.validBuffers),
            .inputFrames: Double(counts.inputFrames), .convertedFrames: Double(counts.frames), .rms: counts.rms,
            .conversionErrors: Double(counts.conversionErrors), .formatChanges: Double(counts.formatChanges),
            .configurationChanges: Double(configurationChanges), .restarts: Double(restartCount),
            .failure: category == .failed ? Double(counts.failureCode) : 0]
        func format(_ value: AVAudioFormat?, _ keys: [CaptureField]) {
            guard let value else { return }
            fields[keys[0]] = value.sampleRate; fields[keys[1]] = Double(value.channelCount)
            fields[keys[2]] = Double(value.commonFormat.rawValue); fields[keys[3]] = value.isInterleaved ? 1 : 0
        }
        format(engine.inputNode.inputFormat(forBus: 0), [.inputRate, .inputCount, .inputCommon, .inputInterleaved])
        format(engine.inputNode.outputFormat(forBus: 0), [.outputRate, .outputCount, .outputCommon, .outputInterleaved])
        format(requestedFormat, [.requestedRate, .requestedCount, .requestedCommon, .requestedInterleaved])
        format(counts.format, [.actualRate, .actualCount, .actualCommon, .actualInterleaved])
        StageDiagnostics.shared.record(.capture, category, audio: CaptureSnapshot(fields))
    }
    private func recordPlayback(_ event: PlaybackEvent, _ fields: [CaptureField: Double] = [:]) {
        var values = fields
        values[.playbackActive] = playbackActive ? 1 : 0
        values[.queueDepth] = Double(scheduled)
        values[.epoch] = Double(epoch); values[.graphGeneration] = Double(graphGeneration)
        values[.utteranceOrdinal] = Double(playbackOrdinal)
        values[.engine] = engine.isRunning ? 1 : 0
        values[.speakerRoute] = coordinator.currentPhoneRoute == .speaker ? 1 : 0
        StageDiagnostics.shared.recordPlayback(event, fields: values, attempt: playbackAttempt)
    }
    private func recordVoiceProcessing(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastVPSample >= 1 else { return }
        lastVPSample = now
        let input = engine.inputNode, enabled = input.isVoiceProcessingEnabled
        var fields: [CaptureField: Double] = [.voiceProcessing: enabled ? 1 : 0,
            .vpOutputEnabled: engine.outputNode.isVoiceProcessingEnabled ? 1 : 0,
            .vpBypassed: input.isVoiceProcessingBypassed ? 1 : 0, .vpAGC: input.isVoiceProcessingAGCEnabled ? 1 : 0,
            .vpDucking: -1, .vpAdvancedDucking: -1]
        if enabled {
            let ducking = input.voiceProcessingOtherAudioDuckingConfiguration
            fields[.vpDucking] = Double(ducking.duckingLevel.rawValue)
            fields[.vpAdvancedDucking] = ducking.enableAdvancedDucking.boolValue ? 1 : 0
        }
        guard force || fields != lastVPFields else { return }
        lastVPFields = fields; recordPlayback(.voiceProcessingState, fields)
    }
    func stopPlayback() { stopPlayback(cause: .outputStop) }
    private func stopPlayback(cause: PlaybackStopCause) {
        recordPlayback(.stopPlayback, [.stopCause: Double(cause.rawValue)])
        playbackActive = false; renderDropouts.suspend()
        epoch += 1; player.stop(); captureOrigin.setRendering(false)
        playbackContinuity?.cancel(); resumeRetainedPlayback = nil
        sourceSignals.suspend()
        playbackQueue.cancel(); onLevel?(0)
    }
    private func suspendPlaybackForRouteRepair() {
        guard playbackActive, let continuity = playbackContinuity, !continuity.suspended else { return }
        player.pause()
        let nodeFrames = playbackQueue.hasStarted
            ? player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }.map { Int($0.sampleTime) } : nil
        let tapFrames = sourceSignals.renderedPosition.map { max(0, $0 - continuity.renderBase) }
        let frames = [nodeFrames, tapFrames].compactMap { $0 }.max()
        sourceSignals.suspend()
        let consumed = continuity.suspend(renderedFrames: frames)
        let skippedMs = sourceSignals.noteHandoffPosition(generation: pendingRecovery?.generation ?? 0,
            positionKnown: continuity.positionKnown, skippedFrames: continuity.skippedFrames)
        // Repair boundaries are not source starvation and cannot fake a refill gap.
        for _ in consumed { playbackObservation?.queue.played(now: ProcessInfo.processInfo.systemUptime, moreExpected: false) }
        _ = playbackObservation?.queue.closeGap(now: ProcessInfo.processInfo.systemUptime, count: false)
        captureOrigin.setRendering(false)
        recordPlayback(.suspendForRepair, [.playbackPositionFrames: Double(continuity.position),
            .retainedPCMBytes: Double(continuity.segments.reduce(0) { $0 + $1.pcm.count }),
            .positionKnown: continuity.positionKnown ? 1 : 0, .skippedUpToMs: skippedMs])
    }
    private func enqueueRetainedSegment(_ segment: PlaybackContinuity.Segment, format: AVAudioFormat,
        continuity: PlaybackContinuity, owner: Int, ordinal: Int, observation: PlayerDiagnosticObservation) throws {
        let count = segment.pcm.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw ClientError("Playback allocation failed")
        }
        buffer.frameLength = AVAudioFrameCount(count)
        let bytes = [UInt8](segment.pcm)
        for i in 0..<count { buffer.floatChannelData![0][i] = Float(Int16(bitPattern: UInt16(bytes[i*2]) | UInt16(bytes[i*2+1]) << 8)) / 32768 }
        let revision = continuity.revision
        let receipt = continuity.completionReceipt(for: segment)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            receipt.record() // Audio thread: prove completion even when MainActor is busy.
            Task { @MainActor in
            guard let self, owner == self.epoch, ordinal == self.playbackOrdinal,
                  continuity.completed(segment.token, revision: revision) else { return }
            if observation.queue.played(now: ProcessInfo.processInfo.systemUptime, moreExpected: observation.moreExpected) {
                self.recordPlayback(.starvationBegin, [.sourceFinished: 0])
            }
            VoiceTrace.shared.event("player.playedBack", ["remaining": String(self.scheduled)])
#if DEBUG && targetEnvironment(simulator)
            self.proof.played()
#endif
            if continuity.queue.depth == 0 { self.captureOrigin.setRendering(false) }
        } }
    }
    func interruptPlayback(cause: PlaybackStopCause = .unspecified) {
        recordPlayback(.interruptPlayback, [.stopCause: Double(cause.rawValue)])
        recoverableEpochs.insert(epoch)
        if recoverableEpochs.count > 16 { recoverableEpochs = [epoch] }
        stopPlayback(cause: cause)
        onPlaybackRepair?()
    }
    private func checkPlayback(_ owner: Int) throws {
        if Task.isCancelled { throw CancellationError() }
        guard owner == epoch else {
            if recoverableEpochs.contains(owner) { throw PlaybackInterruption.recoverable }
            throw CancellationError()
        }
    }
    func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try Task.checkCancellation()
            guard coordinator.mayRunMedia else { throw CancellationError() }
            if capturing, engine.isRunning, ingressState?.snapshot().ready == true, graphAdmission.ready, recoveryTask == nil { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ClientError("Audio did not become ready for sentence replay")
    }
    func play(_ audio: SpeechAudio, label: String, onStart: @escaping () -> Void) async throws {
        if recoveryTask != nil { try await waitUntilReady() }
        guard capturing else { throw ClientError("Voice audio is off") }
        let owner = epoch
        let queue = PlaybackBufferScheduler()
        let continuity = PlaybackContinuity(queue: queue)
        playbackContinuity = continuity
        playbackQueue = queue
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(audio.sampleRate), channels: 1, interleaved: false) else { throw ClientError("Invalid playback rate") }
        playbackOrdinal += 1
        let ordinal = playbackOrdinal
        let callToken = StageDiagnostics.shared.playbackCallToken
        playbackAttempt = audio.diagnosticAttempt; playbackActive = true
        let observation = PlayerDiagnosticObservation()
        playbackObservation = observation
        renderDropouts.begin(token: ordinal, graph: graphGeneration)
        sourceSignals.begin(token: ordinal, graph: graphGeneration, rate: Double(audio.sampleRate),
            attempt: audio.diagnosticAttempt, callToken: callToken)
        recordPlayback(.utteranceBegin, [.fullyBuffered: audio.fullyBuffered ? 1 : 0, .sourceRate: Double(audio.sampleRate)])
        defer {
            if let duration = observation.queue.closeGap(now: ProcessInfo.processInfo.systemUptime, count: false) {
                StageDiagnostics.shared.recordPlayback(.starvationEnd, fields: [.gapDurationMs: duration, .cancelled: 1,
                    .sourceFinished: observation.moreExpected ? 0 : 1], attempt: audio.diagnosticAttempt, category: .cancelled, callToken: callToken)
            }
            let gaps = renderDropouts.end(token: ordinal)
            let signals = sourceSignals.end(token: ordinal)
            // Explicit captured attempt: old completions must not tag a new utterance.
            StageDiagnostics.shared.recordPlayback(.utteranceEnd, fields: [.utteranceOrdinal: Double(ordinal), .starvationCount: Double(observation.queue.starvationCount),
                    .starvationMaxMs: observation.queue.starvationMaxMs, .renderGapCount: Double(gaps.count), .renderGapMaxMs: gaps.maxMs,
                     .renderFloor: RenderDropoutMeter.floor, .renderThresholdMs: RenderDropoutMeter.thresholdMs,
                     .renderInvalidBuffers: Double(gaps.invalidBuffers),
                     .sourceSilenceCount: Double(signals.sourceSilenceCount), .dropoutCount: Double(signals.dropoutCount),
                     .dropoutMaxMs: signals.dropoutMaxMs, .renderAlignmentUnknown: Double(signals.alignmentUnknown),
                     .routeHandoffDropped: Double(signals.handoffsDropped)],
                attempt: audio.diagnosticAttempt,
                category: observation.completed ? .complete : (owner != epoch || Task.isCancelled ? .cancelled : .failed), callToken: callToken)
            if playbackOrdinal == ordinal {
                playbackActive = false; playbackAttempt = nil; playbackObservation = nil
                playbackContinuity = nil; resumeRetainedPlayback = nil
            }
        }
        recordPlayback(.stopPlayback, [.stopCause: Double(PlaybackStopCause.sentenceBoundary.rawValue)])
        player.stop()
        engine.disconnectNodeOutput(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        installedIO = ioFormats
        resumeRetainedPlayback = { [weak self] in
            guard let self else { return }
            try self.checkPlayback(owner)
            guard continuity.suspended else { return }
            self.engine.disconnectNodeOutput(self.player)
            self.engine.connect(self.player, to: self.engine.mainMixerNode, format: format)
            self.installedIO = self.ioFormats
            for segment in continuity.segments {
                try self.enqueueRetainedSegment(segment, format: format, continuity: continuity,
                    owner: owner, ordinal: ordinal, observation: observation)
            }
            continuity.resume()
            self.renderDropouts.resume(token: ordinal, graph: self.graphGeneration)
            self.sourceSignals.resume(graph: self.graphGeneration, base: continuity.position)
            self.captureOrigin.setRendering(queue.depth > 0)
            self.recordPlayback(.resumeFromPosition, [.playbackPositionFrames: Double(continuity.position),
                .positionKnown: continuity.positionKnown ? 1 : 0,
                .skippedUpToMs: Double(continuity.skippedFrames) / format.sampleRate * 1000,
                .retainedPCMBytes: Double(continuity.segments.reduce(0) { $0 + $1.pcm.count })])
        }
        let mixed = engine.mainMixerNode.outputFormat(forBus: 0), output = engine.outputNode.inputFormat(forBus: 0)
        recordPlayback(.playbackFormat, [.sourceRate: Double(audio.sampleRate), .playerRate: format.sampleRate,
            .mixerRate: mixed.sampleRate, .outputCount: Double(mixed.channelCount), .outputCommon: Double(mixed.commonFormat.rawValue),
            .outputInterleaved: mixed.isInterleaved ? 1 : 0, .hardwareRate: AVAudioSession.sharedInstance().sampleRate,
            .outputRate: output.sampleRate, .actualCount: Double(output.channelCount), .actualCommon: Double(output.commonFormat.rawValue),
            .actualInterleaved: output.isInterleaved ? 1 : 0])
        var carry = Data()
        for try await chunk in audio.chunks {
            VoiceTrace.shared.event("player.chunk", ["bytes": String(chunk.count)])
            try checkPlayback(owner)
            carry.append(chunk)
            while carry.count >= 2 {
                try await continuity.waitUntilResumed()
                try checkPlayback(owner)
                let refillEmptyRun = queue.depth == 0 && queue.hasStarted
                if refillEmptyRun {
                    // A streaming supply/producer gap advances the node clock
                    // without advancing source PCM. Reset ONLY this empty node.
                    recordPlayback(.sourceClockReset, [.playbackPositionFrames: Double(continuity.position)])
                    player.stop(); continuity.restartEmptyRun()
                    sourceSignals.resume(graph: graphGeneration, base: continuity.position)
                }
                let count = PlaybackBufferScheduler.frameCount(bytes: carry.count, sampleRate: audio.sampleRate)
                let data = Data(carry.prefix(count * 2)); carry.removeFirst(count * 2)
                observation.moreExpected = !audio.fullyBuffered || carry.count >= 2
                guard let bufferToken = queue.schedule() else { throw CancellationError() }
                continuity.append(data, token: bufferToken)
                sourceSignals.source(data)
                if let duration = observation.queue.schedule(now: ProcessInfo.processInfo.systemUptime) {
                    recordPlayback(.starvationEnd, [.gapDurationMs: duration, .sourceFinished: 0])
                }
                recordPlayback(.scheduled, [.bufferFrames: Double(count), .bufferMs: Double(count) / Double(audio.sampleRate) * 1000,
                    .pendingPCMBytes: Double(carry.count), .sourceFinished: observation.moreExpected ? 0 : 1])
                captureOrigin.setRendering(true)
                try enqueueRetainedSegment(continuity.segments.last!, format: format, continuity: continuity,
                    owner: owner, ordinal: ordinal, observation: observation)
                if queue.startIfNeeded() {
                    captureOrigin.setRendering(true); player.play(); sourceSignals.start(token: ordinal); onStart()
                } else if refillEmptyRun { player.play(); sourceSignals.start(token: ordinal) }
                // Four buffers maximum; refill with one left, not after an empty batch.
                if queue.depth >= PlaybackBufferScheduler.highWater { try await queue.waitForCapacity() }
                try checkPlayback(owner)
            }
        }
        observation.moreExpected = false
        sourceSignals.sourceFinished()
        if let duration = observation.queue.closeGap(now: ProcessInfo.processInfo.systemUptime, count: false) {
            recordPlayback(.starvationEnd, [.gapDurationMs: duration, .sourceFinished: 1]) // EOF, not a confirmed refill starvation.
        }
        try await queue.waitForDrain() // EOF is ALWAYS a true zero-buffer drain.
        try await continuity.waitUntilResumed()
        try checkPlayback(owner)
        captureOrigin.setRendering(false)
        onLevel?(0)
        observation.completed = true
    }
}
