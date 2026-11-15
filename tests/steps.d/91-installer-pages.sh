#!/bin/sh
# The Tk installer against what the backend does (tests/run.sh "Tk installer" draws every page and drives the flow):
#   - installer-rules.tcl: what the pages offer on legacy BIOS, an MBR disk, Windows not shut down, ZFS away from
#     "Erase disk", swap on ZFS and bcachefs, and the swap and boot loader copy (no Secure Boot promise);
#   - installer-swap.sh: page::swap_plan, which the Hardware page's sizes come from, against postinstall's step_swap;
#   - installer-close.tcl: the close button asks while installing, and Keep installing goes on (a slow fake backend runs to its end and
#     leaves RIBBON_FAKE_MARKER), and quits on Done;
#   - the Hardware page (scene "hardware") against the Inst-5 board's crop in tests/fixtures/installer-pages
#     (blurred RMSE < 0.05).
# Needs tclsh8.6; the window parts need wish8.6 and xvfb-run, the board compare ImageMagick.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
MAIN=srcpkgs/ribbon-installer/files/tk/main.tcl
run_wish() { # scene file, then env assignments
	s=$1; shift
	env HOME="$T/home" XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$T" RIBBON_INSTALLER_SCENE="$s" "$@" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$MAIN"
}
mkdir -p "$T/home" "$T/cache"

bash tests/installer-swap.sh || fails=$((fails + 1))

# the backend's own help and boot loader prompt promise no Secure Boot either (nothing signs a boot loader yet)
if bash srcpkgs/ribbon-installer/files/bin/ribbon-install --help 2>&1 | grep -qi 'secure boot' ||
	grep -i 'echo.*secure boot' srcpkgs/ribbon-installer/files/bin/ribbon-install >/dev/null; then
	echo "  FAIL ribbon-install's help or boot loader prompt promises Secure Boot"; fails=$((fails + 1))
else
	echo "  ok   ribbon-install's help and boot loader prompt promise no Secure Boot"
fi

if command -v wish8.6 >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1; then
	if out=$(run_wish tests/installer-rules.tcl 2>&1); then
		echo "  ok   installer rules: $(printf '%s\n' "$out" | grep -c '  ok ') checks"
	else
		printf '%s\n' "$out" | grep -v '  ok '; echo "  FAIL installer rules"; fails=$((fails + 1))
	fi

	# closing while installing: the backend must still reach its end
	run_wish tests/installer-close.tcl RIBBON_FAKE_DELAY=0.25 RIBBON_FAKE_MARKER="$T/finished" > "$T/close.out" 2>&1; rc=$?
	i=0; while [ ! -e "$T/finished" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
	grep -v '^  FAIL' "$T/close.out" | grep '^  ok' || :
	if [ -e "$T/finished" ] && [ $rc -eq 0 ] && ! grep -q FAIL "$T/close.out"; then
		echo "  ok   the install finished although the window was asked to close; Done's close button quits"
	else
		grep -v '^  ok' "$T/close.out"; echo "  FAIL closing the window while installing (exit $rc, backend finished: $([ -e "$T/finished" ] && echo yes || echo no))"
		fails=$((fails + 1))
	fi

	# the Hardware page against its board
	if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1 && command -v import >/dev/null 2>&1; then
		run_wish tests/installer-scene.tcl RIBBON_SCENE=hardware RIBBON_INSTALLER_SHOT="$T/hw.png" >/dev/null 2>&1
		if [ -s "$T/hw.png" ]; then
			convert "$T/hw.png" -crop 1100x720+170+104 +repage -blur 0x2 "$T/a.png"
			convert tests/fixtures/installer-pages/hardware.png -blur 0x2 "$T/b.png"
			r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
			if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   the Hardware page matches the board (blurred RMSE $r)"
			else echo "  FAIL the Hardware page against the board: RMSE ${r:-?}"; fails=$((fails + 1)); fi
		else
			echo "  FAIL no screenshot of the Hardware page"; fails=$((fails + 1))
		fi
	else
		echo "  skip the Hardware page against the board (no ImageMagick)"
	fi
else
	echo "  skip installer pages (no wish8.6 / xvfb-run)"
fi

[ $fails -eq 0 ] && echo "installer pages: all checks passed"
exit $fails
