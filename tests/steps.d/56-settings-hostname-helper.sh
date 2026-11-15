#!/bin/sh
# Settings → About, the privileged half: apps/settings/bin/ribbon-hostname-helper on a fake root
# (tests/settings-hostname-helper.tcl), under every POSIX shell there is here: what it refuses, /etc/hostname replaced
# atomically, /etc/hosts line by line, links never followed, the safety checks on /etc, the running system named and
# named back, a hostile environment, the real `hostname` in a private UTS namespace; shellcheck on the helper and
# xmllint on its polkit policy where they are installed. The page's backend driving the helper through a stub pkexec
# is in 55-settings-about.sh. Skips without tclsh8.6. NOT covered: real root on the real /etc, a real polkit prompt.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip Settings → About helper (no tclsh8.6)"; exit 0
fi
D=srcpkgs/ribbon-desktop/files
H=$D/apps/settings/bin/ribbon-hostname-helper
P=$D/apps/settings/policy/org.ribbon.hostname.policy
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
fails=0
if env TMPDIR="$T" timeout -k 5 120 tclsh8.6 tests/settings-hostname-helper.tcl "$H" >"$T/hh.out" 2>&1; then
	grep -v '^  ok ' "$T/hh.out" | grep -v '^hostname helper: all checks passed$' | grep -v '^  -- under ' | sed 's/^/     /'
	echo "  ok   Settings → About helper: refusals, atomic writes, /etc/hosts, links, the running system ($(grep -c '^  ok ' "$T/hh.out") checks)"
else
	sed 's/^/       /' "$T/hh.out"
	echo "  FAIL Settings → About helper"; fails=$((fails + 1))
fi
if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck -s sh "$H" >"$T/sc.out" 2>&1; then echo "  ok   ribbon-hostname-helper is shellcheck-clean"; else sed 's/^/       /' "$T/sc.out"; echo "  FAIL shellcheck on ribbon-hostname-helper"; fails=$((fails + 1)); fi
else
	echo "  skip shellcheck on ribbon-hostname-helper (not installed)"
fi
if command -v xmllint >/dev/null 2>&1; then
	if xmllint --noout --nonet "$P" 2>"$T/xml.out" && grep -q 'exec.path">/usr/bin/ribbon-hostname-helper<' "$P" && grep -q '<allow_active>auth_admin_keep</allow_active>' "$P"; then
		echo "  ok   org.ribbon.hostname.policy is well-formed, names the helper, asks an admin"
	else
		sed 's/^/       /' "$T/xml.out"; echo "  FAIL org.ribbon.hostname.policy"; fails=$((fails + 1))
	fi
else
	echo "  skip the policy's XML (no xmllint)"
fi
[ -x "$H" ] || { echo "  FAIL ribbon-hostname-helper is not executable"; fails=$((fails + 1)); }
[ $fails -eq 0 ] || exit 1
