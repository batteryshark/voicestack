import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct VoiceEndedReviewTests {
    @Test func backgroundToForegroundBeforeAdmissionDoesNotDisconnect() async {
        // Even if cancellation were missed, the completion consults CURRENT scene state.
        let gate = VoiceEndedSceneDeferral()
        var foreground = false, paired = true, disconnects = 0
        var completion: CheckedContinuation<Void, Never>?
        let admission = Task { await withCheckedContinuation { completion = $0 } }
        #expect(await waitUntil { completion != nil })
        var reconciliations = 0
        gate.reconcileAfter(admission, key: UUID()) {
            reconciliations += 1
            CallSceneReconciler.reconcile(hasCall: false, foreground: foreground, protectedDataAvailable: true) {
                disconnects += 1; paired = false
            }
        }
        foreground = true
        completion?.resume(); await admission.value
        #expect(await waitUntil { reconciliations == 1 })
        #expect(disconnects == 0 && paired)
    }

    @Test(arguments: ["resume", "Start", "selection"])
    func aNewSceneOrOwnerSupersedesTheOldWaiter(_ action: String) async {
        let gate = VoiceEndedSceneDeferral()
        var completion: CheckedContinuation<Void, Never>?, reconciliations = 0
        let admission = Task { await withCheckedContinuation { completion = $0 } }
        #expect(await waitUntil { completion != nil })
        gate.reconcileAfter(admission, key: UUID(), maximumDelay: 20_000_000) { reconciliations += 1 }
        // These production entry points invalidate the same shared gate. Keep
        // the scene inactive here: a scene-only fix would still cancel new work.
        if action == "resume" { gate.sceneResumed(foreground: true, protectedDataAvailable: true) }
        else { gate.invalidate() }
        completion?.resume(); await admission.value
        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect(reconciliations == 0, "Old \(action) owner cannot disconnect/cancel new work")
    }

    @Test func lockScreenEndCoalescesAndDisconnectsIfStillInactive() async {
        let gate = VoiceEndedSceneDeferral(), key = UUID()
        var completion: CheckedContinuation<Void, Never>?, disconnects = 0
        let admission = Task { await withCheckedContinuation { completion = $0 } }
        #expect(await waitUntil { completion != nil })
        let reconcile = {
            CallSceneReconciler.reconcile(hasCall: false, foreground: false, protectedDataAvailable: false) { disconnects += 1 }
        }
        gate.reconcileAfter(admission, key: key, reconcileCurrent: reconcile)
        gate.reconcileAfter(admission, key: key, reconcileCurrent: reconcile)
        completion?.resume(); await admission.value
        #expect(await waitUntil { disconnects == 1 })
        await Task.yield(); #expect(disconnects == 1)
    }

    @Test(arguments: [false, true]) func protectedDataNotificationWhileStillInactiveDoesNotCancelCleanup(_ completionFirst: Bool) async {
        let gate = VoiceEndedSceneDeferral()
        var completion: CheckedContinuation<Void, Never>?, disconnects = 0
        let admission = Task { await withCheckedContinuation { completion = $0 } }
        #expect(await waitUntil { completion != nil })
        gate.reconcileAfter(admission, key: UUID(), maximumDelay: 20_000_000) {
            CallSceneReconciler.reconcile(hasCall: false, foreground: false, protectedDataAvailable: true) { disconnects += 1 }
        }
        gate.sceneResumed(foreground: false, protectedDataAvailable: true)
        if completionFirst { completion?.resume() }
        #expect(await waitUntil { disconnects == 1 })
        if !completionFirst { completion?.resume() }
        await admission.value
        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect(disconnects == 1)
    }

    @Test func deferralIsBoundedAndDoesNotCancelOrReplayHandedOffAdmission() async {
        let gate = VoiceEndedSceneDeferral()
        var completion: CheckedContinuation<Void, Never>?, disconnects = 0, finished = false
        let admission = Task {
            await withCheckedContinuation { completion = $0 }
            #expect(!Task.isCancelled); finished = true
        }
        #expect(await waitUntil { completion != nil })
        gate.reconcileAfter(admission, key: UUID(), maximumDelay: 20_000_000) {
            CallSceneReconciler.reconcile(hasCall: false, foreground: false, protectedDataAvailable: false) { disconnects += 1 }
        }
        #expect(await waitUntil { disconnects == 1 })
        #expect(!finished)
        completion?.resume(); await admission.value
        await Task.yield()
        #expect(finished && disconnects == 1)
    }

    @Test func aCurrentCallStillPreventsDeferredSceneCleanup() async {
        let gate = VoiceEndedSceneDeferral()
        var disconnects = 0, completion: CheckedContinuation<Void, Never>?
        var hasCall = false
        let admission = Task { await withCheckedContinuation { completion = $0 } }
        #expect(await waitUntil { completion != nil })
        gate.reconcileAfter(admission, key: UUID()) {
            CallSceneReconciler.reconcile(hasCall: hasCall, foreground: false, protectedDataAvailable: false) { disconnects += 1 }
        }
        hasCall = true
        completion?.resume(); await admission.value
        await Task.yield()
        #expect(disconnects == 0)
    }

    @Test(arguments: [false, true]) func failedNativeRepairRemainsIneligibleAfterSuccessfulRetry(_ retry: Bool) async {
        let rig = CallCoordinatorRig(), provider = await rig.active()
        // Native failed-repair entry first revokes ALL notice leases, including
        // this actual coordinator ticket, then keeps the call in nonterminal pause.
        rig.calls.invalidateVoiceEnded()
        rig.calls.pauseMediaForRouteRecovery()
        if retry {
            rig.calls.resumeMediaAfterRouteRecovery()
            #expect(await waitUntil { rig.starts == 2 && !rig.calls.mediaIsPaused })
        }
        var task: Task<Void, Never>?, posts = 0
        rig.calls.onDeliberateEnd = { session in
            task = Task { await session.end(currentLease: { rig.target }, admit: { _, _ in posts += 1 }) }
        }
        rig.calls.end(); provider.emit(.reset); await task?.value
        #expect(posts == 0)
        // A genuinely fresh admitted Start, not Retry, mints a new eligible ticket.
        let fresh = rig.start(); fresh.emit(.activated)
        #expect(await waitUntil { rig.calls.lifecycle.state == .active })
        rig.calls.end(); fresh.emit(.reset); await task?.value
        #expect(posts == 1)
    }

    @Test func failedStandaloneRepairCannotBeRearmedByRecovery() async {
        let target = TargetLease(sessionID: "ses_app", generation: "one")
        let session = VoiceEndedSession(kind: .app, target: target)
        session.invalidate()
        let capture = NativeVoiceLifecycle()
        _ = capture.requestStart() // Successful device/recovery generation is NOT a new logical session.
        var posts = 0
        await session.end(currentLease: { target }, admit: { _, _ in posts += 1 })
        #expect(posts == 0)
        let fresh = VoiceEndedSession(kind: .app, target: target)
        await fresh.end(currentLease: { target }, admit: { _, _ in posts += 1 })
        #expect(posts == 1)
    }
}
