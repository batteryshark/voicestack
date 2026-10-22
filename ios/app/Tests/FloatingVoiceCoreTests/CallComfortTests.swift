import XCTest
@testable import FloatingVoiceCore

final class CallComfortTests: XCTestCase {
    @MainActor func testPickupCuesPreparedUpFrontGreetingThenOneFollowupAfterItEnds() async throws {
        var tickets: [CueTestTicket] = [], played: [String] = [], allowed = true
        var finish: ((Bool) -> Void)?
        let cue = PickupCueTiming(greetingDelay:20_000_000,followupDelay:60_000_000,
            prepare:{ let ticket = CueTestTicket($0); tickets.append(ticket); return ticket },
            play:{ ticket, ended in played.append(ticket.text); finish = ended },mayFollowUp:{ allowed })
        cue.begin(greeting:"Hey, it’s the chief")
        XCTAssertEqual(tickets.map(\.text),["Hey, it’s the chief","I'm here"]); XCTAssertTrue(played.isEmpty)
        let greeted = await waitUntil { played == ["Hey, it’s the chief"] }; XCTAssertTrue(greeted)
        // The follow-up clock starts when the greeting finishes, not at pickup.
        try await Task.sleep(nanoseconds:120_000_000); XCTAssertEqual(played.count,1)
        finish?(true)
        let followed = await waitUntil { played.count == 2 }; XCTAssertTrue(followed)
        XCTAssertEqual(played.last,"I'm here"); finish?(true)
        try await Task.sleep(nanoseconds:100_000_000); XCTAssertEqual(played.count,2)
        XCTAssertFalse(tickets.contains { $0.cancelled })
        // Cancel while the greeting plays: only the unused follow-up ticket is dropped.
        tickets = []; played = []
        cue.begin(); let second = await waitUntil { played == ["Connected"] }; XCTAssertTrue(second)
        cue.cancel(); XCTAssertEqual(tickets.map(\.cancelled),[false,true])
        finish?(true); try await Task.sleep(nanoseconds:100_000_000); XCTAssertEqual(played,["Connected"])
        // Cancel before the greeting: nothing plays, both tickets released.
        tickets = []; played = []
        cue.begin(); cue.cancel(); XCTAssertEqual(tickets.map(\.cancelled),[true,true])
        try await Task.sleep(nanoseconds:60_000_000); XCTAssertTrue(played.isEmpty)
        // Principal spoke / something playing: no follow-up, its ticket is released.
        tickets = []; played = []; allowed = false
        cue.begin(); let third = await waitUntil { played.count == 1 }; XCTAssertTrue(third); finish?(true)
        try await Task.sleep(nanoseconds:120_000_000); XCTAssertEqual(played,["Connected"]); XCTAssertEqual(tickets.map(\.cancelled),[false,true])
    }
    @MainActor func testCueIsNotAReplyRepliesQueueBehindAndHoldCannotStart() async {
        let output = ComfortOutput(), speaker = Speaker(synth:ComfortSynth(),output:output,onError:{ XCTFail("\($0)") })
        var replyEnqueues = 0, captions: [String] = [], ended: [Bool] = []
        speaker.onReplyEnqueue = { replyEnqueues += 1 }
        speaker.onSentence = { label, _ in captions.append(label) }
        speaker.enqueueCue(ComfortTicket(),ended:{ ended.append($0) })
        let cueing = await waitUntil { speaker.cuePlaying && speaker.playing }; XCTAssertTrue(cueing)
        XCTAssertEqual(replyEnqueues,0); XCTAssertTrue(captions.isEmpty); XCTAssertFalse(speaker.playingReply)
        speaker.enqueueHold(ComfortTicket()); XCTAssertFalse(speaker.isHolding)
        speaker.enqueue("Reply",label:"chief"); XCTAssertEqual(replyEnqueues,1)
        XCTAssertTrue(speaker.cuePlaying) // a reply queues behind the greeting, never cuts it
        output.stopPlayback() // natural end of the cue
        let replying = await waitUntil { captions == ["chief"] }; XCTAssertTrue(replying)
        XCTAssertEqual(ended,[true]); XCTAssertTrue(speaker.playingReply)
        speaker.enqueueCue(ComfortTicket()); XCTAssertEqual(speaker.queuedCount,1)
        speaker.pause(); XCTAssertEqual(speaker.queuedCount,0) // never replayed after pause/recovery
        speaker.stop()
    }
    @MainActor func testCueKeepsExistingSpeakerCaptureGuardAndQuietTail() async {
        let rig = Rig(); rig.input.duplexSafe = false
        await rig.start()
        rig.controller.speaker.enqueueCue(rig.controller.speaker.prepareCue("Connected"))
        let cueing = await waitUntil { rig.controller.speaker.cuePlaying && rig.controller.speaker.playing }; XCTAssertTrue(cueing)
        XCTAssertTrue(rig.controller.status.listeningSuppressed)
        rig.speak(); await Task.yield(); XCTAssertTrue(rig.backend.prompts.isEmpty)
        let done = await waitUntil { !rig.controller.speaker.active }; XCTAssertTrue(done)
        XCTAssertTrue(rig.controller.status.listeningSuppressed)
        XCTAssertEqual(rig.output.plays.map(\.text),["Connected"])
        rig.controller.stop(discardUnfinished:true)
    }
    @MainActor func testRealControllerPostWhileStoreAlreadyActiveWaitsForFreshExecutionThenStopsAtReply() async throws {
        let rig = Rig(busyDelivery:.queue)
        await rig.start()
        let target = try XCTUnwrap(rig.controller.currentLease)
        let store = ConversationStore(target:target)
        try store.reconcile(history:Data("{\"data\":[]}".utf8),active:true,for:target)
        var starts = 0, playing = false, postedWhileActive = false, posts = 0
        let music = ProcessingHoldMusic(delay:20_000_000,start:{ starts += 1; playing = true },stop:{ playing = false })
        rig.controller.onCaption = { event in
            if case .posted = event { posts += 1; postedWhileActive = store.active }
            music.caption(event)
        }
        rig.controller.onAgentProcessing = { music.processing($0) }
        var serial = 0
        func event(_ type: String, data: [String:Any] = [:]) {
            serial += 1
            var payload = data; payload["sessionID"] = target.sessionID
            let event = ServerEvent(type:type,data:payload)
            if let update = store.receive(event,eventID:"evt-\(serial)",for:target) { rig.controller.consumeNarration(update) }
            // RemoteSessionBackend publishes execution events; text uses the store narration seam.
            if !type.hasPrefix("session.text.") { rig.controller.handle(event) }
        }
        event("session.execution.started")
        rig.speak()
        let posted = await waitUntil { posts == 1 }; XCTAssertTrue(posted); XCTAssertTrue(postedWhileActive)
        let initial = await waitUntil { starts == 1 }; XCTAssertTrue(initial) // authoritative execution, including initial reply
        event("session.execution.succeeded")
        event("session.execution.started")
        let began = await waitUntil { playing }; XCTAssertTrue(began); XCTAssertEqual(starts,2)
        event("session.text.delta",data:["assistantMessageID":"reply", "ordinal":0, "delta":"Here is the reply. "])
        event("session.text.ended",data:["assistantMessageID":"reply", "ordinal":0, "text":"Here is the reply. "])
        let stopped = await waitUntil { !playing }; XCTAssertTrue(stopped)
        music.enabled = false; event("session.execution.started")
        try await Task.sleep(nanoseconds:30_000_000); XCTAssertEqual(starts,2)
        music.end(); rig.controller.stop(discardUnfinished:true)
    }
    func testLocalOrdinaryPermissionCannotReplacePilotAcknowledgementOrZoneFence() {
        let now = Date(), local = ReachOutPolicy(quietHoursEnabled:false,timeZone:"UTC")
        var synced = PushPolicySync(policy:local)
        XCTAssertTrue(local.localCallsAllowed(at:now))
        XCTAssertFalse(synced.allowsPilotCall(at:now,timeZone:"UTC"))
        XCTAssertTrue(synced.acknowledge(local,at:now))
        XCTAssertTrue(synced.allowsPilotCall(at:now,timeZone:"UTC"))
        XCTAssertFalse(synced.allowsPilotCall(at:now,timeZone:"America/New_York"))
        XCTAssertFalse(synced.allowsPilotCall(at:now.addingTimeInterval(86_400),timeZone:"UTC"))
        var restricted = local; restricted.callsEnabled = false; synced.edit(restricted)
        XCTAssertTrue(local.localCallsAllowed(at:now))
        XCTAssertFalse(synced.allowsPilotCall(at:now,timeZone:"UTC"))
    }
    @MainActor func testHoldUsesProtectedPlaybackWithoutChiefCaptionsAndYieldsToSpeech() async {
        let output = ComfortOutput(), synth = ComfortSynth()
        let speaker = Speaker(synth:synth,output:output,onError:{ XCTFail("\($0)") })
        var captions: [String] = []
        speaker.onSentence = { label, _ in captions.append(label) }
        speaker.enqueueHold(ComfortTicket())
        let holding = await waitUntil { speaker.playing }; XCTAssertTrue(holding)
        XCTAssertTrue(speaker.isHolding); XCTAssertTrue(captions.isEmpty)
        speaker.stopHold(); XCTAssertFalse(speaker.playing)
        speaker.enqueue("Reply",label:"chief")
        let replying = await waitUntil { captions == ["chief"] }; XCTAssertTrue(replying)
        speaker.stopHold(); XCTAssertTrue(speaker.playing)
        speaker.stop()
    }
    @MainActor func testEndingBeforeMediaReadyNeverStartsPickupCue() async {
        let provider = FakeCallProvider(), calls = CallCoordinator(makeProvider:{ _ in provider })
        let invitation = PushInvitation(payload:["reachoutID":"cancel-cue", "callUUID":UUID().uuidString,
            "expiry":Date().addingTimeInterval(30).timeIntervalSince1970*1000,
            "ringDeadline":Date().addingTimeInterval(30).timeIntervalSince1970*1000])
        var release: CheckedContinuation<Bool,Never>?, cues = 0, answered = false
        calls.resolveIncoming = { _ in TargetLease(sessionID:"ses_comfort",generation:"fixture") }
        calls.pickupCue = { cues += 1 }
        calls.beginMedia = { _ in await withCheckedContinuation { release = $0 } }
        calls.receivePush(invitation,allowed:true) {}
        provider.emit(.answer(invitation.id,{ answered = $0 }))
        let ready = await waitUntil { answered }; XCTAssertTrue(ready)
        provider.emit(.activated)
        let starting = await waitUntil { release != nil }; XCTAssertTrue(starting); XCTAssertEqual(cues,0)
        calls.end(); release?.resume(returning:true); release = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(cues,0); provider.emit(.deactivated)
    }
    @MainActor func testMusicRequiresActualProcessingAndFencesStoppedClipCompletions() async throws {
        var starts = 0, stops = 0
        let music = ProcessingHoldMusic(delay:20_000_000,start:{ starts += 1 },stop:{ stops += 1 })
        music.posted(); try await Task.sleep(nanoseconds:30_000_000); XCTAssertEqual(starts,0)
        music.processing(true); let first = await waitUntil { starts == 1 }; XCTAssertTrue(first)
        music.processing(true); try await Task.sleep(nanoseconds:30_000_000); XCTAssertEqual(starts,1)
        music.enabled = false; XCTAssertGreaterThan(stops,0)
        let stoppedGeneration = music.playbackGeneration
        music.clipEnded(true,generation:stoppedGeneration); try await Task.sleep(nanoseconds:30_000_000); XCTAssertEqual(starts,1)
        music.end(); music.enabled = true
        try await Task.sleep(nanoseconds:30_000_000); XCTAssertEqual(starts,1)
        music.posted(); music.processing(true); music.processing(false)
        try await Task.sleep(nanoseconds:30_000_000); XCTAssertEqual(starts,1)
        music.posted(); music.processing(true); let second = await waitUntil { starts == 2 }; XCTAssertTrue(second)
        let old = music.playbackGeneration
        music.replyStarted(); music.processing(true); music.clipEnded(true,generation:old)
        try await Task.sleep(nanoseconds:30_000_000); XCTAssertEqual(starts,2)
        music.end(); music.clipEnded(true,generation:old); try await Task.sleep(nanoseconds:30_000_000); XCTAssertEqual(starts,2)
    }
    @MainActor func testPickupCueStartsOnceAfterMediaReadyNeverOnRecovery() async {
        let provider = FakeCallProvider(), calls = CallCoordinator(makeProvider:{ _ in provider })
        let target = TargetLease(sessionID:"ses_comfort",generation:"fixture")
        let invitation = PushInvitation(payload:["reachoutID":"comfort", "callUUID":UUID().uuidString,
            "expiry":Date().addingTimeInterval(30).timeIntervalSince1970*1000,
            "ringDeadline":Date().addingTimeInterval(30).timeIntervalSince1970*1000])
        var cues = 0, captures = 0, answered = false, cueAfterReady = false
        calls.resolveIncoming = { _ in target }
        calls.pickupCue = { cues += 1; cueAfterReady = calls.hasEverBeenMediaReady && captures == 1 }
        calls.beginMedia = { _ in captures += 1; return true }
        calls.receivePush(invitation,allowed:true) {}
        provider.emit(.answer(invitation.id,{ answered = $0 }))
        let answerReady = await waitUntil { answered }; XCTAssertTrue(answerReady); XCTAssertEqual(cues,0)
        provider.emit(.activated)
        let cued = await waitUntil { cues == 1 }; XCTAssertTrue(cued); XCTAssertTrue(cueAfterReady)
        calls.pauseMediaForRouteRecovery(); calls.resumeMediaAfterRouteRecovery()
        let recovered = await waitUntil { captures == 2 }; XCTAssertTrue(recovered)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(cues,1)
        provider.emit(.activated); XCTAssertEqual(cues,1)
        calls.end(); provider.emit(.deactivated)
    }
    func testPhoneQuietWindowNeedsNoAcknowledgmentAndHandlesOvernight() throws {
        let policy = ReachOutPolicy(quietStart:"22:00",quietEnd:"08:00",timeZone:"UTC")
        let formatter = ISO8601DateFormatter(), night = try XCTUnwrap(formatter.date(from:"2026-10-22T23:00:00Z"))
        XCTAssertFalse(policy.localCallsAllowed(at:night))
        XCTAssertEqual(policy.quietUntil(at:night),formatter.date(from:"2026-10-23T08:00:00Z"))
        XCTAssertTrue(policy.localCallsAllowed(at:try XCTUnwrap(formatter.date(from:"2026-10-23T08:00:00Z"))))
        var disabled = policy; disabled.quietHoursEnabled = false
        XCTAssertTrue(disabled.localCallsAllowed(at:night)); XCTAssertNil(disabled.quietUntil(at:night))
    }
}

private final class CueTestTicket: SpeechTicket {
    let text: String
    var cancelled = false
    init(_ text: String) { self.text = text }
    func audio() async throws -> SpeechAudio { .whole(Data([0,0]),sampleRate:24000) }
    func cancel() { cancelled = true }
}
private final class ComfortTicket: SpeechTicket {
    let text = "Reply"
    func audio() async throws -> SpeechAudio { .whole(Data([0,0]),sampleRate:24000) }
    func cancel() {}
}
private final class ComfortSynth: SpeechSynthesizer {
    func prepare(_ text: String) -> SpeechTicket { ComfortTicket() }
}
@MainActor private final class ComfortOutput: AudioOutput {
    private var waiter: CheckedContinuation<Void,Never>?
    func play(_ audio: SpeechAudio,label: String,onStart: @escaping () -> Void) async throws {
        onStart(); await withCheckedContinuation { waiter = $0 }
    }
    func stopPlayback() { let pending = waiter; waiter = nil; pending?.resume() }
}
