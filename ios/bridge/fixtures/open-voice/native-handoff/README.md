# Native → production speech handoff fixture

Reuses the accepted actual-engine fixture at
`fv-real-engine-interop-s2oepcny` (see
`lead/2026-10-20-actual-engine-interop-accepted.md`). The copied TLS trust helper
is unchanged. Existing HTTP/control/media setup, bounded child IPC, certificate
recipe and cleanup are retained. The former fake speech sink is replaced by
`createLocalSpeechAdapter` and an actual-shaped synthetic STT WebSocket peer.
No SDK is loaded or addressed; the submit trap must remain unused.

`run.py` stages tracked public core/bridge sources plus this fixture in the new
task-owned `output/native-handoff-3df39493694f/` directory. It reuses existing
`bridge/node_modules` through an owned staging symlink, installs nothing, and
uses the Xcode toolchain with one compiler job and a 110-second process-group
watchdog. Default is synthetic loopback STT only. `--resume` was used once for
the recorded missing-public-resource staging correction. Neither mode
touches the phone, live bridge/SDK or any production store/credential.

The selected test drives ordinary `OpenVoiceRecognition.write` with 134 paced
20-ms, 640-byte mono16k PCM blocks, not a fake Swift socket or a manually flushed
buffered shortcut. The actual owner pump/URLSession, real Node control/media and
real speech adapter perform configuration, exact-owner readiness, input flow,
recognition commit/finalization and cleanup. Activation alone is synthetic.
`OpenVoiceBackend.onMediaClosed` is observed; **Controller, IOSAudio and physical
CallKit/capture are not instantiated**. No response.create or deliberate End is
sent. All invitation/grant/device/store identities are fresh isolated fakes.

Historical authorized `--real-stt` invocation used exactly one segment at
`ws://127.0.0.1:8446/v1/transcribe`, after one idle/ready health observation.
The same tone, native producer, adapter and grammar were used; the peer alone
was changed. Socket observers count only event categories/close code without
intercepting, dropping, changing or retaining any message body. TTS is never
requested. This opt-in is **not standing authorization to repeat service use**.
There is no health-driven fallback, service ensure, credential discovery or retry.

See `docs/OPEN-VOICE-EARLY-STOP-FIX.md`, continuation 3df39493694f, for exact
results and remaining field gap. Passing this case is not pilot acceptance or a
proof that the old iPhone error was fixed. Runtime output/build trees are not
committed. The small fixture is retained for a separately scoped next use,
not to create an ongoing helper/service or expand the test campaign.

Continuation dd87 adds exactly one `--controller` case to this same package.
It stages the existing `Fakes.swift` test helpers verbatim and drives the actual
Controller/NativeVoiceLifecycle rather than directly driving recognition. Only
the grounded synthetic STT mode is selected, regardless of any inherited live
mode flag. Output is isolated in `output/controller-handoff-dd87addea00a/`.
Readiness 0→1, default 1100-ms endpointing, held neutral text, no early close,
explicit owner-close teardown and stale PCM fencing are asserted. No pending
permission race, physical audio or historical route/scene failure is claimed.
The case passed; further offscreen expansion is stopped.

Explicit resumed job d3b3 replaces that controller case with
`testCandidateReadyReplacesLegacyActivityBeforeCaptureOnset`. Current
`--controller` stages into `output/native-gate-d3b3d9549d18/`; `--controller
--resume` preserves its build for red/green checks. It uses actual CaptureIngress
with 48k/100-ms buffers and readiness delivered during start, seeds prior legacy
activity, checks pre-speech Listening/quiet/mute/busy and voiced admission, then
bounded lost-callback failure/review preservation. No real STT mode is selected.
See the d3b3 report section for the demonstrated defect and historical limits.
