#!/bin/sh
# Builds a native Mac (Catalyst) Cinepub from the iOS .ipa with CinepubFix.dylib injected.
# usage: macos/build.sh [path/to.ipa] [output.app]  (default: newest ios/Cinepub_*.ipa)
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
IPA=${1:-$(ls "$HERE"/../ios/Cinepub_*.ipa | tail -1)}
OUT=${2:-$HOME/Applications/Cinepub.app}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET=arm64-apple-ios17.6-macabi
IOS_FW=$SDK/System/iOSSupport/System/Library/Frameworks

xcrun clang -c -target $TARGET -isysroot "$SDK" "$HERE/tramp.s" -o "$WORK/tramp.o"
xcrun clang -c -fobjc-arc -target $TARGET -isysroot "$SDK" -iframework "$IOS_FW" "$HERE/interpose.m" -o "$WORK/interpose.o"
xcrun swiftc -emit-library -parse-as-library -O -module-name CinepubFix -target $TARGET -sdk "$SDK" \
    -Fsystem "$IOS_FW" -I "$SDK/System/iOSSupport/usr/lib/swift" -L "$SDK/System/iOSSupport/usr/lib/swift" \
    "$HERE"/*.swift "$WORK/tramp.o" "$WORK/interpose.o" -framework Security -framework UIKit -o "$WORK/CinepubFix.dylib"

unzip -q "$IPA" -d "$WORK"
APP=$(ls -d "$WORK"/Payload/*.app)
EXE=$APP/$(plutil -extract CFBundleExecutable raw "$APP/Info.plist")
# Widget extension can't run on Mac; the old signature and profile are useless here.
rm -rf "$APP/PlugIns" "$APP/_CodeSignature" "$APP/embedded.mobileprovision"

# Retag iOS binaries as Mac Catalyst so they run natively with an ad-hoc signature.
for bin in "$EXE" "$APP"/Frameworks/*.framework/*; do
    [ -f "$bin" ] && file "$bin" | grep -q 'Mach-O' || continue
    xcrun vtool -arch arm64 -set-build-version maccatalyst 17.6 26.4 -replace -output "$bin.tmp" "$bin" 2>/dev/null
    mv "$bin.tmp" "$bin"
done

cp "$WORK/CinepubFix.dylib" "$APP/Frameworks/"
codesign --remove-signature "$EXE"
python3 -I "$HERE/add_dylib.py" "$EXE" @executable_path/Frameworks/CinepubFix.dylib
for fw in "$APP"/Frameworks/*; do codesign -f -s - "$fw"; done
codesign -f -s - "$APP"

rm -rf "$OUT"
ditto "$APP" "$OUT"
echo "built $OUT"
