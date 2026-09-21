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

## Quick path: the labelle CLI

```sh
export ANDROID_HOME=~/Library/Android/sdk
labelle android doctor          # every required SDK/NDK tool, checked
labelle android run             # Debug: generate → build → package → install → launch
labelle android run --release   # ReleaseFast — judge performance on this one only
adb logcat -s labelle BGFX      # "bgfx: INIT_WINDOW surface WxH" → "sprite shaders initialized"
```

`labelle run`/`labelle android run` exit with the game's own status since
labelle-cli v1.70.0, and the generated `main` routes `std.log` to logcat under
the tag `labelle` in every optimize mode.

## Build, package, deploy (by hand)

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
- Run with the device **awake and unlocked** — a dozing screen never creates
  the foreground surface, so `INIT_WINDOW`/bgfx-init never fires: the activity
  gets `Resume` → `Pause` → `Stop` within ~150 ms and then just sits there, alive
  and blank. It is easy to cause by accident: a cold build takes longer than the
  default 30 s screen-off timeout, so the screen is off again by the time the CLI
  launches the app, and `svc power stayon usb` alone does not prevent it on
  Samsung. For a test session:
  `adb shell settings put system screen_off_timeout 1800000` (restore it after),
  then `adb shell input keyevent KEYCODE_WAKEUP && adb shell wm dismiss-keyguard`.
- A scene the engine rejects **aborts in `gameInit`** (SIGABRT ~2 s after launch,
  "app has a bug" dialog). The reason is one `E/labelle` line above the
  tombstone — e.g. `[unified-format] legacy "entities" key is no longer accepted`
  (labelle-bgfx#104 / #114). Read `adb logcat -b crash` for the backtrace.
