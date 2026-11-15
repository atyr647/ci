#!/bin/sh
# Settings → Users, the privileged half: apps/settings/bin/ribbon-users-helper on a fake root with stand-ins for
# useradd, usermod, userdel, gpasswd, groupadd and chpasswd that record their arguments, standard input and
# environment (tests/settings-users-helper.tcl): what each verb runs, the password in chpasswd's standard input and in
# no argument, environment or message, and every refusal (system accounts, the caller's own account, the last
# administrator, bad names, injection attempts). The list runs under sh and, where installed, dash, bash --posix and busybox sh.
# Then shellcheck on the helper and xmllint on its polkit policy (one action per verb; nothing kept but rename).
# Skips without tclsh8.6. NOT covered here: the real tools (56-settings-users-real.sh), a real polkit prompt.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip Settings → Users helper (no tclsh8.6)"; exit 0
fi
D=srcpkgs/ribbon-desktop/files
H=$D/apps/settings/bin/ribbon-users-helper
P=$D/apps/settings/policy/org.ribbon.users.policy
T=$(mktemp -d)
chmod 755 "$T"   # as root the helper is run as another uid, which must reach its fake root
trap 'rm -rf "${T:?}"' EXIT
fails=0
# the shells /bin/sh may be: bash as sh is bash --posix (plain bash would read BASH_ENV before the script's first line;
# pkexec starts the helper through its #!/bin/sh with a cleaned environment)
set -- sh
names='sh'
command -v dash >/dev/null 2>&1 && { set -- "$@" dash; names="$names, dash"; }
command -v bash >/dev/null 2>&1 && { set -- "$@" "bash --posix"; names="$names, bash --posix"; }
command -v busybox >/dev/null 2>&1 && busybox sh -c : 2>/dev/null && { set -- "$@" "busybox sh"; names="$names, busybox sh"; }
env TMPDIR="$T" timeout -k 5 300 tclsh8.6 -encoding utf-8 tests/settings-users-helper.tcl "$H" "$@" >"$T/uh.out" 2>&1
rc=$?
case $rc in
	0) grep -v '^  ok ' "$T/uh.out" | grep -v ' checks, 0 failed$' | sed 's/^/     /'
		echo "  ok   Settings → Users helper: verbs, the password's path, refusals ($(grep -c '^  ok ' "$T/uh.out") checks under: $names)" ;;
	77) tail -n 1 "$T/uh.out"; echo "  skip Settings → Users helper" ;;
	*) sed 's/^/       /' "$T/uh.out"; echo "  FAIL Settings → Users helper"; fails=$((fails + 1)) ;;
esac
if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck -s sh "$H" >"$T/sc.out" 2>&1; then echo "  ok   ribbon-users-helper is shellcheck-clean"; else sed 's/^/       /' "$T/sc.out"; echo "  FAIL shellcheck on ribbon-users-helper"; fails=$((fails + 1)); fi
else
	echo "  skip shellcheck on ribbon-users-helper (not installed)"
fi
if command -v xmllint >/dev/null 2>&1; then
	ok=1
	xmllint --noout --nonet "$P" 2>"$T/xml.out" || ok=0
	for v in add remove admin passwd nopass rename; do
		grep -q "<action id=\"org.ribbon.users.$v\">" "$P" && grep -q "exec.argv1\">$v<" "$P" || ok=0
	done
	[ "$(grep -c 'exec.path">/usr/bin/ribbon-users-helper<' "$P")" = 6 ] || ok=0
	# an administrator's password every time, except for a displayed name; never less than an administrator
	[ "$(grep -c '<allow_active>auth_admin</allow_active>' "$P")" = 5 ] && [ "$(grep -c '<allow_active>auth_admin_keep</allow_active>' "$P")" = 1 ] || ok=0
	if grep -q 'auth_self\|>yes<' "$P"; then ok=0; fi
	if [ $ok = 1 ]; then echo "  ok   org.ribbon.users.policy: well-formed, one action per verb, an administrator every time (kept only for rename)"; else
		sed 's/^/       /' "$T/xml.out"; echo "  FAIL org.ribbon.users.policy"; fails=$((fails + 1)); fi
else
	echo "  skip the policy's XML (no xmllint)"
fi
[ -x "$H" ] || { echo "  FAIL ribbon-users-helper is not executable"; fails=$((fails + 1)); }
[ $fails -eq 0 ] || exit 1
