# Canvas: personal source builds

The phone bridge serves Canvas from locally built resources. This recipe checks
exact input hashes and produces renderer JS/CSS plus four browser libraries.
Generated dependencies aren't included in this repository.

The owned source uses the root MIT license; copied Canvas source retains
`CANVAS-LICENSE`. Historical `manifest.json` and
`assets/THIRD_PARTY_NOTICES.md` are separate from `source-lock.json` and each
new output manifest. See [dependency obligations](../../../DEPENDENCIES.md)
before redistributing any generated output and
[development notes](../../../docs/DEVELOPMENT.md) for build evidence limits.

## Build prerequisites

Use the exact Node/esbuild/dependency pins in `source-lock.json` and the external
npm lock. No package manager is invoked by `build.mjs`. Supply a separately
provisioned dependency root with `node_modules` at `FV_CANVAS_DEPENDENCIES`.
It must match every hashed input and package metadata byte. A newly resolved or
newer dependency tree is refused. The currently admitted native compiler platform
is darwin-arm64; other platforms need an explicit audited compiler hash in the
lock. This is portable source/configuration, **not** a proved clean-machine or
hermetic cross-platform build. No historical compiler version is claimed.

The npm declaration/lock retains the **broader pinned upstream dependency
environment** (694 package entries); it is not a claim that every declared
package is rendered or every installed root was read. The build actually admits
4,008 renderer inputs, 183 historical roots and six additional library/tool roots,
with the exact installed metadata hashes in `source-lock.json`. Source metadata
may differ across package-manager versions: mismatches must be reviewed, not
silently accepted. The npm version and clean-install reproducibility are unproved.

For a future operator authorized to install dependencies, copy `package.json`
and `package-lock.json` into a separate empty external dependency root, review
the registry URLs/integrities, and run `npm ci --ignore-scripts --no-audit --no-fund`
there. This is a **conditional, unexecuted provisioning instruction**, not a
verified install. Keep optional platform esbuild packages. No lifecycle script
is needed by this recipe; missing platform binaries fail closed. Then use that
root as `FV_CANVAS_DEPENDENCIES`. Do not bypass metadata/input/compiler hash
mismatches or install/upgrade packages from the build recipe itself.

From the repository root, deliberately create an owner-owned non-symlink
`ios/output` directory (mode 0700) if absent. Choose an unused direct-child name
(replace the example below if it exists), then run:

```sh
export FV_CANVAS_RESOURCES="$PWD/ios/output/canvas-personal-01"
FV_CANVAS_DEPENDENCIES=/absolute/reviewed/dependency-root \
  node ios/bridge/renderer/build.mjs
node ios/bridge/renderer/resources.mjs
```

The fallback output is `ios/output/canvas`; it is not guaranteed fresh. Keep the
explicit `FV_CANVAS_RESOURCES` above consistently for build, resource verification,
native generation/packaging and bridge, including separately configured processes.
Never automatically use a developer's r5 scratch path. Every ancestor must already
exist, with no symlinks, raw `.`/`..` or empty
components. Existing output is never overwritten or deleted. Failed builds leave
an explicitly incomplete directory: select a new name, do not reuse it. Manifest
publication is last; consumers reject incomplete, modified or source-stale output.

Build source is reviewed locally before execution. For untrusted dependencies use
an OS network-denying/write-confining sandbox and a <=120s exact-PID watchdog;
the recipe permits only one pinned esbuild service child, no shell/other tools.
No emitted HTML or JavaScript should be run just to validate source packaging.

## Resource contract

The output contains renderer JS/CSS plus full Tailwind browser, Chart.js, D3 and
Mermaid IIFEs. Libraries keep their upstream globals (`Chart`, `d3`, `mermaid`),
and Tailwind's browser stylesheet support. The HTML minimum/intrinsic-height
patch and OpenUI theme exports are hash-recorded guarded transforms, not feature
removal. Static checks are not browser/offline-diagram acceptance.

`canvas-page.mjs` serves only freshly verified resources from ignored output.
iOS native WebKit receives HTML and library source through the existing bridge
message/chunk contract, not a missing Git bundle. Native project/build generation
preflights that same path before configuration writes. The Mac pill has no local
Canvas consumer; its independent build is not gated on unused bridge assets.
No Swift/WebView asset dependency is invented or copied into that app.

## Redistribution

External npm packages can contain compiled artifacts. They are read/copied only
for the operator's personal local build, including `.work` scratch, never into
Git, source archives or release assets; compiler and node_modules stay out too.
Dependency resolution on other hosts, clean installation and native/browser
behavior remain unverified. Don't redistribute the output app or bundles while
Mermaid's embedded-version notice gaps, patched Fastdom provenance and ELK
preferred-source obligations remain unresolved. Keep original notices and Canvas
MIT attribution for the 14 copied source files.
