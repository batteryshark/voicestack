import Foundation
import AVFoundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct RouteRecoveryTests {
    @Test func fiveQuickTogglesIncludingImmediatelyAfterActivationDoNotSpendFlapBudget() {
        var tracker = RouteRecoveryTracker(), budget = RouteRecoveryBudget()
        tracker.begin(route: .phone)
        // The actual startup reason 8 still consumes just one unexpected repair.
        let startup = budget.admit(tracker.notification(route: .phone, reason: 8, now: 0), now: 0)
        #expect(startup)
        for i in 0..<5 {
            let now = Double(i) * 1.5 + 0.01, route: PhoneAudioRoute = i.isMultiple(of: 2) ? .speaker : .phone
            let toggle = tracker.expect(route, now: now)
            let notice = tracker.notification(route: route, reason: 3, now: now + 0.02)
            let repair = tracker.engine(route: route, now: now + 0.17)
            #expect(toggle == notice && notice == repair && repair.source == .appToggle)
            let admitted = budget.admit(repair, now: now + 0.17)
            #expect(admitted)
        }
        #expect(!budget.paused && budget.unexpected.count == 1)
    }
    @Test func requestedRouteAloneIsNotProofAndMismatchedExpiredOrRetiredTicketsCannotExempt() {
        var tracker = RouteRecoveryTracker()
        tracker.begin(route: .phone)
        let first = tracker.expect(.speaker, now: 0)
        #expect(tracker.engine(route: .speaker, now: 0.1).source == .unexpected)
        #expect(tracker.notification(route: .phone, reason: 3, now: 0.2).source == .unexpected)
        #expect(tracker.notification(route: .speaker, reason: 3, now: 2.1).source == .unexpected)
        let cancelled = tracker.expect(.speaker, now: 3); tracker.cancel(cancelled)
        #expect(tracker.notification(route: .speaker, reason: 3, now: 3.1).source == .unexpected)
        tracker.begin(route: .phone)
        #expect(tracker.notification(route: .speaker, reason: 3, now: 3.2).source == .unexpected)
        #expect(first.generation != cancelled.generation)
    }
    @Test func onlyLatestToggleCanOwnNotificationAndGraphRecovery() {
        var tracker = RouteRecoveryTracker(); tracker.begin(route: .phone)
        let old = tracker.expect(.speaker, now: 0)
        let latest = tracker.expect(.phone, now: 0.1)
        #expect(tracker.notification(route: .speaker, reason: 3, now: 0.15).source == .unexpected)
        let notice = tracker.notification(route: .phone, reason: 3, now: 0.2)
        #expect(notice == latest && notice != old)
        #expect(tracker.engine(route: .phone, now: 0.3) == latest)
        #expect(tracker.engine(route: .speaker, now: 0.3).source == .unexpected)
    }
    @Test func explicitSystemChoiceIsAdoptedThroughRecoveryButReason8AloneIsNotIntent() {
        var tracker = RouteRecoveryTracker(), budget = RouteRecoveryBudget(); tracker.begin(route: .phone)
        for i in 0..<5 {
            let route: PhoneAudioRoute = i.isMultiple(of: 2) ? .speaker : .phone, now = Double(i)
            let selected = tracker.notification(route: route, reason: 4, now: now)
            #expect(selected.source == .systemChoice)
            #expect(tracker.engine(route: route, now: now + 0.15) == selected)
            let admitted = budget.admit(selected, now: now + 0.15)
            #expect(admitted)
        }
        #expect(budget.unexpected.isEmpty)
        #expect(tracker.notification(route: .phone, reason: 8, now: 5).source == .unexpected)
    }
    @Test func realUnrequestedFlappingPausesAndOnlyManualRetryReopensAdmission() {
        var tracker = RouteRecoveryTracker(), budget = RouteRecoveryBudget(); tracker.begin(route: .phone)
        for i in 0..<4 {
            let context = tracker.notification(route: i.isMultiple(of: 2) ? .speaker : .phone, reason: 8, now: Double(i))
            #expect(context.source == .unexpected)
            #expect(budget.admit(context, now: Double(i)) == (i < 3))
        }
        #expect(budget.paused && budget.unexpected.count == 3)
        let deliberate = tracker.notification(route: .speaker, reason: 4, now: 20)
        let automatic = budget.admit(deliberate, now: 20)
        #expect(!automatic, "Neither route choices nor quiet time silently restart paused capture")
        budget.retry()
        let retry = tracker.retry(route: .speaker, now: 21)
        #expect(retry.source == .retry && budget.admit(retry, now: 21) && !budget.paused)
    }
    @Test func unexpectedBudgetRollsOffAfterTenSecondsAndNoticeRemainsVisible() {
        var tracker = RouteRecoveryTracker(), budget = RouteRecoveryBudget()
        for time in [0.0, 1, 2, 10.1] {
            let admitted = budget.admit(tracker.engine(route: .phone, now: time), now: time)
            #expect(admitted)
        }
        #expect(budget.unexpected.count == 3 && !budget.paused)
        #expect(PrincipalError.message(RouteRecoveryNotice.paused, captureRunning: true) == RouteRecoveryNotice.paused)
    }
    @Test func exhaustedFlapBudgetKeepsActiveCallAndFreshVoiceCanRetryWithoutNewActivation() async {
        let rig = CallCoordinatorRig(), p = await rig.active()
        let epoch = rig.calls.lifecycle.epoch, grants = p.grants
        var tracker = RouteRecoveryTracker(), budget = RouteRecoveryBudget()
        for i in 0..<4 {
            if !budget.admit(tracker.notification(route: i.isMultiple(of: 2) ? .phone : .speaker, reason: 8, now: Double(i)), now: Double(i)) {
                rig.calls.pauseMediaForRouteRecovery()
            }
        }
        #expect(budget.paused)
        #expect(rig.calls.hasCall && rig.calls.lifecycle.epoch == epoch && rig.calls.lifecycle.mayRunMedia)
        #expect(rig.ends == 0 && p.endedCount == 0 && p.invalidations == 0 && p.grants == grants)
        #expect(rig.pauses == 1)
        rig.calls.resumeMediaAfterRouteRecovery()
        #expect(await waitUntil { rig.starts == 2 && rig.calls.lifecycle.state == .active })
        #expect(p.connectedCount == 1 && p.grants == grants)
        rig.cleanup(p)
    }
    @Test func fiveDeliberateToggleRepairsKeepCallAndVoiceAdmission() async {
        let rig = CallCoordinatorRig(), p = await rig.active()
        var tracker = RouteRecoveryTracker(), budget = RouteRecoveryBudget()
        tracker.begin(route: .phone)
        let epoch = rig.calls.lifecycle.epoch
        for i in 0..<5 {
            let route: PhoneAudioRoute = i.isMultiple(of: 2) ? .speaker : .phone, now = Double(i) * 1.5
            let toggle = tracker.expect(route, now: now)
            let cause = tracker.notification(route: route, reason: 3, now: now + 0.02)
            #expect(toggle == cause && tracker.engine(route: route, now: now + 0.2) == toggle)
            if !budget.admit(cause, now: now + 0.2) { rig.calls.pauseMediaForRouteRecovery() }
            #expect(rig.calls.hasCall && rig.calls.lifecycle.mayRunMedia && rig.calls.lifecycle.epoch == epoch)
        }
        #expect(rig.pauses == 0 && rig.starts == 1 && rig.ends == 0 && p.endedCount == 0)
        rig.cleanup(p)
    }
    @Test func routePauseDuringInitialCaptureFencesLateFailedSetupAndKeepsCall() async {
        let rig = CallCoordinatorRig(); var pending: CheckedContinuation<Bool, Never>?
        rig.begin = { await withCheckedContinuation { pending = $0 } }
        let p = rig.start(); p.emit(.activated)
        #expect(await waitUntil { pending != nil })
        let epoch = rig.calls.lifecycle.epoch
        rig.calls.pauseMediaForRouteRecovery()
        pending?.resume(returning: false)
        await Task.yield()
        #expect(rig.calls.hasCall && rig.calls.lifecycle.epoch == epoch && rig.calls.lifecycle.mayRunMedia)
        #expect(p.endedCount == 0 && p.invalidations == 0 && rig.ends == 0)
        rig.begin = { true }; rig.calls.resumeMediaAfterRouteRecovery()
        #expect(await waitUntil { rig.calls.lifecycle.state == .active && rig.starts == 2 })
        rig.cleanup(p)
    }
    @Test func staleRecoveryCannotResumeEndedOrHeldCall() async {
        let rig = CallCoordinatorRig(), p = await rig.active()
        rig.calls.pauseMediaForRouteRecovery(); rig.calls.hold(true)
        rig.calls.resumeMediaAfterRouteRecovery()
        #expect(rig.starts == 1 && !rig.calls.lifecycle.mayRunMedia)
        rig.cleanup(p); rig.calls.resumeMediaAfterRouteRecovery()
        #expect(rig.starts == 1 && !rig.calls.hasCall)
    }
    @Test func pausedHoldReleaseUnholdActivationOutlivesReadinessDeadlineUntilExplicitEnd() async throws {
        let rig = CallCoordinatorRig(), p = await rig.active()
        #expect(rig.calls.readinessTimeout == 20_000_000_000)
        rig.calls.readinessTimeout = 20_000_000 // Same production timer, short deterministic test interval.
        let epoch = rig.calls.lifecycle.epoch
        rig.calls.pauseMediaForRouteRecovery()
        rig.calls.hold(true); p.emit(.deactivated)
        rig.calls.hold(false); p.emit(.activated)
        try await Task.sleep(nanoseconds: 120_000_000) // Six readiness periods, NO Retry.
        #expect(rig.calls.hasCall && rig.calls.lifecycle.epoch == epoch && rig.calls.lifecycle.mayRunMedia)
        #expect(rig.starts == 1 && rig.ends == 0 && p.endedCount == 0 && p.invalidations == 0)
        #expect(rig.errors.isEmpty)
        rig.calls.end()
        #expect(rig.ends == 1 && p.endedCount == 1)
        p.emit(.reset)
    }
    @Test func explicitRetryAfterPausedHoldCycleTimeoutRestoresPauseNotEnd() async {
        let rig = CallCoordinatorRig(), p = await rig.active()
        rig.calls.readinessTimeout = 20_000_000
        rig.calls.pauseMediaForRouteRecovery()
        rig.calls.hold(true); p.emit(.deactivated); rig.calls.hold(false); p.emit(.activated)
        rig.begin = { try? await Task.sleep(nanoseconds: 500_000_000); return false }
        rig.calls.resumeMediaAfterRouteRecovery()
        #expect(await waitUntil { rig.starts == 2 && rig.calls.mediaIsPaused })
        #expect(rig.calls.hasCall && rig.calls.mediaAttempt == .recovery && rig.errors.isEmpty)
        #expect(p.endedCount == 0 && p.invalidations == 0)
        rig.cleanup(p)
    }
    @Test func queuedFormatErrorFromRetiredTapIsDroppedDuringRepairDebounce() async throws {
        let rig = CallCoordinatorRig(), p = await rig.active()
        let buffers = CaptureIngressTests(), ingress = CaptureIngress()
        _ = try ingress.consume(buffers.buffer(), hardware: true)
        var queued: Error?
        do { _ = try ingress.consume(buffers.buffer(channels: 2), hardware: true) }
        catch { queued = error }
        #expect(queued != nil, "Inject a real AVAudioConverter input-format transition, not a synthetic no-op")
        var graph = 7, admission = CaptureGraphAdmission()
        let tapGraph = graph
        admission.installed(graph); admission.delivered(graph)
        // Actual native scheduleRecovery order, BEFORE its 150ms sleep.
        admission.beginRepair(); graph += 1; ingress.invalidate()
        var pause = 0, generic = 0
        let delivered = CaptureFailureDelivery.deliver(capture: true, graph: graph == tapGraph, call: true,
            media: rig.calls.lifecycle.mayRunMedia, callOwned: true,
            pause: { pause += 1; rig.calls.pauseMediaForRouteRecovery() }, fail: { generic += 1; rig.calls.end() })
        #expect(delivered == .stale && pause == 0 && generic == 0 && !admission.ready)
        #expect(try ingress.consume(buffers.buffer(channels: 2), hardware: true).isEmpty)
        #expect(rig.calls.hasCall && p.endedCount == 0 && p.invalidations == 0 && rig.ends == 0)
        rig.cleanup(p)
    }
    @Test func replacementTapFormatErrorDuringRepairReadinessPausesWithoutHangupOrDeactivation() async throws {
        let rig = CallCoordinatorRig(), p = await rig.active()
        let grants = p.grants, epoch = rig.calls.lifecycle.epoch
        let buffers = CaptureIngressTests(), replacement = CaptureIngress()
        var admission = CaptureGraphAdmission(); admission.beginRepair(); admission.installed(8)
        _ = try replacement.consume(buffers.buffer(), hardware: true)
        var notice: String?, retry = false, generic = 0
        do {
            _ = try replacement.consume(buffers.buffer(channels: 2), hardware: true)
            Issue.record("Real replacement-tap format conversion must throw")
        } catch {
            let delivered = CaptureFailureDelivery.deliver(capture: true, graph: true,
                call: rig.calls.lifecycle.epoch == epoch, media: rig.calls.lifecycle.mayRunMedia, callOwned: true,
                pause: { notice = RouteRecoveryNotice.paused; retry = true; rig.calls.pauseMediaForRouteRecovery() },
                fail: { generic += 1; rig.calls.end() })
            #expect(delivered == .routePaused)
        }
        #expect(notice == RouteRecoveryNotice.paused && retry && !admission.ready && generic == 0)
        #expect(rig.calls.hasCall && p.endedCount == 0 && p.invalidations == 0 && p.grants == grants && rig.ends == 0)
        rig.calls.resumeMediaAfterRouteRecovery()
        #expect(await waitUntil { rig.starts == 2 && rig.calls.lifecycle.state == .active })
        rig.cleanup(p)
    }
    @Test func admittedFormatErrorRacingAheadOfDebounceStillPausesWithNoticeAndRetry() async throws {
        let rig = CallCoordinatorRig(), p = await rig.active()
        let grants = p.grants, buffers = CaptureIngressTests(), ingress = CaptureIngress()
        _ = try ingress.consume(buffers.buffer(), hardware: true)
        var notice: String?, retry = false, generic = 0
        do {
            _ = try ingress.consume(buffers.buffer(channels: 2), hardware: true)
            Issue.record("Inject a real format-transition error before its recovery notification is processed")
        } catch {
            let delivered = CaptureFailureDelivery.deliver(capture: true, graph: true, call: true,
                media: rig.calls.lifecycle.mayRunMedia, callOwned: true,
                pause: { notice = RouteRecoveryNotice.paused; retry = true; rig.calls.pauseMediaForRouteRecovery() },
                fail: { generic += 1; rig.calls.end() })
            #expect(delivered == .routePaused)
        }
        #expect(notice == RouteRecoveryNotice.paused && retry && generic == 0)
        #expect(rig.calls.hasCall && p.endedCount == 0 && p.invalidations == 0 && p.grants == grants)
        rig.cleanup(p)
    }
    @Test func captureErrorDeliveryKeepsOwnerGraphCallMediaAndDiscardSpeechGuards() {
        for rejected in 0..<5 {
            var flags = [true, true, true, true, true]; flags[rejected] = false
            var effects = 0
            let delivered = CaptureFailureDelivery.deliver(capture: flags[0], graph: flags[1], call: flags[2], media: flags[3], speech: flags[4],
                callOwned: true, pause: { effects += 1 }, fail: { effects += 1 })
            #expect(delivered == .stale && effects == 0)
        }
        var standalone = 0, pause = 0
        let delivered = CaptureFailureDelivery.deliver(capture: true, graph: true, call: true, media: true, callOwned: false,
            pause: { pause += 1 }, fail: { standalone += 1 })
        #expect(delivered == .standaloneFailure && standalone == 1 && pause == 0)
    }
}
