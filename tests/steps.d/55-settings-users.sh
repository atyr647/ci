#!/bin/sh
# Settings → Users (the backend, apps/settings/users.tcl) without a display (tests/settings-users.tcl): /etc/passwd and
# /etc/group read under a fake root (people only, administrators, who you are, damaged and missing files), the names,
# every change as the one helper call it makes through a stand-in pkexec that records its arguments, environment and
# standard input (a password is in the standard input only), then the whole chain users.tcl → stand-in pkexec → the
# real ribbon-users-helper on the fake root → stand-in shadow tools, and your own password through a stand-in passwd.
# Skips without tclsh8.6. NOT covered here: the helper's own refusals (56-settings-users-helper.sh), the real shadow
# tools and PAM (56-settings-users-real.sh), the page (57-settings-users-page.sh), a real polkit prompt.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip Settings → Users (no tclsh8.6)"; exit 0
fi
T=$(mktemp -d)
chmod 755 "$T"   # as root the helper is run as another uid, which must reach its fake root
trap 'rm -rf "${T:?}"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
if env TMPDIR="$T" timeout -k 5 150 tclsh8.6 -encoding utf-8 tests/settings-users.tcl "$D" >"$T/users.out" 2>&1; then
	grep -v '^  ok ' "$T/users.out" | grep -v ' checks, 0 failed$' | sed 's/^/     /'
	echo "  ok   Settings → Users: the backend ($(grep -c '^  ok ' "$T/users.out") checks: a fake root, a stand-in pkexec, the helper behind it)"
else
	cat "$T/users.out"
	echo "  FAIL Settings → Users: the backend"
	exit 1
fi
