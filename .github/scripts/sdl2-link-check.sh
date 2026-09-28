#!/usr/bin/env bash
# Drives `zig build sdl2-link-check` through the real SDL2 wiring
# (sdl2_link.zig) on a Windows host and asserts which path ran
# (labelle-cli#471 S2):
#   1. SDL2 missing (LABELLE_SDL2_LIB -> empty dir, and unset): the build
#      fails with exactly the one-line message and no linker error.
#   2. `.gamepad = .none` (-Dgamepad_enabled=false) with SDL2 missing: builds.
#   3. SDL2 present (SDL2_PRESENT_LIB = a lib dir holding SDL2.dll): links.
# pkg-config is pointed at a non-existent exe so the result can't depend on
# whatever the runner happens to have installed.
set -uo pipefail

msg='error: SDL2 not found: set LABELLE_SDL2_LIB or use `.gamepad = .none`'
export PKG_CONFIG=labelle-no-pkg-config
empty="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/labelle-no-sdl2"
mkdir -p "$empty"
log="$empty.log"
failures=0

expect_missing() { # $1 = label; remaining = env assignments for `env`
  local label="$1"; shift
  env "$@" zig build sdl2-link-check >"$log" 2>&1
  local code=$?
  cat "$log"
  if [ "$code" -eq 0 ]; then
    echo "FAIL[$label]: build succeeded but SDL2 is missing"; failures=$((failures + 1)); return
  fi
  if ! grep -qxF -- "$msg" "$log"; then
    echo "FAIL[$label]: missing-SDL2 line not printed"; failures=$((failures + 1)); return
  fi
  if grep -q "unable to find dynamic system library" "$log"; then
    echo "FAIL[$label]: the linker ran (its error was printed)"; failures=$((failures + 1)); return
  fi
  if [ "$(grep -c "SDL2" "$log")" -ne 1 ]; then # two SDL modules in the graph, one line
    echo "FAIL[$label]: expected exactly one line mentioning SDL2"; failures=$((failures + 1)); return
  fi
  echo "ok[$label]"
}

expect_success() { # $1 = label; remaining = env assignments, then `--` zig args
  local label="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  if env "${envs[@]}" zig build sdl2-link-check "$@" >"$log" 2>&1; then
    echo "ok[$label]"
  else
    cat "$log"; echo "FAIL[$label]: build failed"; failures=$((failures + 1))
  fi
}

empty_w="$(cygpath -w "$empty" 2>/dev/null || echo "$empty")"
expect_missing "env -> empty dir" "LABELLE_SDL2_LIB=$empty_w"
expect_missing "env unset" -u LABELLE_SDL2_LIB
expect_success "gamepad opt-out, SDL2 missing" "LABELLE_SDL2_LIB=$empty_w" -- -Dgamepad_enabled=false
if [ -n "${SDL2_PRESENT_LIB:-}" ]; then
  expect_success "SDL2 present" "LABELLE_SDL2_LIB=$SDL2_PRESENT_LIB" --
else
  echo "FAIL: SDL2_PRESENT_LIB not set"; failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || { echo "$failures sdl2-link-check scenario(s) failed"; exit 1; }
echo "all sdl2-link-check scenarios passed"
