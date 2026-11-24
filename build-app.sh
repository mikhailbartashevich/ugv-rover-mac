#!/bin/bash
# Builds UGVControl.app next to this script (Command Line Tools are enough, Xcode not required).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=UGVControl.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/UGVControl "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>UGV Control</string>
  <key>CFBundleDisplayName</key><string>UGV Control</string>
  <key>CFBundleIdentifier</key><string>local.ugvcontrol</string>
  <key>CFBundleExecutable</key><string>UGVControl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Controls the UGV rover on your local network</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
