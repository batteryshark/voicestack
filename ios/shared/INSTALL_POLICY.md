# Operator install-link policy (nonsecret)

Neither a hostname nor membership in `.ts.net` proves ownership. Empty policy
denies all install links. No private deployment name or manifests are supplied.

Configure the **same** nonsecret values for bridge startup and native generation:

```sh
export FV_INSTALL_DEPLOYMENT_SUFFIX=''
export FV_APPROVED_INSTALL_MANIFESTS='[]'
```

The suffix must be a lowercase dotted DNS suffix strictly beneath `.ts.net`,
with no trailing dot (for example, the synthetic `.demo.ts.net`). A configured
suffix permits only hosts inside it, not its bare domain. A nonempty JSON string
array of exact raw HTTPS manifest URLs further narrows that scope. It cannot
bypass the suffix. An invalid configured suffix denies, even with an exact list.
Without a suffix, only a nonempty exact raw manifest list can permit a structured
`.ts.net` endpoint. Raw spelling matters, including case and a trailing dot;
normalized host checks do not normalize allowlist entries. Ports, paths and
queries remain permitted subject to the existing structured URL guards.

## Strict spelling contract

Before URL-library normalization, both implementations require nonempty ASCII
URI spelling using only letters, digits and `._~:/?@!$&'()*+,;=%-`, with every
percent sign followed by two hexadecimal digits. This applies to the entire
wrapper and again to its once-percent-decoded manifest value. Literal spaces,
controls (including DEL), Unicode, backslashes, fragments and other punctuation
are deliberately rejected, not trimmed or repaired. Use percent encoding for
non-ASCII path/query bytes. Query components decode once as UTF-8; plus stays
literal. Exactly two fields are required: action=download-manifest and url.

The manifest authority is ASCII DNS spelling with an optional decimal port of
**one to five digits**, numeric value 0–65535. Omitted ports retain HTTPS default
semantics; explicit 443, 0, 65535 and leading zeros within five digits are valid.
Longer spellings (even redundant zeros) deliberately deny rather than depend on
Foundation/WHATWG overflow or implicit-default behavior. Existing case/trailing-dot
host handling and exact raw allowlist comparisons are unchanged. No URL-library
repair can authorize a raw string outside this grammar. Native URL callers use
the same validator on absoluteString; raw-string callers can validate before URL
construction with LinkPolicy.install(String).

Bridge `CONFIG` consumes those environment settings; native `build.py configure`
writes `InstallDeploymentSuffix` and `ApprovedInstallManifests` into the generated
private Info.plist. Native navigation/confirmation/push review paths use
`phoneLinkPolicy`, which reads those keys. Malformed typed config fails closed.
Do not put credentials or redeemable tokens in these nonsecret settings.

`install-policy-fixtures.json` is the single mirrored positive/negative table
read by JavaScript and Swift tests. The pure Node policy test requires no server.
These checks are not first-enrollment, renderer, native-app or release clearance.
