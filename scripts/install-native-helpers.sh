#!/bin/bash
# Xcode's final app build phase: install and sign nested code BEFORE Xcode seals the app.
# No inference build is needed for real DNG decoding. The optional inference runtime is
# packaged by build-native.sh; every app/test host always gets these three helpers.
set -euo pipefail
[[ $# == 2 ]] || { echo 'usage: install-native-helpers.sh <built app> <Rust release directory>' >&2; exit 64; }
app=$1
release=$2
[[ -d "$app/Contents" ]] || { echo "Not a built app: $app" >&2; exit 1; }
for source in photocatalog lensworks-decode-worker lensworks-mcp; do
  [[ -x "$release/$source" ]] || { echo "Missing native helper: $release/$source" >&2; exit 1; }
done
helpers="$app/Contents/Helpers"
mkdir -p "$helpers"
for pair in photocatalog:PhotoCatalogWorker lensworks-decode-worker:LensWorksDecodeWorker lensworks-mcp:LensWorksMCP; do
  install -m 755 "$release/${pair%%:*}" "$helpers/${pair#*:}"
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$helpers/${pair#*:}"
  codesign --verify --strict "$helpers/${pair#*:}"
done
