#!/bin/sh
# Mail's accounts (U42: apps/mail/accounts.tcl, secrets.tcl, ui-account.tcl) and what sync keeps on this computer:
#   tests/mail-secrets.tcl        the Secret Service client against tests/mail-secret-service.tcl on a private bus
#                                 (save, read, replace, clear, a locked collection's prompt, a dismissed prompt, no
#                                 default collection, no provider); RIBBON_TEST_GNOME_KEYRING=1 adds a real gnome-keyring
#   tests/mail-accounts.tcl       the accounts file, the checks, autoconfig / SRV / MX / ISPDB lookups against fixture
#                                 HTTP and DNS servers, Test connection against tests/mail-fixture-server.tcl
#   tests/mail-sync-local.tcl     non-ASCII labels stay local; a sent copy made offline survives a quit and reaches
#                                 the server's Sent at the next start; no second session during a password lookup
#   the sheet (Mail-A6-Account)   drawn under xvfb (tests/mail-account-scene.tcl) and compared with the board's crop
#                                 (tests/mail-fixtures/boards/account.png; both blurred, RMSE), then
#                                 tests/mail-account-flow.tcl adds an account through the window end to end
# Skips without tclsh8.6, dbus-daemon, or (for the window) wish8.6 / xvfb-run. Every run has a hard timeout.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1 || ! command -v dbus-daemon >/dev/null 2>&1; then
	echo "  skip mail accounts (no tclsh8.6 / dbus-daemon)"; exit 0
fi
T=$(mktemp -d)
pids=
trap 'for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "${T:?}"' EXIT
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip mail accounts (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
D=$PWD/srcpkgs/ribbon-desktop/files
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"; export TCLLIBPATH
# the session's locale (a password with non-ASCII letters goes out as UTF-8 under Tcl 8.6.14 only in a UTF-8 locale)
LANG=C.UTF-8; LC_ALL=C.UTF-8; export LANG LC_ALL
status=0
run() { # NAME FILE SECONDS
	if TMPDIR=$T timeout -k 5 "$3" tclsh8.6 "$2" </dev/null >"$T/$1.out" 2>&1 && grep -q "^$1: ok" "$T/$1.out"
	then grep '^  ok' "$T/$1.out"
	else sed 's/^/       /' "$T/$1.out"; echo "  FAIL $1"; status=1; fi
}
run secrets tests/mail-secrets.tcl 90
run accounts tests/mail-accounts.tcl 150
run sync-local tests/mail-sync-local.tcl 150

if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the Add an account sheet (no wish8.6 / xvfb-run)"; exit $status
fi
app=srcpkgs/ribbon-desktop/files/apps/mail/main.tcl
mkdir -p "$T/sc/home" "$T/sc/state" "$T/sc/cache" "$T/sc/config"
if HOME="$T/sc/home" XDG_STATE_HOME="$T/sc/state" XDG_CACHE_HOME="$T/sc/cache" XDG_CONFIG_HOME="$T/sc/config" \
	RIBBON_MAIL_SCENE="$PWD/tests/mail-account-scene.tcl" RIBBON_MAIL_FIXTURES="$T/sc/fx" RIBBON_MAIL_SHOT="$T/sc/shot.png" \
	timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 $app </dev/null >"$T/sc.out" 2>&1 && [ -s "$T/sc/shot.png" ]
then
	echo "  ok   draws the Add an account sheet"
	if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1; then
		convert "$T/sc/shot.png" -blur 0x2 "$T/a.png"
		convert tests/mail-fixtures/boards/account.png -blur 0x2 "$T/b.png"
		r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.040) }"; then echo "  ok   the window with the sheet matches Mail-A6-Account (blurred RMSE $r)"
		else echo "  FAIL the window with the sheet against Mail-A6-Account: RMSE ${r:-?} (at most 0.040)"; status=1; fi
		convert "$T/sc/shot.png" -crop 700x614+270+84 +repage -blur 0x2 "$T/a2.png"
		convert tests/mail-fixtures/boards/account.png -crop 700x614+270+84 +repage -blur 0x2 "$T/b2.png"
		r=$(compare -metric RMSE "$T/a2.png" "$T/b2.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.015) }"; then echo "  ok   the sheet itself matches the board's (blurred RMSE $r)"
		else echo "  FAIL the sheet against the board's: RMSE ${r:-?} (at most 0.015)"; status=1; fi
	else
		echo "  skip the sheet's board comparison (no ImageMagick)"
	fi
else sed 's/^/       /' "$T/sc.out"; echo "  FAIL draws the Add an account sheet"; status=1; fi

# the sheet's answers (Mail-A15-Tested, Mail-A16-Refused): the window against the board, and the foot alone
for sc in tested refused; do
	mkdir -p "$T/$sc/home" "$T/$sc/state" "$T/$sc/cache" "$T/$sc/config"
	if HOME="$T/$sc/home" XDG_STATE_HOME="$T/$sc/state" XDG_CACHE_HOME="$T/$sc/cache" XDG_CONFIG_HOME="$T/$sc/config" RIBBON_SCENE=$sc \
		RIBBON_MAIL_SCENE="$PWD/tests/mail-account-scene.tcl" RIBBON_MAIL_FIXTURES="$T/$sc/fx" RIBBON_MAIL_SHOT="$T/$sc/shot.png" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 $app </dev/null >"$T/$sc.out" 2>&1 && [ -s "$T/$sc/shot.png" ]
	then
		if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1; then
			convert "$T/$sc/shot.png" -blur 0x2 "$T/$sc/a.png"
			convert "tests/mail-fixtures/boards/account-$sc.png" -blur 0x2 "$T/$sc/b.png"
			r=$(compare -metric RMSE "$T/$sc/a.png" "$T/$sc/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
			convert "$T/$sc/shot.png" -crop 700x72+270+626 +repage -blur 0x2 "$T/$sc/a2.png"
			convert "tests/mail-fixtures/boards/account-$sc.png" -crop 700x72+270+626 +repage -blur 0x2 "$T/$sc/b2.png"
			r2=$(compare -metric RMSE "$T/$sc/a2.png" "$T/$sc/b2.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
			if awk "BEGIN { exit !(${r:-1} < 0.040 && ${r2:-1} < 0.030) }"; then
				echo "  ok   the sheet's answer ($sc) matches its board (blurred RMSE $r, the foot $r2)"
			else echo "  FAIL the sheet's answer ($sc) against its board: RMSE ${r:-?} (at most 0.040), the foot ${r2:-?} (at most 0.030)"; status=1; fi
		else echo "  skip the $sc board comparison (no ImageMagick)"; fi
	else sed 's/^/       /' "$T/$sc.out"; echo "  FAIL draws the sheet's answer ($sc)"; status=1; fi
done

# a private bus with the Secret Service stand-in for the window's run
dbus-daemon --config-file="$PWD/tests/mail-fixtures/session-bus.conf" --nofork --print-address=1 >"$T/bus" 2>/dev/null &
pids="$pids $!"
i=0; while [ ! -s "$T/bus" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
DBUS_SESSION_BUS_ADDRESS=$(head -n 1 "$T/bus"); export DBUS_SESSION_BUS_ADDRESS
tclsh8.6 tests/mail-secret-service.tcl >"$T/ss" 2>&1 </dev/null &
pids="$pids $!"
i=0; while ! grep -q ready "$T/ss" 2>/dev/null && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
mkdir -p "$T/fl/home" "$T/fl/state" "$T/fl/cache"
if HOME="$T/fl/home" XDG_STATE_HOME="$T/fl/state" XDG_CACHE_HOME="$T/fl/cache" RIBBON_MAIL_SCENE="$PWD/tests/mail-account-flow.tcl" \
	RIBBON_MAIL_FIXTURES="$T/fl/fx" timeout -k 5 200 xvfb-run -a -s "-screen 0 1440x900x24" \
	wish8.6 -encoding utf-8 $app </dev/null >"$T/fl.out" 2>&1 && grep -q "^account-flow: ok" "$T/fl.out"
then grep '^  ok' "$T/fl.out"; echo "  ok   an account is added through the window (Secret Service stand-in, fixture servers)"
else sed 's/^/       /' "$T/fl.out"; echo "  FAIL adding an account through the window"; status=1; fi
exit $status
