# Source dependencies and binary gates

**Renderer r5 completed locally:** the existing macOS arm64 Node 26.10.0/esbuild
0.25.12 toolchain built the exact 4,008 inputs plus reviewed metadata, all six
resources and a success manifest published after observed child close. Independent
review corroborated hashes/metafile/transforms/source freshness and passed 16 pure
lifecycle checks, without rebuilding or executing browser/native code. The earlier
`react-remove-scroll-bar/constants` metadata failure remains historical provenance.
Consumer review completed 13 named checks but stopped overall Node 1 on a later
unjournaled raw-path refusal assertion returning normally: complete consumer and
unsafe-path execution coverage remain unresolved, not a proved product defect.
The independent Mac pill has no renderer consumer or gate; bridge serves resources
and iOS fetches them. Use a fresh ignored `ios/output` direct child and the same
explicit `FV_CANVAS_RESOURCES` for build/verification, bridge and iOS, never an
automatically selected developer r5 scratch path.

Canvas is a local source-build dependency, not a distributed prebuilt bundle.
See [the executable build recipe and prerequisites](ios/bridge/renderer/README.md).
The 14 copied Canvas MIT source inputs are pinned to
`dc5fd81d0aa0e29a96a4278c61cf4248471e694b`; `CANVAS-LICENSE` applies to those
inputs, not a new license for Voicestack. Current `source-lock.json` hashes the
actual renderer input closure, external library artifacts, metadata and compiler.
The npm lock declares external dependencies; matching source/input hashes remain
mandatory even after installation. Platform compiler support is conditional on
admitted hashes. A clean-machine/hermetic build has not been established.

The historical `ios/bridge/renderer/manifest.json` is immutable provenance, **not**
the live resource manifest. Its `assets/THIRD_PARTY_NOTICES.md` contains 258 package
sections (not 269); retained notice bytes are not complete future-binary rights.
The new recipe generates renderer JS/CSS and four pinned browser libraries only
under ignored, source-archive-excluded `ios/output`, and publishes a fresh manifest
last. The bridge verifies output and current source hashes before serving. Native
iOS packaging preflights that actual bridge path; iOS still receives HTML/libraries
through its original authenticated bridge transport and credential-free WebKit.
The Mac pill does not have a local Canvas WebView/resource consumer.

**Binary redistribution is parked:** Mermaid has 20 unmatched embedded-version
notice pairs; patched Fastdom provenance and ELK preferred-form Java source and
EPL retrieval obligations remain unresolved. Tailwind/Chart/D3 embedded-input
and notice correspondence is not fully cleared. Personal build artifacts must
not become Git blobs, source archives, release attachments or distributed apps.
No license condition is waived and no original-code license is granted.

Swift packages have no remote package dependencies. Apple SDKs/signing,
OpenChamber, speech services, voices/models and legally usable reference media
are operator prerequisites, not bundled software or newly granted rights.
This is a source-only recipe/pins release form, not a distributable app or
package/release clearance. Native compilation/signing/device/browser/clean-install
behavior, dependency resolution on other hosts, standard scanner clearance,
owned-code license/principal logos and model/reference/third-party binary rights
remain unestablished. Local source-build corroboration is not all-platform or
hermetic build proof. Generated resources, compiler and node_modules remain out
of Git and source archives.
