import Foundation
import Testing
@testable import FloatingVoiceCore

private final class OfflineSocket: RecognitionSession {
    let socket: WebSocketRecognition
    init(_ socket: WebSocketRecognition) { self.socket = socket }
    func start() {}
    func write(_ pcm: Data) {}
    func end() {}
    func cancel() { socket.cancel() }
}

@Suite @MainActor struct NetworkPolicyTests {
    @Test func jitteredBackoffCapsAndResetsOnlyAfterHealth() {
        var retry = ReconnectBackoff()
        #expect((0..<7).map { _ in retry.next(healthyFor: 0, jitter: 0.5) } == [1, 2, 4, 8, 15, 15, 15])
        #expect(retry.next(healthyFor: 29, jitter: 0) == 12)
        #expect(abs(retry.next(healthyFor: 30, jitter: 1) - 1.2) < 0.0001)
        #expect(retry.next(healthyFor: 0, jitter: 0.5) == 2)
    }
    @Test func heartbeatBytesKeepIdleWatchdogAliveButNotForever() {
        var idle = StreamIdleWatchdog(now: 0)
        for now in stride(from: 15.0, through: 600, by: 15) {
            #expect(!idle.expired(now: now)); idle.received(now: now)
        }
        #expect(!idle.expired(now: 674.9)); #expect(idle.expired(now: 675))
        var parser = SSEParser()
        #expect(parser.push(Data(": heartbeat\n\n".utf8)).isEmpty)
    }
    @Test func pingWatchdogRequiresPongAndBoundsPendingAudio() {
        var ping = PingWatchdog(now: 0)
        #expect(ping.tick(now: 19) == .none); #expect(ping.tick(now: 20) == .ping)
        #expect(ping.tick(now: 29.9) == .none); ping.pong()
        #expect(ping.tick(now: 40) == .ping); #expect(ping.tick(now: 50) == .timeout)
        var sends = PCMSendBudget()
        for _ in 0..<100 { let accepted = sends.reserve(640); #expect(accepted) }
        let overflow = sends.reserve(640); #expect(!overflow)
        sends.release(640); let freed = sends.reserve(640); #expect(freed)
        var oversized = PCMSendBudget(); let large = oversized.reserve(64001); #expect(!large)
    }
    @Test func boundedCatchUpRejectsRepeatedCursorAndStopsAtTenPages() {
        var gap = HistoryCatchUp(boundary: "lastKnown")
        let first = gap.accept(ids: ["new"], next: "older"); #expect(first)
        let repeated = gap.accept(ids: ["oldButNotBoundary"], next: "older"); #expect(!repeated); #expect(!gap.complete)
        var huge = HistoryCatchUp(boundary: "missing")
        for index in 1...10 { #expect(huge.accept(ids: ["new\(index)"], next: "page\(index)") == (index < 10)) }
        #expect(!huge.complete)
    }
    @Test(arguments: [false, true]) func socketDiscontinuityRetainsPartialAndRequiresNewSpeech(_ receiveAfterEnd: Bool) throws {
        var cb = TurnCallbacks(), review: [String] = [], finals: [String] = []
        cb.review = { review.append($0) }; cb.transcript = { finals.append($0) }
        var sockets: [WebSocketRecognition] = [], callbacks: [RecognitionCallbacks] = []
        let turn = TurnTaker(config: VoiceConfig(), callbacks: cb) { incoming in
            callbacks.append(incoming)
            let ws = WebSocketRecognition(url: "wss://example.invalid", apiKey: nil, callbacks: incoming)
            ws.pingWatch = PingWatchdog(now: 0); sockets.append(ws)
            return OfflineSocket(ws)
        }
        let voiced = Data(repeating: 0x20, count: 640)
        for _ in 0..<30 { turn.push(voiced) }
        let ws = try #require(sockets.first)
        callbacks[0].live("uncertain words")
        if receiveAfterEnd { ws.end(); ws.receiveFailed(URLError(.networkConnectionLost)) }
        else { ws.checkPing(now: 20); ws.checkPing(now: 30) }
        #expect(review == ["uncertain words"] && finals.isEmpty && !turn.inUtterance)
        for _ in 0..<50 { turn.push(voiced) }
        #expect(sockets.count == 1)
        for _ in 0..<25 { turn.push(Data(repeating: 0, count: 640)) }
        for _ in 0..<30 { turn.push(voiced) }
        #expect(sockets.count == 2); turn.stop()
    }
    @Test func controllerDiscontinuityQuarantinesAndNeverSubmits() async throws {
        let rig = Rig(holdMs: 10)
        await rig.start()
        #expect(await waitUntil { rig.controller.currentLease != nil })
        rig.input.frames(30, voiced: true)
        let recognition = try #require(rig.recognitions.first)
        let owner = try #require(rig.controller.currentLease)
        recognition.callbacks.live("review these words")
        recognition.callbacks.error(URLError(.networkConnectionLost)); recognition.callbacks.done("")
        #expect(rig.controller.draftsForReview.contains { $0.target == owner && $0.text == "review these words" })
        #expect(rig.backend.prompts.isEmpty && rig.backend.admits.isEmpty)
        rig.controller.stop()
    }
    @Test func finalDeadlineRetainsOriginalOwnerClearsSubmissionAndRequiresFreshGap() async throws {
        let rig = Rig(holdMs: 10_000)
        rig.silentEnd = true
        await rig.start()
        defer { rig.controller.stop() }
        #expect(await waitUntil { rig.controller.currentLease != nil })
        let owner = try #require(rig.controller.currentLease)
        let turn = try #require(rig.controller.turnTaker)
        turn.finalTimeout = 0.01
        rig.controller.composer.utterance("previous held words")
        rig.input.frames(30, voiced: true)
        let first = try #require(rig.recognitions.first)
        first.callbacks.live("uncertain final words")
        turn.endNow()
        #expect(await waitUntil { !turn.inUtterance })
        #expect(rig.controller.draftsForReview.contains { $0.target == owner && $0.text == "uncertain final words" })
        #expect(rig.controller.draftsForReview.contains { $0.target == owner && $0.text == "previous held words" })
        #expect(rig.controller.composer.held.isEmpty)
        first.callbacks.done("late result must not submit")
        rig.input.frames(40, voiced: true)
        #expect(rig.recognitions.count == 1)
        rig.input.frames(25, voiced: false)
        rig.input.frames(30, voiced: true)
        #expect(rig.recognitions.count == 2)
        #expect(rig.backend.prompts.isEmpty && rig.backend.admits.isEmpty)
    }
}
