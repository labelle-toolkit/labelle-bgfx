#!/usr/bin/env bash
# Build + sign the DecodeTest NativeActivity APK (FP#549 Half 2).
# Verifies the Android AMediaCodec decoder inside a real app process.
#
# Prereqs: ANDROID_SDK_ROOT, an installed NDK, and a built native lib at
#   /tmp/apk/lib/arm64-v8a/libdecodetest.so  (see the zig build-lib command in
#   the spike notes / commit message).
# Produces: /tmp/apk/decodetest.apk
set -euo pipefail

SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/34.0.0"
JAR="$SDK/platforms/android-34/android.jar"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK=/tmp/apk
CLIP="${1:-/tmp/dectest.mp4}"   # H.264 test clip to bundle as an asset

# 1. Debug keystore (create once).
KS="$HOME/.android/debug.keystore"
if [ ! -f "$KS" ]; then
  mkdir -p "$HOME/.android"
  keytool -genkeypair -keystore "$KS" -storepass android -keypass android \
    -alias androiddebugkey -dname "CN=Android Debug,O=Android,C=US" \
    -keyalg RSA -keysize 2048 -validity 10000
fi

# 2. Stage the asset (uncompressed mp4 so AAsset_openFileDescriptor works).
mkdir -p "$WORK/assets"
cp "$CLIP" "$WORK/assets/dectest.mp4"

# 3. Link manifest + assets into a base APK.
"$BT/aapt2" link \
  --manifest "$HERE/AndroidManifest.xml" \
  -I "$JAR" \
  -A "$WORK/assets" \
  -0 mp4 \
  --min-sdk-version 28 --target-sdk-version 34 \
  -o "$WORK/base.apk"

# 4. Add the native lib (lib/arm64-v8a/libdecodetest.so already staged there).
( cd "$WORK" && zip -q "$WORK/base.apk" lib/arm64-v8a/libdecodetest.so )

# 5. Align, then sign.
"$BT/zipalign" -f 4 "$WORK/base.apk" "$WORK/aligned.apk"
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --ks-key-alias androiddebugkey \
  --out "$WORK/decodetest.apk" "$WORK/aligned.apk"

echo "OK: $WORK/decodetest.apk"
