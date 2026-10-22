# Development notes

## Backend compatibility

The supported setup is OpenChamber desktop backed by OpenCode. The two native
clients share session concepts, but use different transports:

- Mac `OpenChamberClient.connect()` chooses `FV_OPENCHAMBER_URL`, then
  `OPENCHAMBER_PORT`, then `desktopLocalPort` from settings under
  `OPENCHAMBER_DATA_DIR` or `~/.config/openchamber`. It requires
  `GET /api/system/info` with `runtime: "desktop"`. That request has no Bearer
  header; subsequent requests use `OPENCHAMBER_BEARER` when supplied. The Mac app
  doesn't implement desktop-client enrollment. An auth-protected identity
  endpoint needs client changes; supplying a Bearer variable alone won't fix it.
- The iPhone connects to HTTPS `/floating-voice` on its Mac bridge, using its own
  device Bearer credential and target-generation header. The bridge discovers
  OpenChamber's loopback port, verifies `/health` with `openchamberVersion`, uses
  its enrolled desktop-client token, and requires the same desktop runtime check.
  Enrollment uses `/api/client-auth/pairing/redeem`. Canvas also needs the
  OpenChamber guest service route `/api/guests/agent-canvas/service/request`.

Session traffic uses `GET /api/session`, `/api/session/active`, session detail,
`GET /api/event`, `POST /api/session/{id}/prompt` with `text`, optional
`delivery: "queue"|"steer"` and `resume: false` for silent admission, and
`POST /api/session/{id}/interrupt?resume=false`. Clients expect `data` response
envelopes, prompt receipt `data.id`, `interrupted`, and event JSON with
`type`, `data.sessionID`, text deltas and block ordinals. Phone history additionally
uses paginated `/api/session/{id}/message` and individual message records.

The current official [OpenCode V2 API](https://opencode.ai/v2/docs/api) and
[OpenAPI contract](https://opencode.ai/v2/openapi.json) expose these session routes
and matching prompt/interrupt fields. Its server identity is `/api/info`, and its
pairing routes are `/api/pair` and `/auth/connect/{code}`. The
[V2 client guide](https://opencode.ai/v2/docs/build/client) documents explicit
authentication headers and local service discovery/authentication; neither
Voicestack transport uses that discovery flow. The contract doesn't advertise
OpenChamber's desktop identity, client-auth or guest Canvas routes. The published
event schema is a JSON-encoded string, so the route alone doesn't establish every
event payload detail. A direct OpenCode adapter looks feasible for basic session
conversation, but requires discovery/auth changes and event validation; phone
Canvas needs its own replacement integration. No direct-server interoperability
was demonstrated. Changing a URL alone doesn't remove these requirements.

## Conversation behavior

Both controllers send utterance PCM to the custom ASR WebSocket while recording.
Partial transcripts update captions when the service supplies them; committed
words and silence determine turn submission. Manual mode holds words for Send.
The default busy delivery is Queue; select Steer to send into a running turn.

Assistant text events are cleaned and segmented into sentences automatically.
Fenced blocks and images are omitted from speech; links keep their labels.
Reasoning and tool-result events aren't a speech source. The phone reconciles
live narration with its conversation store; ordinary history loads silently.
There is no tool-selected speech endpoint in either client. Agent instructions
can shape audible prose versus fenced reading material, but exclusive explicit
speech selection would need code changes. Reach-out tools choose the call
intent and context, not a TTS utterance.

Voicestack's sender is calls-only. Messages and notifications use Nod. Chief
calls have a pickup greeting, an optional local hold-music asset and an explicit
hold-music switch. Quiet hours, Calls settings, Focus and outstanding-call safety
remain enforced; ordinary calls no longer have daily/spacing caps or fallback alerts.

`ttsStream` defaults false (whole-sentence WAV). With it enabled, compatible
services provide raw PCM chunks that play as they arrive. This is streamed ASR,
session text and TTS, not an OpenAI Realtime session or an end-to-end latency
guarantee.

Mac capture continues during playback only with `duplex` enabled and an echo-safe
input/output arrangement. The iPhone trusts the receiver; external routes need an
actual non-built-in microphone. Its built-in speaker suppresses recognition during
playback and the configured quiet tail. Tap to cut in silences narration and
reopens listening after a short guard; words wholly inside that guard can be lost.
Both cores include acknowledgement-aware duck/pause/restore decisions on safe
routes. `bargeInAborts` defaults false: stopping speech doesn't cancel execution.
Explicit reply interruption does. Native acknowledgement-aware cut-in, route
changes and locked/background calls remain unverified in this combined copy.

For comparison, OpenChamber's upstream voice documentation and
`packages/ui/src/lib/voice/browserVoiceService.ts` at
[`bf977d2`](https://github.com/openchamber/openchamber/tree/bf977d2ed89c079ec592210d7cd0e2d649ba0636)
describe dictation, several playback/recognition backends and conversation-mode
auto-resume after speech. The dedicated-client rationale is native controls and
the bridge reach-out workflow; it doesn't establish missing call or interruption
features in OpenChamber.

## Source selection

Mac: `4c33124f8bf318313e460210ecf55018f648e692` plus the tracked source delta through `e259a757c4d2a570c574dcf5055419173e4cea5a`. The lifecycle observer bounds new diagnostic records to 120 per explicit voice start, at most one per second. It records software state, not audible-output measurements. The existing distribution's private-configuration and build-path adaptations remain in place.

iPhone: `7b81fb6a48c34b124f1b6d7563c98424f40290b4`; comparison with `169348bb46096fe98e4743ab68e158e9f162b50e` found no later changes under app, bridge, native or shared. Distribution adaptations include explicit enrollment inputs, portable paths, source-built Canvas resources, synthetic fixtures and sparse conversation storage. The apps retain independent Swift implementations.

`AudioLifecycleDiagnosticTests`, `RestartStopTests` and `FirstReplyReconnectTests` are included as test source. The latter two require `macos/scripts/reconnect-fixture.mjs`, a temporary loopback fixture with synthetic desktop/speech responses and a 45-second watchdog. They use native manual-render audio graphs; don't treat them as syntax-only checks. They weren't executed during this preparation. The installed-bundle-specific `reproduce-end-note-ui.mjs` investigation helper is omitted.

## Test safety

The optional [local speech reference](../examples/local-speech/#offline-checks)
has a focused stdlib fixture command that doesn't start servers or load models.
Its inference dependencies are separate from the apps and bridge.

Don't run `ios/native/mac_parity_reader.py` or its retained PACKAGE21 path. Static review identified post-reap process-group killing, unbounded waits, child-registration and global-deadline risks. The separate R4 replacement proposal isn't included. No execution of the retained reader is recommended.

Review tests individually: some open sockets, spawn fixture processes or exercise native audio. Whole-suite execution isn't an offline validation command. Seven original source Git modes weren't available; ordinary distribution modes don't reconstruct those modes.

The sparse conversation store can leave a missing prefix undisplayed indefinitely. Narration is per arrival/key and can differ from displayed materialization. Durable gap recovery and exact display/narration correspondence aren't implemented by that adaptation.

## Build evidence limits

This combined distribution hasn't been compiled, signed or exercised on a device. Native builds, full test suites, live pairing and calls weren't run during preparation. No microphone, simulator, speech server or live desktop session was used. The phone captures are genuine build 36 UI with approved fictional content; they don't establish that this source copy produces that build or that calls work. The Mac screenshot has no visible build label.

An earlier renderer source build completed on macOS arm64 with Node 26.10.0 and esbuild 0.25.12. Independent inspection corroborated its source/output hashes and selected lifecycle checks, without rebuilding or running browser/native code. Subsequent resource checks had incomplete unsafe-path coverage. These historical results don't validate a new build. The dependency recipe requires exact inputs; clean installation and other hosts remain unverified.
