#!/bin/sh
# Settings → Users against the real programs: ribbon-users-helper as root running the real shadow tools (useradd,
# usermod, userdel, gpasswd, groupadd, chpasswd), and users.tcl changing your own password through the real passwd(1)
# and PAM (tests/settings-users-real.sh, tests/settings-users-real.tcl). All of it in a private mount namespace with a
# COPY of /etc mounted over /etc and new home folders under a temporary directory: the machine's accounts are not
# touched (checked: /etc/passwd, /etc/group and /etc/shadow are the same afterwards). Skips unless root with unshare,
# mount, the shadow tools and perl. NOT covered: polkit's prompt (no pkexec here), a PAM stack other than this machine's.
set -u
cd "$(dirname "$0")/../.." || exit 1
D=$PWD/srcpkgs/ribbon-desktop/files
for t in unshare mount useradd usermod userdel gpasswd groupadd chpasswd perl md5sum; do
	command -v "$t" >/dev/null 2>&1 || { echo "  skip Settings → Users with the real tools (no $t)"; exit 0; }
done
[ "$(id -u)" = 0 ] || { echo "  skip Settings → Users with the real tools (not root)"; exit 0; }
unshare -m true 2>/dev/null || { echo "  skip Settings → Users with the real tools (no mount namespace here)"; exit 0; }
T=$(mktemp -d /tmp/users-real.XXXXXX) || exit 1
trap 'rm -rf "${T:?}"' EXIT
chmod 755 "$T"; mkdir "$T/home"
cp -a /etc "$T/etc" 2>/dev/null
: >"$T/etc/.ribbon-users-test"
mkdir -p "$T/etc/default"; { grep -v '^HOME=' "$T/etc/default/useradd" 2>/dev/null; echo "HOME=$T/home"; } >"$T/useradd.new"; mv "$T/useradd.new" "$T/etc/default/useradd"
before=$(cat /etc/passwd /etc/group /etc/shadow | md5sum)
timeout -k 5 180 unshare -m sh tests/settings-users-real.sh "$D/apps/settings/bin/ribbon-users-helper" "$D" "$T" >"$T/out" 2>&1
rc=$?
after=$(cat /etc/passwd /etc/group /etc/shadow | md5sum)
if [ "$before" != "$after" ]; then sed 's/^/       /' "$T/out"; echo "  FAIL Settings → Users with the real tools: THIS MACHINE'S /etc CHANGED"; exit 1; fi
case $rc in
	0) grep -v '^  ok ' "$T/out" | sed 's/^/       /'; echo "  ok   Settings → Users with the real shadow tools and passwd(1), in a private /etc: $(tail -n 1 "$T/out")" ;;
	77) sed 's/^/  /' "$T/out" | tail -n 1; echo "  skip Settings → Users with the real tools" ;;
	*) sed 's/^/       /' "$T/out"; echo "  FAIL Settings → Users with the real tools"; exit 1 ;;
esac
