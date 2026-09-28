#!/usr/bin/env bash
# Asserts that an Android `libgame.so` DEFINES every symbol the gamepad JNI
# glue (`android_gamepad_jni.c`, linked unconditionally by this backend)
# calls back into, and carries no undefined `labelle_*` symbol at all.
#
# Why this needs its own check (labelle-engine#800, labelle-bgfx#64/#108):
# the referents are Zig `export`s that Zig only emits from files something
# references. When the reference is lost, a shared-library link still
# SUCCEEDS with the symbols undefined (`U`), and the failure only shows at
# `dlopen` on a device:
#   dlopen failed: cannot locate symbol "labelle_android_on_device_added"
# The `comptime` references in src/input.zig / src/android.zig are what keep
# them; this check is what notices if they stop working.
#
# Usage: android-jni-exports-check.sh <libgame.so> [nm]
#   nm defaults to `nm` (binutils / llvm-nm both work).
set -uo pipefail

so="${1:?usage: $0 <libgame.so> [nm]}"
nm="${2:-nm}"
[ -f "$so" ] || { echo "FAIL: $so not found"; exit 1; }

# Into variables first: `nm | grep -q` under pipefail fails on SIGPIPE.
if ! defined=$("$nm" -D --defined-only "$so"); then echo "FAIL: $nm -D --defined-only failed"; exit 1; fi
if ! undefined=$("$nm" -D --undefined-only "$so"); then echo "FAIL: $nm -D --undefined-only failed"; exit 1; fi
defined=$(printf '%s\n' "$defined" | awk '{ print $NF }' | sort)
undefined=$(printf '%s\n' "$undefined" | awk '{ print $NF }' | sort)

fail=0
# labelle-core gamepad_source/android.zig: hotplug callbacks.
# android_gamepad state module: per-device state.
for sym in labelle_android_on_device_added labelle_android_on_device_removed \
           labelle_android_gamepad_state_added labelle_android_gamepad_state_removed; do
  n=$(printf '%s\n' "$defined" | grep -cx "$sym" || true)
  if [ "$n" -ne 1 ]; then
    echo "FAIL: $sym defined $n times (want 1)"; fail=1
  else
    echo "ok    $sym defined"
  fi
done

bad=$(printf '%s\n' "$undefined" | grep '^labelle_' || true)
if [ -n "$bad" ]; then
  echo "FAIL: undefined labelle_* symbols (would fail dlopen on device):"
  printf '  %s\n' $bad
  fail=1
else
  echo "ok    no undefined labelle_* symbols"
fi
exit "$fail"
