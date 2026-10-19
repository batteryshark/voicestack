# iPhone development setup

The iPhone app uses a Mac bridge, separate speech services and its own revocable
OpenChamber desktop client. Configure an independent development deployment with
your own private route, signing identity and credentials. Native builds, signing
and live enrollment haven't been tested for this source copy.

Commands below use `ios` as the working directory unless stated otherwise.
The environment examples are references: fill them privately and explicitly
export the variables needed by each process; the Python generator doesn't load
an env file automatically.

## Bridge and external services

The bridge connects to OpenChamber desktop on the Mac and to separately operated
loopback ASR/TTS services (default ports 8446 and 8444). The bridge binds only
`127.0.0.1` at an explicitly chosen unprivileged port; a separately configured
private HTTPS proxy/tailnet route must preserve `/floating-voice`, streaming
responses and WebSocket upgrades. No DNS, Tailscale, service or proxy config is
activated by these files. A fictitious route shape is
`https://bridge.example.ts.net:9443/floating-voice`; it is not a usable address.

The phone never connects directly to an OpenCode server. Its `/v1` bridge routes,
device credential and target-generation lease are separate from desktop-client
authentication. The bridge requires OpenChamber's `/health` identity,
`/api/system/info` desktop runtime and `/api/client-auth` enrollment; Canvas uses
its guest service API. Shared OpenCode V2 session routes don't make a standalone
server a drop-in backend. See [backend compatibility](../docs/DEVELOPMENT.md#backend-compatibility).

The shipped app replaces configured speech URLs/keys with bridge routes and its
device credential; that credential is not a cloud provider key. The bridge uses
loopback speech ports and does not forward arbitrary provider keys. Cloud speech
therefore needs an operator-managed compatible proxy/adapter or code changes,
not just a provider URL in app settings. Neither app starts or stops speech services.

Keep the [speech contracts](../README.md#speech-contracts-and-model-choices) when
changing models: custom `/v1/transcribe` WebSocket ASR and WAV/streamed mono
24 kHz s16le PCM TTS, not full OpenAI API parity. Use operator-registered local
voice stems or `default`, not an assumed OpenAI catalog. Model changes are
deployment/adapter work, not arbitrary drop-ins. Provider authentication, formats
and data handling need separate review; no cloud calls or automatic fallback are implied.

The optional [local speech reference](../examples/local-speech/) supplies matching
ASR and TTS wrappers for a separately configured loopback deployment.

Setup order:

0. Follow the [renderer recipe](bridge/renderer/README.md) to build and verify
   resources in a **fresh ignored direct child** of owner-owned, non-symlink
   `ios/output`. Keep its explicit absolute `FV_CANVAS_RESOURCES` in the bridge
   environment and every iOS generation/build environment. The bridge serves
   these resources and iOS fetches them; the Mac pill has no renderer consumer
   or gate. Do not default to a developer's existing r5 scratch path. Missing,
   stale or incomplete resources are refused before native configuration writes.
1. Run and configure OpenChamber desktop and speech services separately. Review
   permissions, authentication, endpoint reachability and speech protocol support.
2. Enroll Voicestack's **own** OpenChamber desktop client using a fresh Connection
   link and `bridge/pair_openchamber.py`. Its `redeem` command accepts the link
   privately from stdin/getpass, not command-line arguments; `status` reports
   binding metadata only. Default state is `ios/private/openchamber`, or an
   explicit `FV_OC_CLIENT_DIR` shared with the bridge. Never borrow another
   application's client token. Redemption is one-shot; uncertain results require
    operator review/revocation, not retries.
3. Independently provision a fresh owner-only bridge credential store. The bridge
   CLI exposes `provision PRIVATE_STORE PRIVATE_PAIRING_CONFIG`,
   `serve PRIVATE_STORE PORT`, and `revoke PRIVATE_STORE DEVICE_ID`. Paths must
   be operator-selected ignored private state, not source files. Use a 0700
   directory and 0600 state; do not print/copy bootstrap or bearer values into
   docs, URLs or logs. The store and bootstrap are not shipped.
4. Review `config/bridge.env.example` and supply your own APNs key path, key ID,
   Apple team and topic outside Git. Push is opt-in with `FV_PUSH_ENABLED=1`;
   do not enable it merely to check configuration. Apple keys/profiles are not
   included. Enrollment, token rotation and revocation remain operator actions.
 5. Before starting the bridge, run the **offline**
   preflight with the same `FV_OC_CLIENT_DIR` used by enrollment and the bridge:
   `node bridge/deployment-preflight.mjs`. No arguments or secret values are accepted.
   It requires private `client.json` and `identity.json`, matching Voicestack dedupe
   identity, binding shape, fingerprint and IPv4 loopback enrollment origin with
   an explicit integer port in 1–65535 (zero is refused). It
   does not contact a device/host, verify a live token, or prove server auth enforcement.
   Missing/invalid binding fails closed; fix/review enrollment independently, never
   borrow credentials. CLI `serve` repeats this check before any state or listener.
   Only after authorization, run the bridge in the foreground for development.
   It reads your own desktop port from `~/.config/openchamber/settings.json`
   and, in chief mode, your own `~/.chief-of-staff/chief.json`. It creates private
   diagnostic/push state beside the supplied credential store. The pinned legacy
   absent-binding path is not authenticated enrollment; provision a real own
   client before use. Once paired, removal/rejection fails closed.

## Agent-initiated alerts and calls

Reach-out is an explicit tool action by the configured caller, separate from
automatic assistant-prose playback during active voice. Give that agent authorized
shell/tool access to `bridge/reachout.mjs`; the repository doesn't install an agent
tool or grant permission to use it. The sender connects to the owner-only
`ios/private/push/sender.sock` (0600 inside 0700 directories). It doesn't prompt
a session or expose a public send endpoint.

The bridge's `readChief()` reads the `session` field of the operator's
`~/.chief-of-staff/chief.json`. `PushService.send()` requires the request's
`session` to equal that current ID, checks that the session exists, and checks
an optional `messageID` against its message record. An arbitrary session selected
in the phone UI doesn't acquire caller authority. An explicit target suffices for
ordinary conversation; this reach-out path needs the caller pointer too.

The sender's `send` command takes `--kind`, `--reason`, `--session`, a unique
`--id`, `--title` and `--body`. Allowed intents are `need` (decision/hands/stuck),
`ready-to-try` (install/build), and `urgent-call` (decision/goal-risk). Review
`bridge/reachout.mjs` before granting tool access. Its `--dry-run` validates only
the schema; it doesn't evaluate live delivery policy. Use `status --id ID` after
an uncertain send; don't retry blindly or substitute a new ID.

Push delivery requires `FV_PUSH_ENABLED=1`, APNs credentials, enrolled device
tokens and native notification permission. Urgent calls use APNs VoIP pushes,
PushKit and CallKit; answering resolves the origin and starts that session's
voice loop. The request body supplies reach-out context, not text to synthesize.
Alerts use generic lock-screen text and retrieve context after the user opens them.

Calls need fresh synced settings, calls enabled, a valid time zone, no outstanding
call and a quiet-hours window that covers ringing. Defaults are 22:00–09:00 quiet
hours, 15-minute call spacing, three calls/day and six notifications/hour.
Ineligible calls can become ordinary alerts, subject to token and notification
limits; quiet hours restrict calls, not every alert. The native app rechecks call
policy, and CallKit can reject a call under Do Not Disturb or other OS restrictions.
There is no Focus bypass or Critical Alerts entitlement. The development override
only relaxes spacing/daily/notification caps; it doesn't bypass quiet hours or
outstanding-call safety. Locked/background delivery remains unverified for this
combined source copy. [Development notes](../docs/DEVELOPMENT.md) cover native
cut-in and route limits.

## Optional service/proxy design

A per-user LaunchAgent can invoke an **absolute Node executable**, absolute
`bridge/server.mjs`, `serve`, an absolute private store, and your chosen loopback
port, with an explicit working directory and a minimal reviewed environment.
Keep private logs out of Git. Construct the plist with an XML/plist serializer
so spaces and special characters are escaped. Review restart/KeepAlive behavior,
permissions and teardown before loading it. There is no personal LaunchAgent
plist, bootstrap/load instruction or installer in this snapshot.

For Tailscale Serve, independently map a chosen private HTTPS port/path to that
loopback bridge port. Check the currently installed Tailscale syntax and existing
routes before configuring it; do not overwrite existing routes. Restrict access
with your tailnet policy, retain app credential checks, and never use public
Funnel as a shortcut. No route or service was inspected, changed or tested here.

## Native project and pairing boundaries

Use Xcode with iOS SDK/Icon Composer support, Swift 6 tools and your own signing
team, registered app identifier, development profile and push capabilities.
`native/build.py generate` accepts the environment example and writes local
project metadata plus an ignored Info.plist only. `FV_BRIDGE_URL` defaults empty;
`FV_BUNDLE_ID` defaults to `org.example.voicestack`; the signing team and optional
`FV_DEVICE_UDID` default empty. The Keychain service derives from the configured
bundle ID. These are not values for the live accepted app.

Default generation has `PairingMode=UPDATE` and empty `PairingBootstrap`; it never
discovers a private store. Before generation create the exact `ios/private` directory,
owned by you, mode 0700, without symlink ancestors. The output must not already exist.

For first enrollment, after separately authorized provisioning, select
`FV_BUILD_MODE=ENROLL` and **exactly one** of:

- `FV_PAIRING_BOOTSTRAP_FILE`: absolute path to the provisioner's private JSON
  output, shape `{ "bootstrap": <one-use string> }`. This is **not** the credential
  store (which contains a hash). Require a regular, single-link, owner-owned 0600
  file, at most 64 KiB, no symlink ancestors or `..` path components.
- `FV_PAIRING_BOOTSTRAP_JSON`: the same JSON object injected privately by your
  environment manager, never a literal shell command or CLI secret argument.
  Environment input can be inherited by child tools and exposed by process
  inspection, crash reports or shell tracing; prefer the private file. Do not
  print, trace, export broadly, or persist its value in source/config examples.

The provisioner's base64url token is copied into `PairingBootstrap`, the field the
actual native consumer uses. Unknown/duplicate fields, invalid tokens, ambiguous,
missing and oversized input are refused without displaying values. UPDATE rejects
either selector, even if empty. Validation precedes generation writes. Publication
is atomic, exclusive and 0600; existing files, symlinks and wrong directory modes
are refused. Precreate directories deliberately; no private-state discovery occurs.

**An enrollment-signed app contains a redeemable one-use secret.** Protect the app,
archives, derived data and plist as credentials; do not distribute or attach them.
After enrollment, unset both input selectors, select UPDATE, deliberately retire
the prior private plist outside source control, and generate a new empty UPDATE
plist. No automatic overwrite/cleanup is provided. Pending-proof/recovery in Remote
is unchanged; an uncertain enrollment is not permission to retry/reprovision.
Private/output/build trees are ignored and export-excluded; arbitrary external
private inputs must remain outside source archives. Never use broad directory-copy
archives including ignored files. Generated third-party resources, compiler and
node_modules must not enter Git or source archives. Generate/config validation is not build/install
acceptance, and no enrollment/signing was executed here.

The optional archive recipe uses pre-provisioned signing, does not request
automatic provisioning updates, and requires explicit build opt-in. It has not
been exercised here. No OTA, IPA publication, physical device/simulator install,
proof capture or locked-phone playtest is part of this package.

Once a separate development app is legitimately configured and paired, use its
session picker, call controls, history, sender labels and notification preferences.
Quiet hours and urgent-call rate limits are enforced by bridge policy, not an
OS Focus bypass. Never retry an uncertain reach-out or Canvas submission blindly.
