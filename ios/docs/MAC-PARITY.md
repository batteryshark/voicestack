# Portable committed Mac parity — unshipped adapter candidate

This candidate is not a product export or a new-pair parity result. Its real
`ios/shared/mac-parity-manifest.json` and all eight Mac inputs are deliberately
absent pending adapter approval and separately authorized source preparation.

## Package selection

`FV_MAC_PARITY_MODE` absent means `package`; only `package` and `external` are
accepted. Package mode requires `FV_MAC_PARITY_PACKAGE_COMMIT` to contain exactly
one full lowercase 40-hex **unified repository commit**, not a branch or `HEAD`.
There is no pin/default/checkout/external fallback. The repository is located
relative to the packaged script, independent of caller CWD. Selection is checked
once; subsequent reads use immutable commit/tree/blob IDs.

The manifest and eight Mac blobs must all be committed at that selection. Every
blob is validated before any Mac bytes are returned and the verified map is
cached. Dirty working files/manifest/pin do not override or repair committed
objects. Source paths are closed to the eight consumers, not to all legitimate
Core files. Symlinks, gitlinks, nonregular blobs and non-tree ancestors fail.
Manifest limit: 256 KiB; each source: 4 MiB. Git reads have ten-second deadlines,
bounded stdout/stderr, scrubbed environment and kill/reap cleanup. No fetch,
checkout, filter, index refresh, hook, credential helper or maintenance command.

After separate approval and preparation only, the gate's exact invocation is:

```sh
FV_MAC_PARITY_PACKAGE_COMMIT=<full-reviewed-unified-commit> /usr/bin/python3 -B -E -S ios/native/test_mac_voice_parity.py
```

The placeholder is an instruction, not an accepted SHA. The Swift wrapper's
invocation and assertion are unchanged; it inherits explicit package selection.
Missing configuration fails clearly. Do not run Swift as adapter-only proof.

## Provenance and trust boundary

`shared/mac-parity-ref.txt` remains byte-identical original Mac provenance; it is
not the unified commit selector. The committed schema-1 manifest records the
original Mac4c commit, fixed original/packaged paths, raw Git blob payload SHA256s
and reviewed sanitization mapping for every changed blob. It does **not** contain
its containing unified commit SHA. See the review packet's schema-v1 template.

The runtime verifies packaged hashes and provenance structure. Without original
history it cannot authenticate original hashes or mapping accuracy. The source
owner must validate those against the actual original Mac4c blobs and approve
generic publishable descriptions; private before-strings must never enter the
mapping. A separate owner-review receipt binds approval to the actual final
unified commit and manifest accuracy. Self-consistency is not a security
signature, authentication or independent owner approval.

The production factory always uses Mac4c origin policy. Only the explicit unit
constructor can receive synthetic policy; no environment/manifest toggle or
automatic test detection changes production policy.

## Explicit external diagnostics

`FV_MAC_PARITY_MODE=external` requires an absolute
`FV_MAC_PARITY_EXTERNAL_REPOSITORY` directory. It reads the original
`app/Sources/FloatingVoiceCore/` path. Legacy `reference()` semantics remain:
`FV_MAC_PARITY_REF` overrides the recorded pin; empty override fails; absent
override reads the full original pin. `WORKTREE` explicitly opts into working
bytes. Committed external refs resolve once, with no working fallback. Output
labels external mode **NOT packaged committed proof**. No private path is built in.

Package mode rejects either external variable even if empty; external mode
rejects package-commit configuration. External/WORKTREE results cannot establish
packaged integrity or proposed-pair release parity.

## Current reference

The recorded pin is `4c33124f8bf318313e460210ecf55018f648e692`, the reviewed
Mac long-thought port. The cut-in and long-thought allowances are retired;
`PENDING_MAC_PORT` is empty. Only the existing explicit phone-only strips/seams
remain (for example, `manualGuard = nil` in discard and `diagnosticStart`).
These are not pending Mac-port allowances; do not broaden them.

## Review gates (not execution permission)

1. Independently review this frozen source packet, then obtain explicit finite
   adapter-only execution GO. Run only the named reference test file against
   self-contained synthetic local repositories, never canonical/private fixtures.
2. Send the exact adapter diff and actual synthetic output to the source owner.
   Obtain source-owner review **before staging export or repin**, as required by
   the chief. No test output exists in this phase.
3. Separately authorize actual sanitized proposed-pair preparation and provenance
   mapping review. Create a real committed manifest only from those actual bytes.
4. Obtain the retained 21 gate results against actual Mac8/phone9 candidate bytes
   separately. Phone working-file and mutation seams remain unchanged; this gate
does not assert that phone files are themselves committed release bytes.
5. Bind owner review to the final unified commit; renewed changed inputs require
   renewed review. Publication remains a separate principal approval.

Do not change comparison bodies, normalization, mutation guards, manualGuard
seam, existing platform exceptions, or empty `PENDING_MAC_PORT` to get a pass.
Actual source export, pair repin, native/compiler/runtime/device tests and
renderer work are not authorized by this adapter document.

History: `ad662ca` retired the cut-in allowances; `4c33124` retired the
long-thought allowances and is the current reviewed pin. Do not bump automatically
when the Mac branch advances or introduce replacement normalization.
