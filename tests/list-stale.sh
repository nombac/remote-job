#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/remote-job-list-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
WORK=$TMP/shared
PREFIX=$TMP/prefix
mkdir -p "$WORK" "$PREFIX/bin"
cp "$ROOT/bin/remote-job" "$PREFIX/bin/remote-job"
chmod +x "$PREFIX/bin/remote-job"
printf 'WORK_ROOT=%s\n' "$WORK" > "$PREFIX/config"
for name in job-status job-list; do ln -s "$PREFIX/bin/remote-job" "$TMP/$name"; done

# An empty/missing status directory is harmless and still prints the header.
$TMP/job-list | grep -q '^DIR.*STATE.*REQUEST.*UPDATED (JST)$'
if "$TMP/job-status" >/dev/null 2>&1; then echo "job-status accepted a missing job ID" >&2; exit 1; fi

now=$(date +%s)
write_status() {
  id=$1 state=$2 project=$3 updated=$4 heartbeat=$5
  {
    printf 'state=%s\nid=%s\nproject=%s\nupdated=%s\n' "$state" "$id" "$project" "$updated"
    [ -z "$heartbeat" ] || printf 'heartbeat_epoch=%s\n' "$heartbeat"
  } > "$WORK/.remote/status/$id.status"
}
write_status newest-running running AAA 2026-08-15T10:31:00Z "$now"
write_status old-running running BBB 2026-08-15T09:45:00Z 1
write_status done-job finished CCC/DDD 2026-08-15T09:15:00Z 1
write_status error-job error EEE 2026-08-15T08:42:00Z ''
write_status cancel-job cancelled FFF 2026-08-15T08:00:00Z 1
write_status queued-job queued GGG 2026-08-15T07:30:00Z ''
write_status cancelling-job cancelling HHH 2026-08-15T07:00:00Z "$now"
queued_id=20260815T071500Z-queued-without-status
printf 'QUEUED\n' > "$WORK/.remote/requests/$queued_id.request"

list=$($TMP/job-list)
printf '%s\n' "$list" | sed -n '2p' | grep -q 'AAA.*running.*newest-running'
printf '%s\n' "$list" | grep -q 'BBB.*stale.*old-running'
printf '%s\n' "$list" | grep -q 'CCC/DDD.*finished.*done-job'
printf '%s\n' "$list" | grep -q 'EEE.*error.*error-job'
printf '%s\n' "$list" | grep -q 'FFF.*cancelled.*cancel-job'
printf '%s\n' "$list" | grep -q 'GGG.*queued.*queued-job'
printf '%s\n' "$list" | grep -q 'HHH.*cancelling.*cancelling-job'
printf '%s\n' "$list" | grep -q "QUEUED.*queued.*$queued_id.*2026-08-15 16:15 JST"

$TMP/job-status newest-running | grep -q '^state=running$'
$TMP/job-status newest-running | grep -q '^updated=2026-08-15T19:31:00+09:00$'
$TMP/job-status "$queued_id" | grep -q '^updated=2026-08-15T16:15:00+09:00$'
$TMP/job-status old-running | grep -q '^state=stale$'
$TMP/job-status old-running | grep -q '^reported_state=running$'
$TMP/job-status done-job | grep -q '^state=finished$'
$TMP/job-status cancel-job | grep -q '^state=cancelled$'

echo "list/stale test passed"
