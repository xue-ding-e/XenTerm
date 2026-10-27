#!/usr/bin/env bash
# Runs inside this job's xvfb-run + dbus-run-session, never a user's desktop.
set -euo pipefail
source_root="$(realpath "$1")"
host="$(realpath "$2")"
control="$(realpath "$3")"
evidence="$(realpath "$4")"
sha="$5"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]]
test -n "${DISPLAY:-}"
test -n "${DBUS_SESSION_BUS_ADDRESS:-}"
private="$(mktemp -d "$RUNNER_TEMP/xenterm-native.XXXXXXXX")"
chmod 700 "$private"
wm_pid= fixture_pid= driver_pid=
cleanup() {
  for process in "$driver_pid" "$fixture_pid" "$wm_pid"; do
    if [[ -n "$process" ]] && kill -0 "$process" 2>/dev/null; then
      kill -TERM "$process" 2>/dev/null || true
      wait "$process" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT
mkdir -m 700 "$private/wm-home" "$private/wm-config"
HOME="$private/wm-home" XDG_CONFIG_HOME="$private/wm-config" openbox --sm-disable >"$private/wm.log" 2>&1 &
wm_pid=$!
for _ in $(seq 1 50); do
  if xprop -root _NET_SUPPORTING_WM_CHECK | grep -q 'window id'; then break; fi
  sleep .1
done
xprop -root _NET_SUPPORTING_WM_CHECK | grep -q 'window id'

# Release smoke runs the original product bundle, before test instrumentation.
timeout --kill-after=10s 90s python3 "$control/release_bundle_smoke.py" \
  --bundle "$source_root/apps/xenterm/build/linux/x64/release/bundle" \
  --runtime "$private/release" --source-sha "$sha"
mkdir -p "$evidence/release-smoke"
cp "$private/release/artifacts/"* "$evidence/release-smoke/"

# Build outputs live only under the disposable test-host. Its bridge override
# is explicit here because Flutter cleans debug/bundle during every build.
# The independent release smoke above proves normal bundle/lib discovery.
mkdir -p "$host/build"
for language in en zh; do
  runtime="$private/$language"
  mkdir -m 700 "$runtime" "$runtime/home" "$runtime/config" "$runtime/data" "$runtime/cache" "$runtime/profile"
  python3 "$control/loopback_desktop_fixture.py" --runtime "$runtime/fixture" >"$runtime/fixture.log" 2>&1 &
  fixture_pid=$!
  for _ in $(seq 1 100); do
    test -e "$runtime/fixture/ready.json" && break
    kill -0 "$fixture_pid"
    sleep .1
  done
  test -e "$runtime/fixture/ready.json"
  python3 "$control/native_desktop_driver.py" --runtime "$runtime" \
    --binary-root "$host/build" --source-sha "$sha" --timeout 900 >"$runtime/driver.log" 2>&1 &
  driver_pid=$!
  locale=en_US.UTF-8
  [[ "$language" == zh ]] && locale=zh_CN.UTF-8
  set +e
  (cd "$host" && env HOME="$runtime/home" XDG_CONFIG_HOME="$runtime/config" \
    XDG_DATA_HOME="$runtime/data" XDG_CACHE_HOME="$runtime/cache" \
    XENTERM_DATA_DIR="$runtime/profile" XENTERM_BRIDGE_PATH="$source_root/target/release/libxenterm_bridge.so" \
    XENTERM_UI_TEST_RUNTIME="$runtime" XENTERM_UI_TEST_SOURCE_SHA="$sha" \
    XENTERM_UI_EXPECT_LANGUAGE="$language" XENTERM_UI_TEST_CLI="$source_root/target/debug/xenterm" \
    LANG="$locale" LC_ALL="$locale" LANGUAGE="$language" \
    timeout --kill-after=10s 900s flutter test integration_test/native_desktop_test.dart -d linux --no-pub --reporter expanded) \
    >"$evidence/native-$language.log" 2>&1
  app_status=$?
  # The driver must have consumed all physical checkpoints AND completion.
  # A successful flutter test alone is insufficient.
  if [[ "$app_status" != 0 ]]; then kill -TERM "$driver_pid" 2>/dev/null || true; fi
  wait "$driver_pid"
  driver_status=$?
  set -e
  driver_pid=
  mkdir -p "$evidence/native-$language"
  if [[ -d "$runtime/artifacts" ]]; then find "$runtime/artifacts" -maxdepth 1 -name "*.png" -exec cp {} "$evidence/native-$language/" \; ; fi
  if [[ -f "$runtime/test-complete.json" ]]; then cp "$runtime/test-complete.json" "$evidence/native-$language/"; fi
  kill -TERM "$fixture_pid"
  wait "$fixture_pid"
  fixture_pid=
  printf 'language=%s flutter_exit=%s driver_exit=%s\n' "$language" "$app_status" "$driver_status" | tee "$evidence/native-$language-status.log"
  test "$app_status" = 0
  test "$driver_status" = 0
  test -f "$evidence/native-$language/test-complete.json"
  # Deliberately do not copy HOME, profile, steps, fixture credentials, received
  # byte journals or private driver/fixture logs into downloadable artifacts.
done
