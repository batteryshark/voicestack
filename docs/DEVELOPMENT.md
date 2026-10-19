# Development notes

## Source selection

Mac: `4c33124f8bf318313e460210ecf55018f648e692` plus the tracked source delta through `e259a757c4d2a570c574dcf5055419173e4cea5a`. The lifecycle observer bounds new diagnostic records to 120 per explicit voice start, at most one per second. It records software state, not audible-output measurements. The existing distribution's private-configuration and build-path adaptations remain in place.

iPhone: `7b81fb6a48c34b124f1b6d7563c98424f40290b4`; comparison with `169348bb46096fe98e4743ab68e158e9f162b50e` found no later changes under app, bridge, native or shared. Distribution adaptations include explicit enrollment inputs, portable paths, source-built Canvas resources, synthetic fixtures and sparse conversation storage. The apps retain independent Swift implementations.

`AudioLifecycleDiagnosticTests`, `RestartStopTests` and `FirstReplyReconnectTests` are included as test source. The latter two require `macos/scripts/reconnect-fixture.mjs`, a temporary loopback fixture with synthetic desktop/speech responses and a 45-second watchdog. They use native manual-render audio graphs; don't treat them as syntax-only checks. They weren't executed during this preparation. The installed-bundle-specific `reproduce-end-note-ui.mjs` investigation helper is omitted.

## Test safety

Don't run `ios/native/mac_parity_reader.py` or its retained PACKAGE21 path. Static review identified post-reap process-group killing, unbounded waits, child-registration and global-deadline risks. The separate R4 replacement proposal isn't included. No execution of the retained reader is recommended.

Review tests individually: some open sockets, spawn fixture processes or exercise native audio. Whole-suite execution isn't an offline validation command. Seven original source Git modes weren't available; ordinary distribution modes don't reconstruct those modes.

The sparse conversation store can leave a missing prefix undisplayed indefinitely. Narration is per arrival/key and can differ from displayed materialization. Durable gap recovery and exact display/narration correspondence aren't implemented by that adaptation.

## Build evidence limits

This combined distribution hasn't been compiled, signed or exercised on a device. No microphone, simulator, speech server or live desktop session was used during preparation. The phone captures are genuine build 36 UI with approved fictional content; they don't establish that this source copy produces that build or that calls work.

An earlier renderer source build completed on macOS arm64 with Node 26.10.0 and esbuild 0.25.12. Independent inspection corroborated its source/output hashes and selected lifecycle checks, without rebuilding or running browser/native code. Subsequent resource checks had incomplete unsafe-path coverage. These historical results don't validate a new build. The dependency recipe requires exact inputs; clean installation and other hosts remain unverified.
