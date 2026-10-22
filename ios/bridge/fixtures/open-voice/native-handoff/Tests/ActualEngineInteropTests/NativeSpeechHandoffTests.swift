#if DEBUG && os(macOS)
import XCTest
import Foundation
import AVFoundation
@testable import FloatingVoiceCore

// Setup/lifetime reused from accepted ActualEngineInteropTests.InteropContext.
@MainActor private final class InteropContext {
    let peer: ActualEngineFixture
    let control: OpenVoiceRecipientControl
    let invitation: OpenVoiceInvitation
    let journal: OpenVoiceOperationJournal
    let directory: URL
    var backends: [OpenVoiceBackend] = []
    init(peer: ActualEngineFixture, control: OpenVoiceRecipientControl, invitation: OpenVoiceInvitation, directory: URL) {
        self.peer = peer; self.control = control; self.invitation = invitation; self.directory = directory
        journal = OpenVoiceOperationJournal(file:directory.appendingPathComponent("journal.json"))
    }
    static func start(_ scenario: String) async throws -> InteropContext {
        let peer = try await ActualEngineFixture.start(scenario)
        var openedControl: OpenVoiceRecipientControl?
        do {
            let control = try peer.control(); openedControl = control
            _ = try await control.capability(enabled:true,build:peer.build)
            let notice = try await peer.command("invite")
            guard let raw = notice["call_id"].string, let id = UUID(uuidString:raw) else { throw FixtureFailure.protocolFailure }
            let ringing = try await control.invitation(callID:id)
            let accepted = try await control.accept(ringing)
            let directory = peer.root.appendingPathComponent("swift-run-" + UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            return InteropContext(peer:peer,control:control,invitation:accepted,directory:directory)
        } catch { openedControl?.close(); await peer.stop(); throw error }
    }
    func backend(_ test: XCTestCase, activate: Bool = true) async throws -> OpenVoiceBackend {
        let lease = try await control.mediaLease(invitation)
        let pump = try peer.pump(lease)
        let backend = try OpenVoiceBackend(pump:pump,invitation:invitation,control:control,journal:journal)
        backends.append(backend)
        let configured = test.expectation(description:"actual same-socket effective configuration")
        var seen = false; let previous = pump.client.onState
        pump.client.onState = { state in
            previous?(state)
            if state == .configured && !seen { seen = true; configured.fulfill() }
        }
        try await backend.startMedia()
        await test.fulfillment(of:[configured],timeout:4)
        XCTAssertFalse(backend.ready)
        if activate {
            backend.nativeCaptureChanged(true) // Synthetic activation; no hardware.
            _ = try await backend.connect()
            XCTAssertTrue(backend.ready); XCTAssertTrue(pump.reportedReady)
        }
        return backend
    }
    func stop() async {
        for backend in backends.reversed() { await backend.shutdown(closeControl:false) }
        control.close(); await peer.stop()
        try? FileManager.default.removeItem(at:directory)
    }
}

final class NativeSpeechHandoffTests: XCTestCase {
    @MainActor func testCandidateReadyReplacesLegacyActivityBeforeCaptureOnset() async throws {
        let c = try await InteropContext.start("normal") // Grounded fake STT only.
        let backend: OpenVoiceBackend
        do { backend = try await c.backend(self, activate:false) }
        catch { await c.stop(); throw error }
        let input = HardwareShapedInput(), output = FakeOutput(duration:0), surface = VoiceSurface()
        var clock = 100_000.0
        surface.update(records:[],connection:"connected",active:true) // Prior legacy execution.
        let binding = surface.replaceBinding(target:backend.target)
        surface.preparing = true
        var voice = VoiceConfig(); voice.pauseMs = AppSettings.defaultPauseMs
        let settings = LoadedSettings(app:AppSettings(), voice:voice, voiceFile:nil,
            appFile:c.directory.appendingPathComponent("unused-settings.json").path,
            chiefFile:c.directory.appendingPathComponent("unused-chief.json").path)
        let controller = ConversationController(settings:settings, backend:backend,
            synth:OpenVoicePreparedOnlySynthesizer(), output:output, input:input,
            makeRecognition:{ OpenVoiceRecognition(client:backend.pump.client,callbacks:$0,discardUnsentOnCancel:true) },now:{ clock })
        let lifecycle = NativeVoiceLifecycle(); lifecycle.controller = controller
        var meterFrames = 0, meterPeak = 0.0
        controller.onStatus = { surface.update(status:$0,owner:binding) }
        controller.onCaption = { event in
            if case .micLevel(let level) = event { meterFrames += 1; meterPeak = max(meterPeak,level) }
            surface.handle(event,owner:binding)
        }
        input.onRunning = {
            surface.updateCapture(.running,owner:binding)
            XCTAssertEqual(surface.state,"Preparing microphone…", "Capture alone is not candidate readiness")
        }
        input.onStopped = { surface.updateCapture(.off,owner:binding) }
        let owner = lifecycle.requestStart()
        var closed = false, stoppedAtClose = false
        let originalClose = backend.onMediaClosed // Preserve actual Controller hook.
        backend.onMediaClosed = {
            originalClose?(); closed = true
            stoppedAtClose = !input.started && input.onPCM == nil && !controller.status.running
        }
        let startup = Task { await lifecycle.start(owner) }
        do {
            await startup.value
            XCTAssertTrue(lifecycle.isCurrent(owner)); XCTAssertTrue(input.started)
            XCTAssertEqual(input.starts,1); XCTAssertEqual(input.stops,0)
            XCTAssertTrue(input.readyInsideStart)
            XCTAssertEqual(backend.pump.client.admittedSamples,0)
            let ready = await waitUntil { controller.status.phase == "ready" && backend.ready }
            XCTAssertTrue(ready); guard ready else { throw FixtureFailure.timeout }
            surface.preparing = false
            XCTAssertEqual(surface.state,"Listening", "A candidate must not inherit legacy Agent thinking before any speech")
            guard surface.state == "Listening" else { throw FixtureFailure.protocolFailure }
            XCTAssertTrue(controller.status.manualSend); XCTAssertNotNil(controller.currentLease)
            let oldPCM = try XCTUnwrap(input.onPCM)
            // Quiet, realistic 48k/100ms tap buffers first. Silence is NOT
            // forced through VAD merely to produce nonzero network ingress.
            for _ in 0..<10 {
                clock += 100; try input.hardware(rms:0.0007); controller.checkCandidateInputProgress()
                try await Task.sleep(nanoseconds:100_000_000)
            }
            XCTAssertGreaterThan(meterFrames,0); XCTAssertEqual(backend.pump.client.admittedSamples,0)
            XCTAssertEqual(surface.state,"Listening")
            lifecycle.setMicMuted(true); clock += 6000; try input.hardware(rms:0.025)
            controller.checkCandidateInputProgress()
            XCTAssertTrue(controller.status.running); XCTAssertTrue(controller.status.micMuted)
            XCTAssertEqual(backend.pump.client.admittedSamples,0)
            lifecycle.setMicMuted(false)
            // State-only negative: legitimate work is not capture failure. No
            // response.create/SDK operation is sent by this synthetic event.
            controller.handle(ServerEvent(type:"session.execution.started",data:["sessionID":backend.target.sessionID]))
            clock += 6000; controller.checkCandidateInputProgress()
            XCTAssertTrue(controller.status.running); XCTAssertTrue(controller.status.busy)
            controller.handle(ServerEvent(type:"session.execution.succeeded",data:["sessionID":backend.target.sessionID]))
            // 0.025 RMS voiced PCM after calibration, then native default pause.
            // Actual converter/framer, Controller VAD and endpoint own all sends.
            for n in 0..<41 { // One 100-ms chunk beyond pause: converter tail can straddle the first quiet frame.
                clock += 100
                try input.hardware(rms:n < 8 ? 0.025 : 0)
                controller.checkCandidateInputProgress()
                try await Task.sleep(nanoseconds:100_000_000)
                guard input.started && controller.status.running && backend.ready && !closed else {
                    XCTFail("capture/media stopped before normal endpoint"); throw FixtureFailure.protocolFailure
                }
            }
            print("CANDIDATE_PCM produced=\(input.captureProgress.producedFrames) delivered=\(input.delivered) meterFrames=\(meterFrames) meterPeak=\(meterPeak) hearing=\(controller.status.hearing) admitted=\(backend.pump.client.admittedSamples)")
            let held = await waitUntil { controller.status.holding == "neutral fixture" }
            XCTAssertTrue(held); guard held else { throw FixtureFailure.timeout }
            XCTAssertEqual(controller.status.phase,"ready"); XCTAssertNil(controller.status.lastError)
            XCTAssertFalse(controller.status.busy); XCTAssertFalse(controller.status.hearing)
            XCTAssertEqual(input.starts,1); XCTAssertEqual(input.stops,0); XCTAssertFalse(closed)
            XCTAssertGreaterThan(backend.pump.client.admittedSamples,0)
            XCTAssertEqual(backend.pump.client.sentSamples,backend.pump.client.admittedSamples)
            XCTAssertEqual(backend.pump.client.consumedSamples,backend.pump.client.admittedSamples)
            let snapshot = try await c.peer.command("snapshot")
            XCTAssertGreaterThan(snapshot["samples"].number ?? 0,0); XCTAssertEqual(snapshot["finishes"],.number(1))
            XCTAssertEqual(snapshot["speechEvents"]["closeCode"],.number(1000))
            XCTAssertEqual(snapshot["submits"],.number(0)); XCTAssertEqual(snapshot["operations"].array?.count,0)
            XCTAssertTrue(c.journal.records.isEmpty); XCTAssertTrue(output.plays.isEmpty)
            let stages = try JSONDecoder().decode([DiagnosticEntry].self,from:Data(StageDiagnostics.shared.export().utf8))
            XCTAssertTrue(stages.filter { $0.audio?.values["openVoiceFailureOrigin"] != nil }.isEmpty)
            // Demonstrated safety defect: source conversion/delivery keeps
            // advancing but its Controller callback is lost. It must fail, not
            // stay "Listening" forever. This is not a claim about the old phone.
            var failure: CandidateInputFailure?
            controller.onCandidateInputFailure = { failure = $0 }
            input.onPCM = nil; clock += 6000; try input.hardware(rms:0.025)
            controller.checkCandidateInputProgress()
            XCTAssertEqual(failure,.deliveryStalled)
            XCTAssertNotNil(controller.status.lastError)
            XCTAssertFalse(surface.state.contains("thinking")); XCTAssertNotEqual(surface.state,"Listening")
            let finalStages = try JSONDecoder().decode([DiagnosticEntry].self,from:Data(StageDiagnostics.shared.export().utf8))
            let faults = finalStages.filter { $0.audio?.values["candidateInputFailure"] != nil }
            XCTAssertEqual(faults.count,1); XCTAssertEqual(faults.first?.audio?.values["candidateInputFailure"],2)
            XCTAssertGreaterThan(faults.first?.audio?.values["candidateProducedFrames"] ?? 0,
                faults.first?.audio?.values["candidateReceivedFrames"] ?? 0)
            XCTAssertEqual(faults.first?.audio?.values["candidateVADOnsets"],1)
            XCTAssertFalse(controller.draftsForReview.isEmpty) // Held words retained, never resubmitted.
            lifecycle.invalidate(); startup.cancel()
            XCTAssertTrue(closed); XCTAssertTrue(stoppedAtClose)
            XCTAssertFalse(lifecycle.isCurrent(owner)); XCTAssertNil(input.onPCM)
            let admitted = backend.pump.client.admittedSamples
            oldPCM(FakeInput.tone); await Task.yield()
            XCTAssertEqual(backend.pump.client.admittedSamples,admitted)
            XCTAssertEqual(input.starts,1); XCTAssertFalse(input.started)
            print("CANDIDATE_GATE_PASS readyInsideStart=true quietAdmitted=0 preSpeechListening=true voicedAdmitted=\(admitted) close=1000 submits=0 operations=0 cleanupCaptureStopped=true stalePCMFenced=true")
        } catch {
            print("CONTROLLER_FAILURE running=\(controller.status.running) phase=\(controller.status.phase) inputStarts=\(input.starts) inputStops=\(input.stops) client=\(backend.pump.client.state)")
            print(StageDiagnostics.shared.export())
            lifecycle.invalidate(); startup.cancel(); controller.stop(discardUnfinished:true)
            await c.stop(); throw error
        }
        await c.stop()
    }
    @MainActor func testActualNativePacedPCMThroughProductionSpeech() async throws {
        let realSTT = ProcessInfo.processInfo.environment["FV_HANDOFF_REAL_STT"] == "1"
        let c = try await InteropContext.start(realSTT ? "real-stt" : "normal")
        do {
            let backend = try await c.backend(self), client = backend.pump.client
            var mediaClosed = false, errors = 0, finalText: String?
            backend.onMediaClosed = { mediaClosed = true }
            backend.onFailure = { _ in errors += 1 }
            let final = expectation(description:"actual native recognition final")
            let recognizer = OpenVoiceRecognition(client:client, callbacks:RecognitionCallbacks(
                partial:{ _ in }, error:{ _ in errors += 1 }, done:{ text in finalText = text; final.fulfill() }),
                discardUnsentOnCancel:true)
            recognizer.start()
            var pcm = Data()
            for i in 0..<320 {
                let sample = UInt16(bitPattern:Int16((1000 * sin(Double(i) / 7)).rounded()))
                pcm.append(UInt8(sample & 255)); pcm.append(UInt8(sample >> 8))
            }
            // Actual ordinary capture seam (write, not writeBuffered/flush). The
            // production owner pump, including its safety wake, owns all sends.
            for _ in 0..<134 {
                recognizer.write(pcm)
                try await Task.sleep(nanoseconds:20_000_000)
                XCTAssertEqual(client.state, .ready); XCTAssertFalse(mediaClosed)
                guard client.state == .ready && !mediaClosed else { throw FixtureFailure.protocolFailure }
            }
            XCTAssertEqual(client.admittedSamples, 64320)
            let beforeCommit = try await c.peer.command("snapshot")
            XCTAssertEqual(beforeCommit["finishes"], .number(0))
            XCTAssertEqual(beforeCommit["submits"], .number(0))
            recognizer.end(); backend.pump.signalWrites()
            await fulfillment(of:[final],timeout:5)
            if realSTT { XCTAssertNotNil(finalText) } // Empty successful tone recognition is truthful.
            else { XCTAssertEqual(finalText, "neutral fixture") }
            XCTAssertEqual(errors, 0)
            guard errors == 0 && finalText != nil && client.state == .ready && !mediaClosed else { throw FixtureFailure.protocolFailure }
            XCTAssertEqual(client.state, .ready); XCTAssertFalse(mediaClosed)
            XCTAssertEqual(client.sentSamples, 64320); XCTAssertEqual(client.consumedSamples, 64320)
            let snapshot = try await c.peer.command("snapshot")
            if !realSTT {
                XCTAssertEqual(snapshot["samples"], .number(42880)) // Peer-observed STT 16k samples.
                XCTAssertEqual(snapshot["segments"], .number(1)); XCTAssertEqual(snapshot["finishes"], .number(1))
            }
            XCTAssertEqual(snapshot["adapterInputSamples"], .number(64320))
            XCTAssertEqual(snapshot["speechEvents"]["closeCode"], .number(1000))
            XCTAssertEqual(snapshot["speechEvents"]["error"], .number(0))
            XCTAssertEqual(snapshot["speechEvents"]["other"], .number(0))
            XCTAssertEqual(snapshot["submits"], .number(0)); XCTAssertEqual(snapshot["synthesisPulls"], .number(0))
            XCTAssertEqual(snapshot["operations"].array?.count, 0)
            XCTAssertTrue(c.journal.records.isEmpty)
            let stages = try JSONDecoder().decode([DiagnosticEntry].self, from:Data(StageDiagnostics.shared.export().utf8))
            XCTAssertTrue(stages.filter { $0.audio?.values["openVoiceFailureOrigin"] != nil }.isEmpty)
            print("HANDOFF_PASS realSTT=\(realSTT) blocks=134 admitted24k=\(client.admittedSamples) sent24k=\(client.sentSamples) consumed24k=\(client.consumedSamples) final=normal finalNonempty=\(!(finalText ?? "").isEmpty) close=1000 submits=0 operations=0 mediaClosed=false")
        } catch {
            if let client = c.backends.last?.pump.client {
                print("HANDOFF_FAILURE state=\(client.state) admitted=\(client.admittedSamples) sent=\(client.sentSamples) consumed=\(client.consumedSamples)")
                print(StageDiagnostics.shared.export()) // Closed numeric schema only.
            }
            if let snapshot = try? await c.peer.command("snapshot") {
                print("HANDOFF_SPEECH_CLASSIFICATIONS " + String(decoding:try snapshot["speechEvents"].encoded(),as:UTF8.self))
            }
            await c.stop(); throw error
        }
        await c.stop()
    }
}

// Same CaptureIngress/CaptureLifecycle/CaptureGraphAdmission and main-actor
// eligibility/order as IOSAudio.installInputHandler; only AVAudioEngine/tap and
// CallKit resources are replaced. No fake recognizer or raw-audio persistence.
@MainActor private final class HardwareShapedInput: AudioInput, DuplexReporting, CaptureOriginReporting, CaptureProgressReporting {
    var onPCM: ((Data) -> Void)?, onFailure: ((Error) -> Void)?
    var onDuplexChange: (() -> Void)?, onRunning: (() -> Void)?, onStopped: (() -> Void)?
    var duplexSafe = true, lastCaptureRendered = false, lastCaptureDuplexSafe = true
    let capture = CaptureLifecycle()
    var ingress = CaptureIngress(), graph = CaptureGraphAdmission()
    var graphGeneration = 0, owner = 0, starts = 0, stops = 0, delivered = 0
    var readyInsideStart = false
    var started: Bool { capture.capturing }
    var captureGraphReady: Bool { graph.ready }
    var captureProgress: CaptureProgress { CaptureProgress(producedFrames:ingress.snapshot().frames,deliveredFrames:delivered) }
    func discardPendingAudio() { ingress.discardPendingAudio() }
    func start() async throws {
        starts += 1
        try await capture.start(permission:{},activate:{},open:{ owner in
            self.owner = owner; self.graph.installed(self.graphGeneration)
        },close:{ self.graph.beginRepair(); self.ingress.invalidate(); self.onDuplexChange?() },deactivate:{},ready:{ _ in
            try self.hardware(rms:0.0007)
            self.readyInsideStart = self.graph.ready; self.onRunning?()
            await Task.yield()
        })
    }
    func hardware(rms: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800)!
        buffer.frameLength = 4800
        for n in 0..<4800 { buffer.floatChannelData![0][n] = Float(rms * sqrt(2) * sin(Double(n) * 2 * .pi * 400 / 48000)) }
        let speech = ingress.speechGeneration, graphOwner = graphGeneration
        let frames = try ingress.consume(buffer,hardware:true,speechGeneration:speech)
        guard capture.admits(owner), graphGeneration == graphOwner, ingress.admitsSpeech(speech) else { return }
        let wasReady = graph.ready; graph.delivered(graphOwner)
        if !wasReady && graph.ready { onDuplexChange?() }
        for frame in frames {
            guard ingress.admitsSpeech(speech) else { return }
            delivered += 1; onPCM?(frame)
        }
    }
    func stop() {
        stops += 1
        capture.stop(close:{ self.graph.beginRepair(); self.ingress.invalidate(); self.onDuplexChange?() },deactivate:{})
        onStopped?()
    }
}
#endif
