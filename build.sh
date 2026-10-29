#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

out=build
app="$out/Niche.app"
rm -rf "$out"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp vendor/mediaremote-adapter/mediaremote-adapter.pl "$app/Contents/Resources/"
cp -R idle "$app/Contents/Resources/"
framework="$app/Contents/Resources/MediaRemoteAdapter.framework"
cp -R vendor/mediaremote-adapter/MediaRemoteAdapter.framework "$app/Contents/Resources/"
lipo -thin arm64e -output "$framework/Versions/A/MediaRemoteAdapter" vendor/mediaremote-adapter/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter
strip -x "$framework/Versions/A/MediaRemoteAdapter" 2>/dev/null
sign_identity="${CODE_SIGN_IDENTITY:-}"
if [ -z "$sign_identity" ]; then
    if security find-identity -p codesigning -v 2>/dev/null | grep -q "Apple Development"; then
        sign_identity="Apple Development"
    else
        sign_identity="-"
        echo "no Apple Development certificate, signing ad-hoc. macos asks for permissions again after every build." >&2
    fi
fi
codesign --force --sign "$sign_identity" "$framework"

xcrun swiftc -Osize -wmo -parse-as-library -target arm64-apple-macos15.0 -Xlinker -dead_strip \
    -o "$app/Contents/MacOS/Niche" NotchAnimation.swift AudioSpectrum.swift Lyrics.swift MusicLab.swift OutputDevice.swift Headphones.swift AgentSessions.swift AgentUsage.swift LiveActivities.swift Updater.swift Clipboard.swift IdleArt.swift Onboarding.swift SettingsView.swift NicheApp.swift
strip -x "$app/Contents/MacOS/Niche"

xcrun actool AppIcon.icon --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 15.0 \
    --app-icon AppIcon --output-partial-info-plist "$out/icon.plist" >/dev/null

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.niche</string>
    <key>CFBundleName</key><string>Niche</string>
    <key>CFBundleExecutable</key><string>Niche</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.6.9.7</string>
    <key>CFBundleVersion</key><string>59</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key><string>Niche shows when your AirPods connect, their battery and noise control mode.</string>
    <key>NSAudioCaptureUsageDescription</key><string>Niche listens to the playing app's audio to drive the visualizer bars.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$sign_identity" "$app"

staging="$out/dmg"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Niche -srcfolder "$staging" -ov -format ULMO "$out/Niche.dmg" >/dev/null
rm -rf "$staging"
echo "$out/Niche.dmg"
