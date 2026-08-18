#!/bin/sh
set -eu

PREFIX=$HOME/.local/share/remote-job
WORK_ROOT=
PURGE=0
usage() { echo "usage: ./uninstall.sh [--prefix PATH] [--work-root PATH] [--purge]" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) [ "$#" -ge 2 ] || usage; PREFIX=$2; shift 2 ;;
    --work-root) [ "$#" -ge 2 ] || usage; WORK_ROOT=$2; shift 2 ;;
    --purge) PURGE=1; shift ;;
    *) usage ;;
  esac
done
if [ -z "$WORK_ROOT" ] && [ -f "$PREFIX/config" ]; then
  WORK_ROOT=$(sed -n 's/^WORK_ROOT=//p' "$PREFIX/config" | sed -n '1p')
fi
PLIST=$HOME/Library/LaunchAgents/com.local.remote-job.worker.plist
launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"
for name in job-submit job-status job-list job-cancel job-delete submit-job; do
  link=$HOME/.local/bin/$name
  [ ! -L "$link" ] || { [ "$(readlink "$link")" != "$PREFIX/bin/remote-job" ] || rm -f "$link"; }
done
WORKER_LINK=$HOME/.local/bin/job-worker
[ ! -L "$WORKER_LINK" ] || { [ "$(readlink "$WORKER_LINK")" != "$PREFIX/bin/remote-job-worker" ] || rm -f "$WORKER_LINK"; }
rm -f "$PREFIX/bin/remote-job" "$PREFIX/bin/remote-job-worker" "$PREFIX/config" \
      "$PREFIX/worker.lock" "$PREFIX/worker.out.log" "$PREFIX/worker.err.log"
rmdir "$PREFIX/bin" "$PREFIX" 2>/dev/null || true
if [ "$PURGE" -eq 1 ]; then
  [ -n "$WORK_ROOT" ] || { echo "--purge needs WORK_ROOT (config or --work-root)" >&2; exit 2; }
  case "$WORK_ROOT" in /|.) echo "refusing unsafe WORK_ROOT" >&2; exit 2 ;; esac
  rm -rf "$WORK_ROOT/.remote"
  echo "Removed $WORK_ROOT/.remote (not recoverable unless your sync service retains history)."
fi
echo "remote-job uninstalled."
