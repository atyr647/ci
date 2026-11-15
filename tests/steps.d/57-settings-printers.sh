#!/bin/sh
# Settings → Printers: the page (page-printers.tcl) under xvfb with the REAL printers.tcl over a stand-in CUPS
# (tests/fixtures/cups/fake-cups as lpstat, lpq, lpoptions, lp, cancel, lpadmin, ippfind) and the REAL
# ribbon-printers-helper behind a pkexec stand-in (tests/settings-printers-scene.tcl): drawn in its board's state and
# compared with the board's crop in tests/fixtures/settings-pages (the page right of the rail; both blurred, RMSE), then
# used by clicks and keys (cancel a job, two-sided, paper, the default, the test page, add a nearby printer, remove one,
# a refused prompt, CUPS not running). Then the helper alone: what it refuses before lpadmin runs, and that it will not
# run as anyone but root outside a test. Skips without tclsh8.6, wish8.6 or xvfb-run.
# NOT covered: a real cupsd and printer (CI has neither), a real polkit prompt.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then echo "  skip Settings → Printers (no tclsh8.6)"; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
H=$D/apps/settings/bin/ribbon-printers-helper
fails=0
mkdir -p "$T/bin" "$T/cups"
for p in lpstat lpq lpoptions lp cancel lpadmin ippfind; do ln -s "$PWD/tests/fixtures/cups/fake-cups" "$T/bin/$p"; done
: >"$T/cups/log"
# the helper alone: refusals (exit 2, lpadmin never run), and root only outside a test
ok_h() { # WHAT WANT-EXIT ARGS...
	what=$1 want=$2; shift 2
	env -u PKEXEC_UID RIBBON_PRINTERS_TEST=1 RIBBON_PRINTERS_LPADMIN="$T/bin/lpadmin" FAKE_CUPS="$T/cups" sh "$H" "$@" >/dev/null 2>&1
	got=$?
	if [ "$got" = "$want" ]; then echo "  ok   the helper: $what (exit $got)"; else echo "  FAIL the helper: $what (exit $got, want $want)"; fails=$((fails + 1)); fi
}
printf 'printers {} default {} jobs {} opts {} nearby {}' >"$T/cups/state"
ok_h "a name with a space is refused" 2 add "a b" ipp://h.local/ipp/print
ok_h "a name with a ; is refused" 2 remove "a;b"
ok_h "an address that is not ipp:// is refused" 2 add P file:///etc/shadow
ok_h "an address with a quote or a space is refused" 2 add P "ipp://h.local/a b"
ok_h "another verb is refused" 2 delete P
if [ -s "$T/cups/log" ]; then echo "  FAIL the helper ran lpadmin for a refused call"; fails=$((fails + 1)); else echo "  ok   the helper never ran lpadmin for those"; fi
if [ "$(id -u)" != 0 ]; then
	if env -u RIBBON_PRINTERS_TEST sh "$H" remove P >/dev/null 2>&1; then echo "  FAIL the helper ran as a user outside a test"; fails=$((fails + 1)); else echo "  ok   the helper will not run as a user outside a test"; fi
fi
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the Printers page (no wish8.6 / xvfb-run)"; [ $fails -eq 0 ] && exit 0 || exit 1
fi
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip the Printers page (no unix_extra, no Tcl headers to build it)"; [ $fails -eq 0 ] && exit 0 || exit 1; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"; export TCLLIBPATH
mkdir -p "$T/home/.config/ribbon"; cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"
cat >"$T/cups/state" <<'ST'
printers {
	Brother_HL_L2350DW {label {Brother HL-L2350DW} state idle reason {} uri ipp://BRW1C2D.local/ipp/print reasons none}
	Canon_MF4410 {label {Canon MF4410} state disabled reason {Unable to locate printer "canon.local".} uri ipp://canon.local/ipp/print reasons offline-report}
	HP_OfficeJet_8010 {label {HP OfficeJet 8010} state idle reason {} uri ipps://HPB8D1.local/ipp/print reasons none}
} default Brother_HL_L2350DW
jobs {{printer Brother_HL_L2350DW rank active id 12 file {Report Q3.pdf}} {printer Brother_HL_L2350DW rank 1st id 13 file {Boarding pass.pdf}}}
opts {Brother_HL_L2350DW {PageSize A4 Duplex DuplexNoTumble} Canon_MF4410 {PageSize A4 Duplex None} HP_OfficeJet_8010 {PageSize Letter Duplex None}}
nearby {{ipp://EPSON-ET-2850.local:631/ipp/print {Epson ET-2850}} {ipp://HPLJ-M110w.local:631/ipp/print {HP LaserJet M110w}}}
ST
: >"$T/cups/log"
cat >"$T/pkexec" <<SH
#!/bin/sh
if [ -n "\${FAKE_PKEXEC_REFUSE:-}" ]; then echo "Error executing command as another user: Not authorized" >&2; exit 127; fi
exec env -u PKEXEC_UID RIBBON_PRINTERS_TEST=1 RIBBON_PRINTERS_LPADMIN='$T/bin/lpadmin' "\$@"
SH
chmod +x "$T/pkexec"
: >"$T/testprint"
if env PATH="$T/bin:$PATH" HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" FAKE_CUPS="$T/cups" \
	RIBBON_PRINTERS_TEST=1 RIBBON_PRINTERS_PKEXEC="$T/pkexec" RIBBON_PRINTERS_HELPER="$H" RIBBON_PRINTERS_TESTPAGE="$T/testprint" \
	RIBBON_SETTINGS_SCENE="$PWD/tests/settings-printers-scene.tcl" RIBBON_PRN_SHOT="$T/printers.png" RIBBON_PRN_RESULT="$T/printers.res" \
	timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/out" 2>&1; then
	sed 's/^/  /' "$T/printers.res"
else
	[ -f "$T/printers.res" ] && sed 's/^/  /' "$T/printers.res"; sed 's/^/       /' "$T/out"; echo "  FAIL the Printers page"; fails=$((fails + 1))
fi
if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1 && [ -s "$T/printers.png" ]; then
	convert "$T/printers.png" -crop 870x720+400+104 +repage -blur 0x2 "$T/a.png"; convert tests/fixtures/settings-pages/printers.png -blur 0x2 "$T/b.png"
	r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
	if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   printers matches the board (blurred RMSE $r)"; else echo "  FAIL printers against the board: RMSE ${r:-?}"; fails=$((fails + 1)); fi
	[ -n "${RIBBON_KEEP_SHOT:-}" ] && cp "$T/printers.png" "$RIBBON_KEEP_SHOT"
fi
[ $fails -eq 0 ] && echo "Printers: all checks passed" || { echo "Printers: $fails failed"; exit 1; }
