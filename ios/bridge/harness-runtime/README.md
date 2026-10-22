# Private isolated OpenCode host

This project-owned embedding pins `@opencode/sdk` and `@opencode/core` to **2.0.32**. It does not connect to, replace, restart, discover, or import history/authentication from the principal's OpenChamber/OpenCode server. Upstream MIT notices remain in the installed packages; this private package is not published.

## Proven host boundary (not exchange completion)

`createOwnedHost({root})` requires an explicit real, owner-owned 0700 directory and an already isolated process environment: `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`, and `XDG_STATE_HOME` must point to its own 0700 children. It uses **`root/harness.sqlite`**, never the principal's database. Project, global, system and Claude configuration discovery are disabled. Model fetching/snapshot loading, filesystem watching and fff are disabled. Durable native event persistence is enabled for future exact reconciliation.

The private exact-version `sdk/dist/internal/host.js` entrypoint exposes the owning runtime and idempotent close lifecycle. Ordinary SDK options do not expose `global:false`/`system:false`; the exported `Config.node.replace(Config.configured(...))` embedding override supplies those isolation settings. The public Promise `OpenCode.create` wrapper in this version does not forward the second `EmbedOptions` argument. Do not silently remove the override or substitute a default host.

Returned `host` is an **internal privileged owner handle**, not a caller API. `close()` joins SDK request cancellation/draining and runtime disposal; `stats().closed` becomes true only after disposal settles. The SDK's automatic orphan-session resumption is explicitly disabled: restart never authorizes at-least-once tool reexecution. No provider is initialized or authenticated, and no sign-in is requested at this checkpoint.

## Focused fixture

Do not run the commands below against a dependency graph shared by a live process.
Use a disposable staged source/dependency copy; this project's current root graph
is shared by the preserved live own SDK. No test requires a download or install.

```sh
node bridge/harness-runtime/patch-runtime.mjs
node --test --test-concurrency=1 --test-timeout=35000 bridge/harness-client.test.mjs bridge/harness-runtime/owned-host.test.mjs
```

The lifecycle fixture uses an owned disposable child with a credential-free environment, explicit SQLite file and a 30-second exact-child watchdog. Network requests, socket connection/listen and child creation are actively denied/countable. The actual host creates its database and closes with **zero attempted network/listener/child actions**. Additional fixtures use the published `@opencode/ai/testing` TestLLM layer with the real SDK agent runner, tool executor, coordinator and Job registry. Metadata HTTP is resolved only by an explicit in-memory fixture layer; no real provider is contacted. Actual foreground tool execution and background Job completion/notification/resumed final assistant are proven separately from mere host startup. Competing real admitted input, ambiguous candidate, lost admission receipt, and restart/read-only/no-resubmit cases are covered. The ambiguous-candidate negative injects a conflicting private callback while a real background Job is pending; it is not a positive causal proof. All fixture children exit and owned scratch/SQLite/WAL files are removed.

## Dependency cost

The first public-registry install used empty owned HOME/npm configuration, scripts disabled, optional packages omitted, no audit/fund, and a 180-second watchdog. It completed in **18.60 seconds**, adding **376 packages** with **301,654,132 regular-file bytes** installed (about 302 MB decimal). The earlier approximately 95 MB figure was a partial unpacked **lower bound**, not a full-graph estimate. Lead accepted the measured installed cost. The removed temporary npm cache was **401,840,870 bytes**, including metadata; this is **not measured network transfer**. No native build or install script was run. The dependency tree is ignored; package manifest/lock are tracked.

## Actual private completion and IPC contract

`bridge/harness-client.mjs` exports `await startHarness({root})`. It forks only the fixed owned `child.mjs`; SDK imports and empty HOME/XDG live **only in that child**, never in the bridge process. The owner supplies an existing canonical 0700 root. An exclusive lock inode prevents concurrent hosts; close waits for the exact child and all IPC settlement, with bounded TERM/KILL escalation. There is no HTTP/Unix listener, separate daemon, principal token, inherited provider environment or service registration. Four pending IPC slots and 131072-byte JSON messages are bounded. A caller wait timeout retains its slot until the actual response/child exit and never retries or cancels admitted work.

Methods (private owner/bootstrap use, not public caller routes):

- `prepare({directory,agent,model:{providerID,id,variant}})` creates one actual empty exclusive single-use target. Returns `{instance_id,runtime_version,target_session,authority,pins}`. Model variant must be explicit; `auto` is refused. No call ID is required yet. One target/operation per runtime record; never auto-reprepare/recycle after use/failure.
- `advanceUnused({binding,pins})` is the internal half of the owner-only `advance-unused-target` command described below. It is **not** a general prepare reset: each exact provably empty, never-submitted, terminal-claimed target may be retired once, with its entire old record and prior `retired_unused` chain retained inside the same `exchange.json`. The original SDK sessions and own account DB are untouched. The new session/authority and old snapshot are bounded/atomically persisted before actual session creation. Ordinary `prepare`, old-binding verification and admission stay single-use.
- `verify({binding})` validates actual target pins and seals the full stable private binding. Returns `{instance_id,runtime_version,target_session,authority,pins,exclusive:true,single_use:true,single_use_available,continuation}`. First verification still requires the unused prepared target. Once sealed, **the exact same twelve-field binding** can be verified read-only during dispatch/admission/completion for the current operation; `continuation:true,single_use_available:false` is provenance, not a new-admission/idle claim. Changed bindings, uncertainty, competing input, gaps, poisoned/unknown accounting and changed pins/authority are refused. No new binding can be sealed after an operation exists. The binding has exactly the control mapping's ten fields (`caller_id,project_id,target_session,directory,binding_revision,expires_at,principal_id,audience,device_id,target_id`) plus `authority,pins` from actual preparation. Clone it **before** mapping-only `claimed_call_id`; no call/lease/epoch fields belong in the binding. Authority and pins must match the actual prepared record.
- `submit({call_id,binding,operation_id,planned_inbox_id,item})` requires that exact sealed binding and the explicit canonical user item. The operation is persisted/fsynced before the one prompt attempt; no uncertain retry. Successful output is still exactly `{admission_inbox_id,source_user_id,source_assistant_id,text}`. In this pinned core, inbox/user IDs really are equal. The final assistant is the actual distinct runner candidate, not a scan/text/time match.
- `read({call_id,operation_id})` is read-only reconciliation: `{status,reason?,target_session,operation_id,admission_inbox_id?,source_user_id?,result?}`. Unknown/wrong operation is refused. Completed results survive reopen. An unfinished record on restart remains uncertain; it does not resume work or resubmit input.
- `capability()` returns actual `{instance_id,runtime_version,target_session?,authority?,pins?,modelAvailable,agentAvailable,providerConnected,bindingVerified,singleUseAvailable,ready,providerAcceptance,reason}`. **Before preparation**, `capability({pins:{directory,agent,model:{providerID,id,variant}}})` validates those exact owner pins and evaluates the real Location registry/integration metadata without creating a target/operation or `exchange.json`. Pre-prepare bootstrap checks the individual model/agent/provider/outbound fields, not composite `ready` or binding/target fields. Supplied pins after preparation must match the actual prepared pins. No-argument post-prepare behavior is unchanged. Instance identity is a persisted random UUID in the owned `instance-id` file, not a caller-selected remote authority name or secret. Registry checks await real plugin activation, check exact provider/model/variant + tool/text support + primary agent, and use normal own-integration connection **metadata** without resolving/exporting a credential. Configured connection metadata is not provider execution proof: `providerAcceptance` remains `not_proven` pending signed real use. Composite readiness is for **new admission**, never revocation of already-admitted work merely because its single-use slot was consumed.
- `stats()` is local `{childAlive,pendingRequests,localWorkKnown,localWorkPending,localWorkRevision}`; `runtimeStats()` queries actual `{closed,targets,operations,pendingRequests,localWorkKnown,localWorkPending,localWorkRevision}`. The local-work revision is monotonic for this owned child; a new child starts with unknown cached facts until its first actual query. The asynchronous query checks actual own-host active executions, tracked Jobs (including real settlement after uncertainty), pending background notification markers and target/descendant inboxes. State/ownership changes during the query, gaps, missing running Jobs, poisoned storage or failed reads mean **unknown/busy**, never zero. It is a bridge-local agent/tool-work fact, not proof of a provider's final reply. A deadline may leave operation status uncertain and `pendingRequests:0` while `localWorkPending:true`; it clears only after actual local work settles. Historical response uncertainty alone does not force busy when those actual facts show no local future work. Normal owner sign-in attempt progress remains separately available via `signInStatus()`.
- Parent cached work becomes positive/unknown before submit and stays so until an actual query reconciles it. Older pre-submit zero snapshots cannot overwrite a newer pending generation. Maintenance must treat unknown as blocking and include `localWorkPending`, not merely IPC request count. Both parent and child **refuse normal close while local work is busy/unknown**; a refusal does not escalate to a kill. After successful safe close, the parent joins the exact child, with bounded TERM/KILL escalation only for already-acknowledged teardown (or failed startup before any admitted work). If parent IPC disappears, the child drains actual agent/tool work before disposing the SDK rather than canceling admitted work because transport was lost. **Narration cancel/disconnect must not call close**; submit has no abort signal.

The production child has an explicit **pre-provider-initialization outbound fence**. Startup is always closed, including when this own DB already contains OAuth. Before observed normal completion or explicit validated owner reconciliation it returns `outboundEnabled:false,ready:false` and refuses submit. Owner preflight/prepare/verify/admin/read operations remain usable. TestLLM cannot arm production. Do not interpret IPC startup, methods, source fixture success or registry presence as call readiness.

### One-shot unused pilot retirement

Only the existing private owner socket accepts `advance-unused-target`. Its `value`
has exactly `target_id,target_session,binding_revision,next_binding_revision,expires_at`.
The first three compare-and-swap the **current old mapping**; the next revision must
increase and expiry must be future (at most one day). Pins and the exact old twelve-field
binding come from the configured owner mapping, not caller input. An expired old seal
can be compared structurally for retirement; it is never made current/reusable again.

The owner must already be validly **held, sealed and actually locally quiet**. Bootstrap
then counts the transition as owner work, retains the existing maintenance transition
fence, and uses `push.serial`. Private issue/configure/prepare/advance/provider mutations
and maintenance release are refused while it runs. All effective caller/project
`call:request` grants must be revoked/expired, all old-target calls terminal with no
lease/media/exchange operation, and no resolver/end-note/media work may remain. Control
operations must be empty, except one exact four-field `kind:'end',state:'prepared'`
entry matching `end_operation` on an ended call, with normal UUID/hash and no extra
fields. This exception requires zero pending End notes and either no hook or the exact
trusted normal-assembly hook with an ABSENT future-call policy marker: it recognizes
never-dispatched old local intent, preserving it verbatim. Arbitrary hooks, future-call
markers, other/malformed operations and dispatching/uncertain/completed End entries refuse.
The active mapping must be claimed by an exactly matching terminal call, OR its exact
old seal must be absolutely expired with the claim property absent. The latter permits
no related call (by session, target ID or authority), no pending End note, and no effective
caller/project grant of either scope. Live unclaimed, malformed claims and any related
old call/operation cannot take this alternative. Expiry, mapping CAS and held/sealed
owner facts are rechecked across awaits; expiry never renews old authority.
No grant, ring or listener release is performed by this command.

**Future deliberate End (source-only):** bootstrap installs a closure-identity policy
marking only newly created calls. Only those calls append one bound System `[voice]
ended` note with typed `historyOnly:true`; model conversion excludes it. A separate
terminal-End verifier checks exact seal/mapping/claim, grant, epoch and End operation
before dispatch, without admission/media authority or requiring submitted jobs idle.
No old call is marked, scanned, replayed or backfilled. Crash/transport/revocation
produce no note.

Private `appendEnd` IPC validates the exact binding/call and fixed payload, persists
dispatching + deterministic full-binding/call/epoch/End event ID before publishing
`session.voice.ended` through normal Bus/projector. It never admits Inbox work,
applies instruction changes, resumes/cancels execution, or speaks. Completed receipts
dedupe read-only; dispatched/uncertain records refuse mutation even on reopen. The
existing bounded exchange record holds the single note receipt, not a new ledger.
Parent/child accounting includes append; causal Job accounting stays active. A note
makes the target nonempty and **ineligible for unused retirement or submission**.
Post-note target lifecycle is outside this seam. Verification uses independent copied
dependencies, never the root graph shared by the live SDK; see
`docs/OPEN-VOICE-END-NOTE.md` for evidence. No source activation is implied.

The child refuses an operation/result/candidate, recorded Job/descendant, poison/gap,
foreign input or other uncertainty. Restart-only `process_restarted` uncertainty is
allowed **only** with the exact retained seal and actual unchanged pins, no canonical
user/assistant/synthetic/shell context, empty inbox, no active SDK sessions/Jobs or
pending notifications, known accounting and unchanged work revision across queries.
Later non-restart uncertainty blocks retirement even if the first reason was restart.
Preparatory work is counted in normal `runtimeStats`; only the command's own internal
quiet query excludes that administrative reservation. Zero IPC requests are not quiet.

There is no new file, path rotation, allocator or history journal. The deep-copied old
record remains verbatim under `retired_unused`, including its seal/authority/restart
evidence, within the existing 131072-byte bound; oversize is refused before allocation,
never truncated or deleted. A later distinct terminal-claimed unused target can advance,
retaining every earlier snapshot, until the bounded record no longer fits. Single-attempt
is **per exact old binding**: after fresh intent is saved, old CAS cannot allocate again;
an incomplete fresh seal/mapping stays fail-closed. CLI ring never prepares or advances.
Fresh identity + snapshot are saved before native allocation and new-target tracking
is established before the native `session.created` event. Partial creation/mapping,
crash or a lost reply never authorizes another allocation or retry. Failure leaves
candidate admission unarmed; ordinary legacy voice/history remains independent.

Only after fresh SDK preparation succeeds does bootstrap use the existing strict
new-revision/new-session/new-target-id mapping, new seal, verify and capability path.
Old call bindings, claimed-call history, epochs, grant revocations, old native session,
saved account and instance identity are preserved. Source activation requires a normal
quiet own-runtime reopen; reopening itself does not free a slot or create a target.
Use normal saved-account reconciliation, not sign-in, and metadata `providerSetup`
for old-state preflight (old uncertain `capability` deliberately stays fenced).
See the [lead-only future allocation sequence](../../docs/OPEN-VOICE-QUIET-ROLLOUT.md#one-shot-unused-target-advance-lead-only).

## Normal own-provider initialization (no flow invoked by startup)

The production child loads only the **already-installed bundled model catalog**, with remote catalog fetching still disabled. It never reads principal configuration, history, provider environment, or a principal DB. Normal provider credentials belong exclusively to the child's explicit own SQLite DB.

Four private owner IPC methods are implemented (not caller/public routes):

- `providerSetup({pins})` works before target allocation. It returns `{instance_id,pins,providerID,integrationID,methods:[{id,type,label}],providerConnected,modelAvailable,agentAvailable,outboundEnabled,providerAcceptance:'not_proven'}` from the actual own SDK registry. It does not enable outbound. This slice supports only the source-verified native V2 OpenAI `chatgpt-headless` sign-in method. Other methods are not guessed or invoked. There is no API-key, command, external-credential or copied-token import path. Connection IDs, labels, credentials, headers and record bodies are not exposed.
- `beginSignIn({pins})` explicitly starts **one** normal `Integration.oauth.connect({integrationID:'openai',methodID:'chatgpt-headless'})` attempt. It returns the SDK's `{attemptID,url,instructions,mode,time}` plus `instance_id`, privately to the owner. The principal's one hands step is the native device authorization page/code; no credential material is returned. A lost reply does not authorize a second attempt. This method is never called automatically by preflight, prepare, ring or startup.
- `signInStatus()` reads this process's safe receipt cache, not the currently selected provider or a newly created attempt. Native `Integration.oauth.status` deletes terminal attempts after 60–90 seconds, even before the advertised authorization expiry; absence is not failure or success. Immediately after the one connect, a finite internal observer captures **that Integration service + integration ID + attempt ID**, observes normal native status (one-second interval), and retains terminal `{status,time}` in memory past native pruning. Native `failed` messages are not exported. Existing native `integration.updated` events do not carry attempt settlement, so this is one bounded observer job, not a service/watcher or an agent polling campaign. It ends at a terminal native result, missing receipt, error, or at most 10m35s (also bounded by native expiry +35s). Each query is bounded to five seconds; deadline/error cleanup uses normal cancellation of only that attempt and one final status check (at most ten additional seconds). Missing/error/deadline returns `status:'receipt_unavailable'` plus a safe reason, never guessed pending/failed/expired/complete. Only a real native expired result is `expired`. Unknown cleanup remains unknown/busy for maintenance; no retry/new flow is implied.
- `reconcileProvider({pins})` explicitly rechecks the **same own SDK's normal saved-connection metadata**, including after a normal reopen of its unchanged own DB. It is refused during auth work, or with unknown accounting, changed owner pins, or an existing operation. It first closes the outbound fence, then requires provider/integration `openai`, the active saved connection of type `credential`/method `oauth` with no `needs_auth` or other status, actual Codex endpoint `https://chatgpt.com/backend-api/codex`, exact enabled tool/text model/variant and primary agent. Only all-valid metadata enables provider phase. It returns the setup projection plus `{reconciled,receipt}`. Missing/invalid metadata leaves `reconciled:false,outboundEnabled:false`; invalid pins are refused and leave idle revalidation closed. No HTTP request, login, target or prompt is part of this command. The SDK's normal service reads its own saved connection; the wrapper never resolves/exports credential contents. This establishes **configured, not executed**. After reopen, `receipt:'receipt_unavailable'` remains truthful; reconciliation does not manufacture historical attempt success. Acceptance remains `providerAcceptance:'not_proven'` until separately authorized real tool use.

The observer/start/cleanup is actual local work in `runtimeStats()` with monotonic revision and wakeups. Parent cached work is positive/unknown before begin; pending/unknown auth blocks maintenance seal and normal close, including after the begin RPC settles. Normal close refuses rather than canceling pending authorization. IPC loss drains it through terminal/expiry/cleanup. The cache has no journal and is deliberately not recovered across processes. A fresh process reports `receipt_unavailable` even if saved connection metadata is valid. Startup never auto-reconciles or calls begin. An observed native `complete` can enable outbound without another owner status poll; terminal failure/expiry/unavailable closes it. Explicit reconciliation cannot interrupt a still-running auth observer.

During sign-in, the fetch fence permits only `https://auth.openai.com`; no model prompt is sent. A callback server is always prohibited. The inspected V2 `chatgpt-browser` method binds localhost 1455/1457 and is deliberately not offered; native `chatgpt-headless` uses device authorization with no listener. Actual source: `@opencode/core@2.0.32/dist/chunks/instance-zdhmwdxf.js:125–166`; attempt retention/status: `instance-6vzwhms5.js:112–114,233–278,322–343,549–558`. Full normal outbound/tool capability follows observed completion or explicit validated own-connection reconciliation, not a foreground-only agent profile. Narration loss never closes/cancels that host or an admitted exchange.

The synthetic provider fixture uses the real SDK OAuth attempt, scoped callback, own credential persistence, registry refresh, same-own-DB reopen and status lifecycle with known **non-authoritative synthetic** credentials. It proves plumbing, not successful OpenAI authorization. It allocates no target, exports no credential and performs no network access. Missing native attempt, needs-auth, wrong provider/endpoint/model/agent and changed pins fail closed. A small observer fixture simulates native terminal-map pruning without a real-time 90-second wait and checks expiry distinction, bounded cleanup and unknown accounting. Owner bootstrap exposes `provider-setup`, `begin-sign-in`, `sign-in-status` and `reconcile-provider` only on the existing owner-only admin socket, with configured pins (no caller override). No new public route is added.

For recovery, use the [lead-only quiet procedure](../../docs/OPEN-VOICE-QUIET-ROLLOUT.md#own-provider-receipt-recovery-lead-only), not another begin attempt. This source slice performed no live status query, sign-in, close/restart, target/grant/prompt or provider acceptance. The separately approved narrow quiet reopen exception is lead-owned and only follows review/normal quiet gating; it does not authorize principal/shared-service restart or credential/DB copying.

## Real hook boundary and limits

`patch-runtime.mjs` makes exact-anchor, idempotent changes in six owned **2.0.32** core chunks and two schema files. See `UPSTREAM-NOTICE.md` for MIT attribution. Completion hooks record the real `Completed(needsContinuation:false)` assistant ID after tool/retry handling, actual Job transitions and coordinator settlement **after active ownership removal**. A committed Bus listener observes actual input delivery and contiguous durable session sequence. Candidate selection is invalidated on input/steps/wakes, not by a history-only End note. Actual Job/notification/descendant/execution state, empty inbox, pins and revision must all agree before final assistant persistence. A Job settling before its notification/parent continuation is not finality. Only final assistant text is selected.

One bounded `exchange.json` (131072 bytes maximum), with at most 128 tracked descendants/jobs, is fsynced with atomic rename and directory fsync. Store failure poisons execution; gaps, external competing input, ambiguous candidate, authority/pin changes, unsuccessful root termination or deadline leave uncertainty. No exactly-once guarantee is claimed. The SDK is exact-version patched; a different core distribution requires explicit review, not approximate patch matching. No principal installed runtime binary is claimed equivalent.

Remaining gates for receipt recovery: reviewed source activation by the lead under the normal quiet gate, then explicit metadata-only owner reconciliation. This does not require a renewed sign-in and does not prove provider execution. Any real tool exchange remains separately authorized. Public media wire, speech services, native/device/build/install, principal runtime and protected configuration remain unchanged.
