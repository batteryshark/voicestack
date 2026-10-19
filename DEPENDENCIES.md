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
aren't distributed here. Don't commit them or attach generated apps/bundles to
releases while these obligations remain unresolved:

- Mermaid has 20 unmatched embedded-version notice pairs.
- Patched Fastdom provenance needs resolution.
- ELK has preferred-form Java source and EPL retrieval obligations.
- Tailwind/Chart/D3 embedded-input and notice correspondence isn't fully cleared.

Retaining historical notices doesn't resolve those obligations. The root MIT
license covers owned code/docs and the specified icons, without waiving any
third-party conditions. Models and reference media need their own usable rights.
