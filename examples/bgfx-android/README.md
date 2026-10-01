# bgfx-on-Android example (#303)

On-device sibling of [`examples/bgfx`](../bgfx) — the bgfx backend running on
Android as a NativeActivity app. This is the end-to-end vehicle for phase 4 of
the bgfx-on-Android bring-up (#303): assembler `backend_bgfx_android` codegen →
`lib<name>.so` link → APK packaging → deploy + run on-device (packaging and
deploy now through the `android` provider).

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

## Run it on a device: the `android` provider

APK packaging, install and launch moved out of the labelle CLI into the
`android` provider, [labelle-android](https://github.com/labelle-toolkit/labelle-android)
v0.4.0, which needs **labelle-cli v2.0.0 or newer** (older CLIs reserve the
`android` namespace and reject the provider). This example does not list the
provider yet: CI's `android-example` job builds it with labelle-cli v1.71.0,
which would reject it. To run it on a device, add the plugin and
its settings file to `project.labelle`:

```zig
.plugins = .{
    .{ .name = "android", .repo = "github.com/labelle-toolkit/labelle-android", .version = "0.4.0" },
},
.provider_config = .{ .{ .package = "android", .file = "providers/android.json" } },
```

`providers/android.json` carries the packaging keys that used to live in
`.android` (package name, app name, version name, orientation, …):

```json
{
  "schema_version": 1,
  "package_name": "com.labelle.bgfx_demo",
  "app_name": "LaBelle bgfx",
  "version_name": "0.1"
}
```

From labelle-assembler v0.116.0 the `.android` block keeps only the codegen
keys (`immersive_mode`, `target_sdk_version`, `load_assets_from_apk`) and
rejects the others, which belong in `providers/android.json`. This
example still carries `app_name`, `package_name` and `min_sdk_version`
because CI generates it with assembler v0.109.0; drop them when you move it
to the provider flow.

Then pin the provider (`labelle providers resolve`, review the preview, then
`labelle providers resolve --accept`) and:

```sh
export ANDROID_HOME=~/Library/Android/sdk
labelle android doctor                                  # SDK/NDK/JDK tools, checked
labelle run --platform=android                          # Debug: build → package → install → launch
labelle run --platform=android --optimize=ReleaseFast   # judge performance on this one only
labelle bundle --platform=android --build-number=1      # the release APK
adb logcat -s labelle BGFX      # "bgfx: INIT_WINDOW surface WxH" → "sprite shaders initialized"
```

`labelle build --platform=android` packages `zig-out/apk/game.apk` under
`.labelle/bgfx_android/` (the provider's `package` hook); `labelle run`
installs and launches it (the `deploy` hook). The generated `main` routes
`std.log` to logcat under the tag `labelle` in every optimize mode.

bgfx 0.30.0 pins the same labelle-android release. The provider plugin and
the backend still resolve to two `labelle_android` packages (the plugin is a
`.path` dependency, the backend's is url+hash), so bgfx's build hook points
the backend's imports at the plugin's module and the JNI C links once
(labelle-cli#405 D11). [`test/android-provider`](../../test/android-provider)
is the CI fixture for that.

## Build libgame.so by hand (what CI runs)

```sh
export ANDROID_HOME=~/Library/Android/sdk          # the NDK

# 1. Generate the Android build
labelle generate --platform=android

# 2. Build libgame.so (aarch64 ELF shared object)
cd .labelle/bgfx_android && zig build
```

There is no standalone packaging script any more: the provider owns APK
packaging (`aapt2`, `zipalign`, `apksigner`, the generated
`AndroidManifest.xml`).

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
