#!/bin/sh
# Settings → Date and time, the privileged half: apps/settings/bin/ribbon-time-helper on a fake root
# (tests/settings-time-helper.tcl), under every POSIX shell there is here: what it refuses (paths, options, dates that
# are not dates), the zone link replaced whole, /etc/timezone, date -s and hwclock -w, the time service through a
# dinitctl stand-in, the safety checks on /etc, a hostile environment; the real zone files and the real date's reading
# of the helper's words; shellcheck on the helper and xmllint on its polkit policy where they are installed. The
# page's backend driving the helper through a stub pkexec is in 55-settings-datetime.sh. Skips without tclsh8.6 or the
# zone files. NOT covered: real root on the real /etc, a real `date -s` and `hwclock -w`, a real dinit, a real polkit
# prompt.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip Settings → Date and time helper (no tclsh8.6)"; exit 0
fi
if [ ! -f /usr/share/zoneinfo/Europe/London ] || [ ! -f /usr/share/zoneinfo/Asia/Tokyo ]; then
	echo "  skip Settings → Date and time helper (no zone files in /usr/share/zoneinfo)"; exit 0
fi
D=srcpkgs/ribbon-desktop/files
H=$D/apps/settings/bin/ribbon-time-helper
P=$D/apps/settings/policy/org.ribbon.time.policy
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
fails=0
if env TMPDIR="$T" timeout -k 5 300 tclsh8.6 tests/settings-time-helper.tcl "$H" >"$T/th.out" 2>&1; then
	grep -v '^  ok ' "$T/th.out" | grep -v '^time helper: all checks passed$' | grep -v '^  -- under ' | sed 's/^/     /'
	echo "  ok   Settings → Date and time helper: refusals, the zone link, date and hwclock, the time service ($(grep -c '^  ok ' "$T/th.out") checks)"
else
	grep -v '^  ok ' "$T/th.out" | sed 's/^/       /'
	echo "  FAIL Settings → Date and time helper"; fails=$((fails + 1))
fi
if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck -s sh "$H" >"$T/sc.out" 2>&1; then echo "  ok   ribbon-time-helper is shellcheck-clean"; else sed 's/^/       /' "$T/sc.out"; echo "  FAIL shellcheck on ribbon-time-helper"; fails=$((fails + 1)); fi
else
	echo "  skip shellcheck on ribbon-time-helper (not installed)"
fi
if command -v xmllint >/dev/null 2>&1; then
	if xmllint --noout --nonet "$P" 2>"$T/xml.out" && grep -q 'exec.path">/usr/bin/ribbon-time-helper<' "$P" && grep -q '<allow_active>auth_admin_keep</allow_active>' "$P"; then
		echo "  ok   org.ribbon.time.policy is well-formed, names the helper, asks an admin"
	else
		sed 's/^/       /' "$T/xml.out"; echo "  FAIL org.ribbon.time.policy"; fails=$((fails + 1))
	fi
else
	echo "  skip the policy's XML (no xmllint)"
fi
[ -x "$H" ] || { echo "  FAIL ribbon-time-helper is not executable"; fails=$((fails + 1)); }
[ $fails -eq 0 ] || exit 1
