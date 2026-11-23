#!/bin/bash
# Builds the two asset catalogs (phone, watch) from icon.png. Run before xcodegen.
set -eu
cd "$(dirname "$0")"
for t in ios watchos; do
  d="gen/$t/Assets.xcassets/AppIcon.appiconset"; mkdir -p "$d"; cp icon.png "$d/icon.png"
  printf '{"images":[{"filename":"icon.png","idiom":"universal","platform":"%s","size":"1024x1024"}],"info":{"author":"xcode","version":1}}' "$t" > "$d/Contents.json"
  printf '{"info":{"author":"xcode","version":1}}' > "gen/$t/Assets.xcassets/Contents.json"
done
