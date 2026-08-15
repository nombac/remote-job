#!/bin/sh
set -eu

usage() { echo "usage: ./install.sh {client|worker} --work-root PATH [--prefix PATH]" >&2; exit 2; }
[ "$#" -ge 1 ] || usage
ROLE=$1; shift
case "$ROLE" in client|worker) ;; *) usage ;; esac
PREFIX=$HOME/.local/share/remote-job
WORK_ROOT=
BUILD_DIR=
INSTALL_TMP=
cleanup() {
  [ -z "$INSTALL_TMP" ] || rm -f "$INSTALL_TMP"
  [ -z "$BUILD_DIR" ] || rm -rf "$BUILD_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
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
SCRIPT_DIR=$(CDPATH= cd -P "$(dirname "$0")" && pwd)
if [ "$ROLE" = worker ]; then
  command -v swiftc >/dev/null 2>&1 || { echo "worker install needs Xcode Command Line Tools (swiftc)" >&2; exit 1; }
  BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/remote-job-install.XXXXXX")
  swiftc -O "$SCRIPT_DIR/Sources/RemoteJobWorker/main.swift" -o "$BUILD_DIR/remote-job-worker"
fi

mkdir -p "$WORK_ROOT" "$WORK_ROOT/.remote/requests" "$WORK_ROOT/.remote/status" \
  "$WORK_ROOT/.remote/cancel" "$PREFIX/bin" "$HOME/.local/bin"
WORK_ROOT=$(CDPATH= cd -P "$WORK_ROOT" && pwd)
PREFIX_PARENT=$(dirname "$PREFIX"); PREFIX_NAME=$(basename "$PREFIX")
PREFIX=$(CDPATH= cd -P "$PREFIX_PARENT" && pwd)/$PREFIX_NAME

check_link() {
  dest=$1
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then echo "refusing to replace $dest" >&2; exit 1; fi
}
for name in submit-job job-status job-list job-cancel; do check_link "$HOME/.local/bin/$name"; done
[ "$ROLE" != worker ] || check_link "$HOME/.local/bin/job-worker"

if [ "$ROLE" = worker ]; then
  PLIST=$HOME/Library/LaunchAgents/com.local.remote-job.worker.plist
  xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g'; }
  sed_replacement() { sed 's/[\\&|]/\\&/g'; }
  BIN_XML=$(xml_escape "$PREFIX/bin/remote-job-worker" | sed_replacement)
  CONFIG_XML=$(xml_escape "$PREFIX/config" | sed_replacement)
  OUT_XML=$(xml_escape "$PREFIX/worker.out.log" | sed_replacement)
  ERR_XML=$(xml_escape "$PREFIX/worker.err.log" | sed_replacement)
  sed -e "s|@BINARY@|$BIN_XML|g" -e "s|@CONFIG@|$CONFIG_XML|g" \
      -e "s|@STDOUT@|$OUT_XML|g" -e "s|@STDERR@|$ERR_XML|g" \
      "$SCRIPT_DIR/launchd/com.local.remote-job.worker.plist.in" > "$BUILD_DIR/worker.plist"
  /usr/bin/plutil -lint "$BUILD_DIR/worker.plist" >/dev/null
fi

atomic_install() {
  source_file=$1 destination=$2 mode=$3
  INSTALL_TMP=$(mktemp "$destination.XXXXXX")
  install -m "$mode" "$source_file" "$INSTALL_TMP"
  mv "$INSTALL_TMP" "$destination"
  INSTALL_TMP=
}

atomic_install "$SCRIPT_DIR/bin/remote-job" "$PREFIX/bin/remote-job" 755
INSTALL_TMP=$(mktemp "$PREFIX/.config.XXXXXX")
printf 'WORK_ROOT=%s\n' "$WORK_ROOT" > "$INSTALL_TMP"
chmod 600 "$INSTALL_TMP"
mv "$INSTALL_TMP" "$PREFIX/config"
INSTALL_TMP=
for name in submit-job job-status job-list job-cancel; do
  ln -sfn "$PREFIX/bin/remote-job" "$HOME/.local/bin/$name"
done

if [ "$ROLE" = worker ]; then
  atomic_install "$BUILD_DIR/remote-job-worker" "$PREFIX/bin/remote-job-worker" 755
  ln -sfn "$PREFIX/bin/remote-job-worker" "$HOME/.local/bin/job-worker"
  mkdir -p "$(dirname "$PLIST")"
  atomic_install "$BUILD_DIR/worker.plist" "$PLIST" 644
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "Worker installed. Give Full Disk Access to: $PREFIX/bin/remote-job-worker"
  echo "Also mark WORK_ROOT as always available offline/local in the sync app."
else
  echo "Client installed."
fi
echo "Add $HOME/.local/bin to PATH, then use submit-job, job-status, job-list, and job-cancel."
cleanup
trap - EXIT HUP INT TERM
