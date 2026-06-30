#!/usr/bin/env bash
# Package the bgfx-android example's libgame.so into a signed NativeActivity
# APK (#303, phase 4 milestone B). Reproduces the steps the labelle CLI's
# Android pipeline runs, standalone, so the bgfx-on-Android bring-up can be
# packaged + deployed without the full CLI.
#
# Prereqs:
#   * `labelle-assembler generate --project-root . --platform android`
#   * `cd .labelle/bgfx_android && zig build`  (produces zig-out/lib/libgame.so)
#   * ANDROID_HOME set; build-tools + platforms/android-34 installed
#   * ~/.labelle/android-debug.keystore (debug keystore, pass: android)
#
# Output: apk-build/game.apk  (signed, ready for `adb install -r`)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

: "${ANDROID_HOME:?set ANDROID_HOME to your Android SDK}"

# Pick newest installed build-tools.
BT=""
for v in 36.0.0 35.0.1 35.0.0 34.0.0; do
    if [ -d "$ANDROID_HOME/build-tools/$v" ]; then BT="$ANDROID_HOME/build-tools/$v"; break; fi
done
[ -n "$BT" ] || { echo "no build-tools found under $ANDROID_HOME/build-tools"; exit 1; }

# Pick an android.jar (target SDK 34, fall back to any installed).
PLAT=""
for v in 34 35 36; do
    if [ -f "$ANDROID_HOME/platforms/android-$v/android.jar" ]; then PLAT="$ANDROID_HOME/platforms/android-$v/android.jar"; break; fi
done
[ -n "$PLAT" ] || { echo "no platforms/android-*/android.jar found"; exit 1; }

KS="${LABELLE_KEYSTORE:-$HOME/.labelle/android-debug.keystore}"
[ -f "$KS" ] || { echo "debug keystore not found at $KS"; exit 1; }

SO=".labelle/bgfx_android/zig-out/lib/libgame.so"
[ -f "$SO" ] || { echo "$SO missing — run 'zig build' in .labelle/bgfx_android first"; exit 1; }

rm -rf apk-build
mkdir -p apk-build/staging/lib/arm64-v8a

echo "[1/5] aapt2 link"
"$BT/aapt2" link -o apk-build/base.apk -I "$PLAT" \
    --manifest android/AndroidManifest.xml \
    --min-sdk-version 28 --target-sdk-version 34

echo "[2/5] stage .so"
unzip -o -q apk-build/base.apk -d apk-build/staging
cp "$SO" apk-build/staging/lib/arm64-v8a/libgame.so

echo "[3/5] zip"
# Android R+ (API 30+) requires resources.arsc and the native libs to be
# STORED (uncompressed) and 4-byte aligned, else `installPackageLI` rejects
# the APK. Add resources.arsc (and the .so) with `-0` (no compression);
# zipalign -p then page-aligns the stored entries.
(cd apk-build/staging \
    && zip -q -X -0 ../game_unsigned.apk resources.arsc lib/arm64-v8a/libgame.so \
    && zip -q -X -r ../game_unsigned.apk . -x '*.idsig' resources.arsc 'lib/arm64-v8a/libgame.so')

echo "[4/5] zipalign"
"$BT/zipalign" -p -f 4 apk-build/game_unsigned.apk apk-build/game_aligned.apk

echo "[5/5] apksigner sign"
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --min-sdk-version 28 --out apk-build/game.apk apk-build/game_aligned.apk

"$BT/apksigner" verify apk-build/game.apk && echo "OK: apk-build/game.apk signed + verified"
