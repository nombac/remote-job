#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
WORKER=$ROOT/.build/release/remote-job-worker
TMP=$(mktemp -d "${TMPDIR:-/tmp}/remote-job-heartbeat-test.XXXXXX")
worker_pid=
cleanup() {
  [ -z "$worker_pid" ] || kill "$worker_pid" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM
WORK=$TMP/shared
PREFIX=$TMP/prefix
mkdir -p "$WORK/projects" "$PREFIX/bin"
cp -R "$ROOT/tests/fixtures/heartbeat" "$WORK/projects/heartbeat"
cp "$ROOT/bin/remote-job" "$PREFIX/bin/remote-job"
chmod +x "$PREFIX/bin/remote-job" "$WORK/projects/heartbeat/run"
printf 'WORK_ROOT=%s\n' "$WORK" > "$PREFIX/config"
for name in job-submit job-cancel; do ln -s "$PREFIX/bin/remote-job" "$TMP/$name"; done

id=$(cd "$WORK/projects/heartbeat" && "$TMP/job-submit")
"$WORKER" --config "$PREFIX/config" & worker_pid=$!
count=0
while [ ! -f "$WORK/.remote/status/$id.status" ]; do
  count=$((count + 1)); [ "$count" -lt 50 ] || { echo "initial heartbeat missing" >&2; exit 1; }
  sleep 0.1
done
first=$(sed -n 's/^heartbeat_epoch=//p' "$WORK/.remote/status/$id.status")
[ -n "$first" ]
count=0
while [ "$(sed -n 's/^heartbeat_epoch=//p' "$WORK/.remote/status/$id.status")" = "$first" ]; do
  count=$((count + 1)); [ "$count" -lt 50 ] || { echo "heartbeat was not refreshed" >&2; exit 1; }
  sleep 0.5
done
(cd "$WORK/projects/heartbeat" && $TMP/job-cancel) >/dev/null
wait "$worker_pid"; worker_pid=
grep -q '^state=cancelled$' "$WORK/.remote/status/$id.status"

echo "heartbeat refresh test passed"
