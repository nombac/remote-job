#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/remote-job-worker-install-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
TEST_HOME=$TMP/home
WORK=$TMP/shared
PREFIX=$TMP/prefix
FAKE_BIN=$TMP/fake-bin
LAUNCH_STATE=$TMP/launch-state
LAUNCH_LOG=$TMP/launch.log
mkdir -p "$TEST_HOME" "$FAKE_BIN"

printf '%s\n' '#!/bin/sh' \
  'out=' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac' \
  'done' \
  '[ -n "$out" ] || exit 1' \
  'printf "#!/bin/sh\\nexit 0\\n" > "$out"' \
  'chmod +x "$out"' > "$FAKE_BIN/swiftc"
chmod +x "$FAKE_BIN/swiftc"

printf '%s\n' '#!/bin/sh' \
  'printf "%s\\n" "$*" >> "$MOCK_LAUNCH_LOG"' \
  'case "$1" in' \
  '  print) [ -f "$MOCK_LAUNCH_STATE" ] || exit 1; cat "$MOCK_LAUNCH_STATE" ;;' \
  '  bootstrap) printf "state = not running\\n" > "$MOCK_LAUNCH_STATE" ;;' \
  '  bootout) rm -f "$MOCK_LAUNCH_STATE" ;;' \
  '  *) exit 1 ;;' \
  'esac' > "$FAKE_BIN/launchctl"
chmod +x "$FAKE_BIN/launchctl"

run_install() {
  HOME="$TEST_HOME" PATH="$FAKE_BIN:$PATH" MOCK_LAUNCH_STATE="$LAUNCH_STATE" \
    MOCK_LAUNCH_LOG="$LAUNCH_LOG" "$ROOT/install.sh" worker --work-root "$WORK" \
    --prefix "$PREFIX" "$@"
}

# First installation registers the LaunchAgent.
run_install >/dev/null
grep -q '^bootstrap ' "$LAUNCH_LOG"

# Reinstallation updates files without unloading an existing LaunchAgent.
before=$(wc -l < "$LAUNCH_LOG" | tr -d ' ')
run_install > "$TMP/reinstall.out"
grep -q 'was not reloaded' "$TMP/reinstall.out"
after=$(wc -l < "$LAUNCH_LOG" | tr -d ' ')
[ "$after" -eq $((before + 1)) ]
[ "$(awk '/^bootout / { count++ } END { print count + 0 }' "$LAUNCH_LOG")" -eq 0 ]

# Explicit reload is rejected while launchd reports an active worker.
printf 'state = running\n' > "$LAUNCH_STATE"
if run_install --reload-launch-agent >/dev/null 2>&1; then
  echo "reloaded a running worker" >&2
  exit 1
fi

# Explicit reload is allowed only after the worker becomes idle.
printf 'state = not running\n' > "$LAUNCH_STATE"
run_install --reload-launch-agent >/dev/null
tail -n 2 "$LAUNCH_LOG" | sed -n '1p' | grep -q '^bootout '
tail -n 1 "$LAUNCH_LOG" | grep -q '^bootstrap '

echo "worker install test passed"
