#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/remote-job-install-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
TEST_HOME=$TMP/home
WORK=$TMP/shared
PREFIX=$TMP/prefix
mkdir -p "$TEST_HOME" "$TMP/fail-bin"

# A worker compile failure must not leave a partial client installation.
printf '#!/bin/sh\nexit 1\n' > "$TMP/fail-bin/swiftc"
chmod +x "$TMP/fail-bin/swiftc"
if HOME="$TEST_HOME" PATH="$TMP/fail-bin:$PATH" \
    "$ROOT/install.sh" worker --work-root "$WORK" --prefix "$PREFIX" >/dev/null 2>&1; then
  echo "worker install unexpectedly succeeded" >&2
  exit 1
fi
[ ! -e "$PREFIX/bin/remote-job" ]
[ ! -e "$PREFIX/config" ]
[ ! -e "$TEST_HOME/.local/bin/submit-job" ]

# Client installation and reinstallation produce the complete expected layout.
HOME="$TEST_HOME" "$ROOT/install.sh" client --work-root "$WORK" --prefix "$PREFIX" >/dev/null
HOME="$TEST_HOME" "$ROOT/install.sh" client --work-root "$WORK" --prefix "$PREFIX" >/dev/null
[ -x "$PREFIX/bin/remote-job" ]
configured_root=$(sed -n 's/^WORK_ROOT=//p' "$PREFIX/config")
[ "$configured_root" = "$(CDPATH= cd -P "$WORK" && pwd)" ]
installed_prefix=$(CDPATH= cd -P "$PREFIX" && pwd)
for name in submit-job job-status job-list job-cancel; do
  [ "$(readlink "$TEST_HOME/.local/bin/$name")" = "$installed_prefix/bin/remote-job" ]
done

HOME="$TEST_HOME" "$ROOT/uninstall.sh" --prefix "$PREFIX" >/dev/null
[ ! -e "$PREFIX/bin/remote-job" ]
[ ! -e "$PREFIX/config" ]
for name in submit-job job-status job-list job-cancel; do
  [ ! -e "$TEST_HOME/.local/bin/$name" ]
done

echo "client install test passed"
