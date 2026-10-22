# Voicestack

<img src="macos/app/Icon/AppIcon-1024.png" alt="Voicestack waveform icon" width="160">

Voicestack lets you talk to an OpenChamber agent session from a floating Mac control or a native iPhone app. Speak a request, send it to the session you're working in, and hear the reply while keeping captions and conversation history available.

On Mac, choose your microphone, speaker and target session. Automatic mode sends after a pause; manual mode holds your words until Send. Discard clears unsent words. Spoken submissions carry a `[voice]` label, and captions distinguish you, the assistant and other senders. The iPhone app adds CallKit controls, a session picker, History and Canvas panels, plus notifications and policy-limited incoming calls through its Mac bridge.

<img src="assets/screenshots/q88-manual-srgb-mac-pill.png" alt="Mac pill with Start and settings controls" width="360">

<img src="assets/screenshots/q88-phone-01b-main-idle-after-reply-run1.png" alt="iPhone conversation showing fictional trail plans, voice off" width="280"> <img src="assets/screenshots/q88-phone-03-history-top-table-code-run1.png" alt="iPhone History with a fictional trail table and packing checklist" width="280">

[More screenshots](assets/screenshots/)

## Why use a dedicated voice client?

[OpenChamber's built-in voice mode](https://github.com/openchamber/openchamber/blob/bf977d2ed89c079ec592210d7cd0e2d649ba0636/packages/docs/content/docs/voice.mdx) provides dictation and reply playback inside its interface, with several speech backends. Its browser voice service also supports resuming listening after playback. Voicestack puts the conversation in a floating Mac control or a native iPhone call, with microphone and speaker controls close at hand. The phone keeps History and Canvas available alongside the conversation.

Speak, watch your words appear as recognition arrives, and pause to send a turn, or hold it for manual Send. Replies play sentence by sentence as the agent writes; compatible speech services can stream audio too. On an echo-safe route you can cut into playback and continue the conversation. On the iPhone speaker, use Tap to cut in before talking. Queue or Steer controls how new words reach a busy agent, and cutting off playback doesn't cancel its work by default.

Chief can use the bridge's call sender for an urgent decision. Answering opens a voice conversation with the originating session, with a pickup greeting and optional hold music while the agent is working. Hold music has its own off switch; a missing local music asset leaves it silent. The personal recording is not distributed: see [hold music](ios/native/HoldMusic.md). Calls respect Calls settings, quiet hours, Focus and outstanding-call safety. Ordinary calls no longer have daily or spacing caps. An unanswered or declined call reports its outcome without a follow-up notification.

**Messages and notifications go through Nod, not Voicestack.** The Voicestack sender accepts calls only; it is not a general message-delivery tool. [iPhone setup](ios/SETUP.md#agent-initiated-alerts-and-calls) covers the authorized call path. Source for the opt-in Open Voice transport and isolated SDK runtime is also included; it is experimental and disabled by default, not proof of a working deployment.

During voice mode, Voicestack automatically speaks the selected session's assistant prose. The agent can keep a spoken answer short and put longer material in fenced blocks that remain available to read. Tool results and reasoning aren't narrated. See [conversation behavior](docs/DEVELOPMENT.md#conversation-behavior) for route-specific interruption limits.

## What you need

- macOS 14+ and Swift 6 tools (Swift 5 language mode). The iPhone app targets iOS 17+ and needs Xcode with Icon Composer support, an iOS SDK, your own Apple signing team and push capabilities. Native `.icon` compilation uses Xcode 26-class tooling; the Mac script also supports PNG-to-ICNS with Command Line Tools.
- OpenChamber desktop with an OpenCode agent session. Both clients currently require OpenChamber-specific discovery and identity checks around OpenCode's session API. A standalone OpenCode V2 server isn't a supported direct connection; [backend details](docs/DEVELOPMENT.md#backend-compatibility) explain the protocol overlap and platform differences.
- Separately operated speech recognition and synthesis services. The apps connect to them; they don't start or stop servers. An optional [local speech reference](examples/local-speech/) provides matching ASR wrappers and a Breeze TTS gateway. Models, voices, reference recordings and provider credentials aren't included.
- For iPhone: a Mac bridge, Node with built-in fetch and global WebSocket (a recent Node 22 or newer), Python 3.10+, and a private HTTPS/tailnet route. Canvas also requires the [pinned renderer dependency tree and local build](ios/bridge/renderer/README.md). Only darwin-arm64 has an admitted renderer compiler hash.

This repository includes both apps, the phone bridge, tests and renderer source. It doesn't include an installable app or generated Canvas libraries. The two apps have independent Swift implementations.

## Mac setup

From the repository root:

```sh
cd macos
sh scripts/build-app.sh
```

The script builds `macos/build/Voicestack.app` and signs it ad hoc. It doesn't install or launch it, and refuses existing output. An optional output path must be a fresh direct child of `macos/build`. The bundle identifier is `local.floating-voice`; avoid replacing a live installation. The Mac pill doesn't require the phone's renderer resources. Distribution signing and notarization aren't provided.

Copy [settings.example.json](macos/config/settings.example.json) to `~/.config/floating-voice/settings.json` and edit it for your services and session. `FV_SETTINGS` overrides that path. Set:

- `target` to your session ID. Alternatively, `chief` reads your own pointer JSON's `session` field; `FV_TARGET` and `FV_CHIEF_FILE` override these choices. No Chief installation is needed for an explicit session.
- `asrUrl` and `ttsUrl` to compatible speech endpoints. Use an operator-registered `voice` or `default`; the example's `alloy` requires a voice registered under that name. `ttsModel` doesn't select the local gateway backend.
- `sendMode` to `manual` or your preferred automatic setting, then select input/output devices in the app.

`FV_OPENCHAMBER_URL` selects an OpenChamber desktop endpoint; `OPENCHAMBER_PORT` overrides port discovery. Otherwise the app reads `desktopLocalPort` from OpenChamber settings. Review [desktop authentication](docs/DEVELOPMENT.md#backend-compatibility) before connecting to an auth-protected endpoint. Existing agent-voice settings can supply speech defaults and are read only; Voicestack settings override them. Keep API keys outside Git. Mac speech requests support separate ASR/TTS Bearer keys.

Start OpenChamber and the speech services separately. Open your development app, allow microphone access, select a target and choose Start voice. Manual Send also has a configurable global shortcut. Stop voice when finished. The app pauses when agent-voice owns the microphone.

## iPhone setup

Follow [ios/SETUP.md](ios/SETUP.md) for the bridge, private route, dedicated desktop-client enrollment and signing configuration. The phone sends audio through the bridge using a device credential. The bridge connects to loopback speech services; changing to a cloud backend requires a compatible proxy/adapter or code changes.

Build and verify Canvas resources first, keeping the same explicit `FV_CANVAS_RESOURCES` for the bridge and native project generation. Review [build.env.example](ios/config/build.env.example), choose your own bundle identifier and signing team, and create an owner-only `ios/private` directory. Then, from the repository root:

```sh
python3 ios/native/build.py generate
```

Generation verifies renderer resources, updates the Xcode project and presentation source, and writes a new private Info.plist. It doesn't contact Apple or build the app. Existing private output is refused. The default configuration has an empty bridge URL and enrollment bootstrap. `unsigned` and `archive` require explicit `FV_ALLOW_BUILD=1`; signing uses pre-provisioned resources without automatic provisioning downloads.

First enrollment requires a one-use secret in signed configuration; there's no runtime pairing-entry screen. Protect enrollment builds and artifacts as credentials; regenerate empty UPDATE configuration after enrollment. Use Voicestack's own revocable OpenChamber client, never another application's token. The bridge's offline deployment preflight is required before `serve`.

Once provisioned and paired, pick a session and start or answer a call. Configure microphone and call permissions, quiet hours and speaker routing. Urgent calls remain policy-limited and don't bypass Focus. Revoking the dedicated desktop client cuts off its bridge access. Install links default to deny; the native client accepts only its exact configured manifest, not arbitrary links.

## Speech contracts and model choices

ASR uses a custom one-utterance WebSocket at `/v1/transcribe`: binary mono 16 kHz s16le PCM followed by `input_audio.end`. Keep the socket open until normal server close. Append committed `transcript` text; replace the display with `transcript.partial` snapshots. Live captions require a server that supports partials. This isn't the OpenAI Transcriptions or Realtime protocol.

TTS uses the `/v1/audio/speech` subset with WAV or streamed headerless mono 24 kHz s16le PCM. It doesn't implement full OpenAI format, SSE, speed-control or voice-management parity. The separate local gateway uses Breeze; `--upstream` changes its address and request `model` is ignored. Parakeet/Voxtral ASR adapters likewise constrain backend choices. A different model needs a compatible service or adapter.

Review endpoint authentication and audio retention before connecting. A remote endpoint sends audio off the machine. A cloud TTS URL isn't a verified drop-in replacement: health probes and voice discovery can affect the client even when synthesis itself works.

## License

Original Voicestack source, documentation and the selected original icon PNGs are [MIT licensed](LICENSE). [RIGHTS.md](RIGHTS.md) defines the artwork scope; [THIRD_PARTY.md](THIRD_PARTY.md) and [DEPENDENCIES.md](DEPENDENCIES.md) cover third-party notices and conditions.
