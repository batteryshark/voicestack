import AVFoundation
import CallKit
import UIKit
import SwiftUI
import AVKit

final class BundledHoldMusicTicket: SpeechTicket {
    let text = ""
    private let pcm: Data
    private var cancelled = false
    init?() {
        guard let url = Bundle.main.url(forResource:"HoldMusic",withExtension:"pcm"),
              let data = try? Data(contentsOf:url), !data.isEmpty, data.count <= 1_440_000 else { return nil }
        pcm = data
    }
    func audio() async throws -> SpeechAudio {
        guard !cancelled else { throw CancellationError() }
        return .whole(pcm,sampleRate:24000)
    }
    func cancel() { cancelled = true }
}

extension CallCoordinator {
    convenience init(audio: AudioSessionCoordinator) {
        self.init(makeProvider: { NativeCallProvider(audio: audio, lifecycle: $0) })
        audio.call = lifecycle
    }
}

/// One immutable provider identity per call. Retire/reset before admitting its replacement;
/// the core coordinator fences callbacks from this adapter even after retirement.
@MainActor private final class NativeCallProvider: NSObject, CallProviderAdapter, @preconcurrency CXProviderDelegate {
    var onEvent: ((CallProviderEvent) -> Void)?
    private let provider: CXProvider
    private let controller = CXCallController()
    private let audio: AudioSessionCoordinator
    private static var nextInstance = 0
    private let diagnosticInstance: Int
    init(audio: AudioSessionCoordinator, lifecycle: CallLifecycle) {
        self.audio = audio
        Self.nextInstance += 1; diagnosticInstance = Self.nextInstance
        let config = VoicestackCallKitPresentation.configuration()
        provider = CXProvider(configuration: config)
        super.init()
        audio.beginCallRoute()
        provider.setDelegate(self, queue: .main)
        audio.onRoute = { [weak self] in self?.onEvent?(.routeChanged) }
        // Schedule diagnostics after the synchronous mandatory PushKit report path.
        let instance = diagnosticInstance
        Task { @MainActor in StageDiagnostics.shared.record(.call, .begin, audio: CaptureSnapshot([.providerInstance: Double(instance), .processID: Double(ProcessInfo.processInfo.processIdentifier)]), callEvent: .providerCreated) }
    }
    deinit { StageDiagnostics.shared.record(.call, .complete, audio: CaptureSnapshot([.providerInstance: Double(diagnosticInstance)]), callEvent: .providerDeallocated) }
    var routeLabel: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map {
            switch $0.portType {
            case .builtInReceiver: return "Phone"
            case .builtInSpeaker: return "Speaker"
            case .bluetoothHFP: return "Bluetooth HFP"
            case .bluetoothLE: return "Bluetooth LE"
            case .bluetoothA2DP: return "Bluetooth audio"
            default: return "Headset / external"
            }
        }.joined(separator: " · ")
    }
    func toggleSpeaker() {
        do { try audio.toggleLiveRoute() }
        catch RouteSwitchError.unavailable { onEvent?(.controlRejected) }
        catch { onEvent?(.failed(error.localizedDescription)) }
    }
    func requestStart(_ id: UUID, completion: @escaping (Error?) -> Void) {
        StageDiagnostics.shared.record(.call, .begin, status: 1)
        VoiceTrace.shared.event("call.startRequested")
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: AgentPresentation.name))
        controller.request(CXTransaction(action: action)) { error in Task { @MainActor in completion(error) } }
    }
    func reportIncoming(_ id: UUID, completion: @escaping (Error?) -> Void) {
        let update = CXCallUpdate()
        update.localizedCallerName = AgentPresentation.name; update.remoteHandle = CXHandle(type: .generic, value: AgentPresentation.name)
        update.supportsHolding = true; update.supportsGrouping = false; update.supportsUngrouping = false
        update.supportsDTMF = false; update.hasVideo = false
        provider.reportNewIncomingCall(with: id, update: update) { error in
            let closed: IncomingReportError? = error.map { error in
                let value = error as NSError
                var failure: IncomingReportFailure = .other
                if value.domain == CXErrorDomainIncomingCall {
                    switch value.code {
                    case CXErrorCodeIncomingCallError.unentitled.rawValue: failure = .unentitled
                    case CXErrorCodeIncomingCallError.callUUIDAlreadyExists.rawValue: failure = .callUUIDAlreadyExists
                    case CXErrorCodeIncomingCallError.filteredByDoNotDisturb.rawValue: failure = .filteredByDoNotDisturb
                    case CXErrorCodeIncomingCallError.filteredByBlockList.rawValue: failure = .filteredByBlockList
                    default: break
                    }
                }
                return IncomingReportError(code: value.code, failure: failure)
            }
            Task { @MainActor in completion(closed) }
        }
    }
    func requestEnd(_ id: UUID) {
        StageDiagnostics.shared.record(.call, .cancelled, status: 9)
        VoiceTrace.shared.event("call.endRequested")
        controller.request(CXTransaction(action: CXEndCallAction(call: id))) { _ in }
    }
    func requestMute(_ id: UUID, muted: Bool) { request(CXSetMutedCallAction(call: id, muted: muted)) }
    func requestHold(_ id: UUID, held: Bool) { request(CXSetHeldCallAction(call: id, onHold: held)) }
    private func request(_ action: CXCallAction) {
        controller.request(CXTransaction(action: action)) { [weak self] error in
            Task { @MainActor in if let error { self?.onEvent?(.failed(error.localizedDescription)) } }
        }
    }
    func configure() throws { try audio.configure() }
    func connecting(_ id: UUID) {
        let update = CXCallUpdate()
        update.localizedCallerName = AgentPresentation.name; update.remoteHandle = CXHandle(type: .generic, value: AgentPresentation.name)
        update.supportsHolding = true; update.supportsGrouping = false
        update.supportsUngrouping = false; update.supportsDTMF = false; update.hasVideo = false
        provider.reportCall(with: id, updated: update)
        provider.reportOutgoingCall(with: id, startedConnectingAt: Date())
    }
    func connected(_ id: UUID) { provider.reportOutgoingCall(with: id, connectedAt: Date()) }
    func ended(_ id: UUID, reason: CallEndReason) { provider.reportCall(with: id, endedAt: Date(), reason: reason == .failed ? .failed : .remoteEnded) }
    func observeActivation(_ granted: Bool) { audio.activationObserved(granted) }
    func refresh(proximity: Bool) {
        audio.refreshProximity(activeCall: proximity)
    }
    func invalidate() {
        StageDiagnostics.shared.record(.call, .cancelled, audio: CaptureSnapshot([.providerInstance: Double(diagnosticInstance)]), callEvent: .providerInvalidated)
        provider.invalidate()
    }
    private func complete(_ action: CXAction) -> (Bool) -> Void { { success in if success { action.fulfill() } else { action.fail() } } }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) { onEvent?(.answer(action.callUUID, complete(action))) }
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        StageDiagnostics.shared.record(.call, .begin, status: 2)
        VoiceTrace.shared.event("call.startAction")
        onEvent?(.start(action.callUUID, complete(action)))
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) { onEvent?(.end(action.callUUID, complete(action))) }
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) { onEvent?(.mute(action.callUUID, action.isMuted, complete(action))) }
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) { onEvent?(.hold(action.callUUID, action.isOnHold, complete(action))) }
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        StageDiagnostics.shared.record(.call, .ready, status: 3)
        VoiceTrace.shared.event("call.didActivate")
        onEvent?(.activated)
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        StageDiagnostics.shared.record(.call, .suspended, status: 8)
        VoiceTrace.shared.event("call.didDeactivate")
        onEvent?(.deactivated)
    }
    func providerDidReset(_ provider: CXProvider) {
        StageDiagnostics.shared.record(.call, .cancelled, audio: CaptureSnapshot([.providerInstance: Double(diagnosticInstance)]), callEvent: .providerReset, callEndInitiator: .providerReset)
        onEvent?(.reset)
    }
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        if let action = action as? CXCallAction { onEvent?(.timedOut(action.callUUID)) }
    }
}

struct CallRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
