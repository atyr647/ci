#!/bin/sh
# Settings → About, the page (page-about.tcl) under xvfb with about.tcl's model stood in for
# (tests/settings-about-scene.tcl): drawn in its board's state and compared with the board's crop in
# tests/fixtures/settings-pages/about.png (the page right of the rail; both blurred, RMSE < 0.05), then every control
# pressed: Copy details (the clipboard's text), the name and its pencil (the field, what it takes, Return, Escape, a
# click elsewhere, leaving the page), a refused change, the keyboard's way to both, and the page with few rows and
# with none. Then end to end (tests/settings-about-real-scene.tcl): the page over the real about.tcl on a fake root,
# the real labwc and df, and the name changed by clicks and keys through a stand-in pkexec and the real
# ribbon-hostname-helper (the fake root's /etc/hostname and /etc/hosts), and a dismissed prompt. The logic behind the
# page has its own steps (55-settings-about.sh, 56-settings-hostname-helper.sh).
# Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the About page (no wish8.6 / xvfb-run)"; exit 0
fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip the About page (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
D=$PWD/srcpkgs/ribbon-desktop/files
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"; export TCLLIBPATH
mkdir -p "$T/home/.config/ribbon"; cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"
fails=0
page() { # NAME SCENE-FILE SHOT-VAR RESULT-VAR [RIBBON_SCENE]
	name=$1
	if env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" RIBBON_SETTINGS_SCENE="$PWD/$2" "$3=$T/$name.png" "$4=$T/$name.res" RIBBON_SCENE="${5:-main}" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/out" 2>&1; then
		sed 's/^/  /' "$T/$name.res"
	else
		[ -f "$T/$name.res" ] && sed 's/^/  /' "$T/$name.res"; sed 's/^/       /' "$T/out"; echo "  FAIL the $name page"; fails=$((fails + 1))
	fi
	if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1 && [ -s "$T/$name.png" ]; then
		convert "$T/$name.png" -crop 870x720+400+104 +repage -blur 0x2 "$T/a.png"; convert "tests/fixtures/settings-pages/$name.png" -blur 0x2 "$T/b.png"
		r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   $name matches the board (blurred RMSE $r)"; else echo "  FAIL $name against the board: RMSE ${r:-?}"; fails=$((fails + 1)); fi
	fi
}
page about tests/settings-about-scene.tcl RIBBON_ABOUT_SHOT RIBBON_ABOUT_RESULT
# end to end: the page over the real about.tcl on a fake root, a stand-in pkexec running the real helper on it
R=$T/root
mkdir -p "$R/etc" "$R/proc/sys/kernel"
printf 'NAME="Ribbon OS"\nPRETTY_NAME="Ribbon OS"\nVERSION_ID="0.9"\n' >"$R/etc/os-release"
printf 'ribbon\n' >"$R/etc/hostname"; printf 'ribbon\n' >"$R/proc/sys/kernel/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tribbon\n' >"$R/etc/hosts"
printf '6.18.58_1\n' >"$R/proc/sys/kernel/osrelease"
printf 'processor\t: 0\nmodel name\t: Test(R) Chip(TM) 9000 CPU @ 3.00GHz\n\nprocessor\t: 1\nmodel name\t: Test(R) Chip(TM) 9000 CPU @ 3.00GHz\n' >"$R/proc/cpuinfo"
printf 'MemTotal:       16261032 kB\n' >"$R/proc/meminfo"
# shellcheck disable=SC2016  # the stand-in's own $* and $@
{
	printf '#!/bin/sh\n'
	printf 'echo "$*" >>"%s/pkexec.log"\n' "$T"
	printf 'case ${PKEXEC_SAYS:-run} in\n'
	printf '\trun) RIBBON_HOSTNAME_TEST=1 RIBBON_HOSTNAME_ROOT="%s" exec sh "$@" ;;\n' "$R"
	printf "\t*) echo 'Error executing command as another user: Request dismissed' >&2; exit 126 ;;\n"
	printf 'esac\n'
} >"$T/pkexec"
chmod 755 "$T/pkexec"
if env -u PKEXEC_UID -u WAYLAND_DISPLAY -u PKEXEC_SAYS HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" \
	RIBBON_SETTINGS_SCENE="$PWD/tests/settings-about-real-scene.tcl" RIBBON_ABOUT_ROOT="$R" RIBBON_ABOUT_TEST=1 RIBBON_ABOUT_PKEXEC="$T/pkexec" \
	RIBBON_ABOUT_HELPER="$D/apps/settings/bin/ribbon-hostname-helper" RIBBON_ABOUT_LOG="$T/pkexec.log" \
	RIBBON_ABOUT_SHOT="$T/about-real.png" RIBBON_ABOUT_RESULT="$T/about-real.res" RIBBON_SCENE=main \
	timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/out" 2>&1; then
	sed 's/^/  /' "$T/about-real.res"
else
	[ -f "$T/about-real.res" ] && sed 's/^/  /' "$T/about-real.res"; sed 's/^/       /' "$T/out"; echo "  FAIL the About page, end to end"; fails=$((fails + 1))
fi
[ -n "${SHOTS:-}" ] && cp "$T"/about*.png "$SHOTS"/ 2>/dev/null
[ $fails -eq 0 ] && echo "About page: all checks passed" || { echo "About page: $fails failed"; exit 1; }
