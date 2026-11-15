#!/bin/sh
# Settings → Keyboard and mouse (the backend, apps/settings/input.tcl) with no display (tests/settings-input.tcl): the
# settings file (validation, atomic writes, lines it does not know, a place that cannot be written), the layout list
# from a fixture rules list and from this machine's, touchpad detection from fixture device lists, labwc's generated
# rc.xml and environment, the reconfigure (a stand-in command; its debounce), and `ribbon-input generate`. The
# generated rc.xml is checked with xmllint when there is one; the launcher with shellcheck.
# Skips without tclsh8.6. NOT covered here: labwc itself (65-settings-input-live.sh), the page (57-settings-keyboard-page.sh).
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip Settings → Keyboard and mouse (no tclsh8.6)"; exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
mkdir -p "$T/home" "$T/cfg" "$T/state"
printf '#!/bin/sh\necho reconfigure >> "%s/reconf.log"\n' "$T" > "$T/reconf"; chmod +x "$T/reconf"
st=0
if env HOME="$T/home" XDG_CONFIG_HOME="$T/cfg" XDG_STATE_HOME="$T/state" RIBBON_INPUT_RECONFIGURE="$T/reconf" \
	timeout -k 5 120 tclsh8.6 -encoding utf-8 tests/settings-input.tcl "$D" "$T" >"$T/out" 2>&1; then
	echo "  ok   Settings → Keyboard and mouse: the backend ($(grep -c '^ok' "$T/out") checks)"
else
	sed 's/^/  /' "$T/out"
	echo "  FAIL Settings → Keyboard and mouse: the backend"
	st=1
fi
if command -v xmllint >/dev/null 2>&1 && [ -s "$T/rc-for-xmllint.xml" ]; then
	if xmllint --noout "$T/rc-for-xmllint.xml" 2>"$T/xml.err"; then echo "  ok   the generated rc.xml is well-formed (xmllint)"; else cat "$T/xml.err"; echo "  FAIL the generated rc.xml is not well-formed"; st=1; fi
fi
if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck -e SC1090 "$D/apps/settings/bin/ribbon-input" "$D/bin/ribbon-session" >"$T/sc" 2>&1; then echo "  ok   ribbon-input and ribbon-session pass shellcheck"; else cat "$T/sc"; echo "  FAIL shellcheck"; st=1; fi
fi
exit $st
