import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct CallAdmissionRecoveryTests {
    private func invitation(seconds: TimeInterval = 3) -> PushInvitation {
        PushInvitation(payload: ["reachoutID": "admission-test", "callUUID": UUID().uuidString,
            "expiry": Date().addingTimeInterval(30).timeIntervalSince1970 * 1000,
            "ringDeadline": Date().addingTimeInterval(seconds).timeIntervalSince1970 * 1000])
    }
    @Test func eachUnansweredTerminalPathAdmitsNextPushAndWorkingStartWithoutReleaseCallback() async {
        for ending in ["expiry", "decline", "reportFailure", "endBeforeAnswer"] {
            var providers: [FakeCallProvider] = []
            let calls = CallCoordinator(makeProvider: { _ in
                let p = FakeCallProvider()
                if providers.isEmpty && ending == "reportFailure" { p.reportError = IncomingReportError(code: 1, failure: .other) }
                providers.append(p); return p
            })
            calls.beginMedia = { _ in true }
            let first = invitation(seconds: ending == "expiry" ? 0.03 : 3)
            calls.receivePush(first, allowed: true) {}
            let old = providers[0]
            if ending == "decline" { old.emit(.end(first.id, { #expect($0) })) }
            if ending == "endBeforeAnswer" { calls.end() }
            #expect(await waitUntil { !calls.hasCall })
            #expect(old.invalidations == 1 && !old.grants.contains(true))
            // NO didDeactivate or reset: this is the real-phone failure condition.
            let second = invitation()
            calls.receivePush(second, allowed: true) {}
            #expect(calls.hasCall && calls.lifecycle.state == .ringing && calls.lifecycle.id == second.id)
            #expect(providers.count == 2 && providers[1] !== old)
            calls.end() // The next Start must also work after another audio-idle terminal call.
            calls.start(target: TargetLease(sessionID: "ses_test", generation: "start"))
            #expect(providers.count == 3)
            let started = providers.last!; started.performStart(); started.emit(.activated)
            #expect(await waitUntil { calls.lifecycle.state == .active })
            #expect(calls.hasEverBeenMediaReady)
            old.emit(.activated); old.emit(.deactivated); old.emit(.reset) // Retired callbacks cannot reach the replacement.
            #expect(calls.hasCall && calls.lifecycle.mayRunMedia)
            calls.end(); started.emit(.deactivated)
        }
    }
    @Test func answeredCallStillWaitsForRealDeactivationBeforeReplacement() async {
        let rig = CallCoordinatorRig(), old = await rig.active()
        rig.calls.end(); rig.calls.start(target: rig.target)
        #expect(rig.providers.count == 1 && !rig.calls.hasCall)
        old.emit(.deactivated)
        let replacement = rig.start(); replacement.emit(.activated)
        #expect(await waitUntil { rig.calls.lifecycle.state == .active })
        #expect(rig.providers.count == 2)
        rig.cleanup(replacement)
    }
    @Test func fulfilledActionWithPendingActivationKeepsBarrierIncludingLateGrant() {
        let rig = CallCoordinatorRig(), old = rig.start() // Start action fulfilled; didActivate is in flight.
        rig.calls.end(); rig.calls.start(target: rig.target)
        #expect(rig.providers.count == 1)
        old.emit(.activated) // A late grant to the retiring provider is still an active session.
        rig.calls.start(target: rig.target)
        #expect(rig.providers.count == 1)
        old.emit(.deactivated)
        let replacement = rig.start()
        #expect(rig.providers.count == 2)
        rig.cleanup(replacement)
    }
    @Test func preactivationRouteControlDoesNotCancelInitialReadinessDeadline() async {
        let rig = CallCoordinatorRig(); rig.calls.readinessTimeout = 20_000_000
        var pauses = 0; rig.calls.recoveryPaused = { _ in pauses += 1 }
        let p = rig.start()
        rig.calls.toggleSpeaker(); rig.calls.pauseMediaForRouteRecovery() // Also defend against the old catch mapping.
        #expect(p.routeToggleCount == 0 && !rig.calls.mediaIsPaused && pauses == 0 && rig.starts == 0)
        #expect(rig.errors.contains("Audio route can be changed once the call connects."))
        #expect(await waitUntil { !rig.calls.hasCall })
        #expect(p.endedCount == 1 && p.invalidations == 1)
        p.emit(.reset)
    }
    @Test func activationAfterRefusedControlStartsWithoutRetry() async {
        let rig = CallCoordinatorRig(), p = rig.start()
        rig.calls.toggleSpeaker(); p.emit(.controlRejected); rig.calls.pauseMediaForRouteRecovery()
        #expect(!rig.calls.mediaIsPaused && rig.starts == 0 && !rig.calls.mayChangeLiveRoute)
        p.emit(.activated)
        #expect(await waitUntil { rig.calls.lifecycle.state == .active })
        #expect(rig.starts == 1 && rig.calls.mayChangeLiveRoute && !rig.calls.mediaIsPaused)
        rig.calls.toggleSpeaker(); #expect(p.routeToggleCount == 1)
        rig.cleanup(p)
    }
    @Test func ringingControlRefusalDoesNotCancelRingDeadline() async {
        let p = FakeCallProvider(), calls = CallCoordinator(makeProvider: { _ in p })
        var pauses = 0; calls.recoveryPaused = { _ in pauses += 1 }
        calls.receivePush(invitation(seconds: 0.03), allowed: true) {}
        calls.toggleSpeaker(); calls.pauseMediaForRouteRecovery(); p.emit(.controlRejected)
        #expect(calls.lifecycle.state == .ringing && !calls.mediaIsPaused && pauses == 0)
        #expect(await waitUntil { !calls.hasCall })
        #expect(p.endedCount == 1 && p.invalidations == 1)
    }
    @Test func answerLookupControlRefusalPreservesAnswerDeadline() async {
        let p = FakeCallProvider(), calls = CallCoordinator(makeProvider: { _ in p })
        calls.incomingTimeout = 20_000_000
        var lookup: CheckedContinuation<TargetLease, Never>?
        calls.resolveIncoming = { _ in await withCheckedContinuation { lookup = $0 } }
        let incoming = invitation(); calls.receivePush(incoming, allowed: true) {}
        p.emit(.answer(incoming.id, { _ in }))
        #expect(await waitUntil { lookup != nil })
        calls.toggleSpeaker(); calls.pauseMediaForRouteRecovery()
        #expect(!calls.mediaIsPaused)
        #expect(await waitUntil { !calls.hasCall })
        lookup?.resume(returning: TargetLease(sessionID: "ses_test", generation: "late")); await Task.yield()
        #expect(p.endedCount == 1 && p.invalidations == 1)
    }
    @Test func answerLookupContinuesAfterControlRefusalAndStartsOnGrantWithoutRetry() async {
        let p = FakeCallProvider(), calls = CallCoordinator(makeProvider: { _ in p })
        var lookup: CheckedContinuation<TargetLease, Never>?, starts = 0
        calls.resolveIncoming = { _ in await withCheckedContinuation { lookup = $0 } }
        calls.beginMedia = { _ in starts += 1; return true }
        let incoming = invitation(); calls.receivePush(incoming, allowed: true) {}
        p.emit(.answer(incoming.id, { #expect($0) }))
        #expect(await waitUntil { lookup != nil })
        calls.toggleSpeaker(); calls.pauseMediaForRouteRecovery()
        lookup?.resume(returning: TargetLease(sessionID: "ses_test", generation: "answer"))
        #expect(await waitUntil { p.configured })
        p.emit(.activated)
        #expect(await waitUntil { calls.lifecycle.state == .active })
        #expect(starts == 1 && !calls.mediaIsPaused)
        calls.end(); p.emit(.deactivated)
    }
}
