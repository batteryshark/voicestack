import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct CallEndAuthorityTests {
    @Test func exhaustivePolicyNeverGivesMediaOrRecoveryTerminalAuthority() {
        let alwaysTerminal: Set<CallEndCause> = [.userEnd, .systemEnd, .providerReset, .systemFailure]
        for cause in CallEndCause.allCases {
            for attempt in [CallMediaAttempt.initial, .recovery] {
                #expect(CallEndAuthority.decide(cause, everReady: true, attempt: attempt) == (alwaysTerminal.contains(cause) ? .terminal : .pause))
                #expect(CallEndAuthority.decide(cause, everReady: false, attempt: .recovery) == (alwaysTerminal.contains(cause) ? .terminal : .pause))
            }
        }
        for cause in [CallEndCause.ringDeadline, .answerDeadline, .readinessDeadline, .setupFailure, .admissionRejected] {
            #expect(CallEndAuthority.decide(cause, everReady: false, attempt: .initial) == .terminal)
        }
    }
    @Test func retryStallBeforeNativeReadinessLoopRestoresNoticeWithoutTeardown() async {
        let rig = CallCoordinatorRig(), p = await rig.active()
        rig.calls.readinessTimeout = 20_000_000
        var backend: CheckedContinuation<Bool, Never>?, reachedCaptureLoop = false, retryAvailable = false
        rig.calls.recoveryPaused = { _ in retryAvailable = true }
        rig.calls.mediaReady = { retryAvailable = false }
        rig.calls.pauseMediaForRouteRecovery()
        let epoch = rig.calls.lifecycle.epoch, grants = p.grants
        rig.begin = {
            let ready = await withCheckedContinuation { backend = $0 } // backend.targetLease, BEFORE readiness loop
            reachedCaptureLoop = true
            return ready
        }
        retryAvailable = false; rig.calls.resumeMediaAfterRouteRecovery()
        #expect(await waitUntil { backend != nil })
        #expect(rig.calls.mediaAttempt == .recovery && !reachedCaptureLoop)
        #expect(await waitUntil { retryAvailable && rig.calls.mediaIsPaused })
        #expect(!reachedCaptureLoop && rig.calls.hasCall && rig.calls.hasEverBeenMediaReady)
        #expect(rig.calls.lifecycle.epoch == epoch && p.grants == grants && p.invalidations == 0 && p.endedCount == 0 && rig.ends == 0)
        #expect(rig.calls.mediaAttempt == .recovery)
        backend?.resume(returning: false); await Task.yield() // Late failed read cannot end the paused call.
        #expect(rig.calls.hasCall && rig.calls.mediaIsPaused)
        rig.begin = { true }; rig.calls.resumeMediaAfterRouteRecovery()
        #expect(await waitUntil { !rig.calls.mediaIsPaused && rig.calls.mediaAttempt == .initial && rig.starts == 3 })
        #expect(!retryAvailable && p.connectedCount == 1)
        rig.cleanup(p)
    }
    @Test func retryFalseResultAndAllRuntimeFailureKindsShareOnePause() async {
        let rig = CallCoordinatorRig(), p = await rig.active()
        var notices = 0
        rig.calls.recoveryPaused = { _ in notices += 1 }
        rig.calls.pauseMediaForRouteRecovery(); rig.begin = { false }
        rig.calls.resumeMediaAfterRouteRecovery()
        #expect(await waitUntil { notices == 2 && rig.calls.mediaIsPaused })
        for cause in [CallEndCause.captureFailure, .conversionFailure, .repairFailure, .backendFailure, .leaseFailure, .mediaReset,
            .userEnd, .systemEnd, .providerReset, .systemFailure] {
            rig.calls.mediaFailed(cause) // Media callers cannot impersonate ANY privileged terminal event.
        }
        #expect(notices == 2 && p.endedCount == 0 && p.invalidations == 0 && rig.ends == 0)
        #expect(rig.calls.hasCall && rig.calls.mediaAttempt == .recovery && rig.calls.hasEverBeenMediaReady)
        rig.cleanup(p)
    }
    @Test func initialReadinessTimeoutAndInitialFalseResultStillEnd() async {
        for falseResult in [false, true] {
            let rig = CallCoordinatorRig(); rig.calls.readinessTimeout = 20_000_000
            let p = rig.start()
            if falseResult { rig.begin = { false }; p.emit(.activated) }
            #expect(await waitUntil { !rig.calls.hasCall })
            #expect(!rig.calls.hasEverBeenMediaReady && p.endedCount == 1 && p.invalidations == 1)
            p.emit(.reset)
        }
    }
    @Test func initialRingAndAnswerDeadlinesStillEnd() async {
        for answer in [false, true] {
            let p = FakeCallProvider(), calls = CallCoordinator(makeProvider: { _ in p })
            calls.incomingTimeout = 20_000_000
            var stalled: CheckedContinuation<TargetLease, Never>?
            calls.resolveIncoming = { _ in await withCheckedContinuation { stalled = $0 } }
            let invitation = PushInvitation(payload: ["reachoutID": "authority-test", "callUUID": UUID().uuidString,
                "expiry": Date().addingTimeInterval(10).timeIntervalSince1970 * 1000,
                "ringDeadline": Date().addingTimeInterval(answer ? 5 : 0.03).timeIntervalSince1970 * 1000])
            calls.receivePush(invitation, allowed: true) {}
            if answer { p.emit(.answer(invitation.id, { _ in })) }
            #expect(await waitUntil { !calls.hasCall })
            #expect(!calls.hasEverBeenMediaReady && p.endedCount == 1 && p.invalidations == 1)
            stalled?.resume(returning: TargetLease(sessionID: "ses_test", generation: "late")); await Task.yield()
            p.emit(.reset)
        }
    }
    @Test func explicitAppAndSystemEndRemainTerminalWhileActivePausedAndRetrying() async {
        for state in 0..<3 {
            for system in [false, true] {
                let rig = CallCoordinatorRig(), p = await rig.active()
                if state > 0 { rig.calls.pauseMediaForRouteRecovery() }
                if state == 2 {
                    rig.begin = { try? await Task.sleep(nanoseconds: 200_000_000); return false }
                    rig.calls.resumeMediaAfterRouteRecovery()
                }
                if system { p.emit(.end(p.id, { #expect($0) })) } else { rig.calls.end() }
                #expect(!rig.calls.hasCall && p.endedCount == 1 && p.invalidations == 1 && rig.ends == 1)
                p.emit(.reset)
            }
        }
    }
    @Test func providerResetAndCallKitReportedSystemFailureRemainTerminalAfterReadiness() async {
        for reset in [false, true] {
            let rig = CallCoordinatorRig(), p = await rig.active()
            rig.calls.pauseMediaForRouteRecovery()
            p.emit(reset ? .reset : .systemFailure(p.id))
            #expect(!rig.calls.hasCall && p.endedCount == 1 && p.invalidations == 1)
            p.emit(.reset)
        }
    }
    @Test func heldCallReadinessFalseOnReactivationCannotUndoEverReady() async {
        let rig = CallCoordinatorRig(), p = await rig.active()
        rig.calls.hold(true); p.emit(.deactivated); rig.calls.hold(false)
        rig.begin = { false }; p.emit(.activated)
        #expect(await waitUntil { rig.calls.mediaIsPaused })
        #expect(rig.calls.hasEverBeenMediaReady && rig.calls.hasCall && p.endedCount == 0 && p.invalidations == 0)
        rig.cleanup(p)
    }
    @Test func localOperationErrorAndMediaResetUsePauseNotSystemFailureAuthority() async {
        for operation in [false, true] {
            let rig = CallCoordinatorRig(), p = await rig.active(), grants = p.grants
            if operation { p.emit(.failed("Local operation failed")) } else { rig.calls.mediaReset() }
            #expect(rig.calls.mediaIsPaused && rig.calls.hasCall && rig.calls.hasEverBeenMediaReady)
            #expect(p.endedCount == 0 && p.invalidations == 0 && p.grants == grants)
            rig.cleanup(p)
        }
    }
    @Test func admissionRejectionEndsOnlyRejectedReportNotExistingReadyCall() async {
        let rig = CallCoordinatorRig(), p = await rig.active()
        let epoch = rig.calls.lifecycle.epoch, id = rig.calls.lifecycle.id
        let invitation = PushInvitation(payload: ["reachoutID": "rejected", "callUUID": UUID().uuidString,
            "expiry": Date().addingTimeInterval(20).timeIntervalSince1970 * 1000,
            "ringDeadline": Date().addingTimeInterval(10).timeIntervalSince1970 * 1000])
        rig.calls.receivePush(invitation, allowed: false) {}
        #expect(rig.calls.hasCall && rig.calls.lifecycle.epoch == epoch && rig.calls.lifecycle.id == id)
        #expect(p.endedCount == 1 && p.invalidations == 0 && rig.ends == 0)
        rig.cleanup(p)
    }
}
