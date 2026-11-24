#!/bin/sh
# Settings → Language and region. The logic (apps/settings/locale.tcl) with no display (tests/settings-locale.tcl):
# the UTF-8 locales offered and their names, the language and the formats from the account's locale.conf, the system's
# file and the environment, every change written (other lines kept, atomic, an unwritable place said), the formats
# following the language, and the examples from glibc's real data for en_GB, en_US and de_DE (tests/fixtures/locale,
# made with localedef). Then the page (page-language.tcl) under xvfb with the real locale.tcl over a `locale` stand-in
# (tests/settings-language-scene.tcl): drawn in its board's state and compared with the board's crop in
# tests/fixtures/settings-pages (the page right of the rail; both blurred, RMSE), its dropdowns used by clicks and keys
# and the file read back. Skips without tclsh8.6 (and the page without wish8.6 / xvfb-run).
# "From your next login" compares the file with the session's own LANG and LC_TIME, so it survives reopening Settings.
# LANG reaches the session through greetd's start_session of sessions/ribbon.desktop (Exec=ribbon-session), whose
# script reads /etc/locale.conf then the account's locale.conf (tests/test-session-scripts.sh); checked below that the
# entry still runs ribbon-session and that the greeter passes no LANG of its own.
# NOT covered: a real glibc's `locale -a`.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then echo "  skip Settings → Language and region (no tclsh8.6)"; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
FX=$PWD/tests/fixtures/locale
fails=0
mkdir -p "$T/home" "$T/cfg" "$T/tmp"
if env HOME="$T/home" XDG_CONFIG_HOME="$T/cfg" TMPDIR="$T/tmp" timeout -k 5 60 tclsh8.6 -encoding utf-8 tests/settings-locale.tcl "$D" "$FX" >"$T/loc.out" 2>&1; then
	echo "  ok   Settings → Language and region: the logic ($(grep -c '^  ok ' "$T/loc.out") checks)"
else
	grep -v '^  ok ' "$T/loc.out" | sed 's/^/       /'; echo "  FAIL Settings → Language and region: the logic"; fails=$((fails + 1))
fi
if grep -qx 'Exec=ribbon-session' "$D/sessions/ribbon.desktop" && ! grep -q 'LANG' "$D/greeter/system.tcl" &&
	grep -q 'acct_locale=' "$D/bin/ribbon-session" && grep -q 'export "\$k=\$v"' "$D/bin/ribbon-session"; then
	echo "  ok   LANG reaches the session: greetd starts ribbon-session (ribbon.desktop), which exports it from locale.conf"
else
	echo "  FAIL the Ribbon session entry no longer runs ribbon-session, or the greeter sets LANG itself"; fails=$((fails + 1))
fi
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the Language and region page (no wish8.6 / xvfb-run)"
	[ $fails -eq 0 ] && exit 0 || exit 1
fi
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip the Language and region page (no unix_extra, no Tcl headers to build it)"; [ $fails -eq 0 ] && exit 0 || exit 1; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"; export TCLLIBPATH
mkdir -p "$T/s/home/.config/ribbon" "$T/s/etc" "$T/bin"
cp "$D/themes/palettes/ribbon.conf" "$T/s/home/.config/ribbon/palette.conf"
printf 'LANG=en_GB.UTF-8\n' >"$T/s/etc/locale.conf"
printf '%s\n' C C.utf8 POSIX de_DE.utf8 en_CA.utf8 en_GB.utf8 en_US.utf8 >"$T/list"
cat >"$T/bin/locale" <<SH
#!/bin/sh
if [ "\$1" = -a ]; then cat '$T/list'; exit 0; fi
[ -f '$FX'/"\$LC_ALL" ] || exit 1
cat '$FX'/"\$LC_ALL"
SH
chmod +x "$T/bin/locale"
# the session's own LANG, as ribbon-session sets it from the system's locale.conf at login
if env -u LC_ALL -u LC_TIME LANG=en_GB.UTF-8 PATH="$T/bin:$PATH" HOME="$T/s/home" XDG_CONFIG_HOME="$T/s/home/.config" XDG_CACHE_HOME="$T/s/cache" TZ=UTC \
	RIBBON_LOCALE_TEST=1 RIBBON_LOCALE_SYSCONF="$T/s/etc/locale.conf" RIBBON_LOCALE_NOW=1794048120 \
	RIBBON_SETTINGS_SCENE="$PWD/tests/settings-language-scene.tcl" RIBBON_LANG_SHOT="$T/language.png" RIBBON_LANG_RESULT="$T/language.res" \
	timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/out" 2>&1; then
	sed 's/^/  /' "$T/language.res"
else
	[ -f "$T/language.res" ] && sed 's/^/  /' "$T/language.res"; sed 's/^/       /' "$T/out"; echo "  FAIL the Language and region page"; fails=$((fails + 1))
fi
if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1 && [ -s "$T/language.png" ]; then
	convert "$T/language.png" -crop 870x720+400+104 +repage -blur 0x2 "$T/a.png"; convert tests/fixtures/settings-pages/language.png -blur 0x2 "$T/b.png"
	r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
	if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   language matches the board (blurred RMSE $r)"; else echo "  FAIL language against the board: RMSE ${r:-?}"; fails=$((fails + 1)); fi
	[ -n "${RIBBON_KEEP_SHOT:-}" ] && cp "$T/language.png" "$RIBBON_KEEP_SHOT"
fi
[ $fails -eq 0 ] && echo "Language and region: all checks passed" || { echo "Language and region: $fails failed"; exit 1; }
