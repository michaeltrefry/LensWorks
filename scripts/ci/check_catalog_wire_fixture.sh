#!/bin/bash
# The catalog's typed service coverage (docs/CATALOG_SERVICE_COVERAGE.json and the Swift DTOs)
# and the adapter's serde wire fixture (adapters/catalog/tests/source_wire.rs) are generated from
# the engine source. This fails when either has fallen behind it, naming how to regenerate.
# The wire fixture's own test only proves the cases it lists decode; it cannot notice a missing one.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/audit-catalog-service-coverage.py --check-swift
generated=$(mktemp)
trap 'rm -f "$generated"' EXIT
# The same formatting as the checked-in file: the adapter crate's edition.
edition=$(sed -n 's/^edition = "\(.*\)"$/\1/p' adapters/catalog/Cargo.toml)
python3 scripts/audit-catalog-service-coverage.py --emit-rust-wire-fixture | rustfmt --edition "$edition" > "$generated"
if ! diff -u adapters/catalog/tests/source_wire.rs "$generated"; then
  echo "::error::adapters/catalog/tests/source_wire.rs is not what its generator emits. Regenerate it: python3 scripts/audit-catalog-service-coverage.py --emit-rust-wire-fixture | rustfmt --edition $edition > adapters/catalog/tests/source_wire.rs"
  exit 1
fi
echo "PASS WIRE FIXTURE: $(grep -c 'check::<' "$generated") typed cases match the generator"
