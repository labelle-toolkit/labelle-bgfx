# bgfx-on-Android example (#303)

On-device sibling of [`examples/bgfx`](../bgfx) — the bgfx backend running on
Android as a NativeActivity app. This is the end-to-end vehicle for phase 4 of
the bgfx-on-Android bring-up (#303): assembler `backend_bgfx_android` codegen →
`lib<name>.so` link → APK packaging → deploy + run on-device.

## How it works

`labelle-assembler generate --platform android` emits a `build.zig` that:

- fetches the bgfx backend for `aarch64-linux-android` (gfx/input/audio/window
  built Android-capable; zglfw — desktop-only — omitted),
- pulls the `android_app` module (the hand-rolled NativeActivity glue +
  `android_native_app_glue.c`, exported via `backend_app`),
- builds the game as a **shared library** (`libgame.so`) and links the NDK
  libs (`android`, `log`, `EGL`, `GLESv3`, `m`, `dl`).

The generated `main.zig` **owns the `android_main` entry**: it registers a
one-shot engine-init callback (fired once bgfx is live on `INIT_WINDOW`) and a
per-frame tick callback with the bgfx shell, then hands the event/frame loop to
`android_app.run`. (The bgfx desktop template keeps its linear `pub fn main()`
loop — unchanged.)

## Build, package, deploy

```sh
export ANDROID_HOME=~/Library/Android/sdk          # NDK + build-tools + platforms

# 1. Generate the Android build
labelle-assembler generate --project-root . --platform android

# 2. Build libgame.so (aarch64 ELF shared object)
cd .labelle/bgfx_android && zig build && cd ../..

# 3. Package as a signed NativeActivity APK (debug keystore)
./package_apk.sh                                   # → apk-build/game.apk

# 4. Deploy + run
adb install -r apk-build/game.apk
adb shell am start -n com.labelle.bgfx_demo/android.app.NativeActivity
adb logcat | grep BGFX                             # "BGFX Init complete." on-device
```

`package_apk.sh` reproduces the labelle CLI's Android pipeline standalone:
`aapt2 link` (against `android/AndroidManifest.xml`) → stage `.so` →
`zip` (resources.arsc + .so stored uncompressed for R+) → `zipalign -p` →
`apksigner sign` (debug keystore at `~/.labelle/android-debug.keystore`).

## Notes

- The bgfx shell provides sokol-compat shims (`sapp_android_get_native_activity`,
  `labelle_android_gamepad_init`/`_shutdown`) so the engine/core Android paths —
  which assume sokol provides those symbols — resolve without sokol in the graph.
  Gamepad detection is inert on bgfx-Android for now (a separate ticket).
- Run with the device **awake** — a dozing screen never creates the foreground
  surface, so `INIT_WINDOW`/bgfx-init never fires.
