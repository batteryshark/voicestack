import Foundation
import Testing
@testable import FloatingVoiceCore

/// The plain "isn't running" wording when a speech service cannot be reached (host:port from the configured URL, both
/// services, a custom host), a specific message that still names host:port otherwise, and the error clearing once a
/// later request succeeds.
@Suite struct SpeechServiceTests {
    @Test func unreachableWordingForBothServices() {
        let refused = URLError(.cannotConnectToHost)
        #expect(SpeechServiceError.describe(url: "ws://127.0.0.1:8446/v1/transcribe", error: refused)
                == "Speech service at 127.0.0.1:8446 isn't running")
        #expect(SpeechServiceError.describe(url: "http://127.0.0.1:8444/v1/audio/speech", error: refused)
                == "Speech service at 127.0.0.1:8444 isn't running")
        // Timeouts, DNS failures and a lost connection count the same way.
        for code: URLError.Code in [.timedOut, .dnsLookupFailed, .networkConnectionLost, .cannotFindHost] {
            #expect(SpeechServiceError.describe(url: "ws://127.0.0.1:8446/v1/transcribe", error: URLError(code))
                    == "Speech service at 127.0.0.1:8446 isn't running")
        }
        // The self-check's own timeout throws the plain wording, which is passed through unchanged.
        let timeout = ClientError(SpeechServiceError.notRunning("http://127.0.0.1:8444/v1/audio/speech"))
        #expect(SpeechServiceError.describe(url: "http://127.0.0.1:8444/v1/audio/speech", error: timeout)
                == "Speech service at 127.0.0.1:8444 isn't running")
    }

    @Test func specificFailuresStillNameHostAndPort() {
        // An HTTP status or a bad response keeps a specific message that names the service.
        let status = ClientError("Speech service at 127.0.0.1:8444 returned 500: boom")
        #expect(SpeechServiceError.describe(url: "http://127.0.0.1:8444/v1/audio/speech", error: status)
                == "Speech service at 127.0.0.1:8444 returned 500: boom")
        #expect(SpeechServiceError.describe(url: "http://127.0.0.1:8444/v1/audio/speech", error: ClientError("Speech audio is not WAV"))
                == "Speech service at 127.0.0.1:8444: Speech audio is not WAV")
    }

    @Test func customHostAndDefaultPort() {
        #expect(SpeechServiceError.describe(url: "ws://speech.example:9000/v1/transcribe", error: URLError(.cannotConnectToHost))
                == "Speech service at speech.example:9000 isn't running")
        #expect(SpeechServiceError.hostPort("https://speech.example/v1/audio/speech") == "speech.example:443")
        #expect(SpeechServiceError.hostPort("http://speech.example/x") == "speech.example:80")
    }

    @MainActor @Test func recognitionErrorShowsAndClearsAfterRecovery() async {
        let rig = Rig(configure: { $0.asrUrl = "ws://127.0.0.1:8446/v1/transcribe" })
        await rig.start()
        rig.recognitionError = URLError(.cannotConnectToHost)
        rig.speak()
        #expect(await waitUntil { rig.controller.status.lastError == "Speech service at 127.0.0.1:8446 isn't running" })
        // The next utterance reaches the service: the error clears.
        rig.input.frames(TurnTaker.silenceCueFrames, voiced: false) // reviewed failure recovery requires a fresh gap
        rig.speak()
        #expect(await waitUntil { rig.controller.status.lastError == nil })
        rig.controller.stop()
    }

    @MainActor @Test func speechErrorShowsAndClearsAfterRecovery() async {
        let rig = Rig(configure: { $0.ttsUrl = "http://127.0.0.1:8444/v1/audio/speech" })
        rig.synth.failWith = URLError(.cannotConnectToHost)
        await rig.start()
        rig.backend.send("session.execution.started", "ses_A")
        rig.reply(id: "m1", one)
        #expect(await waitUntil { rig.controller.status.lastError == "Speech service at 127.0.0.1:8444 isn't running" })
        // A later reply is synthesized: the error clears.
        rig.reply(id: "m2", two)
        #expect(await waitUntil { rig.controller.status.lastError == nil })
        rig.controller.stop()
    }
}
