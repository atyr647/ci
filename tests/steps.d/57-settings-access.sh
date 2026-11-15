#!/bin/sh
# Settings → Accessibility (apps/settings/page-access.tcl over access.tcl) under xvfb with a stand-in ribbon-theme
# (tests/settings-access-scene.tcl): the rail item after Sound, drawn in its board's state and compared with the board
# (Settings-A14-Accessibility) in tests/fixtures/settings-pages: the page right of the rail (access.png) and the
# 32 px rail with Accessibility chosen and five updates waiting (rail-access.png), both blurred, RMSE < 0.05; then
# every control used by clicks and keys, access.conf read back, ribbon-theme access run after each change (a failure
# said in the subtitle), and High contrast redrawing Settings in ui.tcl's raised colours. What ribbon-theme does with
# the file is step 24-theme-access. First, with no display, shell/text.tcl's text::access (what Ribbon's own apps and
# the shell read: tests/text-access.tcl). Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if command -v tclsh8.6 >/dev/null 2>&1; then
	if out=$(TMPDIR=${TMPDIR:-/tmp} timeout -k 5 60 tclsh8.6 tests/text-access.tcl "$PWD/srcpkgs/ribbon-desktop/files" 2>&1); then
		echo "  ok   text::access reads access.conf for Ribbon's apps and the shell ($(printf '%s\n' "$out" | grep -c '^  ok ') checks)"
	else
		printf '%s\n' "$out" | sed 's/^/       /'; echo "  FAIL text::access (tests/text-access.tcl)"; exit 1
	fi
fi
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then echo "  skip Settings → Accessibility (no wish8.6 / xvfb-run)"; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
fails=0
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip Settings → Accessibility (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"; export TCLLIBPATH
mkdir -p "$T/s/home/.config/ribbon" "$T/s/cache/kit" "$T/bin"
cp "$D/themes/palettes/ribbon.conf" "$T/s/home/.config/ribbon/palette.conf"
# the board's five updates waiting (kit's own format)
printf '%s\n' 'checked 1700000000 notify 1 updates {{name a short a version 1 new 2 flags {} download 1} {name b short b version 1 new 2 flags {} download 1} {name c short c version 1 new 2 flags {} download 1} {name d short d version 1 new 2 flags {} download 1} {name e short e version 1 new 2 flags {} download 1}}' >"$T/s/cache/kit/updates"
cat >"$T/bin/ribbon-theme" <<SH2
#!/bin/sh
echo "\$*" >> '$T/theme.log'
if [ -n "\${RIBBON_ACC_FAIL:-}" ]; then echo "ribbon-theme: no palette here" >&2; exit 1; fi
exit 0
SH2
chmod +x "$T/bin/ribbon-theme"
: >"$T/theme.log"
if env PATH="$T/bin:$PATH" HOME="$T/s/home" XDG_CONFIG_HOME="$T/s/home/.config" XDG_CACHE_HOME="$T/s/cache" \
	RIBBON_SETTINGS_SCENE="$PWD/tests/settings-access-scene.tcl" RIBBON_ACC_SHOT="$T/access.png" RIBBON_ACC_RESULT="$T/access.res" \
	RIBBON_ACC_LOG="$T/theme.log" timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/out" 2>&1; then
	sed 's/^/  /' "$T/access.res"
else
	[ -f "$T/access.res" ] && sed 's/^/  /' "$T/access.res"; sed 's/^/       /' "$T/out"; echo "  FAIL the Accessibility page"; fails=$((fails + 1))
fi
if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1 && [ -s "$T/access.png" ]; then
	for part in "access 870x720+400+104" "rail-access 230x720+170+104"; do
		set -- $part
		convert "$T/access.png" -crop "$2" +repage -blur 0x2 "$T/a.png"; convert "tests/fixtures/settings-pages/$1.png" -blur 0x2 "$T/b.png"
		r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   $1 matches the board (blurred RMSE $r)"; else echo "  FAIL $1 against the board: RMSE ${r:-?}"; fails=$((fails + 1)); fi
	done
	[ -n "${RIBBON_KEEP_SHOT:-}" ] && cp "$T/access.png" "$RIBBON_KEEP_SHOT"
fi
[ $fails -eq 0 ] && echo "Accessibility: all checks passed" || { echo "Accessibility: $fails failed"; exit 1; }
