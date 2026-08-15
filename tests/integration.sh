#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
WORKER=$ROOT/.build/release/remote-job-worker
TMP=$(mktemp -d "${TMPDIR:-/tmp}/remote-job-test.XXXXXX")
worker_pid=
cleanup() {
  [ -z "$worker_pid" ] || kill "$worker_pid" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM
WORK=$TMP/shared
PREFIX=$TMP/prefix
mkdir -p "$WORK/projects" "$PREFIX/bin"
cp -R "$ROOT/example-project" "$WORK/projects/example"
cp -R "$ROOT/tests/fixtures/marker" "$WORK/projects/marker"
cp -R "$ROOT/tests/fixtures/error" "$WORK/projects/error"
cp -R "$ROOT/tests/fixtures/process-tree" "$WORK/projects/process-tree"
cp "$ROOT/bin/remote-job" "$PREFIX/bin/remote-job"
chmod +x "$PREFIX/bin/remote-job" "$WORK/projects"/*/run "$WORK/projects/process-tree/child"
printf 'WORK_ROOT=%s\n' "$WORK" > "$PREFIX/config"
for name in submit-job job-status job-list job-cancel; do ln -s "$PREFIX/bin/remote-job" "$TMP/$name"; done

state_is() { grep -q "^state=$2$" "$WORK/.remote/status/$1.status" 2>/dev/null; }
wait_state() {
  id=$1; wanted=$2; count=0
  while ! state_is "$id" "$wanted"; do
    count=$((count + 1)); [ "$count" -lt 150 ] || { echo "timeout waiting for $id: $wanted" >&2; exit 1; }
    sleep 0.1
  done
}
assert_dead() {
  pid=$1; count=0
  while kill -0 "$pid" 2>/dev/null; do
    count=$((count + 1)); [ "$count" -lt 30 ] || { echo "process survived cancellation: $pid" >&2; exit 1; }
    sleep 0.1
  done
}

# Existing submit/status/worker behavior and a harmless cancel after completion.
normal_id=$($TMP/submit-job projects/example)
$TMP/job-status "$normal_id" | grep -q '^state=queued$'
"$WORKER" --config "$PREFIX/config"
state_is "$normal_id" finished
[ -f "$WORK/projects/example/result.txt" ]
(cd "$WORK/projects/example" && $TMP/job-cancel) | grep -q 'already finished'
[ ! -f "$WORK/.remote/cancel/$normal_id.cancel" ]

# A nonzero ./run remains a distinct error state.
error_id=$($TMP/submit-job projects/error)
"$WORKER" --config "$PREFIX/config"
state_is "$error_id" error

# Queued cancellation must prevent ./run from starting and remove its request.
queued_id=$($TMP/submit-job projects/marker)
(cd "$WORK/projects/marker" && $TMP/job-cancel) | grep -q "$queued_id"
"$WORKER" --config "$PREFIX/config"
state_is "$queued_id" cancelled
[ ! -e "$WORK/projects/marker/started" ]
[ ! -e "$WORK/.remote/requests/$queued_id.request" ]

# Reappearing stale cancellation is tied to its old ID; a new job still finishes.
printf '%s\n' "$queued_id" > "$WORK/.remote/cancel/$queued_id.cancel"
printf '%s\n' "$queued_id" > "$WORK/.remote/cancel/$queued_id (conflicted copy).cancel"
next_id=$($TMP/submit-job projects/marker)
"$WORKER" --config "$PREFIX/config"
state_is "$next_id" finished
[ -f "$WORK/projects/marker/started" ]
[ ! -e "$WORK/.remote/cancel/$queued_id.cancel" ]

# A running process tree ignores TERM, forcing the worker's group-wide KILL path.
tree_id=$($TMP/submit-job projects/process-tree)
"$WORKER" --config "$PREFIX/config" &
worker_pid=$!
wait_state "$tree_id" running
count=0
while [ ! -s "$WORK/projects/process-tree/grandchild.pid" ]; do
  count=$((count + 1)); [ "$count" -lt 50 ] || { echo "process tree did not start" >&2; exit 1; }
  sleep 0.1
done
leader=$(sed -n '1p' "$WORK/projects/process-tree/leader.pid")
child=$(sed -n '1p' "$WORK/projects/process-tree/child.pid")
grandchild=$(sed -n '1p' "$WORK/projects/process-tree/grandchild.pid")
(cd "$WORK/projects/process-tree" && $TMP/job-cancel) | grep -q "$tree_id"
wait_state "$tree_id" cancelling
wait "$worker_pid"; worker_pid=
state_is "$tree_id" cancelled
assert_dead "$leader"; assert_dead "$child"; assert_dead "$grandchild"

# A later submission after running cancellation remains unaffected.
after_id=$($TMP/submit-job projects/example)
"$WORKER" --config "$PREFIX/config"
state_is "$after_id" finished

# Existing path and symlink containment checks remain enforced.
if $TMP/submit-job ../outside >/dev/null 2>&1; then echo "accepted .. path" >&2; exit 1; fi
mkdir -p "$TMP/outside"
cp -R "$ROOT/example-project/." "$TMP/outside/"
ln -s "$TMP/outside" "$WORK/escape"
if $TMP/submit-job escape >/dev/null 2>&1; then echo "accepted escaping symlink" >&2; exit 1; fi
printf 'escape\n' > "$WORK/.remote/requests/symlink-escape.request"
"$WORKER" --config "$PREFIX/config"
state_is symlink-escape error
grep -q 'outside WORK_ROOT' "$WORK/.remote/status/symlink-escape.status"

echo "integration test passed"
