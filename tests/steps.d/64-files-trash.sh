#!/bin/sh
# Ribbon Files' trash (shell/files-trash.tcl, the freedesktop.org Trash spec): tests/files-trash.tcl under xvfb with
# three other drives beside HOME. Where a user and mount namespace can be made (unshare -rm), the drives are
# tmpfs mounts in it; elsewhere they are folders the test reports as other drives (TRASH_FAKE=1).
# Skips without wish8.6 or xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip files trash (no wish8.6 / xvfb-run)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/h/c" "$T/h/s" "$T/h/r" "$T/h/cfg" "$T/v1" "$T/v2" "$T/v3"
VOLS="$T/v1 $T/v2 $T/v3"

# the drives: VOL2 gets a shared .Trash with the sticky bit, VOL3 one without
prep='set -e
for v in $VOLS; do mount -t tmpfs -o size=256m ribbon-test "$v"; done
mkdir "$T/v2/.Trash" "$T/v3/.Trash"
chmod 1777 "$T/v2/.Trash"
chmod 0777 "$T/v3/.Trash"
'
run='exec env HOME="$T/h" XDG_CACHE_HOME="$T/h/c" XDG_STATE_HOME="$T/h/s" XDG_RUNTIME_DIR="$T/h/r" XDG_CONFIG_HOME="$T/h/cfg" \
	TRASH_VOLS="$VOLS" RIBBON_SHELL_TEST=tests/files-trash.tcl timeout -k 5 280 xvfb-run -a -s "-screen 0 1440x900x24" \
	wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell'
export T VOLS
if unshare -rm sh -c 'mount -t tmpfs ribbon-test "$T/v1" && umount "$T/v1"' 2>/dev/null; then
	how="tmpfs drives"
	unshare -rm sh -c "$prep$run" >"$T/out" 2>&1
	rc=$?
else
	how="folders as drives"
	mkdir "$T/v2/.Trash" "$T/v3/.Trash" && chmod 1777 "$T/v2/.Trash" && chmod 0777 "$T/v3/.Trash"
	TRASH_FAKE=1 sh -c "$run" >"$T/out" 2>&1
	rc=$?
fi
if [ $rc = 0 ] && grep -q 'all trash checks passed' "$T/out"; then
	sed -n "s/^  ok   /  ok   files trash ($how): /p" "$T/out"
	echo "files trash: all checks passed"
else
	sed 's/^/       /' "$T/out"
	echo "  FAIL files trash ($how) (tests/files-trash.tcl)"
	exit 1
fi
