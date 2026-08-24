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
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi

echo "Built $APP"
echo "Run:  open $APP"
