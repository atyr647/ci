#!/bin/bash
# The Appearance app: its Tcl is complete, it draws the boards' scenes, and
# (tests/appearance-flow.tcl) it saves, imports, exports and applies themes
# and backgrounds through ribbon-theme, with pkexec stubbed and the login
# helper on a fake /etc. Also "ribbon-theme wallpaper" and the helper's
# login options on their own. Run as root (the helper checks that its
# directories are root's); without root or a display, parts are skipped.
set -u
cd "$(dirname "$0")/.." || exit 1
D=$PWD/srcpkgs/ribbon-desktop/files
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
check() { local what=$1; shift; if "$@" >"$T/out" 2>&1; then ok "$what"; else fail "$what"; sed 's/^/       /' "$T/out"; fi; }
refuse() { local what=$1; shift; if "$@" >"$T/out" 2>&1; then fail "$what (was accepted)"; else ok "$what: $(tail -n 1 "$T/out" | sed 's/^ribbon-[a-z-]*: //')"; fi; }

for f in "$D"/appearance/*.tcl tests/appearance-*.tcl; do
	tclsh8.6 /dev/stdin "$f" <<'TCL' || fail "$f: incomplete Tcl"
set fh [open [lindex $argv 0]]; fconfigure $fh -encoding utf-8; set src [read $fh]; close $fh
exit [expr {[info complete $src] ? 0 : 1}]
TCL
done
ok "the app's Tcl is complete"

# stubs: pkexec runs the helper as root on the fake /etc (as polkit would,
# PKEXEC_UID = the caller) and logs the call; the compositor's tools do nothing
B=$T/stubs; mkdir -p "$B"
cat > "$B/pkexec" <<STUB
#!/bin/sh
echo "\$*" >> "$T/pkexec.log"
case "\$1" in /*) ;; *) echo "pkexec: needs an absolute path" >&2; exit 127 ;; esac
PKEXEC_UID=\$(id -u) exec tclsh8.6 "\$@"
STUB
for c in swaybg pkill ribbon-shell-ctl wlr-randr labwc ribbon-conky; do printf '#!/bin/sh\nexit 1\n' > "$B/$c"; done
printf '#!/bin/sh\nexec tclsh8.6 %s "$@"\n' "$D/bin/ribbon-wallpaper" > "$B/ribbon-wallpaper"
chmod +x "$B"/*
# ribbon-wall --probe, stubbed for the sheet's "Add video": a name with "long"
# is 7 minutes, "short" 3 seconds, anything else not a video (as ribbon-wall reports)
cat > "$T/probe" <<'STUB'
#!/bin/sh
case "$2" in
*long*) echo "codec h264 width 640 height 360 fps 2.000 duration 420.000 bytes 1 max 300 ok 0 error too long: 420.0 s, at most 300 s"; exit 1 ;;
*short*) echo "codec h264 width 640 height 360 fps 2.000 duration 3.000 bytes 1 max 300 ok 1"; exit 0 ;;
*) echo "codec - width 0 height 0 fps 0.000 duration 0.000 bytes 0 max 300 ok 0 error no video stream"; exit 1 ;;
esac
STUB
chmod +x "$T/probe"
export PATH=$B:$PATH HOME=$T/home RIBBON_LOGIN_ROOT=$T/root RIBBON_WALL_CMD=$T/probe
unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME WAYLAND_DISPLAY
mkdir -p "$HOME" "$T/root/etc" "$T/pics"
: > "$T/pkexec.log"
tclsh8.6 tests/make-picture.tcl bands 1600 1000 "$T/pics/a.png"
tclsh8.6 tests/make-picture.tcl bands 800 600 "$T/pics/b.png"
RT="bash $D/bin/ribbon-theme"
WC=$HOME/.config/ribbon/wallpaper.conf

echo "ribbon-theme wallpaper"
check "set IMAGE --fit centre" $RT wallpaper set "$T/pics/a.png" --fit centre
check "  MODE, IMAGE, FIT" sh -c "grep -qx MODE=picture '$WC' && grep -qx 'IMAGE=$T/pics/a.png' '$WC' && grep -qx FIT=centre '$WC'"
check "colour #1a2b3c" $RT wallpaper colour '#1a2b3c'
check "  MODE=colour, COLOUR upper case, the picture's FIT kept" sh -c "grep -qx MODE=colour '$WC' && grep -qx 'COLOUR=#1A2B3C' '$WC' && grep -qx FIT=centre '$WC'"
check "slideshow DIR with every option" $RT wallpaper slideshow "$T/pics" --interval 60 --crossfade 2.5 --shuffle no --subdirs yes --fit fill
check "  its keys, and its first picture" sh -c "grep -qx MODE=slideshow '$WC' && grep -qx 'SLIDESHOW_DIR=$T/pics' '$WC' && grep -qx INTERVAL=60 '$WC' &&
	grep -qx CROSSFADE=2.5 '$WC' && grep -qx SHUFFLE=no '$WC' && grep -qx SUBDIRS=yes '$WC' && grep -qx 'IMAGE=$T/pics/a.png' '$WC'"
printf 'not a video' > "$T/v.mp4"
check "video FILE" $RT wallpaper video "$T/v.mp4"
check "  its defaults: pause when fullscreen only, see-through bars (the slideshow's keys kept)" sh -c "grep -qx MODE=video '$WC' &&
	grep -qx 'VIDEO=$T/v.mp4' '$WC' && grep -qx PAUSE_FULLSCREEN=yes '$WC' && grep -qx PAUSE_COVERED=no '$WC' && grep -qx PAUSE_GAME=no '$WC' &&
	grep -qx PAUSE_BATTERY=no '$WC' && grep -qx BARS=see-through '$WC' && grep -qx INTERVAL=60 '$WC'"
check "video with every option" $RT wallpaper video "$T/v.mp4" --pause-fullscreen no --pause-covered yes --pause-game yes --pause-battery yes --bars solid
check "  PAUSE_FULLSCREEN, PAUSE_COVERED, PAUSE_GAME, PAUSE_BATTERY, BARS" sh -c "grep -qx PAUSE_FULLSCREEN=no '$WC' && grep -qx PAUSE_COVERED=yes '$WC' &&
	grep -qx PAUSE_GAME=yes '$WC' && grep -qx PAUSE_BATTERY=yes '$WC' && grep -qx BARS=solid '$WC'"
check "  kept when only one is given" sh -c "$RT wallpaper video '$T/v.mp4' --pause-game no && grep -qx BARS=solid '$WC' && grep -qx PAUSE_FULLSCREEN=no '$WC'"
check "slideshow --interval 30: clamped to a minute" sh -c "$RT wallpaper slideshow '$T/pics' --interval 30 && grep -qx INTERVAL=60 '$WC'"
check "slideshow --interval 9999999: clamped to 7 days" sh -c "$RT wallpaper slideshow '$T/pics' --interval 9999999 && grep -qx INTERVAL=604800 '$WC'"
check "slideshow --interval 7200" sh -c "$RT wallpaper slideshow '$T/pics' --interval 7200 && grep -qx INTERVAL=7200 '$WC'"

check "ribbon: the pattern" sh -c "$RT wallpaper ribbon && grep -qx MODE=pattern '$WC' && grep -qx IMAGE= '$WC'"
check "show" sh -c "$RT wallpaper show | grep -qx MODE=pattern"
refuse "a fit mode that isn't one" $RT wallpaper set "$T/pics/a.png" --fit stretch
refuse "a colour that isn't one" $RT wallpaper colour 'red'
refuse "a colour with a command" $RT wallpaper colour '#112233$(id)'
refuse "a slideshow of a missing folder" $RT wallpaper slideshow "$T/nosuch"
mkdir -p "$T/empty"; refuse "a slideshow with no pictures" $RT wallpaper slideshow "$T/empty"
refuse "an interval that isn't a number" $RT wallpaper slideshow "$T/pics" --interval 1h
refuse "an interval with a fraction" $RT wallpaper slideshow "$T/pics" --interval 1.5
refuse "bars that aren't see-through or solid" $RT wallpaper video "$T/v.mp4" --bars clear
refuse "a pause that isn't yes or no" $RT wallpaper video "$T/v.mp4" --pause-fullscreen maybe
refuse "a video that isn't there" $RT wallpaper video "$T/nosuch.mp4"
check "refused commands left wallpaper.conf alone" sh -c "grep -qx MODE=pattern '$WC' && grep -qx BARS=solid '$WC' && grep -qx INTERVAL=7200 '$WC'"

if [ "$(id -u)" = 0 ]; then
	echo "ribbon-theme login options (pkexec stubbed)"
	LO=$T/root/etc/ribbon/login/options.conf
	check "FIT BLUR DIM CLOCK COLOUR" $RT login options FIT=tile BLUR=12 DIM=25 CLOCK=no 'COLOUR=#204060'
	check "  through pkexec and the helper" grep -q "ribbon-login-theme set-options FIT=tile BLUR=12 DIM=25 CLOCK=no COLOUR=#204060" "$T/pkexec.log"
	check "  options.conf" sh -c "grep -qx FIT=tile '$LO' && grep -qx BLUR=12 '$LO' && grep -qx DIM=25 '$LO' && grep -qx CLOCK=no '$LO' && grep -qx 'COLOUR=#204060' '$LO'"
	check "one option; the others kept" sh -c "$RT login options CLOCK=yes && grep -qx CLOCK=yes '$LO' && grep -qx BLUR=12 '$LO'"
	check "COLOUR= empty: the pattern" sh -c "$RT login options COLOUR= && grep -qx COLOUR= '$LO'"
	check "show lists them" sh -c "$RT login show | grep -qx DIM=25"
	H() { tclsh8.6 "$D/bin/ribbon-login-theme" "$@"; }
	refuse "helper: an unknown option" H set-options SHELL=/bin/sh
	refuse "helper: blur over 64" H set-options BLUR=65
	refuse "helper: dim over 100" H set-options DIM=101
	refuse "helper: a fit mode that isn't one" H set-options FIT=stretch
	refuse "helper: a newline in a value" H set-options "$(printf 'CLOCK=yes\nEVIL=1')"
	refuse "helper: a colour with junk" H set-options 'COLOUR=#204060;id'
	refuse "helper: no options" H set-options
	refuse "ribbon-theme: an unknown option, before pkexec" $RT login options EVIL=1
	check "refused options left options.conf alone" sh -c "! grep -q EVIL '$LO' && grep -qx DIM=25 '$LO'"
	rm -rf "$T/root/etc/ribbon"
else
	echo "  skip login options (the helper needs root)"
fi

# rbnalpha (the sheet's window: see-through corners and shadow); built from the
# tree and loaded as the shell loads it, through RBNALPHA_LIB
echo "rbnalpha"
if [ -f /usr/include/tcl8.6/tk.h ]; then
	RBN=$T/rbn; mkdir -p "$RBN"
	if timeout 300 make -s -C "$D/rbnalpha" O="$RBN" CFLAGS="-O2 -Werror" >"$T/rbn.log" 2>&1; then
		export RBNALPHA_LIB=$RBN/librbnalpha.so
		ok "builds with -Wall -Wextra -Werror"
	else
		fail "rbnalpha does not build"; sed 's/^/       /' "$T/rbn.log"
	fi
else
	echo "  skip rbnalpha (no Tk headers)"
fi

echo "the app"
if command -v xvfb-run >/dev/null 2>&1 && command -v wish8.6 >/dev/null 2>&1; then
	for scheme in graphite fjord moss; do
		for scene in theme colours; do
			h=$T/scene; rm -rf "$h"; tclsh8.6 tests/appearance-fixture.tcl "$h/cfg" $scheme
			check "draws the $scene page in $scheme" timeout 300 env HOME="$h" XDG_CONFIG_HOME="$h/cfg" XDG_CACHE_HOME="$T/cache" \
				RIBBON_APPEARANCE_SCENE=tests/appearance-scene.tcl RIBBON_SCENE=$scene RIBBON_APPEARANCE_EXIT=600 \
				xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/appearance/main.tcl"
		done
	done
	if [ "$(id -u)" = 0 ]; then
		h=$T/flow; tclsh8.6 tests/appearance-fixture.tcl "$h/cfg" graphite
		mkdir -p "$h/tmp"
		if timeout 300 env HOME=$h XDG_CONFIG_HOME=$h/cfg XDG_CACHE_HOME=$T/cache APPEARANCE_TMP=$h/tmp APPEARANCE_PICTURE=$T/pics/a.png APPEARANCE_VIDEO=$T/v.mp4 \
			PKEXEC_LOG=$T/pkexec.log RIBBON_THEME_CMD=$D/bin/ribbon-theme RIBBON_APPEARANCE_SCENE=tests/appearance-flow.tcl \
			xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/appearance/main.tcl" > "$T/flow.out" 2>&1
		then grep -c '  ok ' "$T/flow.out" | sed 's/^/  ok   flow: /; s/$/ checks/'
		else grep -v '  ok ' "$T/flow.out"; fail "the flow"; fi
		# the background sheet: pictures, a slideshow folder, short videos
		bg=$T/bgfx; mkdir -p "$bg/pictures" "$bg/wallpapers" "$bg/videos"
		for k in 1 2 3 4 5; do tclsh8.6 tests/make-picture.tcl bands $((1400 + 100 * k)) 1000 "$bg/pictures/pic$k.png"; done
		for k in 1 2 3; do cp "$bg/pictures/pic$k.png" "$bg/wallpapers/w$k.png"; done
		if command -v ffmpeg >/dev/null 2>&1; then
			ffmpeg -nostdin -v error -y -loop 1 -i "$bg/pictures/pic1.png" -t 3 -r 2 -vf scale=640:-2 -c:v libx264 -pix_fmt yuv420p "$bg/videos/clip.mp4" 2>/dev/null
		fi
		h=$T/sheet; tclsh8.6 tests/appearance-fixture.tcl "$h/cfg" graphite
		rm -rf "$T/root/etc/ribbon"; : > "$T/pkexec.log"
		if timeout 300 env HOME=$h XDG_CONFIG_HOME=$h/cfg XDG_CACHE_HOME=$T/cache XDG_RUNTIME_DIR=$h APPEARANCE_BG=$bg RIBBON_APPEARANCE_STAGE=window \
			PKEXEC_LOG=$T/pkexec.log RIBBON_THEME_CMD=$D/bin/ribbon-theme RIBBON_APPEARANCE_SCENE=tests/appearance-sheet.tcl \
			xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/appearance/main.tcl" > "$T/sheet.out" 2>&1
		then grep -c '  ok ' "$T/sheet.out" | sed 's/^/  ok   background sheet: /; s/$/ checks/'
		else grep -v '  ok ' "$T/sheet.out"; fail "the background sheet"; fi
	else
		echo "  skip the flow and the background sheet (the login helper needs root)"
	fi
else
	echo "  skip the app (no xvfb-run / wish8.6)"
fi

echo "the login screen's look (the greeter, options.conf)"
if command -v xvfb-run >/dev/null 2>&1 && command -v wish8.6 >/dev/null 2>&1 && command -v import >/dev/null 2>&1; then
	greet() { # what to check, then options.conf lines; RIBBON_GREETER_SHOT is $T/g.png
		local what=$1; shift
		rm -rf "$T/g"; mkdir -p "$T/g/etc/ribbon/login" "$T/g/state"
		[ -n "${PIC:-}" ] && cp "$PIC" "$T/g/etc/ribbon/login/background.png"
		printf '%s\n' "$@" > "$T/g/etc/ribbon/login/options.conf"
		RIBBON_GREETER_STATE=$T/g/state RIBBON_GREETER_ETC=$T/g/etc RIBBON_GREETER_TEST=tests/greeter-scene.tcl \
			RIBBON_GREETER_SCENE=password RIBBON_GREETER_SHOT=$T/g.png RIBBON_GREETER_EXIT=4000 \
			timeout 300 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/greeter/main.tcl" -name ribbon-greeter >/dev/null 2>&1
		[ -s "$T/g.png" ] || { fail "$what: no screenshot"; return 1; }
	}
	px() { convert "$T/g.png" -format "%[hex:p{$1,$2}]" info: | cut -c1-6; }
	PIC='' greet "plain colour" 'COLOUR=#204060' DIM=50 CLOCK=no && {
		check "a plain colour, dimmed by half" test "$(px 5 500)" = 102030
		check "  no clock" test "$(convert "$T/g.png" -crop 500x150+470+130 -format %k info:)" = 1
	}
	PIC=$T/pics/b.png greet "a centred picture" FIT=centre 'COLOUR=#204060' BLUR=8 CLOCK=yes && {
		check "a picture, centred on the colour" sh -c "[ \"\$(convert '$T/g.png' -format '%[hex:p{5,5}]' info: | cut -c1-6)\" = 204060 ]"
		check "  inside it, as it is" test "$(px 420 400)" = 3060A0
		check "  blurred at its edge" sh -c "c=\$(convert '$T/g.png' -format '%[hex:p{320,450}]' info: | cut -c1-6); [ \$c != 3060A0 ] && [ \$c != 204060 ]"
		check "  the clock shows" test "$(convert "$T/g.png" -crop 500x150+470+130 -format %k info:)" -gt 2
	}
else
	echo "  skip (no xvfb-run / wish8.6 / ImageMagick)"
fi

[ $fails -eq 0 ] && echo "appearance: all checks passed" || echo "appearance: $fails checks failed"
[ $fails -eq 0 ]
