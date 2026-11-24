#!/bin/sh
# The volume and brightness keys and their OSD (bin/ribbon-osd, shell/mod-osd.tcl, xdg/labwc/rc.xml; boards OSD-1 to
# OSD-3): tests/shell-osd.tcl in the real shell under xvfb, with wpctl and brightnessctl stood in for, the keys' own
# command run through ribbon-shell-ctl and the FIFO; its three grabs of the pill against the boards' crops in
# tests/fixtures/osd (both blurred, RMSE < 0.05). Then ribbon-osd with no shell running still changes the levels the
# same way, and the keys in rc.xml run it. Then ribbon-lock (tests/test-ribbon-lock.sh).
# Skips the shell part without wish8.6 / xvfb-run / ImageMagick.
# NOT covered: a real PipeWire or backlight, the pill over a fullscreen game under labwc.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
sh tests/test-ribbon-lock.sh || fails=$((fails + 1))
D=$PWD/srcpkgs/ribbon-desktop/files
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
mkdir -p "$T/bin" "$T/stubs" "$T/shots" "$T/home" "$T/cfg/ribbon" "$T/run" "$T/cache"
chmod 700 "$T/run"
# the stand-ins: the level in files under $OSD_STUBS, every call logged; set-volume -l LIMIT clamps to LIMIT as
# wpctl does (wireplumber's do_set_volume: a level already over it is brought down to it)
cat >"$T/bin/wpctl" <<'SH'
#!/bin/sh
S=$OSD_STUBS
echo "$*" >>"$S/calls"
case $1 in
	get-volume) m=; [ "$(cat "$S/mute")" = 1 ] && m=" [MUTED]"; echo "Volume: $(cat "$S/vol")$m" ;;
	set-mute) case $3 in toggle) [ "$(cat "$S/mute")" = 1 ] && echo 0 >"$S/mute" || echo 1 >"$S/mute" ;; *) echo "$3" >"$S/mute" ;; esac ;;
	set-volume)
		shift; lim=9; [ "$1" = -l ] && { lim=$2; shift 2; }
		v=$2; n=${v%%%*}; op=${v#*%}
		awk -v c="$(cat "$S/vol")" -v n="$n" -v op="$op" -v lim="$lim" 'BEGIN { x = (op == "+") ? c + n / 100 : c - n / 100;
			if (x < 0) x = 0; if (x > lim) x = lim; printf "%.2f\n", x }' >"$S/vol.new" && mv "$S/vol.new" "$S/vol" ;;
esac
SH
cat >"$T/bin/brightnessctl" <<'SH'
#!/bin/sh
S=$OSD_STUBS
echo "brightnessctl $*" >>"$S/calls"
q=; [ "$1" = -q ] && { q=1; shift; }
[ "$1" = -m ] && shift
[ "${1:-}" = set ] && { v=${2%\%}; echo "$v" >"$S/bright"; }
p=$(cat "$S/bright")
[ -n "$q" ] || echo "intel_backlight,backlight,$((p * 960 / 100)),$p%,960"
SH
chmod +x "$T/bin/wpctl" "$T/bin/brightnessctl"
printf '%s\n' 0.50 >"$T/stubs/vol"; echo 0 >"$T/stubs/mute"; echo 50 >"$T/stubs/bright"; : >"$T/stubs/calls"

ran=0
for c in wish8.6 xvfb-run import convert compare; do command -v "$c" >/dev/null 2>&1 || { echo "  skip the OSD in the shell (no $c)"; ran=1; }; done
if [ $ran -eq 0 ]; then
	cp "$D/themes/palettes/ribbon.conf" "$T/cfg/ribbon/palette.conf"
	if env HOME="$T/home" XDG_CONFIG_HOME="$T/cfg" XDG_RUNTIME_DIR="$T/run" XDG_CACHE_HOME="$T/cache" \
		PATH="$T/bin:$D/bin:$PATH" OSD_STUBS="$T/stubs" OSD_SHOTS="$T/shots" OSD_BIN="$D/bin" RIBBON_SHELL_TEST=tests/shell-osd.tcl \
		timeout -k 5 90 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/shell/main.tcl" -name ribbon-shell >"$T/out" 2>&1 &&
		grep -q '^osd: all checks passed$' "$T/out"; then
		sed -n 's/^  ok   /  ok   OSD: /p' "$T/out"
	else
		sed 's/^/       /' "$T/out"; echo "  FAIL the OSD in the shell (tests/shell-osd.tcl)"; fails=$((fails + 1))
	fi
	for s in volume:OSD-1-Volume muted:OSD-2-Muted brightness:OSD-3-Brightness; do
		shot=${s%%:*}; b=${s#*:}
		[ -s "$T/shots/$shot.png" ] || { echo "  FAIL no grab of the $shot pill"; fails=$((fails + 1)); continue; }
		convert "$T/shots/$shot.png" -blur 0x2 "$T/a.png"; convert "tests/fixtures/osd/$b.png" -blur 0x2 "$T/b.png"
		r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   the $shot pill matches $b (blurred RMSE $r)"
		else echo "  FAIL the $shot pill against $b: RMSE ${r:-?}"; fails=$((fails + 1)); fi
	done
fi

# no shell: ribbon-osd changes the levels itself (ribbon-shell-ctl finds no FIFO)
: >"$T/stubs/calls"; printf '0.98\n' >"$T/stubs/vol"; echo 1 >"$T/stubs/mute"; echo 4 >"$T/stubs/bright"
o() { env HOME="$T/home" XDG_CONFIG_HOME="$T/none" XDG_RUNTIME_DIR="$T/empty" PATH="$T/bin:$D/bin:$PATH" OSD_STUBS="$T/stubs" sh "$D/bin/ribbon-osd" "$@"; }
o volume +5; o brightness -5
[ "$(cat "$T/stubs/vol")" = 1.00 ] && [ "$(cat "$T/stubs/mute")" = 0 ] && [ "$(cat "$T/stubs/bright")" = 1 ] &&
	echo "  ok   without the shell ribbon-osd still unmutes, stops at 100 % and keeps the backlight at 1 %" ||
	{ echo "  FAIL ribbon-osd without the shell: vol $(cat "$T/stubs/vol") mute $(cat "$T/stubs/mute") bright $(cat "$T/stubs/bright")"; cat "$T/stubs/calls"; fails=$((fails + 1)); }
printf '1.20\n' >"$T/stubs/vol"; o volume +5
[ "$(cat "$T/stubs/vol")" = 1.20 ] && echo "  ok   without the shell a key up leaves a level already over 100 % where it is" ||
	{ echo "  FAIL ribbon-osd volume +5 at 120 % without Louder than 100%: vol $(cat "$T/stubs/vol")"; fails=$((fails + 1)); }
o volume mute; [ "$(cat "$T/stubs/mute")" = 1 ] || { echo "  FAIL ribbon-osd volume mute without the shell"; fails=$((fails + 1)); }
if o volume loud 2>/dev/null; then echo "  FAIL ribbon-osd takes 'volume loud'"; fails=$((fails + 1)); fi

# the keys run it
RC=$D/xdg/labwc/rc.xml
if command -v xmllint >/dev/null 2>&1; then
	e=
	for kv in "XF86AudioRaiseVolume|ribbon-osd volume +5" "XF86AudioLowerVolume|ribbon-osd volume -5" "XF86AudioMute|ribbon-osd volume mute" \
		"XF86MonBrightnessUp|ribbon-osd brightness +5" "XF86MonBrightnessDown|ribbon-osd brightness -5"; do
		k=${kv%%|*}; want=${kv#*|}
		[ "$(xmllint --xpath "string(//keyboard/keybind[@key='$k']/action/@command)" "$RC")" = "$want" ] || e="$e $k"
	done
	[ -z "$e" ] && echo "  ok   the volume and brightness keys run ribbon-osd" || { echo "  FAIL rc.xml:$e do not run ribbon-osd"; fails=$((fails + 1)); }
fi
[ $fails -eq 0 ] && echo "  ok   the lock screen and the OSD" || { echo "  FAIL the lock screen and the OSD: $fails failed"; exit 1; }
