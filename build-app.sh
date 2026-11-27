#!/bin/sh
set -eu
cd "$(dirname "$0")"

./build.sh

build_for_arch() {
    arch="$1"
    scratch="build/swiftpm-$arch"
    swift build -c release --triple "$arch-apple-macosx12.0" --scratch-path "$scratch"
    cp "$scratch/out/Products/Release/noSpeakerUI" "build/noSpeakerUI-$arch"
}

build_for_arch arm64
build_for_arch x86_64
lipo -create build/noSpeakerUI-arm64 build/noSpeakerUI-x86_64 -output build/noSpeakerUI

app="build/noSpeakerUI.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp build/noSpeakerUI "$app/Contents/MacOS/noSpeakerUI"
cp nospeaker "$app/Contents/Resources/nospeaker"
mkdir -p "$app/Contents/Resources/midi"
cp Resources/midi/*.mid "$app/Contents/Resources/midi/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>noSpeakerUI</string>
    <key>CFBundleIdentifier</key><string>com.a90.nospeakerui</string>
    <key>CFBundleName</key><string>noSpeakerUI</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.3.0</string>
    <key>CFBundleVersion</key><string>13</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$app"
echo "Built universal app at $app"
