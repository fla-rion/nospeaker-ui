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
cp "$PWD/Resources/nospeakerCA.crt" "$app/Contents/Resources/nospeakerCA.crt"
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
    <key>CFBundleShortVersionString</key><string>1.9.3</string>
    <key>CFBundleVersion</key><string>193</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - --entitlements noSpeakerUI.entitlements "$app"
echo "Built universal app at $app"

dmg_stage="/tmp/dmg_stage19"
dmg="noSpeakerUI-1.9.0.dmg"
rm -rf "$dmg_stage" "$dmg"
mkdir -p "$dmg_stage"
cp -R "$app" "$dmg_stage/"
cp Resources/nospeakerCA.crt "$dmg_stage/nospeakerCA.crt"
cat > "$dmg_stage/Zertifikat installieren.command" <<'INSTALLER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
security add-trusted-cert -k ~/Library/Keychains/login.keychain-db -r trustRoot "$DIR/nospeakerCA.crt"
echo "Certificate installed successfully!"
read -p "Press Enter to close..."
INSTALLER
chmod +x "$dmg_stage/Zertifikat installieren.command"
hdiutil create -volname "noSpeakerUI 1.9.0" -srcfolder "$dmg_stage" -ov -format UDZO "$dmg"
echo "Built $dmg"
