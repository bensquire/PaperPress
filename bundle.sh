#!/bin/zsh
# Build PaperPress.app from the SwiftPM executable.
#
# Env overrides (used by CI):
#   VERSION           marketing version (default 0.1.0)
#   CODESIGN_IDENTITY signing identity ("-" for ad-hoc; default: local
#                     Developer ID)
set -e
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: BENJAMIN RICHARD SOUIRE (SZHK3JVH6J)}"

swift build -c release -Xswiftc -Osize
APP=PaperPress.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/PaperPress $APP/Contents/MacOS/
strip -rSTx $APP/Contents/MacOS/PaperPress
cp icon/PaperPress.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PaperPress</string>
  <key>CFBundleIdentifier</key><string>com.bensquire.paperpress</string>
  <key>CFBundleExecutable</key><string>PaperPress</string>
  <key>CFBundleIconFile</key><string>PaperPress</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>com.adobe.pdf</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string>
      <key>LSItemContentTypes</key>
      <array><string>public.folder</string></array>
    </dict>
  </array>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict><key>default</key><string>Analyse with PaperPress</string></dict>
      <key>NSMessage</key><string>analyseWithPaperPress</string>
      <key>NSPortName</key><string>PaperPress</string>
      <key>NSSendFileTypes</key>
      <array>
        <string>com.adobe.pdf</string>
        <string>public.folder</string>
      </array>
    </dict>
  </array>
</dict></plist>
EOF
codesign --force --options runtime --timestamp --sign "$IDENTITY" $APP
echo "built and signed $PWD/$APP (v$VERSION)"
