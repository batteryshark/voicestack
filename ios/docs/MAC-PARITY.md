# Mac parity reference

The phone keeps independent Swift implementations of voice behavior. Its
comparison fixtures and manifest refer to the Mac core pin
`4c33124f8bf318313e460210ecf55018f648e692`. The Mac's later lifecycle diagnostic
changes don't modify those eight referenced core inputs. The original reference
pin is provenance, not the unified repository's commit selector.

Don't execute the retained `native/mac_parity_reader.py` or PACKAGE21 path.
Its frozen process supervision has known static safety risks described in
[development notes](../../docs/DEVELOPMENT.md#test-safety).

For source inspection, `shared/mac-parity-manifest.json` records the eight
original/packaged paths, SHA256 payload hashes and distribution mappings.
The package-mode reader requires an explicit full unified-repository commit
through `FV_MAC_PARITY_PACKAGE_COMMIT`; working files cannot override committed
inputs. External mode is an explicit comparison against another repository and
doesn't validate the packaged source. Neither mode should be executed with the
retained unsafe reader.

The source comparison's phone-only strips/seams remain unchanged, including
the discard `manualGuard` seam and `diagnosticStart`. The cut-in and long-thought
allowances are retired; `PENDING_MAC_PORT` is empty. This preparation didn't run
parity tests, repin the core inputs or claim native/runtime equivalence.
