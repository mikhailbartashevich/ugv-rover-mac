#!/bin/bash
# Renders Tools/make-icon.swift into Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swiftc -O -parse-as-library -o "$TMP/make-icon" Tools/make-icon.swift 2>/dev/null || swiftc -O -o "$TMP/make-icon" Tools/make-icon.swift
"$TMP/make-icon" "$TMP/icon_1024.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
cp "$TMP/icon_1024.png" Resources/AppIcon.png
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns"
