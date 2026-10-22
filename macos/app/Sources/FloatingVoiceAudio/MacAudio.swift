import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import FloatingVoiceCore

/// Capture without voice processing. AVAudioEngine's input and output nodes share one AUHAL unit on macOS, so an
/// input-only device cannot be routed there while it plays elsewhere. A separate input-only AUHAL captures the
/// selected microphone as mono float32 at its own rate. (agent-voice native/audio.swift)
final class HALCapture {
    var unit: AudioUnit?
    var samples = [Float](repeating: 0, count: 16384)
    var handler: ((UnsafePointer<Float>, Int) -> Void)?

    static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw audioError(Int(status), "\(what) failed (\(status))") }
    }

    func start(device: AudioDeviceID, handler: @escaping (UnsafePointer<Float>, Int) -> Void) throws -> Double {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw audioError(6, "Audio input unit unavailable") }
        var created: AudioUnit?
        try HALCapture.check(AudioComponentInstanceNew(component, &created), "Opening the microphone")
        guard let unit = created else { throw audioError(6, "Audio input unit unavailable") }
        self.unit = unit; self.handler = handler
        var on: UInt32 = 1, off: UInt32 = 0, id = device
        let word = UInt32(MemoryLayout<UInt32>.size), formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try HALCapture.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, word), "Enabling microphone input")
        try HALCapture.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, word), "Disabling input-unit output")
        try HALCapture.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)), "Selecting the microphone")
        var hardware = AudioStreamBasicDescription(), size = formatSize
        try HALCapture.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "Reading the microphone format")
        guard hardware.mSampleRate > 0 else { throw audioError(3, "Input device has no usable audio format.") }
        var client = AudioStreamBasicDescription(mSampleRate: hardware.mSampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try HALCapture.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, formatSize), "Setting the microphone format")
        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, time, bus, frames, _ in
            let capture = Unmanaged<HALCapture>.fromOpaque(refCon).takeUnretainedValue()
            guard let unit = capture.unit, Int(frames) <= capture.samples.count else { return noErr }
            return capture.samples.withUnsafeMutableBufferPointer { pointer -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(pointer.baseAddress)))
                let status = AudioUnitRender(unit, flags, time, bus, frames, &list)
                if status == noErr, let base = pointer.baseAddress { capture.handler?(base, Int(frames)) }
                return status
            }
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try HALCapture.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Installing the microphone callback")
        try HALCapture.check(AudioUnitInitialize(unit), "Initializing the microphone")
        try HALCapture.check(AudioOutputUnitStart(unit), "Starting the microphone")
        return hardware.mSampleRate
    }

    func matches(_ device: AudioDeviceID) -> Bool {
        guard let unit else { return false }
        var actual: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size) == noErr && actual == device
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit)
        self.unit = nil; handler = nil
    }
}

/// Thread-safe flag read from audio threads.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var get: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

/// Microphone and speech on one AVAudioEngine, adapted from agent-voice native/audio.swift and run in-process.
/// With echo cancellation on, capture uses Apple's voice-processing engine and playback runs on the same engine, so
/// the mic stays live while the agent speaks (duplex) without hearing itself. Devices are chosen by persistent
/// CoreAudio UID; start waits for live microphone frames before reporting ready.
@MainActor
public final class MacAudio: AudioInput, AutomaticCutInOutput, LevelReporting {
    public var onPCM: ((Data) -> Void)?
    private let captureEpoch = CaptureEpoch()
    public func discardPendingAudio() { captureEpoch.advance() }
    /// Playback level (RMS of the speech player's output as it renders), for the visualizer.
    public var onLevel: ((Double) -> Void)?
    public var onFailure: ((Error) -> Void)?
    public var onDiagnosticConfiguration: (() -> Void)?
    public private(set) var echo: (effective: Bool, reason: String)?
    public private(set) var capturing = false
    /// Mic live while speaking is safe only with echo cancellation on, or with headphones / Bluetooth output
    /// (no speaker-to-mic path). Otherwise the controller runs half duplex.
    public private(set) var duplexSafe = true

    private let config: () -> VoiceConfig
    private let log: (String) -> Void
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let hal = HALCapture()
    private let captureQueue = DispatchQueue(label: "floating-voice.audio.capture")
    private let live = AtomicFlag()
    private var running = false
    private var tapInstalled = false
    private var playerTapInstalled = false
    private var voiceProcessing = false
    private var generation = 0
    private var routeTimer: Timer?
    private var configurationObserver: NSObjectProtocol?
    private var receivedInput = false
    private var startup: Task<Void, Error>?
    // Native acquisition ownership, independent of Stop reply / playback generation.
    private var lifecycle = 0
    // Device-free startup gates for focused lifecycle tests; production always uses the native path.
    struct StartupTestHooks {
        var permission: () async throws -> Void
        var beforeEngine: () async throws -> Void = {}
        var open: (Bool) throws -> Void
        var ready: () async throws -> Void = {}
        var closed: () -> Void = {}
    }
    var startupTestHooks: StartupTestHooks?
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter = 0
    private var automaticCutInPaused = false
    private var cutInGain: Float = 1
    private var graphRepair = PlaybackGraphRepairBarrier()
    private var producerWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseBegan: Date?
    private var pausedSeconds: TimeInterval = 0
    private var activeTime: TimeInterval {
        Date().timeIntervalSinceReferenceDate - pausedSeconds - (pauseBegan.map { Date().timeIntervalSince($0) } ?? 0)
    }
    static let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

    public init(config: @escaping () -> VoiceConfig, log: @escaping (String) -> Void = { _ in }) {
        self.config = config; self.log = log
    }

    /// Read-only software state, not output signal/audibility. No node getters on unsafe graphs.
    public func diagnosticSnapshot() -> String {
        let graph = AudioLifecycleDiagnostics.safeGraph(running && readySent && !graphRepair.inProgress) {
            guard engine.isRunning else { return "graph=stopped engine=false" }
            return "graph=current engine=true player=\(player.isPlaying) gain=\(AudioLifecycleDiagnostics.gain(player.volume)) mixer=\(AudioLifecycleDiagnostics.gain(engine.mainMixerNode.outputVolume))"
        }
        return "generation=\(generation) ready=\(readySent) capturing=\(capturing) running=\(running) paused=\(automaticCutInPaused) \(graph)"
    }

    // Offline test seam: installs a real manual-render graph, never opens a device.
    init(offlineEngine: AVAudioEngine, player: AVAudioPlayerNode) {
        config = { VoiceConfig() }; log = { _ in }
        engine = offlineEngine; self.player = player; running = true; readySent = true
    }

    public func setCutInGain(_ gain: Float) {
        cutInGain = gain; player.volume = gain
    }
    public func pauseForAutomaticCutIn() -> Bool {
        guard running, !graphRepair.inProgress else { return false }
        automaticCutInPaused = true
        if pauseBegan == nil { pauseBegan = Date() }
        player.pause()
        return true
    }
    public func resumeAfterAutomaticCutIn() throws {
        guard automaticCutInPaused else { return }
        automaticCutInPaused = false
        // Clearing intent during repair must not restart the OLD running graph.
        guard !graphRepair.inProgress else { return }
        guard running, engine.isRunning else { throw audioError(13, "Audio output is not running") }
        releaseProducer()
        if engine.manualRenderingMode == .offline {
            player.play(at: AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: Self.speechFormat.sampleRate))
        } else { player.play() }
    }
    private func releaseProducer() {
        if let began = pauseBegan { pausedSeconds += Date().timeIntervalSince(began); pauseBegan = nil }
        let waiters = producerWaiters; producerWaiters = []
        waiters.forEach { $0.resume() }
    }
    private func awaitProducer() async {
        if automaticCutInPaused || graphRepair.inProgress {
            await withCheckedContinuation { producerWaiters.append($0) }
        }
    }

    // One admission owner from before any reentrant rollback through install.
    func beginPlaybackGraphRepair() -> Int { graphRepair.begin() }
    func playbackGraphReplacementInstalled(_ owner: Int) {
        guard engine.isRunning, graphRepair.replacementInstalled(owner), !automaticCutInPaused else { return }
        releaseProducer()
        if engine.manualRenderingMode == .offline {
            player.play(at: AVAudioTime(sampleTime: engine.manualRenderingSampleTime, atRate: Self.speechFormat.sampleRate))
        } else { player.play() }
    }

    // MARK: AudioInput

    public func start() async throws {
        try Task.checkCancellation()
        if running && capturing { return }
        close()
        let owner = lifecycle
        if let hooks = startupTestHooks { try await hooks.permission() }
        else { try await Self.requireMicrophonePermission() }
        try checkStartup(owner)
        try await begin(capture: true, owner: owner)
    }

    /// Without permission macOS delivers silent frames instead of failing, so check it explicitly.
    static func requireMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            fallthrough
        default:
            throw audioError(11, "Microphone access denied: allow Voicestack in System Settings › Privacy & Security › Microphone")
        }
    }

    public func stop() { close() }

    // MARK: Engine

    private func checkStartup(_ owner: Int) throws {
        try Task.checkCancellation()
        guard owner == lifecycle else { throw CancellationError() }
    }

    private func begin(capture: Bool, owner: Int) async throws {
        try checkStartup(owner)
        let task = Task<Void, Error> { @MainActor in
            try await self.startupTestHooks?.beforeEngine()
            try self.checkStartup(owner)
            try self.startEngine(capture: capture, owner: owner)
            try await self.waitReady(capture: capture, owner: owner)
            try self.checkStartup(owner)
        }
        startup = task
        do { try await task.value; try checkStartup(owner) }
        catch {
            // A cancelled old start must never close the replacement graph.
            if owner == lifecycle { close() }
            throw error
        }
    }

    private func startEngine(capture: Bool, owner: Int) throws {
        try checkStartup(owner)
        if let hooks = startupTestHooks {
            try hooks.open(capture)
            running = true; capturing = capture
            return
        }
        let repair = beginPlaybackGraphRepair()
        let cfg = config()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        player.volume = cutInGain
        receivedInput = false
        let echoChoice = resolveEcho(setting: cfg.echoCancellation, outputDevice: cfg.outputDevice)
        echo = capture ? echoChoice : nil
        duplexSafe = echoChoice.effective || headphoneOutput(cfg.outputDevice) != nil
        let processed = capture && echoChoice.effective
        let choices = audioDevices()
        let inputUID = cfg.inputDevice, outputUID = cfg.outputDevice
        let microphone = selectDevice(choices, inputUID, input: true)
        guard let speakers = selectDevice(choices, outputUID, input: false) else { throw audioError(1, "The output device \"\(outputUID)\" is not connected. Reconnect the headphones or set outputDevice in agent-voice.json, then press Start voice.") }
        if capture && microphone == nil { throw audioError(2, "The microphone \"\(inputUID)\" is not connected. Reconnect it or set inputDevice in agent-voice.json, then press Start voice.") }
        deviceNames = (capture ? microphone?.name ?? "" : "", speakers.name)
        let output = engine.outputNode
        var common: AVAudioFormat
        if processed, let microphone {
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            voiceProcessing = true
            // Leave other apps' audio as loud as possible while the mic is live.
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            // Voice processing replaces the HAL nodes; set the selected devices on the replacement unit.
            if inputUID != "default" { try assignAudioDevice(input, microphone.id, 1) }
            if outputUID != "default" { try assignAudioDevice(output, speakers.id, 0) }
            common = input.outputFormat(forBus: 0)
            guard common.sampleRate > 0, common.channelCount > 0 else { throw audioError(3, "Input device has no usable audio format.") }
            // VoiceProcessingIO requires exactly matching client input/output formats; the mixer converts speech.
            engine.connect(engine.mainMixerNode, to: output, format: common)
            let mono = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
            let cleanMono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: common.sampleRate, channels: 1, interleaved: false)!
            guard let converter = AVAudioConverter(from: cleanMono, to: mono) else { throw audioError(4, "Microphone audio cannot be converted.") }
            let live = self.live
            let fence = captureEpoch
            var convertedEpoch = fence.current
            let rate = common.sampleRate
            input.installTap(onBus: 0, bufferSize: 1024, format: common) { [weak self] buffer, _ in
                let epoch = fence.current
                if convertedEpoch != epoch { converter.reset(); convertedEpoch = epoch }
                guard live.get else { return }
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / rate) + 32)
                guard let converted = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity),
                      let clean = AVAudioPCMBuffer(pcmFormat: cleanMono, frameCapacity: buffer.frameLength),
                      let source = buffer.floatChannelData, let cleanChannel = clean.floatChannelData else { return }
                clean.frameLength = buffer.frameLength
                memcpy(cleanChannel[0], source[0], Int(buffer.frameLength) * MemoryLayout<Float>.size)
                var used = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if used { status.pointee = .noDataNow; return nil }
                    used = true; status.pointee = .haveData; return clean
                }
                guard error == nil, let samples = converted.int16ChannelData, converted.frameLength > 0 else { return }
                let data = Data(bytes: samples[0], count: Int(converted.frameLength) * 2)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    if fence.current == epoch, self?.lifecycle == owner { self?.deliver(data) }
                } }
            }
            tapInstalled = true
        } else {
            if outputUID != "default" { try assignAudioDevice(output, speakers.id) }
            common = output.inputFormat(forBus: 0)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.speechFormat)
        // Level of what is being played, read off the render (display only).
        player.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { let x = samples[0][i]; sum += x * x }
            let rms = Double((sum / Float(n)).squareRoot())
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.lifecycle == owner { self?.onLevel?(rms) } } }
        }
        playerTapInstalled = true
        // Reapply after graph construction so automatic mixer negotiation cannot reset it.
        if processed { engine.connect(engine.mainMixerNode, to: output, format: common) }
        live.set(true)
        running = true
        capturing = capture
        observeStartup(processed: processed, speakers: speakers, microphone: microphone, common: common, owner: owner)
        try engine.start()
        playbackGraphReplacementInstalled(repair)
        if capture && !processed, let microphone { try startPlainCapture(microphone.id, owner: owner) }
        log("audio: engine started capture=\(capture) echoCancellation=\(processed) (\(echoChoice.reason)) input=\(capture ? microphone?.uid ?? "?" : "off") output=\(speakers.uid)")
        startRouteWatch(capture: capture, processed: processed, speakers: speakers, microphone: microphone, inputUID: inputUID, outputUID: outputUID, owner: owner)
    }

    private var lastConfigurationChange = Date()
    private var readySent = false

    /// Bluetooth can stop the engine while entering its microphone profile. Recover only during startup on the
    /// same confirmed devices, before any speech is accepted.
    private func observeStartup(processed: Bool, speakers: AudioDeviceChoice, microphone: AudioDeviceChoice?, common: AVAudioFormat, owner: Int) {
        let deadline = Date().addingTimeInterval(5)
        var restarts = 0
        readySent = false
        lastConfigurationChange = Date()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.lifecycle == owner, self.running else { return }
                self.lastConfigurationChange = Date()
                self.onDiagnosticConfiguration?()
                guard !self.engine.isRunning, !self.readySent, restarts < 3, Date() < deadline else { return }
                restarts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.lifecycle == owner, self.running, !self.engine.isRunning, !self.readySent else { return }
                        let output = self.engine.outputNode
                        guard audioDeviceMatches(output, speakers.id, 0), !processed || audioDeviceMatches(self.engine.inputNode, microphone!.id, 1) else {
                            self.failNow("Selected audio devices changed during startup."); return
                        }
                        guard !processed || (self.engine.inputNode.outputFormat(forBus: 0).isEqual(common) && output.inputFormat(forBus: 0).isEqual(common)) else {
                            self.failNow("Selected audio devices changed format during startup. Start voice again."); return
                        }
                        do {
                            let repair = self.beginPlaybackGraphRepair()
                            self.player.stop(); try self.engine.start()
                            self.playbackGraphReplacementInstalled(repair)
                        }
                        catch { self.failNow("Audio could not restart after Bluetooth setup: \(error.localizedDescription)") }
                    }
                }
            }
        }
    }

    private var deviceNames = ("", "")

    private func waitReady(capture: Bool, owner: Int) async throws {
        try checkStartup(owner)
        if let hooks = startupTestHooks { try await hooks.ready(); try checkStartup(owner); return }
        let deadline = Date().addingTimeInterval(5)
        while running {
            try checkStartup(owner)
            if engine.isRunning && (!capture || receivedInput) && Date().timeIntervalSince(lastConfigurationChange) > 0.3 {
                readySent = true
                log("audio: ready")
                return
            }
            if Date() > deadline {
                if !engine.isRunning {
                    throw audioError(7, "The audio engine did not start on \(deviceNames.0.isEmpty ? "the output" : "microphone \"\(deviceNames.0)\" and output \"\(deviceNames.1)\""). Check the devices (inputDevice/outputDevice in agent-voice's settings) and press Start voice again.")
                }
                if capture && !receivedInput {
                    throw audioError(12, "The microphone \"\(deviceNames.0)\" opened but sent no audio within 5 s. Check that it is connected and selected (inputDevice in agent-voice's settings), then press Start voice again.")
                }
                throw audioError(7, "The audio route kept changing during startup (Bluetooth?). Press Start voice again or choose another device.")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw CancellationError()
    }

    private func startRouteWatch(capture: Bool, processed: Bool, speakers: AudioDeviceChoice, microphone: AudioDeviceChoice?, inputUID: String, outputUID: String, owner: Int) {
        routeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.lifecycle == owner, self.running else { return }
                let available = Set(audioDevices().map(\.id))
                let outputOK = available.contains(speakers.id) && (outputUID == "default" || audioDeviceMatches(self.engine.outputNode, speakers.id, 0))
                let inputOK = !capture || (available.contains(microphone!.id) && (processed ? inputUID == "default" || audioDeviceMatches(self.engine.inputNode, microphone!.id, 1) : self.hal.matches(microphone!.id)))
                if !outputOK || !inputOK || (self.readySent && !self.engine.isRunning) {
                    self.failNow("Voice paused because the audio route changed or a device disconnected. Reconnect the headphones or set outputDevice in agent-voice.json, then press Start voice.")
                }
            }
        }
    }

    private func failNow(_ message: String) {
        log("audio: \(message)")
        close()
        onFailure?(audioError(8, message))
    }

    /// Same 16 kHz mono s16le stream as the voice-processing tap. Conversion runs off the real-time thread.
    private func startPlainCapture(_ device: AudioDeviceID, owner: Int) throws {
        let queue = captureQueue, live = self.live
        let fence = captureEpoch
        let mono = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        final class Box: @unchecked Sendable { var converter: AVAudioConverter?; var clean: AVAudioFormat?; var epoch = -1 }
        let box = Box()
        let rate = try hal.start(device: device) { [weak self] samples, count in
            let epoch = fence.current
            let copy = Array(UnsafeBufferPointer(start: samples, count: count))
            queue.async {
                guard fence.current == epoch else { return }
                if box.epoch != epoch { box.converter?.reset(); box.epoch = epoch }
                guard live.get, let clean = box.clean, let converter = box.converter, count > 0,
                      let source = AVAudioPCMBuffer(pcmFormat: clean, frameCapacity: AVAudioFrameCount(count)), let channel = source.floatChannelData else { return }
                source.frameLength = AVAudioFrameCount(count)
                _ = copy.withUnsafeBufferPointer { memcpy(channel[0], $0.baseAddress!, count * MemoryLayout<Float>.size) }
                let capacity = AVAudioFrameCount(ceil(Double(count) * 16000 / clean.sampleRate) + 32)
                guard let converted = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity) else { return }
                var used = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if used { status.pointee = .noDataNow; return nil }
                    used = true; status.pointee = .haveData; return source
                }
                guard error == nil, let out = converted.int16ChannelData, converted.frameLength > 0 else { return }
                let data = Data(bytes: out[0], count: Int(converted.frameLength) * 2)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    if fence.current == epoch, self?.lifecycle == owner { self?.deliver(data) }
                } }
            }
        }
        queue.sync {
            box.clean = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            box.converter = box.clean.flatMap { AVAudioConverter(from: $0, to: mono) }
        }
        guard box.converter != nil else { throw audioError(4, "Microphone audio cannot be converted.") }
    }

    private func deliver(_ data: Data) {
        guard running, capturing else { return }
        // All-zero frames (no permission, dead device) do not count as live input.
        if !receivedInput && data.contains(where: { $0 != 0 }) { receivedInput = true }
        guard receivedInput else { return }
        onPCM?(data)
    }

    // MARK: AudioOutput

    public func play(_ audio: SpeechAudio, label: String, onStart: @escaping () -> Void) async throws {
        try Task.checkCancellation()
        if !running { close() }
        let owner = lifecycle, gen = generation
        if !running { try await begin(capture: false, owner: owner) }
        else if let startup { try await startup.value }
        try checkStartup(owner)
        guard gen == generation else { return }
        // The engine stops during a route change (Bluetooth); the route watch then pauses voice.
        guard engine.isRunning else { throw audioError(13, "Audio output is not running (the audio route changed). Check the output device, then use Stop voice and Start voice to retry.") }
        await awaitProducer()
        guard gen == generation else { return }
        guard let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(audio.sampleRate), channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: Self.speechFormat) else { throw audioError(9, "Unsupported speech sample rate \(audio.sampleRate)") }
        var carry = Data()
        var pending = 0
        var ended = false
        var started = false
        var seconds = 0.0
        let begin = activeTime
        let waiterID = nextWaiter
        nextWaiter += 1
        var finished: CheckedContinuation<Void, Never>?

        func schedule(_ buffer: AVAudioPCMBuffer) {
            guard buffer.frameLength > 0 else { return }
            pending += 1
            seconds += Double(buffer.frameLength) / 48000
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == gen else { return }
                        pending -= 1
                        if pending == 0 && ended { finished?.resume(); finished = nil; self.waiters[waiterID] = nil }
                    }
                }
            }
            if !started { started = true; onStart() }
        }

        func convert(_ bytes: Data, final: Bool) {
            var input: AVAudioPCMBuffer?
            if !bytes.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(bytes.count / 2)) {
                b.frameLength = b.frameCapacity
                bytes.withUnsafeBytes { raw in if let base = raw.baseAddress { memcpy(b.int16ChannelData![0], base, bytes.count) } }
                input = b
            }
            let frames = Double(bytes.count / 2) * 48000 / Double(audio.sampleRate)
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.speechFormat, frameCapacity: AVAudioFrameCount(frames + 4096)) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if !supplied, let input { supplied = true; status.pointee = .haveData; return input }
                status.pointee = final ? .endOfStream : .noDataNow
                return nil
            }
            if error == nil { schedule(out) }
        }

        do {
            for try await chunk in audio.chunks {
                await awaitProducer()
                guard gen == generation else { return }
                var bytes = carry + chunk
                carry = Data()
                if bytes.count % 2 == 1 { carry = bytes.suffix(1); bytes = bytes.dropLast() }
                convert(Data(bytes), final: false)
            }
        } catch {
            if gen != generation { return }
            throw error
        }
        await awaitProducer()
        guard gen == generation else { return }
        convert(Data(), final: true)
        ended = true
        if pending == 0 { return }
        // Wait for playback to finish; stopPlayback() resumes early. Guard against a stalled device.
        let deadline = activeTime + max(0, seconds - (activeTime - begin)) + 5
        let timedOut = AtomicFlag()
        var timeoutTask: Task<Void, Never>?
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finished = c
            waiters[waiterID] = c
            timeoutTask = Task { @MainActor in
                while !Task.isCancelled, self.generation == gen, self.waiters[waiterID] != nil {
                    if !self.automaticCutInPaused && !self.graphRepair.inProgress && self.activeTime >= deadline {
                        guard let c = self.waiters.removeValue(forKey: waiterID) else { return }
                        timedOut.set(true); finished = nil; c.resume(); return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        timeoutTask?.cancel()
        if timedOut.get && gen == generation { throw audioError(10, "Selected output device stopped playing. Check the output device, then use Stop voice and Start voice to retry.") }
    }

    public func stopPlayback() {
        generation += 1
        automaticCutInPaused = false
        cutInGain = 1; player.volume = 1
        releaseProducer()
        player.stop()
        // player.play() raises if the engine is stopped (route change, Bluetooth profile switch).
        if running && engine.isRunning && !graphRepair.inProgress { player.play() }
        let all = waiters
        waiters = [:]
        all.values.forEach { $0.resume() }
    }

    private func close() {
        lifecycle += 1
        captureEpoch.advance()
        _ = graphRepair.begin() // Fence synchronous rollback before stop/close callbacks.
        startup?.cancel(); startup = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
        routeTimer?.invalidate(); routeTimer = nil
        live.set(false)
        let wasRunning = running
        running = false
        capturing = false
        stopPlayback()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if playerTapInstalled { player.removeTap(onBus: 0); playerTapInstalled = false }
        hal.stop()
        engine.stop()
        if voiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false); voiceProcessing = false }
        if engine.attachedNodes.contains(player) { engine.detach(player) }
        engine.reset()
        graphRepair.resetAfterClose()
        startupTestHooks?.closed()
        // The next start builds a fresh engine and player.
        if wasRunning { log("audio: closed (microphone released)") }
    }
}
