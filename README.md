# Voicestack

<img src="macos/app/Icon/AppIcon-1024.png" alt="Voicestack waveform icon" width="160">

Voicestack lets you talk to an OpenChamber agent session from a floating Mac control or a native iPhone app. Speak a request, send it to the session you're working in, and hear the reply while keeping captions and conversation history available.

On Mac, choose your microphone, speaker and target session. Automatic mode sends after a pause; manual mode holds your words until Send. Discard clears unsent words. Spoken submissions carry a `[voice]` label, and captions distinguish you, the assistant and other senders. The iPhone app adds CallKit controls, a session picker, History and Canvas panels, plus notifications and policy-limited incoming calls through its Mac bridge.

<img src="assets/screenshots/q88-manual-srgb-mac-pill.png" alt="Mac pill with Start and settings controls" width="360">

<img src="assets/screenshots/q88-phone-01b-main-idle-after-reply-run1.png" alt="iPhone conversation showing fictional trail plans, voice off" width="280"> <img src="assets/screenshots/q88-phone-03-history-top-table-code-run1.png" alt="iPhone History with a fictional trail table and packing checklist" width="280">

The phone captures show real build 36 UI with fictional trail-plan content. [More captures](assets/screenshots/) include recent history and settings. The Mac capture has no visible build label. This source copy hasn't been device-tested.

## What you need

- macOS 14+ and Swift 6 tools (Swift 5 language mode). The iPhone app targets iOS 17+ and needs Xcode with Icon Composer support, an iOS SDK, your own Apple signing team and push capabilities. Native `.icon` compilation uses Xcode 26-class tooling; the Mac script also supports PNG-to-ICNS with Command Line Tools.
- OpenChamber desktop with an agent session. The clients use its desktop API; OpenCode alone doesn't supply that API.
- Separately operated speech recognition and synthesis services. The apps connect to them; they don't start or stop servers. [local-speech-servers](https://github.com/batteryshark/local-speech-servers) is a separate project. Models, voices, reference recordings and provider credentials aren't included.
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

`FV_OPENCHAMBER_URL` selects a desktop API endpoint. Existing agent-voice settings can supply speech defaults and are read only; Voicestack settings override them. Keep API keys outside Git. Mac speech requests support separate ASR/TTS Bearer keys.

Start OpenChamber and the speech services separately. Open your development app, allow microphone access, select a target and choose Start voice. Manual Send also has a configurable global shortcut. Stop voice when finished. The app pauses when agent-voice owns the microphone.

## iPhone setup

Follow [ios/SETUP.md](ios/SETUP.md) for the bridge, private route, dedicated desktop-client enrollment and signing configuration. The phone sends audio through the bridge using a device credential. The bridge connects to loopback speech services; changing to a cloud backend requires a compatible proxy/adapter or code changes.

Build and verify Canvas resources first, keeping the same explicit `FV_CANVAS_RESOURCES` for the bridge and native project generation. Review [build.env.example](ios/config/build.env.example), choose your own bundle identifier and signing team, and create an owner-only `ios/private` directory. Then, from the repository root:

```sh
python3 ios/native/build.py generate
```

Generation verifies renderer resources, updates the Xcode project and presentation source, and writes a new private Info.plist. It doesn't contact Apple or build the app. Existing private output is refused. The default configuration has an empty bridge URL and enrollment bootstrap. `unsigned` and `archive` require explicit `FV_ALLOW_BUILD=1`; signing uses pre-provisioned resources without automatic provisioning downloads.

First enrollment requires a one-use secret in signed configuration; there's no runtime pairing-entry screen. Protect enrollment builds and artifacts as credentials; regenerate empty UPDATE configuration after enrollment. Use Voicestack's own revocable OpenChamber client, never another application's token. The bridge's offline deployment preflight is required before `serve`.

Once provisioned and paired, pick a session and start or answer a call. Configure microphone, notification and call permissions, quiet hours and speaker routing. Urgent calls remain policy-limited and don't bypass Focus. Revoking the dedicated desktop client cuts off its bridge access. [Install links](ios/shared/INSTALL_POLICY.md) default to deny and need an explicit matching native/bridge policy.

## Speech contracts and model choices

ASR uses a custom one-utterance WebSocket at `/v1/transcribe`: binary mono 16 kHz s16le PCM followed by `input_audio.end`. Keep the socket open until normal server close. Append committed `transcript` text; replace the display with `transcript.partial` snapshots. Live captions require a server that supports partials. This isn't the OpenAI Transcriptions or Realtime protocol.

TTS uses the `/v1/audio/speech` subset with WAV or streamed headerless mono 24 kHz s16le PCM. It doesn't implement full OpenAI format, SSE, speed-control or voice-management parity. The separate local gateway uses Breeze; `--upstream` changes its address and request `model` is ignored. Parakeet/Voxtral ASR adapters likewise constrain backend choices. A different model needs a compatible service or adapter.

Review endpoint authentication and audio retention before connecting. A remote endpoint sends audio off the machine. A cloud TTS URL isn't a verified drop-in replacement: health probes and voice discovery can affect the client even when synthesis itself works.

## Source and development status

The Mac source includes the changes through `e259a757`, including bounded lifecycle diagnostics and reconnect/restart test cases. The iPhone source is based on `7b81fb6a`; its app/bridge/native/shared code matches the later source head `169348bb` before the distribution adaptations. Private configuration, portable build paths, synthetic fixtures and the sparse conversation-store adaptation are retained. See [development notes](docs/DEVELOPMENT.md) for exact source pins and test cautions.

This combined source copy hasn't been compiled or device-tested. Locked/background calling and acknowledgement-aware cut-in remain unverified. Sparse history can leave missing prefixes undisplayed indefinitely; spoken arrivals and displayed history can differ. Native builds, signing, live pairing, calls and full test suites weren't run during preparation.

Don't run the retained `mac_parity_reader.py`/PACKAGE21 path: its process supervision has known static safety risks. Some other tests open sockets or exercise native audio; review them individually before execution. Canvas dependency provisioning and clean-machine builds also remain unverified. Generated apps and browser bundles have [unresolved third-party redistribution obligations](DEPENDENCIES.md).

## License

Original Voicestack source, documentation and the selected original icon PNGs are [MIT licensed](LICENSE). Voicestack retains its independent branding. [RIGHTS.md](RIGHTS.md) defines the artwork scope; [THIRD_PARTY.md](THIRD_PARTY.md) preserves dependency attribution. Models, voices, reference media and generated third-party resources carry their own rights.
