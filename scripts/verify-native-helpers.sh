#!/bin/bash
# Fail before a test host launches, not later as a misleading real-DNG export failure.
set -euo pipefail
[[ $# == 1 ]] || { echo 'usage: verify-native-helpers.sh <built app>' >&2; exit 64; }
app=$1
for helper in PhotoCatalogWorker LensWorksDecodeWorker LensWorksMCP; do
  [[ -x "$app/Contents/Helpers/$helper" ]] || { echo "Missing native helper: $app/Contents/Helpers/$helper" >&2; exit 1; }
  codesign --verify --strict "$app/Contents/Helpers/$helper"
done
codesign --verify --strict --deep "$app"
