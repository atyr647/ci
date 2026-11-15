#!/bin/sh
# Mail's window (U41: apps/mail/main.tcl, ui-*.tcl, compose.tcl): the boards' states are drawn headless under xvfb with
# tests/mail-scene.tcl on the fixture Maildirs (tests/fixtures/maildir) at the boards' time, and each is compared with
# its board (Mail-A-Ledger, -A2-Thread, -A3-Reply, -A4-Search, -A5-Caught-up, -A7-Compose rendered by
# design/tools/render.js and cropped to the 1240 x 780 window at 100,74: tests/mail-fixtures/boards; both blurred,
# RMSE). What keeps a figure above zero: the fixture's own mail where a board shows other text (the list's yesterday
# group, two list conversations where the board has one, the reply board's shortened message), its pictures (tiny
# placeholders, drawn as tiles), square scene corners. Then tests/mail-flow.tcl sends and receives through the app
# against tests/mail-fixture-server.tcl. Without tclsh8.6, wish8.6 or xvfb-run it skips; without ImageMagick the
# comparison skips. Every run has a hard timeout.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1 || ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip mail window (no wish8.6 / tclsh8.6 / xvfb-run)"; exit 0
fi
status=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
app=srcpkgs/ribbon-desktop/files/apps/mail/main.tcl
for sc in ledger thread reply search caught compose; do
	mkdir -p "$T/$sc/home" "$T/$sc/state" "$T/$sc/cache"
	if HOME="$T/$sc/home" XDG_STATE_HOME="$T/$sc/state" XDG_CACHE_HOME="$T/$sc/cache" RIBBON_MAIL_SCENE="$PWD/tests/mail-scene.tcl" \
		RIBBON_SCENE=$sc RIBBON_MAIL_ACCOUNTS="$PWD/tests/mail-accounts-standin.tcl" RIBBON_MAIL_FIXTURES="$T/$sc/fx" \
		RIBBON_MAIL_SHOT="$T/$sc/shot.png" timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" \
		wish8.6 -encoding utf-8 $app </dev/null >"$T/$sc/out" 2>&1 && [ -s "$T/$sc/shot.png" ]
	then echo "  ok   draws the $sc board state"
	else sed 's/^/       /' "$T/$sc/out"; echo "  FAIL draws the $sc board state"; status=1; continue; fi
	if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1; then
		case $sc in ledger) max=0.050 ;; thread) max=0.075 ;; reply) max=0.062 ;; search) max=0.050 ;; caught) max=0.050 ;; compose) max=0.042 ;; esac
		convert "$T/$sc/shot.png" -blur 0x2 "$T/$sc/a.png"
		convert "tests/mail-fixtures/boards/$sc.png" -blur 0x2 "$T/$sc/b.png"
		r=$(compare -metric RMSE "$T/$sc/a.png" "$T/$sc/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < $max) }"; then echo "  ok   the $sc state matches its board (blurred RMSE $r)"
		else echo "  FAIL the $sc state against its board: RMSE ${r:-?} (at most $max)"; status=1; fi
	else
		echo "  skip the $sc board comparison (no ImageMagick)"
	fi
done
# the app's own start (no scene, an empty home): it comes up and stays up, saying nothing, until it is stopped
mkdir -p "$T/app/home"
HOME="$T/app/home" XDG_STATE_HOME="$T/app/state" XDG_CACHE_HOME="$T/app/cache" timeout -k 5 10 \
	xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 $app </dev/null >"$T/app.out" 2>&1
rc=$?
if [ $rc -eq 124 ] && [ ! -s "$T/app.out" ]; then echo "  ok   ribbon-mail starts on an empty home and stays up"
else sed 's/^/       /' "$T/app.out"; echo "  FAIL ribbon-mail starts on an empty home and stays up (exit $rc)"; status=1; fi
mkdir -p "$T/flow/home" "$T/flow/state" "$T/flow/cache"
if HOME="$T/flow/home" XDG_STATE_HOME="$T/flow/state" XDG_CACHE_HOME="$T/flow/cache" RIBBON_MAIL_SCENE="$PWD/tests/mail-flow.tcl" \
	RIBBON_MAIL_ACCOUNTS="$PWD/tests/mail-accounts-standin.tcl" RIBBON_MAIL_FIXTURES="$T/flow/fx" timeout -k 5 200 \
	xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 $app </dev/null >"$T/flow.out" 2>&1 && grep -q "^flow: ok" "$T/flow.out"
then grep '^  ok' "$T/flow.out"; echo "  ok   send and receive through the app (fixture IMAP and SMTP server)"
else sed 's/^/       /' "$T/flow.out"; echo "  FAIL send and receive through the app"; status=1; fi
exit $status
