import Foundation
import Testing
@testable import FloatingVoiceCore

@MainActor final class FakeCallProvider: CallProviderAdapter {
    var onEvent: ((CallProviderEvent) -> Void)?
    var id: UUID!
    var startCompletion: ((Error?) -> Void)?
    var configured = false, startFulfilled = false
    var connectedCount = 0, endedCount = 0, invalidations = 0
    var grants: [Bool] = []
    var reportError: Error?
    var routeToggleCount = 0
    var routeLabel: String { "Receiver" }
    func requestStart(_ id: UUID, completion: @escaping (Error?) -> Void) { self.id = id; startCompletion = completion }
    func requestEnd(_ id: UUID) {}
    func reportIncoming(_ id: UUID, completion: @escaping (Error?) -> Void) { completion(reportError) }
    func requestMute(_ id: UUID, muted: Bool) { emit(.mute(id, muted, { #expect($0) })) }
    func requestHold(_ id: UUID, held: Bool) { emit(.hold(id, held, { #expect($0) })) }
    func configure() throws { configured = true }
    func connecting(_ id: UUID) { #expect(configured) }
    func connected(_ id: UUID) { connectedCount += 1 }
    func ended(_ id: UUID, reason: CallEndReason) { endedCount += 1 }
    func observeActivation(_ granted: Bool) { grants.append(granted) }
    func refresh(proximity: Bool) {}
    func toggleSpeaker() { routeToggleCount += 1 }
    func invalidate() { invalidations += 1 } // reset/release explicitly driven by each test
    func emit(_ event: CallProviderEvent) { onEvent?(event) }
    func performStart() {
        emit(.start(id, { [self] success in
            #expect(success && configured)
            startFulfilled = success
        }))
    }
}

@MainActor final class CallCoordinatorRig {
    var providers: [FakeCallProvider] = []
    var starts = 0, pauses = 0, ends = 0
    var errors: [String] = []
    var begin: (() async -> Bool)?
    lazy var calls: CallCoordinator = {
        let calls = CallCoordinator(makeProvider: { [unowned self] _ in
            let provider = FakeCallProvider(); providers.append(provider); return provider
        })
        calls.beginMedia = { [unowned self] _ in starts += 1; return await begin?() ?? true }
        calls.pauseMedia = { [unowned self] in pauses += 1 }
        calls.endMedia = { [unowned self] in ends += 1 }
        calls.failed = { [unowned self] in errors.append($0) }
        return calls
    }()
    let target = TargetLease(sessionID: "ses_A", generation: "one")
    func start() -> FakeCallProvider {
        calls.start(target: target)
        let provider = providers.last!; provider.performStart(); return provider
    }
    func active() async -> FakeCallProvider {
        let provider = start()
        #expect(provider.startFulfilled && starts == 0) // no fulfil/activation deadlock
        provider.emit(.activated)
        #expect(await waitUntil { self.calls.lifecycle.state == .active })
        return provider
    }
    func cleanup(_ provider: FakeCallProvider) { calls.end(); provider.emit(.reset) }
}

@Suite(.serialized) @MainActor struct CallCoordinatorRegressionTests {
    @Test func holdUnholdBeforeReleaseWaitsForNewActivation() async {
        let rig = CallCoordinatorRig()
        let p = await rig.active()
        rig.calls.hold(true); rig.calls.hold(false)
        #expect(!rig.calls.lifecycle.mayRunMedia)
        p.emit(.activated) // duplicate old activation, before the held cycle releases
        await Task.yield()
        #expect(rig.starts == 1 && !rig.calls.lifecycle.mayRunMedia)
        p.emit(.deactivated); p.emit(.activated)
        #expect(await waitUntil { rig.starts == 2 && rig.calls.lifecycle.state == .active })
        rig.cleanup(p)
    }

    @Test func activationWhileHeldIsNotSavedForUnhold() async {
        let rig = CallCoordinatorRig(); let p = await rig.active()
        rig.calls.hold(true); p.emit(.deactivated)
        p.emit(.activated) // OS grants while held; never a usable resume grant
        rig.calls.hold(false)
        #expect(!rig.calls.lifecycle.activationGranted && !rig.calls.lifecycle.mayRunMedia)
        p.emit(.activated)
        await Task.yield()
        #expect(rig.starts == 1)
        p.emit(.deactivated); p.emit(.activated)
        #expect(await waitUntil { rig.starts == 2 })
        rig.cleanup(p)
    }

    @Test func delayedDeactivationFencesResumedSetupCompletion() async {
        let rig = CallCoordinatorRig(); let p = await rig.active()
        rig.calls.hold(true); p.emit(.deactivated); rig.calls.hold(false)
        var continuation: CheckedContinuation<Bool, Never>?
        rig.begin = { await withCheckedContinuation { continuation = $0 } }
        p.emit(.activated)
        #expect(await waitUntil { continuation != nil })
        p.emit(.deactivated)
        continuation?.resume(returning: true)
        await Task.yield()
        #expect(!rig.calls.lifecycle.mayRunMedia && rig.calls.lifecycle.state != .active)
        #expect(p.connectedCount == 1)
        rig.begin = { true }; p.emit(.activated)
        #expect(await waitUntil { rig.starts == 3 && rig.calls.lifecycle.state == .active })
        rig.cleanup(p)
    }

    @Test func rapidEndStartWaitsForReleaseAndOldCallbacksCannotTouchReplacement() async {
        let rig = CallCoordinatorRig(); let a = await rig.active()
        rig.calls.end(); rig.calls.start(target: rig.target)
        #expect(rig.providers.count == 1 && !rig.calls.hasCall)
        #expect(!rig.errors.isEmpty && a.invalidations == 1)
        a.emit(.activated)
        #expect(rig.starts == 1)
        a.emit(.deactivated) // real-phone late release after End
        let b = rig.start()
        a.emit(.activated); a.emit(.deactivated); a.emit(.reset)
        #expect(rig.calls.hasCall && !rig.calls.lifecycle.mayRunMedia)
        #expect(rig.starts == 1 && rig.ends == 1)
        b.emit(.activated)
        #expect(await waitUntil { rig.starts == 2 && rig.calls.lifecycle.state == .active })
        a.emit(.deactivated); a.emit(.activated)
        #expect(rig.calls.lifecycle.mayRunMedia && rig.pauses == 0)
        rig.cleanup(b)
    }

    @Test func resetIsReleaseBarrierEvenIfActivationNeverArrived() async {
        let rig = CallCoordinatorRig(); let a = rig.start()
        rig.calls.end(); rig.calls.start(target: rig.target)
        #expect(rig.providers.count == 1)
        a.emit(.reset)
        let b = rig.start()
        a.emit(.activated); a.emit(.deactivated)
        a.startCompletion?(ClientError("late transaction failure"))
        #expect(rig.calls.hasCall && !rig.calls.lifecycle.mayRunMedia && rig.ends == 1)
        b.emit(.activated)
        #expect(await waitUntil { rig.calls.lifecycle.state == .active })
        rig.cleanup(b)
    }

    @Test func releasedOldProviderCannotActivateOrDeactivateReplacement() async {
        let rig = CallCoordinatorRig(); let a = await rig.active()
        rig.calls.end(); a.emit(.reset)
        let b = rig.start()
        a.emit(.activated)
        #expect(!rig.calls.lifecycle.mayRunMedia) // A cannot supply B's grant
        b.emit(.activated)
        #expect(await waitUntil { rig.starts == 2 && rig.calls.lifecycle.state == .active })
        a.emit(.deactivated); a.emit(.reset)
        #expect(rig.calls.hasCall && rig.calls.lifecycle.mayRunMedia)
        #expect(rig.pauses == 0 && rig.ends == 1)
        rig.cleanup(b)
    }

    @Test func duplicateCallbacksDoNotStartPauseOrCleanupTwice() async {
        let rig = CallCoordinatorRig(); let p = await rig.active()
        p.emit(.activated); p.emit(.activated)
        await Task.yield()
        #expect(rig.starts == 1)
        p.emit(.deactivated); p.emit(.deactivated)
        #expect(rig.pauses == 1)
        p.emit(.activated)
        #expect(await waitUntil { rig.starts == 2 })
        rig.calls.end(); p.emit(.reset); p.emit(.reset); p.emit(.deactivated)
        #expect(rig.ends == 1 && !rig.calls.hasCall)
        var staleAction: Bool?
        p.emit(.start(p.id, { staleAction = $0 }))
        #expect(staleAction == false)
    }
}
