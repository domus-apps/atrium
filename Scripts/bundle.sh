#!/bin/bash
# Builds a standalone Atrium.app at build/Atrium.app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Atrium.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Atrium "$APP/Contents/MacOS/Atrium"
cp Scripts/Info.plist "$APP/Contents/Info.plist"

# Embed Sparkle.framework (auto-update). The binary references it via
# @rpath/../Frameworks (see Package.swift linkerSettings).
SPARKLE=$(find .build/artifacts -type d -name Sparkle.framework -path "*macos*" | head -1)
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"

# Compile the Icon Composer document into Assets.car so macOS 26+ renders
# the icon live with the Liquid Glass treatment (dark/clear/tinted variants).
if [[ -d Assets/AppIcon.icon ]]; then
    ICONBUILD=$(mktemp -d)
    xcrun actool Assets/AppIcon.icon --compile "$ICONBUILD" \
        --platform macosx --minimum-deployment-target 26.0 \
        --app-icon AppIcon --output-partial-info-plist "$ICONBUILD/partial.plist" \
        --output-format human-readable-text --errors > /dev/null
    cp "$ICONBUILD/Assets.car" "$APP/Contents/Resources/Assets.car"
    cp "$ICONBUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONBUILD"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
fi

# With CODESIGN_IDENTITY set (e.g. "Developer ID Application"), produce a
# distributable, notarization-ready signature (hardened runtime + timestamp).
# Otherwise fall back to ad-hoc, which keeps any future TCC grants stable
# across rebuilds on this machine.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    SIGN=(codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY")
else
    SIGN=(codesign --force --options runtime --sign -)
fi

# Sparkle's helpers must be signed individually, innermost first
# (https://sparkle-project.org/documentation/sandboxing/#code-signing).
FW="$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" "$FW/Versions/B/Autoupdate"
"${SIGN[@]}" "$FW/Versions/B/Updater.app"
"${SIGN[@]}" "$FW"
"${SIGN[@]}" "$APP"

echo "Built $APP"
echo "Run:  open $APP"
