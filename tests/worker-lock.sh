#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
WORKER=$ROOT/.build/release/remote-job-worker
TMP=$(mktemp -d "${TMPDIR:-/tmp}/remote-job-lock-test.XXXXXX")
worker_pid=
cleanup() {
  [ -z "$worker_pid" ] || kill "$worker_pid" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM
WORK=$TMP/shared
PREFIX=$TMP/prefix
mkdir -p "$WORK/projects" "$PREFIX/bin"
cp -R "$ROOT/tests/fixtures/lock" "$WORK/projects/lock"
cp -R "$ROOT/tests/fixtures/lock" "$WORK/projects/crash"
cp -R "$ROOT/tests/fixtures/marker" "$WORK/projects/next"
cp -R "$ROOT/tests/fixtures/marker" "$WORK/projects/after-crash"
cp "$ROOT/bin/remote-job" "$PREFIX/bin/remote-job"
cp "$WORKER" "$PREFIX/bin/remote-job-worker"
chmod +x "$PREFIX/bin/remote-job" "$PREFIX/bin/remote-job-worker" "$WORK/projects"/*/run
printf 'WORK_ROOT=%s\n' "$WORK" > "$PREFIX/config"
ln -s "$PREFIX/bin/remote-job" "$TMP/submit-job"
ln -s "$PREFIX/bin/remote-job-worker" "$TMP/job-worker"

state_is() { grep -q "^state=$2$" "$WORK/.remote/status/$1.status" 2>/dev/null; }
wait_state() {
  id=$1; wanted=$2; count=0
  while ! state_is "$id" "$wanted"; do
    count=$((count + 1)); [ "$count" -lt 100 ] || { echo "timeout waiting for $id: $wanted" >&2; exit 1; }
    sleep 0.1
  done
}

# A manual/launchd-style collision cannot process the next request concurrently.
first=$(cd "$WORK/projects/lock" && "$TMP/submit-job")
sleep 1
second=$(cd "$WORK/projects/next" && "$TMP/submit-job")
"$WORKER" --config "$PREFIX/config" & worker_pid=$!
wait_state "$first" running
grep -q '^heartbeat_epoch=' "$WORK/.remote/status/$first.status"
"$TMP/job-worker"
[ ! -e "$WORK/projects/next/started" ]
[ ! -e "$WORK/.remote/status/$second.status" ]
wait "$worker_pid"; worker_pid=
"$TMP/job-worker"
state_is "$second" finished
[ "$(find "$WORK/projects/lock" -name 'start.*' -type f | wc -l | tr -d ' ')" -eq 1 ]

# flock is released by the OS after a worker crash even though worker.lock remains.
crashed=$(cd "$WORK/projects/crash" && "$TMP/submit-job")
"$WORKER" --config "$PREFIX/config" & worker_pid=$!
wait_state "$crashed" running
pgid=$(sed -n 's/^pgid=//p' "$WORK/.remote/status/$crashed.status")
kill -KILL "$worker_pid"; wait "$worker_pid" 2>/dev/null || true; worker_pid=
kill -KILL "-$pgid" 2>/dev/null || true
[ -f "$PREFIX/worker.lock" ]
after=$(cd "$WORK/projects/after-crash" && "$TMP/submit-job")
"$WORKER" --config "$PREFIX/config"
state_is "$after" finished

echo "worker lock test passed"
