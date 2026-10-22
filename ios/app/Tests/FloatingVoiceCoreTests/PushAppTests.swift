import Foundation
import Testing
@testable import FloatingVoiceCore

@MainActor private final class IncomingProvider: CallProviderAdapter {
    var onEvent: ((CallProviderEvent) -> Void)?
    var reports: [UUID] = [], endedIDs: [UUID] = []
    var invalidations = 0
    var reportCompletion: ((Error?) -> Void)?
    var routeLabel: String { "Receiver" }
    func reportIncoming(_ id: UUID, completion: @escaping (Error?) -> Void) { reports.append(id); reportCompletion = completion }
    func requestStart(_ id: UUID, completion: @escaping (Error?) -> Void) { completion(nil) }
    func requestEnd(_ id: UUID) {}
    func requestMute(_ id: UUID, muted: Bool) {}
    func requestHold(_ id: UUID, held: Bool) {}
    func configure() throws {}
    func connecting(_ id: UUID) {}
    func connected(_ id: UUID) {}
    func ended(_ id: UUID, reason: CallEndReason) { endedIDs.append(id) }
    func observeActivation(_ granted: Bool) {}
    func refresh(proximity: Bool) {}
    func toggleSpeaker() {}
    func invalidate() { invalidations += 1 }
}

@Suite(.serialized) @MainActor struct PushAppTests {
    @Test func coldPushOwnerSurvivesLaterSceneMountWithoutSecondProviderOrInvalidation() {
        var creations = 0
        let provider = IncomingProvider()
        let delegateOwnedCalls = CallCoordinator(makeProvider: { _ in creations += 1; return provider })
        let instance = delegateOwnedCalls.diagnosticInstance
        delegateOwnedCalls.receivePush(invitation(deadline: Date().addingTimeInterval(30)), allowed: true) {}
        provider.reportCompletion?(nil)
        let epoch = delegateOwnedCalls.lifecycle.epoch
        // The native app delegate and SwiftUI scene both access PhoneModel.shared.
        // Scene replacement does not reconstruct its coordinator/provider.
        for _ in 0..<4 {
            let sceneCalls = delegateOwnedCalls
            CallSceneReconciler.reconcile(hasCall: sceneCalls.hasCall, foreground: false, protectedDataAvailable: true,
                suspend: { Issue.record("Ringing owner was suspended") })
            provider.onEvent?(.routeChanged); provider.onEvent?(.deactivated)
            #expect(sceneCalls === delegateOwnedCalls && sceneCalls.diagnosticInstance == instance)
        }
        #expect(creations == 1 && provider.invalidations == 0 && delegateOwnedCalls.lifecycle.epoch == epoch)
        #expect(delegateOwnedCalls.lifecycle.state == .ringing)
        delegateOwnedCalls.end()
        #expect(provider.invalidations == 1 && delegateOwnedCalls.lifecycle.epoch == epoch + 1)
    }
    @Test func endDiagnosticsAndTerminalReceiptIdentifyRealResetNotSceneOrTimer() throws {
        let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p })
        var values: [CallReceipt] = []; calls.detailedReceipt = { _, r in values.append(r) }
        calls.receivePush(invitation(deadline: Date().addingTimeInterval(30)), allowed: true) {}; p.reportCompletion?(nil)
        p.onEvent?(.reset)
        let terminal = try #require(values.last)
        #expect(terminal.event == .ended && terminal.endReason == .providerReset && terminal.endInitiator == .providerReset && terminal.reportedRinging == true)
        #expect(p.invalidations == 1)
        p.onEvent?(.reset)
        #expect(values.filter { $0.event == .ended }.count == 1)
    }
    @Test func reportDNDAndBlockedAreClosedAndNeverReportedAsRinging() {
        for failure in [IncomingReportFailure.filteredByDoNotDisturb, .filteredByBlockList] {
            let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p })
            var values: [CallReceipt] = []; calls.detailedReceipt = { _, r in values.append(r) }
            calls.receivePush(invitation(), allowed: true) {}; p.reportCompletion?(IncomingReportError(code:3,failure:failure))
            #expect(values.contains { $0.event == .reportFailed && $0.reportFailure == failure && $0.endReason == .reportRejected && $0.reportedRinging == false })
            #expect(!values.contains { $0.event == .ringing })
        }
    }
    @Test func p14MillisecondDeadlineComputesAboutThirtySecondsNotOne() {
        let input = PushInvitation(payload:["reachoutID":"p14-call-20261016-0911","callUUID":UUID().uuidString,
            "expiry":1792156237796.0,"ringDeadline":1792156207818.0])
        let delay = CallCoordinator.ringDelay(input,now:Date(timeIntervalSince1970:1792156178.274))
        #expect(abs(delay - 29.544) < 0.002)
    }
    @Test func backgroundPushRingingSurvivesSceneSuspendDeactivationAndRefresh() async throws {
        let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p })
        var suspensions = 0, events: [String] = []
        calls.receipt = { _, event in events.append(event) }
        func scene(_ foreground: Bool, _ protected: Bool) {
            CallSceneReconciler.reconcile(hasCall: calls.hasCall, foreground: foreground,
                protectedDataAvailable: protected, suspend: { suspensions += 1 })
        }
        scene(false, true) // Cold PushKit launch, before the invitation arrives.
        calls.receivePush(invitation(deadline: Date().addingTimeInterval(30)), allowed: true) {}
        p.reportCompletion?(nil)
        for state in [(false,true), (false,false), (true,true), (false,true)] {
            scene(state.0, state.1); p.onEvent?(.deactivated); p.onEvent?(.routeChanged)
        }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        #expect(suspensions == 1 && calls.hasCall && calls.lifecycle.state == .ringing)
        #expect(events == ["reported", "ringing"] && p.endedIDs.isEmpty)
        calls.end()
    }
    @Test func providerResetCanReproduceEarlyEndButCoordinatorDoesEmitTerminalReceipt() {
        let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p })
        var events: [String] = []; calls.receipt = { _, event in events.append(event) }
        calls.receivePush(invitation(deadline: Date().addingTimeInterval(30)), allowed: true) {}
        p.reportCompletion?(nil); p.onEvent?(.reset)
        #expect(!calls.hasCall && events == ["reported", "ringing", "ended"])
    }
    @Test func cancelledAnswerLookupCannotMutateReplacementCall() async throws {
        let lifecycle = CallLifecycle(), first = invitation()
        _ = lifecycle.incoming(id: first.id)
        let context = try ReachOutContext(record: ["reachoutID": "urgent-1", "session": "ses_A", "expiry": Date().addingTimeInterval(60).timeIntervalSince1970 * 1000], reachoutID: "urgent-1")
        var delayed: CheckedContinuation<ReachOutContext, Never>?
        var draft = "B's unsent words", backend = "B", controller = "B", joins = 0
        let answerA = Task {
            try await IncomingCallResolution.resolve(invitation: first, lifecycle: lifecycle, lookup: {
                // Deliberately emulate a lookup that returns despite cancellation.
                await withCheckedContinuation { delayed = $0 }
            }, join: { context, owner in
                joins += 1; draft = ""; backend = context.session; controller = "A"
                return TargetLease(sessionID: context.session, generation: String(owner.epoch))
            })
        }
        #expect(await waitUntil { delayed != nil })
        _ = lifecycle.end(lifecycle.epoch); answerA.cancel()
        let replacement = TargetLease(sessionID: "ses_B", generation: "replacement")
        _ = lifecycle.begin(target: replacement)
        let epochB = lifecycle.epoch, idB = lifecycle.id
        delayed?.resume(returning: context)
        do { _ = try await answerA.value; Issue.record("Stale answer joined after replacement") } catch {}
        #expect(joins == 0 && draft == "B's unsent words" && backend == "B" && controller == "B")
        #expect(lifecycle.epoch == epochB && lifecycle.id == idB && lifecycle.target == replacement && lifecycle.hasCall)
    }
    @Test func replacedAnswerIsRejectedEvenIfLookupWasNotCancelled() async throws {
        let lifecycle = CallLifecycle(), first = invitation()
        _ = lifecycle.incoming(id: first.id)
        let owner = try IncomingCallOwner(lifecycle: lifecycle, invitation: first)
        _ = lifecycle.end(lifecycle.epoch)
        _ = lifecycle.begin(target: TargetLease(sessionID: "ses_B", generation: "B"))
        #expect(throws: (any Error).self) { try owner.validate(lifecycle) }
    }
    private func invitation(deadline: Date = Date().addingTimeInterval(20)) -> PushInvitation {
        PushInvitation(payload: ["reachoutID": "urgent-1", "callUUID": UUID().uuidString,
                                 "expiry": Date().addingTimeInterval(60).timeIntervalSince1970 * 1000,
                                 "ringDeadline": deadline.timeIntervalSince1970 * 1000])
    }
    @Test func malformedAndDisallowedAlwaysReportBeforeCompletionAndEnd() {
        for input in [PushInvitation(payload: [:]), invitation()] {
            let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p })
            var complete = false
            calls.receivePush(input, allowed: false) { complete = true }
            #expect(p.reports == [input.id]); #expect(!complete); #expect(p.endedIDs.isEmpty)
            p.reportCompletion?(nil)
            #expect(complete); #expect(p.endedIDs == [input.id]); #expect(!calls.hasCall)
        }
    }
    @Test func staleAlwaysReports() {
        let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p })
        let input = invitation(deadline: Date().addingTimeInterval(-1))
        calls.receivePush(input, allowed: true) {}
        #expect(p.reports == [input.id]); p.reportCompletion?(nil)
        #expect(!calls.hasCall && p.endedIDs == [input.id])
    }
    @Test func duplicateReusesUUIDAndDoesNotKillOriginal() {
        let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p }), input = invitation()
        calls.receivePush(input, allowed: true) {}; p.reportCompletion?(nil)
        var done = false
        calls.receivePush(input, allowed: true) { done = true }
        p.reportCompletion?(ClientError("Duplicate UUID"))
        #expect(p.reports == [input.id, input.id]); #expect(done && calls.hasCall && p.endedIDs.isEmpty)
        calls.end()
    }
    @Test func answerBindsInvitationTargetAndRequiresActivation() async {
        let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p }), input = invitation()
        let selected = TargetLease(sessionID: "ses_invitation", generation: "incoming")
        var mediaTargets: [TargetLease] = [], events: [String] = []
        calls.resolveIncoming = { received in #expect(received == input); return selected }
        calls.beginMedia = { _ in if let target = calls.lifecycle.target { mediaTargets.append(target) }; return true }
        calls.receipt = { _, event in events.append(event) }
        calls.receivePush(input, allowed: true) {}; p.reportCompletion?(nil)
        var answered = false
        p.onEvent?(.answer(input.id, { answered = $0 }))
        #expect(await waitUntil { answered })
        #expect(calls.lifecycle.target == selected && mediaTargets.isEmpty)
        p.onEvent?(.activated)
        #expect(await waitUntil { calls.lifecycle.state == .active })
        #expect(mediaTargets == [selected] && events.contains("answered"))
        calls.end(); #expect(events.last == "ended")
    }
    @Test func duplicateAfterEndReportsButCannotRingAgain() {
        let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p }), input = invitation()
        calls.receivePush(input, allowed: true) {}; p.reportCompletion?(nil)
        calls.end(); p.onEvent?(.reset)
        calls.receivePush(input, allowed: true) {}; p.reportCompletion?(nil)
        #expect(p.reports.count == 2 && !calls.hasCall)
    }
    @Test func declineSendsReceiptThenEnd() {
        let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p }), input = invitation()
        var events: [String] = []; calls.receipt = { _, e in events.append(e) }
        calls.receivePush(input, allowed: true) {}; p.reportCompletion?(nil)
        p.onEvent?(.end(input.id, { #expect($0) }))
        #expect(events == ["reported", "ringing", "declined", "ended"])
    }
    @Test func reportFailureSendsFailureAndEnds() {
        let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p }), input = invitation()
        var events: [String] = []; calls.receipt = { _, e in events.append(e) }
        var done = false; calls.receivePush(input, allowed: true) { done = true }
        p.reportCompletion?(ClientError("Focus"))
        #expect(done && !calls.hasCall); #expect(events == ["report-failed", "ended"])
    }
    @Test func ringDeadlineSendsEndNotSecondCall() async {
        let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p })
        var events: [String] = []; calls.receipt = { _, e in events.append(e) }
        calls.receivePush(invitation(deadline: Date().addingTimeInterval(0.02)), allowed: true) {}; p.reportCompletion?(nil)
        #expect(await waitUntil { !calls.hasCall })
        #expect(events.last == "ended" && p.reports.count == 1)
    }
    @Test func boundedAnswerFailureNeverStartsSilentMedia() async {
        let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p }), input = invitation()
        calls.incomingTimeout = 10_000_000
        calls.resolveIncoming = { _ in try await Task.sleep(nanoseconds: 1_000_000_000); return TargetLease(sessionID: "ses_wrong", generation: "late") }
        var media = false, events: [String] = []
        calls.beginMedia = { _ in media = true; return true }; calls.receipt = { _, e in events.append(e) }
        calls.receivePush(input, allowed: true) {}; p.reportCompletion?(nil)
        p.onEvent?(.answer(input.id, { #expect(!$0) }))
        #expect(await waitUntil { !calls.hasCall })
        #expect(!media && !events.contains("answered") && events.last == "ended")
    }
    @Test func answerBeforeReportCompletionStillHasBoundedSetup() async {
        let p = IncomingProvider(), calls = CallCoordinator(makeProvider: { _ in p }), input = invitation()
        calls.incomingTimeout = 10_000_000
        var resolutions = 0
        calls.resolveIncoming = { _ in resolutions += 1; try await Task.sleep(nanoseconds: 1_000_000_000); return TargetLease(sessionID: "ses_late", generation: "late") }
        calls.receivePush(input, allowed: true) {}
        p.onEvent?(.answer(input.id, { #expect(!$0) }))
        p.onEvent?(.answer(input.id, { #expect(!$0) }))
        p.reportCompletion?(nil)
        #expect(await waitUntil { !calls.hasCall })
        #expect(resolutions == 1)
    }
    @Test func settingsAckCannotOvertakeRestrictiveEdit() {
        var sync = PushPolicySync(policy: ReachOutPolicy(quietHoursEnabled: false, timeZone: "UTC"))
        let first = sync.desired
        #expect(!sync.allowsCall(at: Date()))
        let firstAck = sync.acknowledge(first, at: Date()); #expect(firstAck)
        #expect(sync.allowsCall(at: Date()))
        var off = first; off.callsEnabled = false; sync.edit(off)
        #expect(!sync.allowsCall(at: Date()))
        let staleAck = sync.acknowledge(first, at: Date()); #expect(!staleAck)
        #expect(sync.desired.revision == 2 && !sync.synced)
        let offAck = sync.acknowledge(sync.desired, at: Date()); #expect(offAck)
        off.callsEnabled = true; sync.edit(off)
        #expect(!sync.allowsCall(at: Date()))
        let onAck = sync.acknowledge(sync.desired, at: Date()); #expect(onAck)
        #expect(sync.allowsCall(at: Date()))
    }
    @Test func boundReachOutLookup() throws {
        let record: [String: Any] = ["reachoutID": "need-1", "session": "ses_target", "messageID": "msg_here", "expiry": Date().addingTimeInterval(60).timeIntervalSince1970 * 1000]
        let context = try ReachOutContext(record: record, reachoutID: "need-1")
        #expect(context.session == "ses_target" && context.messageID == "msg_here")
        #expect(throws: (any Error).self) { try ReachOutContext(record: record, reachoutID: "other") }
        #expect(throws: (any Error).self) { try ReachOutContext(record: record, reachoutID: "need-1", now: Date().addingTimeInterval(120)) }
        #expect(throws: (any Error).self) { try ReachOutContext(record: record, reachoutID: "need-1", invitation: invitation()) }
    }
    @Test func installNeverAcceptsRawPushOrLookalikeURL() throws {
        let policy = LinkPolicy(approvedManifests: [LinkPolicy.installManifest])
        let encoded = LinkPolicy.installManifest.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
        let url = try #require(URL(string: "itms-services://?action=download-manifest&url=" + encoded))
        #expect(policy.install(url)?.absoluteString == LinkPolicy.installManifest)
        #expect(LinkPolicy().install(url) == nil)
        for value in [LinkPolicy.installManifest, "itms-services://?action=download-manifest&url=https%3A%2F%2Fmac.example-tailnet.invalid%2Fbuild%2Fmanifest.plist", "itms-services://?action=download-manifest&url=https%3A%2F%2Fmac.example-tailnet.invalid.evil.com%2Fx", "itms-services://?action=download-manifest&url=http%3A%2F%2Fmac.example-tailnet.invalid%2Fx"] {
            #expect(policy.install(URL(string: value)!) == nil)
        }
    }
    @Test func answerLookupRequiresExactCallAndUnexpiredUrgentContext() throws {
        let input = invitation()
        let record: [String: Any] = ["reachoutID": input.reachoutID!, "session": "ses_bound", "kind": "urgent-call", "reason": "decision", "callUUID": input.id.uuidString.lowercased(), "callExpiry": input.expiry!.timeIntervalSince1970 * 1000, "expiry": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000]
        let context = try ReachOutContext(record: record, reachoutID: input.reachoutID!, invitation: input)
        #expect(context.session == "ses_bound")
        var expired = record; expired["callExpiry"] = Date().addingTimeInterval(-1).timeIntervalSince1970 * 1000
        #expect(throws: (any Error).self) { try ReachOutContext(record: expired, reachoutID: input.reachoutID!, invitation: input) }
        var wrong = record; wrong["callUUID"] = UUID().uuidString
        #expect(throws: (any Error).self) { try ReachOutContext(record: wrong, reachoutID: input.reachoutID!, invitation: input) }
    }
}
