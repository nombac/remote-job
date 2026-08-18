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
for name in job-submit job-status job-list job-cancel job-delete; do ln -s "$PREFIX/bin/remote-job" "$TMP/$name"; done

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
normal_id=$(cd "$WORK/projects/example" && "$TMP/job-submit" example)
case "$normal_id" in ????????T??????JST-*) ;; *) echo "job ID is not JST: $normal_id" >&2; exit 1 ;; esac
$TMP/job-status "$normal_id" | grep -q '^state=queued$'
$TMP/job-status "$normal_id" | grep -q '^task=example$'
"$WORKER" --config "$PREFIX/config"
state_is "$normal_id" finished
grep -q '^task=example$' "$WORK/.remote/status/$normal_id.status"
grep -q '^updated=.*+09:00$' "$WORK/.remote/status/$normal_id.status"
[ -f "$WORK/projects/example/result.txt" ]
$TMP/job-cancel "$normal_id" | grep -q 'already finished'
[ ! -f "$WORK/.remote/cancel/$normal_id.cancel" ]

# A nonzero ./run remains a distinct error state.
error_id=$(cd "$WORK/projects/error" && "$TMP/job-submit" expected-error)
"$WORKER" --config "$PREFIX/config"
state_is "$error_id" error

# Queued cancellation must prevent ./run from starting and remove its request.
queued_id=$(cd "$WORK/projects/marker" && "$TMP/job-submit" queued-marker)
$TMP/job-cancel "$queued_id" | grep -q "$queued_id"
$TMP/job-status "$queued_id" | grep -q '^state=cancelling$'
$TMP/job-list | grep -q "marker.*cancelling.*$queued_id"
"$WORKER" --config "$PREFIX/config"
state_is "$queued_id" cancelled
[ ! -e "$WORK/projects/marker/started" ]
[ ! -e "$WORK/.remote/requests/$queued_id.request" ]

# Reappearing stale cancellation is tied to its old ID; a new job still finishes.
printf '%s\n' "$queued_id" > "$WORK/.remote/cancel/$queued_id.cancel"
printf '%s\n' "$queued_id" > "$WORK/.remote/cancel/$queued_id (conflicted copy).cancel"
next_id=$(cd "$WORK/projects/marker" && "$TMP/job-submit" next-marker)
"$WORKER" --config "$PREFIX/config"
state_is "$next_id" finished
[ -f "$WORK/projects/marker/started" ]
grep -q '^next-marker$' "$WORK/projects/marker/started"
[ ! -e "$WORK/.remote/cancel/$queued_id.cancel" ]

# A running process tree ignores TERM, forcing the worker's group-wide KILL path.
tree_id=$(cd "$WORK/projects/process-tree" && "$TMP/job-submit" process-tree)
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

# A stale cancellation is finalized only when its recorded process group is absent.
stale_gone=stale-process-gone
printf 'schema_version=2\nproject=projects/example\ntask=stale-gone\n' > "$WORK/.remote/requests/$stale_gone.request"
printf 'state=running\nid=%s\nproject=projects/example\ntask=stale-gone\nupdated=2026-08-18T00:00:00+09:00\nheartbeat_epoch=1\npgid=999999\n' \
  "$stale_gone" > "$WORK/.remote/status/$stale_gone.status"
$TMP/job-cancel "$stale_gone" | grep -q 'stale'
wait_state "$stale_gone" cancelled

# A pre-task legacy status is also finalized after its process group is confirmed absent.
legacy_stale=legacy-stale-process-gone
printf 'projects/example\n' > "$WORK/.remote/requests/$legacy_stale.request"
printf 'state=running\nid=%s\nproject=projects/example\nupdated=2026-08-18T00:00:00+09:00\nheartbeat_epoch=1\npgid=999999\n' \
  "$legacy_stale" > "$WORK/.remote/status/$legacy_stale.status"
$TMP/job-cancel "$legacy_stale" | grep -q 'stale'
wait_state "$legacy_stale" cancelled
[ ! -e "$WORK/.remote/cancel/$legacy_stale.cancel" ]

# A stale status whose process group still exists is not finalized or terminated.
stale_live=stale-process-live
printf 'schema_version=2\nproject=projects/example\ntask=stale-live\n' > "$WORK/.remote/requests/$stale_live.request"
printf 'state=running\nid=%s\nproject=projects/example\ntask=stale-live\nupdated=2026-08-18T00:00:00+09:00\nheartbeat_epoch=1\npgid=%s\n' \
  "$stale_live" "$leader" > "$WORK/.remote/status/$stale_live.status"
$TMP/job-cancel "$stale_live" | grep -q 'stale'
sleep 1.5
state_is "$stale_live" running
kill -0 "-$leader"
rm -f "$WORK/.remote/requests/$stale_live.request" "$WORK/.remote/status/$stale_live.status" \
  "$WORK/.remote/cancel/$stale_live.cancel"

queued_while_running=$(cd "$WORK/projects/example" && "$TMP/job-submit" queued-during-run)
if $TMP/job-delete "$queued_while_running" >/dev/null 2>&1; then echo "deleted queued job" >&2; exit 1; fi
$TMP/job-cancel "$queued_while_running" | grep -q "$queued_while_running"
[ ! -e "$WORK/.remote/cancel/$tree_id.cancel" ]
wait_state "$queued_while_running" cancelled
$TMP/job-status "$tree_id" | grep -q '^state=running$'
$TMP/job-delete "$queued_while_running" | grep -q "deleted: $queued_while_running (cancelled)"
if $TMP/job-delete "$tree_id" >/dev/null 2>&1; then echo "deleted running job" >&2; exit 1; fi
$TMP/job-cancel "$tree_id" | grep -q "$tree_id"
wait_state "$tree_id" cancelling
wait "$worker_pid"; worker_pid=
state_is "$tree_id" cancelled
assert_dead "$leader"; assert_dead "$child"; assert_dead "$grandchild"

# A later submission after running cancellation remains unaffected.
after_id=$(cd "$WORK/projects/example" && "$TMP/job-submit" example)
"$WORKER" --config "$PREFIX/config"
state_is "$after_id" finished
[ -f "$WORK/.remote/status/$after_id.log" ]
$TMP/job-delete "$after_id" | grep -q "deleted: $after_id (finished)"
[ ! -e "$WORK/.remote/status/$after_id.status" ]
[ ! -e "$WORK/.remote/status/$after_id.log" ]
[ ! -e "$WORK/.remote/requests/$after_id.request" ]
if $TMP/job-status "$after_id" >/dev/null 2>&1; then echo "deleted job still has status" >&2; exit 1; fi
if $TMP/job-list | grep -q "$after_id"; then echo "deleted job is still listed" >&2; exit 1; fi

# Submission requires exactly one validated task and must be run in the project directory.
if (cd "$WORK/projects/example" && "$TMP/job-submit") >/dev/null 2>&1; then echo "accepted missing task" >&2; exit 1; fi
if (cd "$WORK/projects/example" && "$TMP/job-submit" one two) >/dev/null 2>&1; then echo "accepted multiple tasks" >&2; exit 1; fi
for invalid_task in '-option' 'VAR=value' 'path/task' 'has space'; do
  if (cd "$WORK/projects/example" && "$TMP/job-submit" "$invalid_task") >/dev/null 2>&1; then
    echo "accepted invalid task: $invalid_task" >&2; exit 1
  fi
done
if "$TMP/job-cancel" >/dev/null 2>&1; then echo "accepted missing job ID" >&2; exit 1; fi
if "$TMP/job-cancel" 'invalid/id' >/dev/null 2>&1; then echo "accepted invalid job ID" >&2; exit 1; fi
if "$TMP/job-cancel" unknown-job >/dev/null 2>&1; then echo "accepted unknown job ID" >&2; exit 1; fi
if "$TMP/job-delete" >/dev/null 2>&1; then echo "job-delete accepted a missing job ID" >&2; exit 1; fi
if "$TMP/job-delete" 'invalid/id' >/dev/null 2>&1; then echo "job-delete accepted an invalid job ID" >&2; exit 1; fi
if "$TMP/job-delete" unknown-job >/dev/null 2>&1; then echo "job-delete accepted an unknown job ID" >&2; exit 1; fi
mkdir -p "$TMP/outside"
if (cd "$TMP/outside" && "$TMP/job-submit" example) >/dev/null 2>&1; then echo "accepted directory outside WORK_ROOT" >&2; exit 1; fi
cp -R "$ROOT/example-project/." "$TMP/outside/"
ln -s "$TMP/outside" "$WORK/escape"
if (cd "$WORK/escape" && "$TMP/job-submit" example) >/dev/null 2>&1; then echo "accepted escaping symlink" >&2; exit 1; fi
printf 'schema_version=2\nproject=escape\ntask=example\n' > "$WORK/.remote/requests/symlink-escape.request"
"$WORKER" --config "$PREFIX/config"
state_is symlink-escape error
grep -q 'outside WORK_ROOT' "$WORK/.remote/status/symlink-escape.status"
printf 'projects/example\n' > "$WORK/.remote/requests/legacy-request.request"
printf 'schema_version=2\nproject=projects/example\ntask=-option\n' > \
  "$WORK/.remote/requests/invalid-task-request.request"
"$WORKER" --config "$PREFIX/config"
"$WORKER" --config "$PREFIX/config"
state_is legacy-request error
state_is invalid-task-request error
grep -q 'invalid request format' "$WORK/.remote/status/legacy-request.status"
grep -q 'invalid task name' "$WORK/.remote/status/invalid-task-request.status"
printf 'schema_version=2\nproject=projects/example\ntask=example\n' > "$WORK/.remote/requests/日本語.request"
"$WORKER" --config "$PREFIX/config"
[ ! -e "$WORK/.remote/status/日本語.status" ]

echo "integration test passed"
