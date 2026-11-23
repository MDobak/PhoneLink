#!/bin/sh
# Builds "Phone Link.app" into ./build. Needs only the Xcode command-line tools.
set -e
cd "$(dirname "$0")"
swift build -c release --arch arm64
APP="build/Phone Link.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PhoneLink "$APP/Contents/MacOS/PhoneLink"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Helpers"
cp .build/release/PhoneLinkDockShim "$APP/Contents/Helpers/PhoneLinkDockShim"
codesign --force --sign - "$APP/Contents/Helpers/PhoneLinkDockShim"
if [ ! -f build/AppIcon.icns ] || [ tools/make-icon.swift -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift tools/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Optional: without the bundled APK, the phone helpers use the installed Phone Link app.
AGENT_APK=../android/app/build/outputs/apk/debug/app-debug.apk
if [ -f "$AGENT_APK" ]; then
  cp "$AGENT_APK" "$APP/Contents/Resources/phonelink-agent.apk"
else
  echo "warning: $AGENT_APK not found; the app has no phone helper APK" >&2
fi

# App Intents metadata for Shortcuts and Spotlight. Needs full Xcode.
if xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
  META=build/meta
  SDK=$(xcrun --show-sdk-path)
  mkdir -p "$META"
  printf '%s' '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","EntityStringQuery","EntityPropertyQuery"]' > "$META/protocols.json"
  swiftc -module-name PhoneLink -parse-as-library -wmo -c Sources/PhoneLink/*.swift -target arm64-apple-macos14.0 -sdk "$SDK" \
    -emit-const-values-path "$META/PhoneLink.swiftconstvalues" -Xfrontend -const-gather-protocols-file -Xfrontend "$META/protocols.json" \
    -o "$META/PhoneLink.o" 2>/dev/null
  ls "$PWD"/Sources/PhoneLink/*.swift > "$META/sources.txt"
  echo "$PWD/$META/PhoneLink.swiftconstvalues" > "$META/constvals.txt"
  xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" \
    --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")" --module-name PhoneLink --sdk-root "$SDK" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" --platform-family macOS --deployment-target 14.0 \
    --target-triple arm64-apple-macos14.0 --source-file-list "$META/sources.txt" --swift-const-vals-list "$META/constvals.txt" \
    --binary-file "$APP/Contents/MacOS/PhoneLink" --force 2>&1 | grep -iE "error|warning" || true
fi
codesign --force --sign - "$APP"
echo "Built $APP"
