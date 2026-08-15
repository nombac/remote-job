#!/bin/sh
set -eu

usage() { echo "usage: ./install.sh {client|worker} --work-root PATH [--prefix PATH]" >&2; exit 2; }
[ "$#" -ge 1 ] || usage
ROLE=$1; shift
case "$ROLE" in client|worker) ;; *) usage ;; esac
PREFIX=$HOME/.local/share/remote-job
WORK_ROOT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) [ "$#" -ge 2 ] || usage; PREFIX=$2; shift 2 ;;
    --work-root) [ "$#" -ge 2 ] || usage; WORK_ROOT=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$WORK_ROOT" ] || usage
case "$PREFIX$WORK_ROOT" in *"
"*) echo "paths may not contain newlines" >&2; exit 2 ;; esac
mkdir -p "$WORK_ROOT" "$WORK_ROOT/.remote/requests" "$WORK_ROOT/.remote/status" \
  "$WORK_ROOT/.remote/cancel" "$PREFIX/bin" "$HOME/.local/bin"
WORK_ROOT=$(CDPATH= cd -P "$WORK_ROOT" && pwd)
PREFIX_PARENT=$(dirname "$PREFIX"); PREFIX_NAME=$(basename "$PREFIX")
PREFIX=$(CDPATH= cd -P "$PREFIX_PARENT" && pwd)/$PREFIX_NAME
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
install -m 755 "$SCRIPT_DIR/bin/remote-job" "$PREFIX/bin/remote-job"
printf 'WORK_ROOT=%s\n' "$WORK_ROOT" > "$PREFIX/config"

link_command() {
  dest=$HOME/.local/bin/$1
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then echo "refusing to replace $dest" >&2; exit 1; fi
  ln -sfn "$PREFIX/bin/remote-job" "$dest"
}
link_command submit-job
link_command job-status
link_command job-list
link_command job-cancel

if [ "$ROLE" = worker ]; then
  command -v swiftc >/dev/null 2>&1 || { echo "worker install needs Xcode Command Line Tools (swiftc)" >&2; exit 1; }
  swiftc -O "$SCRIPT_DIR/Sources/RemoteJobWorker/main.swift" -o "$PREFIX/bin/remote-job-worker"
  WORKER_LINK=$HOME/.local/bin/job-worker
  if [ -e "$WORKER_LINK" ] && [ ! -L "$WORKER_LINK" ]; then echo "refusing to replace $WORKER_LINK" >&2; exit 1; fi
  ln -sfn "$PREFIX/bin/remote-job-worker" "$WORKER_LINK"
  PLIST=$HOME/Library/LaunchAgents/com.local.remote-job.worker.plist
  mkdir -p "$(dirname "$PLIST")"
  xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g'; }
  sed_replacement() { sed 's/[\\&|]/\\&/g'; }
  BIN_XML=$(xml_escape "$PREFIX/bin/remote-job-worker" | sed_replacement)
  CONFIG_XML=$(xml_escape "$PREFIX/config" | sed_replacement)
  OUT_XML=$(xml_escape "$PREFIX/worker.out.log" | sed_replacement)
  ERR_XML=$(xml_escape "$PREFIX/worker.err.log" | sed_replacement)
  sed -e "s|@BINARY@|$BIN_XML|g" -e "s|@CONFIG@|$CONFIG_XML|g" \
      -e "s|@STDOUT@|$OUT_XML|g" -e "s|@STDERR@|$ERR_XML|g" \
      "$SCRIPT_DIR/launchd/com.local.remote-job.worker.plist.in" > "$PLIST"
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "Worker installed. Give Full Disk Access to: $PREFIX/bin/remote-job-worker"
  echo "Also mark WORK_ROOT as always available offline/local in the sync app."
else
  echo "Client installed."
fi
echo "Add $HOME/.local/bin to PATH, then use submit-job, job-status, job-list, and job-cancel."
