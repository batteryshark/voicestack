import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct VoiceEndedTests {
    let target = TargetLease(sessionID: "ses_voice", generation: "one")
    @Test(arguments: [false, true]) func appAndSystemEndAdmitExactlyOnce(_ system: Bool) async {
        let rig = CallCoordinatorRig(), provider = await rig.active()
        var posts: [String] = [], tasks: [Task<Void, Never>] = []
        rig.calls.onDeliberateEnd = { session in
            #expect(session.kind == .call && session.callEpoch != nil)
            tasks.append(Task { await session.end(currentLease: { rig.target }, admit: { lease, text in
                #expect(lease == rig.target); posts.append(text)
            }) })
        }
        if system { provider.emit(.end(provider.id, { _ in })) } else { rig.calls.end() }
        rig.calls.end(); provider.emit(.end(provider.id, { _ in })); provider.emit(.reset)
        for task in tasks { await task.value }
        #expect(tasks.count == 1 && posts == ["[voice] ended"])
    }
    @Test func standaloneStopIsOncePerActualSessionNotCaptureGeneration() async {
        let session = VoiceEndedSession(kind: .app, target: target)
        let lifecycle = NativeVoiceLifecycle(), identity = session.generation
        _ = lifecycle.requestStart(); lifecycle.invalidate(); _ = lifecycle.requestStart()
        var posts = 0
        for _ in 0..<2 { await session.end(currentLease: { target }, admit: { _, text in #expect(text == "[voice] ended"); posts += 1 }) }
        #expect(posts == 1 && session.generation == identity)
    }
    @Test(arguments: ["reset", "media", "timeout", "failure"])
    func automaticFailuresNeverAdmitEvenIfUserEndsLater(_ mode: String) async {
        let rig = CallCoordinatorRig(), provider = await rig.active()
        var posts = 0, tasks: [Task<Void, Never>] = []
        rig.calls.onDeliberateEnd = { session in tasks.append(Task {
            await session.end(currentLease: { rig.target }, admit: { _, _ in posts += 1 })
        }) }
        switch mode {
        case "reset": provider.emit(.reset)
        case "media": rig.calls.mediaFailed(.mediaFailure)
        case "timeout": provider.emit(.timedOut(provider.id))
        default: provider.emit(.failed("Synthetic failure"))
        }
        rig.calls.end(); provider.emit(.reset)
        for task in tasks { await task.value }
        #expect(posts == 0)
    }
    @Test(arguments: [false, true]) func unansweredOrDeclinedRingNeverAdmits(_ decline: Bool) async {
        let provider = FakeCallProvider(), calls = CallCoordinator(makeProvider: { _ in provider })
        var callbacks = 0
        calls.onDeliberateEnd = { _ in callbacks += 1 }
        let invitation = PushInvitation(payload: ["reachoutID":"voice-ended-ring", "callUUID":UUID().uuidString,
            "expiry":Date().addingTimeInterval(10).timeIntervalSince1970 * 1000,
            "ringDeadline":Date().addingTimeInterval(decline ? 5 : 0.02).timeIntervalSince1970 * 1000])
        calls.receivePush(invitation, allowed: true) {}
        if decline { provider.emit(.end(invitation.id, { _ in })) }
        #expect(await waitUntil { !calls.hasCall })
        #expect(callbacks == 0)
        provider.emit(.reset)
    }
    @Test func relaunchAndIdleEndNeverInventASession() {
        for _ in 0..<2 {
            let calls = CallCoordinator(makeProvider: { _ in FakeCallProvider() })
            var callbacks = 0; calls.onDeliberateEnd = { _ in callbacks += 1 }
            calls.end(); calls.mediaReset()
            #expect(callbacks == 0)
        }
    }
    @Test(arguments: [false, true]) func initialReadinessTimeoutOrMediaFailureNeverAdmits(_ mediaFailure: Bool) async {
        let rig = CallCoordinatorRig(); rig.calls.readinessTimeout = 20_000_000
        var callbacks = 0; rig.calls.onDeliberateEnd = { _ in callbacks += 1 }
        let provider = rig.start()
        if mediaFailure { rig.begin = { false }; provider.emit(.activated) }
        #expect(await waitUntil { !rig.calls.hasCall })
        #expect(callbacks == 0)
        provider.emit(.reset)
    }
    @Test func successfulNativeDeviceRestartsDoNotRemintOrAdmit() async {
        let rig = Rig(); await rig.start(); defer { rig.controller.stop() }
        let lifecycle = NativeVoiceLifecycle(); lifecycle.controller = rig.controller
        _ = lifecycle.requestStart()
        let session = VoiceEndedSession(kind: .app, target: target), identity = UUID()
        var posts: [UUID] = []
        for event in [NativeAudioEvent.routeChanged, .mediaReset] {
            let before = lifecycle.generation
            lifecycle.handle(event)
            #expect(await waitUntil { lifecycle.generation > before && rig.controller.status.phase == "ready" })
            #expect(posts.isEmpty)
        }
        await session.end(currentLease: { target }, admit: { _, _ in posts.append(identity) })
        #expect(posts == [identity])
    }
    @Test func successfulRouteRecoveryKeepsOriginalSessionAndTarget() async {
        let rig = CallCoordinatorRig(), provider = await rig.active()
        let epoch = rig.calls.lifecycle.epoch
        rig.calls.pauseMediaForRouteRecovery(); rig.calls.resumeMediaAfterRouteRecovery()
        #expect(await waitUntil { rig.starts == 2 && !rig.calls.mediaIsPaused })
        var session: VoiceEndedSession?
        rig.calls.onDeliberateEnd = { session = $0 }
        rig.calls.end(); provider.emit(.reset)
        let captured = try? #require(session)
        #expect(captured?.callEpoch == epoch && captured?.target == rig.target)
        var posts = 0
        await captured?.end(currentLease: { rig.target }, admit: { _, _ in posts += 1 })
        #expect(posts == 1)
    }
    @Test func staleLeaseAndFailureInvalidationStayInvalidUntilFreshStart() async {
        for sameLeaseRestored in [false, true] {
            let session = VoiceEndedSession(kind: .app, target: target)
            let replacement = TargetLease(sessionID: "ses_other", generation: "two")
            session.invalidate() // Selection/failure, not a new eligible start.
            var posts = 0, outcomes: [VoiceEndedOutcome] = []
            await session.end(currentLease: { sameLeaseRestored ? target : replacement }, admit: { _, _ in posts += 1 }, diagnostic: { outcomes.append($0.outcome) })
            #expect(posts == 0 && outcomes == [.skippedStaleLease])
            let fresh = VoiceEndedSession(kind: .app, target: replacement)
            await fresh.end(currentLease: { replacement }, admit: { _, _ in posts += 1 })
            #expect(posts == 1)
        }
    }
    @Test func queuedNoteSupersededBeforeHandoffIsSuppressed() async {
        let session = VoiceEndedSession(kind: .app, target: target)
        var posts = 0
        let queued = Task { await session.end(currentLease: { target }, admit: { _, _ in posts += 1 }) }
        session.invalidate() // Fresh deliberate Start before queued MainActor job executes.
        await queued.value
        #expect(posts == 0)
    }
    @Test func capturedLeaseMismatchSkipsWithoutRetargeting() async {
        let session = VoiceEndedSession(kind: .call, target: target, callEpoch: 4)
        var posts = 0, outcomes: [VoiceEndedOutcome] = []
        await session.end(currentLease: { .init(sessionID: target.sessionID, generation: "replacement") }, admit: { _, _ in posts += 1 }, diagnostic: { outcomes.append($0.outcome) })
        #expect(posts == 0 && outcomes == [.skippedStaleLease])
    }
    @Test func admissionAlreadyHandedOffCannotBeUndoneOrRetried() async {
        let session = VoiceEndedSession(kind: .app, target: target)
        var pending: CheckedContinuation<Void, Never>?, posts = 0, outcomes: [VoiceEndedOutcome] = []
        let task = Task { await session.end(currentLease: { target }, admit: { lease, _ in
            #expect(lease == target); posts += 1
            await withCheckedContinuation { pending = $0 }
        }, diagnostic: { outcomes.append($0.outcome) }) }
        #expect(await waitUntil { pending != nil })
        session.invalidate(); pending?.resume(); await task.value
        await session.end(currentLease: { target }, admit: { _, _ in posts += 1 })
        #expect(posts == 1 && outcomes == [.posted])
    }
    @Test func failedAdmissionIsOneAttemptWithClosedDiagnostics() async throws {
        let session = VoiceEndedSession(kind: .app, target: target)
        let diagnostics = StageDiagnostics(); var attempts = 0
        for _ in 0..<2 {
            await session.end(currentLease: { target }, admit: { _, _ in attempts += 1; throw ClientError("Secret must never enter diagnostic") },
                diagnostic: { diagnostics.record(.voiceEnded, .failed, voiceEnded: $0) })
        }
        let entries = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(diagnostics.export().utf8))
        #expect(attempts == 1 && entries.count == 1)
        #expect(entries[0].stage == .voiceEnded && entries[0].voiceEnded?.kind == .app && entries[0].voiceEnded?.outcome == .failed)
        #expect(!diagnostics.export().contains("Secret") && !diagnostics.export().contains(target.sessionID))
    }
    @Test func ownReceiptIsQuietSystemNoteInHistoryAndLogAndNeverNarrated() throws {
        let raw = Data(#"{"id":"msg_note","type":"user","text":"[voice] ended","sender":{"kind":"principal","label":"You"}}"#.utf8)
        var receipts = LocalSenderReceipts()
        receipts.record(Data(#"{"data":{"id":"msg_note"}}"#.utf8), sessionID: target.sessionID)
        let note = receipts.project([raw], sessionID: target.sessionID)[0]
        let row = try #require(MessageRow(note))
        #expect(row.isSystemNote && !row.isPrincipal && row.role == "System")
        #expect(row.displayLabel == "Voicestack" && row.text == "Voice ended")
        var log = ConversationVoiceLog(); log.update(records: [note, note])
        #expect(log.turns.allSatisfy { $0.role == .system && !$0.isPrincipal && $0.spoken == "Voice ended" })
        let store = ConversationStore(target: target)
        #expect(try store.reconcile(history: JSONSerialization.data(withJSONObject: ["data":[JSONSerialization.jsonObject(with: note)]]), active: false, for: target).isEmpty)
        let event = ServerEvent(type: "session.inbox.enqueued", data: ["sessionID":target.sessionID,"item":["type":"user","payload":["text":"[voice] ended"]]])
        #expect(store.receive(event, eventID: "evt_note", for: target) == nil)
    }
}
