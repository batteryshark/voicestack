import Foundation
import Testing
import Carbon
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct VoiceEndTests {
    @Test func exactClassifierAndPrecedence() {
        let exact = SenderAttribution.classify(text: VoiceEnd.text)
        #expect(exact.kind == "system")
        #expect(exact.label == "Voicestack")
        #expect(SenderAttribution.displayText(VoiceEnd.text, sender: exact) == "Voice ended")
        for near in ["[voice] ended.", "[voice] ended ", "[voice] ended\n", "[voice] Ended", "[voice] ended now", "[voice] [voice] ended"] {
            #expect(SenderAttribution.classify(text: near).label == "You")
        }
        for near in [" [voice] ended", "> [voice] ended", "[Voice] ended", "```\n[voice] ended\n```"] {
            #expect(SenderAttribution.classify(text: near).label == "Message")
        }
        #expect(SenderAttribution.classify(text: VoiceEnd.text, local: true).label == "Voicestack")
        let a2a: [String: Any] = ["a2a": ["v": 1, "from": "local/ses_SOURCE", "traceId": "t", "hop": 0, "kind": "request"]]
        let sender = SenderAttribution.classify(text: VoiceEnd.text, metadata: a2a)
        #expect(sender.kind == "agent")
        #expect(SenderAttribution.displayText(VoiceEnd.text, sender: sender) == "ended")
        #expect(VoicePost.transportText("ended") == VoiceEnd.text) // presentation, not lifecycle authority
    }

    @Test(arguments: [false, true]) func deliberateEndExactlyOnce(muted: Bool) async {
        let r = Rig()
        await r.start()
        #expect(r.backend.admits.isEmpty) // no started note
        if muted { r.controller.setMicMuted(true) }
        r.controller.endVoice()
        #expect(r.input.stopped) // release before awaiting the server
        r.controller.endVoice() // Stop + Stop / Quit
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.admits == ["[voice] ended"])
        #expect(r.backend.endAttempts == ["ses_A"])
        #expect(r.backend.prompts.isEmpty)
        #expect(r.synth.prepared.isEmpty)
        #expect(r.output.plays.isEmpty)
    }

    @Test func noPreActiveOrFailedStartupNote() async {
        let r = Rig(preflight: [PreflightCheck(name: "blocked") { try await Task.sleep(for: .milliseconds(150)) }])
        let start = Task { await r.controller.start() }
        await Task.yield()
        r.controller.endVoice()
        await start.value
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.endAttempts.isEmpty)
        let failed = Rig(preflight: [PreflightCheck(name: "failed") { throw URLError(.cannotConnectToHost) }])
        await failed.controller.start()
        failed.controller.endVoice()
        #expect(failed.backend.endAttempts.isEmpty)
    }

    @Test func squareStopMuteDisconnectReconnectAndFailureAreNotEnd() async {
        let r = Rig()
        await r.start()
        await r.controller.stopReply()
        #expect(r.controller.status.running)
        r.controller.setMicMuted(true)
        r.backend.drop()
        #expect(await waitUntil { r.backend.connects > 1 })
        r.input.onFailure?(URLError(.networkConnectionLost))
        r.controller.endVoice()
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.endAttempts.isEmpty)
    }

    @Test func restartPreservesOneLease() async throws {
        let r = Rig(appFile: tempDir() + "/settings.json")
        await r.start()
        try await r.controller.apply(.echoCancellation("off"))
        #expect(r.backend.endAttempts.isEmpty)
        r.controller.endVoice()
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.endAttempts == ["ses_A"])
    }

    @Test func restartRejectedByMicHolderRetiresLease() async throws {
        let r = Rig(appFile: tempDir() + "/settings.json")
        await r.start()
        r.mic.holders = [MicHolder(pid: 42, path: "/fake/agent-voice/bin/audio-macos", isAgentVoice: true)]
        try await r.controller.apply(.echoCancellation("off"))
        #expect(!r.controller.status.running)
        #expect(r.controller.status.lastError == ConversationController.agentVoiceBusyMessage)
        r.controller.endVoice() // Stop or a later explicit Quit must not resurrect the failed lease.
        r.controller.stopForTermination(deliberateQuit: true)
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.endAttempts.isEmpty)
        r.mic.holders = []
        await r.controller.start()
        r.controller.endVoice()
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.endAttempts == ["ses_A"])
    }

    @Test func targetChangeDuringRestartKeepsMutesWithoutRevivingLease() async throws {
        var checks = 0
        var release: CheckedContinuation<Void, Never>?
        let r = Rig(preflight: [PreflightCheck(name: "gated restart") {
            checks += 1
            if checks > 1 { await withCheckedContinuation { release = $0 } }
        }], appFile: tempDir() + "/settings.json")
        await r.start()
        r.controller.setMicMuted(true)
        r.controller.setOutputMuted(true)
        let restart = Task { try await r.controller.apply(.echoCancellation("off")) }
        #expect(await waitUntil { release != nil })
        #expect(r.controller.status.micMuted && r.controller.status.outputMuted)
        r.controller.setTargetSetting("ses_B")
        release?.resume()
        try await restart.value
        #expect(r.controller.status.phase == "ready")
        #expect(r.controller.status.target == "ses_B")
        #expect(r.controller.status.micMuted && r.controller.status.outputMuted)
        r.input.frames(40, voiced: true)
        #expect(r.recognitions.isEmpty)
        r.controller.endVoice()
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.endAttempts.isEmpty)
        #expect(r.synth.prepared.isEmpty)
    }

    @Test func supersededRestartCannotRestoreMutesIntoNewStart() async throws {
        var checks = 0
        var release: CheckedContinuation<Void, Never>?
        let r = Rig(preflight: [PreflightCheck(name: "old restart only") {
            checks += 1
            if checks == 2 { await withCheckedContinuation { release = $0 } }
        }], appFile: tempDir() + "/settings.json")
        await r.start()
        r.controller.setMicMuted(true); r.controller.setOutputMuted(true)
        let oldRestart = Task { try await r.controller.apply(.echoCancellation("off")) }
        #expect(await waitUntil { release != nil })
        r.controller.endVoice()
        await r.controller.start()
        #expect(!r.controller.status.micMuted && !r.controller.status.outputMuted)
        release?.resume()
        try await oldRestart.value
        #expect(r.controller.status.phase == "ready")
        #expect(!r.controller.status.micMuted && !r.controller.status.outputMuted)
        r.controller.stop()
        #expect(await r.controller.waitForPosts(timeout: 1))
    }

    @Test func quitIntentGateAndSystemTermination() async {
        // App/context/settings menus and CmdQ; Dock's ordinary quit Apple event; OS quit reasons.
        for (explicit, event, reason, expected) in [
            (true, false, false, true), (true, true, false, true), (false, true, false, true),
            (false, false, false, false), (false, true, true, false), (true, true, true, false),
            (true, false, true, false)
        ] {
            let deliberate = TerminationIntent.isDeliberateQuit(explicit: explicit, quitAppleEvent: event, hasSystemReason: reason)
            #expect(deliberate == expected)
            let r = Rig()
            await r.start()
            #expect(await r.controller.shutdown(deliberateQuit: deliberate))
            #expect(r.input.stopped)
            #expect(await r.controller.waitForPosts(timeout: 1))
            #expect(r.backend.endAttempts.count == (expected ? 1 : 0))
        }
    }

    @Test func brokenAdmissionQuitBudgetIsCappedAndCancelsRequest() async {
        let r = Rig()
        await r.start()
        r.backend.endDelay = 30 // fake broken request, no network
        let began = Date()
        #expect(!(await r.controller.shutdown(deliberateQuit: true, timeout: 100)))
        #expect(Date().timeIntervalSince(began) < 2.5)
        #expect(r.input.stopped)
        #expect(await waitUntil { r.backend.endCancelled })
        #expect(r.backend.endAttempts == ["ses_A"])
        #expect(r.backend.admits.isEmpty)
        #expect(r.backend.prompts.isEmpty)
        #expect(r.synth.prepared.isEmpty)
        #expect(await r.controller.shutdown(deliberateQuit: true, timeout: 0.01))
        #expect(r.backend.endAttempts.count == 1)
    }

    @Test func quitBudgetRetiresNoteBlockedBehindUncooperativeWords() async {
        let r = Rig(holdMs: 10_000, configure: { $0.pauseMs = 1000 })
        await r.start()
        // This fake swallows cancellation, simulating an ambiguous already-in-flight word post.
        var release: CheckedContinuation<Void, Never>?
        r.backend.promptGate = { await withCheckedContinuation { release = $0 } }
        r.controller.composer.utterance("pending words")
        let quit = Task { await r.controller.shutdown(deliberateQuit: true, timeout: 0.02) }
        #expect(await waitUntil { release != nil })
        #expect(!(await quit.value))
        #expect(r.backend.endAttempts.isEmpty)
        release?.resume()
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.endAttempts.isEmpty)
        await r.controller.start()
        #expect(r.backend.endAttempts.isEmpty)
        r.controller.stop()
    }

    @Test func expiredOldQuitCannotRetireNewStartLeaseOrMutes() async {
        let r = Rig()
        await r.start()
        r.backend.endDelay = 30
        let quit = Task { await r.controller.shutdown(deliberateQuit: true, timeout: 0.1) }
        #expect(await waitUntil { r.backend.endAttempts.count == 1 })
        await r.controller.start()
        r.controller.setMicMuted(true); r.controller.setOutputMuted(true)
        #expect(!(await quit.value))
        #expect(await waitUntil { r.backend.endCancelled })
        #expect(r.controller.status.running)
        #expect(r.controller.status.micMuted && r.controller.status.outputMuted)
        r.backend.endDelay = 0
        #expect(await r.controller.shutdown(deliberateQuit: true))
        #expect(r.backend.endAttempts == ["ses_A", "ses_A"])
        #expect(r.backend.admits == [VoiceEnd.text])
    }

    @Test func quitAppleEventReasonAdapter() {
        #expect(!TerminationIntent.isDeliberateQuit(explicit: false, appleEvent: nil))
        #expect(TerminationIntent.isDeliberateQuit(explicit: true, appleEvent: nil))
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        #expect(TerminationIntent.isDeliberateQuit(explicit: false, appleEvent: event)) // Dock Quit
        for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut, 0x3F3F3F3F] {
            event.setParam(NSAppleEventDescriptor(typeCode: OSType(reason)), forKeyword: AEKeyword(kAEQuitReason))
            #expect(!TerminationIntent.isDeliberateQuit(explicit: false, appleEvent: event))
            #expect(!TerminationIntent.isDeliberateQuit(explicit: true, appleEvent: event))
        }
        var gate = QuitIntentGate()
        gate.requestQuit()
        let system = gate.consume(appleEvent: event)
        let afterSystem = gate.consume(appleEvent: nil)
        #expect(!system) // system/unknown reason defeats stale explicit intent
        #expect(!afterSystem) // and consumes it
        gate.requestQuit()
        let deliberate = gate.consume(appleEvent: nil)
        let afterDeliberate = gate.consume(appleEvent: nil)
        #expect(deliberate)
        #expect(!afterDeliberate)
    }

    @Test func failedRestartAndCancelledStartCannotCreateLease() async throws {
        var checks = 0
        let r = Rig(preflight: [PreflightCheck(name: "restart failure") {
            checks += 1
            if checks > 1 { throw URLError(.cannotConnectToHost) }
        }], appFile: tempDir() + "/settings.json")
        await r.start()
        try await r.controller.apply(.inputDevice("fake-input"))
        r.controller.endVoice()
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.endAttempts.isEmpty)

        let c = Rig(preflight: [PreflightCheck(name: "slow") { try await Task.sleep(for: .milliseconds(60)) }])
        let oldStart = Task { await c.controller.start() }
        #expect(await waitUntil { c.controller.status.running })
        c.controller.endVoice()
        await c.controller.start()
        await oldStart.value
        c.controller.endVoice()
        #expect(await c.controller.waitForPosts(timeout: 1))
        #expect(c.backend.endAttempts == ["ses_A"])
    }

    @Test func changedChiefSuppressesCapturedTargetNote() async {
        let r = Rig(holdMs: 10_000, configure: { $0.pauseMs = 1000 })
        await r.start()
        r.backend.promptDelay = 0.1
        r.controller.composer.utterance("held")
        r.controller.endVoice()
        writeChief(r.chief, "ses_B")
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.prompts.map(\.session) == ["ses_A"])
        #expect(r.backend.endAttempts.isEmpty)
    }

    @Test func quitFlushOrderingAndManualDiscard() async {
        for manual in [false, true] {
            let r = Rig(holdMs: 10_000, configure: { $0.pauseMs = 1000 })
            await r.start()
            if manual { r.controller.setSendMode(.manual) }
            r.backend.promptDelay = 0.1
            r.controller.composer.utterance("held words")
            r.controller.endVoice()
            #expect(await r.controller.waitForPosts(timeout: 1))
            #expect(r.backend.admits == [VoiceEnd.text])
            #expect(r.backend.endOrder == (manual ? [] : ["[voice] held words"]))
            #expect(r.controller.composer.held.isEmpty)
        }
    }

    @Test func staleStartAndTargetCannotMisdirectPendingEnd() async {
        for newStart in [false, true] {
            let r = Rig(holdMs: 10_000, configure: { $0.pauseMs = 1000 })
            await r.start()
            r.backend.promptDelay = 0.1
            r.controller.composer.utterance("held words")
            r.controller.endVoice()
            if newStart { await r.controller.start() }
            else { r.controller.setTargetSetting("ses_B"); r.controller.setTargetSetting("chief") }
            #expect(await r.controller.waitForPosts(timeout: 1))
            #expect(r.backend.endAttempts.isEmpty)
            r.controller.stop()
        }
        let r = Rig()
        await r.start()
        r.controller.setTargetSetting("ses_B")
        r.controller.endVoice()
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.endAttempts.isEmpty)
    }

    @Test func failedAdmissionNeverPromptsOrRetriesOrSpeaks() async {
        let r = Rig()
        await r.start()
        r.backend.admitError = URLError(.networkConnectionLost)
        r.controller.endVoice()
        #expect(await r.controller.waitForPosts(timeout: 1))
        r.controller.endVoice()
        #expect(r.backend.endAttempts.count == 1)
        #expect(r.backend.prompts.isEmpty)
        #expect(r.synth.prepared.isEmpty)
        #expect(r.lines.contains { $0.contains("not retried") })
    }

    @Test func ownReceiptExactNoteIsSystemEvenWithMetadataAndCannotEndVoice() async {
        let r = Rig(configure: { $0.pauseMs = 3200 })
        await r.start()
        var senders: [SenderAttribution] = []
        r.controller.onCaption = { if case .inbound(let sender, _) = $0 { senders.append(sender) } }
        r.backend.receiptID = "msg_ended"
        r.backend.receiptEcho = {
            r.controller.handle(ServerEvent(type: "session.inbox.enqueued", data: [
                "sessionID": "ses_A", "inboxID": "msg_ended",
                "item": ["type": "user", "payload": ["text": VoiceEnd.text,
                    "metadata": ["a2a": ["v": 1, "from": "local/ses_OTHER", "traceId": "t", "hop": 0, "kind": "request"]]]]
            ]))
        }
        r.controller.composer.utterance("ended")
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(senders.map(\.label) == ["Voicestack"])
        #expect(r.controller.status.running)
        #expect(r.backend.endAttempts.isEmpty)
        #expect(r.synth.prepared.isEmpty)
        r.controller.stop()
    }

    @Test func boundedWaitIncludesNoteAndWords() async {
        let r = Rig(holdMs: 10_000, configure: { $0.pauseMs = 1000 })
        await r.start()
        r.backend.promptDelay = 0.15
        r.controller.composer.utterance("pending")
        r.controller.endVoice()
        #expect(!(await r.controller.waitForPosts(timeout: 0.01)))
        #expect(r.backend.endAttempts.isEmpty)
        #expect(await r.controller.waitForPosts(timeout: 1))
        #expect(r.backend.admits == [VoiceEnd.text])
        let slow = Rig()
        await slow.start()
        slow.backend.endDelay = 0.15
        slow.controller.endVoice()
        #expect(!(await slow.controller.waitForPosts(timeout: 0.01)))
        #expect(slow.input.stopped)
        slow.controller.endVoice()
        #expect(await slow.controller.waitForPosts(timeout: 1))
        #expect(slow.backend.endAttempts.count == 1)
    }
}
