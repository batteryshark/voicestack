# Dependencies

The Swift packages have no remote package dependencies. Building requires Apple
SDKs; iPhone signing also requires your own team and development profile.
OpenChamber, speech services, models, voices and reference media are separately
operated prerequisites.

## Canvas renderer

The iPhone bridge serves locally generated Canvas resources. The Mac pill has
no Canvas WebView or renderer dependency. Follow the
[renderer recipe](ios/bridge/renderer/README.md) with a fresh ignored
`ios/output` direct child and the same explicit `FV_CANVAS_RESOURCES` for
verification, bridge operation and native generation/build.

Fourteen copied Canvas MIT source files are pinned to
`dc5fd81d0aa0e29a96a4278c61cf4248471e694b`; their
[`CANVAS-LICENSE`](ios/bridge/renderer/CANVAS-LICENSE) is retained.
`source-lock.json` pins the input closure, metadata, compiler and external library
artifacts. The npm lock declares the broader dependency environment. A matching
package version alone doesn't establish matching input bytes. Only darwin-arm64
has an admitted native compiler hash; clean-machine provisioning remains unverified.

The historical `manifest.json` and
[`THIRD_PARTY_NOTICES.md`](ios/bridge/renderer/assets/THIRD_PARTY_NOTICES.md)
are preserved provenance. The notice bundle has 258 package sections. Each new
build produces a separate live resource manifest; consumers verify its outputs
and current source hashes before serving.

## Binary redistribution

Generated JS/CSS, four browser libraries, compiler binaries and `node_modules`
aren't distributed here. Keep them out of this source tree and its source archives.
A generated app or browser bundle carries the licenses of its included dependencies;
the root MIT license doesn't replace those conditions.

For binary distribution, retain corresponding dependency notices and satisfy
source-availability requirements, including ELK's EPL preferred-form Java source
and retrieval conditions. The historical packaging review recorded 20 unmatched
Mermaid embedded-version/notice pairs, patched Fastdom provenance questions and
incomplete Tailwind/Chart/D3 embedded-input/notice correspondence. Reconcile those
records against the exact output being distributed; the historical notice bundle
alone doesn't establish coverage for a new build. These are binary-packaging
review items, not an established license defect in the source release. No binary
distribution clearance is supplied here. Models and reference media need their
own usable rights.
