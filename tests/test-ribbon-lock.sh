#!/bin/sh
# ribbon-lock (srcpkgs/ribbon-desktop/files/bin/ribbon-lock): the swaylock config it writes at every lock, for every
# built-in palette: the boards' colours (Lock-1 to Lock-4: inside BAR, ring PILL, a key ACCENT, backspace MUTED,
# verifying FG, wrong ACCENT, no border lines), their geometry (gen_lock_osd.py's R, T, FS), the background
# (DESK_BOTTOM; the desktop's picture with its layout through a plain-named link; a plain colour; nothing for the
# pattern or a picture that is gone), only options swaylock 1.7 knows; then a lock with a stand-in swaylock: it is
# run with -f and -C, the file private and in XDG_RUNTIME_DIR, a hand-written ~/.config/swaylock/config left alone and
# used instead; and the power menu, Super+L and the idle timer all lock through it.
# NOT covered: swaylock itself drawing it (not installed here; it needs ext-session-lock on a real session) and PAM.
set -u
cd "$(dirname "$0")/.." || exit 1
D=srcpkgs/ribbon-desktop/files
L=$PWD/$D/bin/ribbon-lock
fails=0
ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
export RIBBON_THEMES="$PWD/$D/themes"

# swaylock 1.7's long options (swaylock(1), its config file takes them without the dashes)
KNOWN="color image scaling tiling daemonize ignore-empty-password show-failed-attempts show-keyboard-layout
hide-keyboard-layout disable-caps-lock-text indicator-caps-lock indicator-idle-visible indicator-radius
indicator-thickness indicator-x-position indicator-y-position font font-size bs-hl-color caps-lock-bs-hl-color
caps-lock-key-hl-color inside-color inside-clear-color inside-caps-lock-color inside-ver-color inside-wrong-color
key-hl-color layout-bg-color layout-border-color layout-text-color line-color line-clear-color line-caps-lock-color
line-ver-color line-wrong-color line-uses-inside line-uses-ring ring-color ring-clear-color ring-caps-lock-color
ring-ver-color ring-wrong-color separator-color text-color text-clear-color text-caps-lock-color text-ver-color
text-wrong-color"
# the value of KEY in a config
get() { sed -n "s/^$1=//p" "$2"; }
pv() { sed -n "s/^$1=#\{0,1\}//p" "$2" | tail -n 1 | tr -d '"'; }   # a palette's colour, without #

# the boards' geometry
geo=$(sed -n 's/^R, T, FS = \([0-9]*\), \([0-9]*\), \([0-9]*\).*/\1 \2 \3/p' design/tools/gen_lock_osd.py)
[ -n "$geo" ] || bad "gen_lock_osd.py has no R, T, FS line"
set -- $geo
R=${1:-?}; TH=${2:-?}; FS=${3:-?}

np=0
for p in "$D"/themes/palettes/*.conf; do
	name=$(basename "$p" .conf)
	mkdir -p "$T/$name/ribbon"; cp "$p" "$T/$name/ribbon/palette.conf"
	c=$T/$name.conf
	XDG_CONFIG_HOME=$T/$name sh "$L" --config >"$c" || { bad "$name: ribbon-lock --config failed"; continue; }
	np=$((np + 1))
	e=""
	for kv in "inside-color BAR" "inside-ver-color BAR" "inside-wrong-color BAR" "inside-clear-color BAR" "ring-color PILL" \
		"ring-clear-color PILL" "key-hl-color ACCENT" "bs-hl-color MUTED" "ring-ver-color FG" "text-ver-color FG" "text-color FG" \
		"ring-wrong-color ACCENT" "text-wrong-color ACCENT" "color DESK_BOTTOM" "layout-text-color FG"; do
		set -- $kv
		want=$(pv "$2" "$p")
		[ "$(get "$1" "$c")" = "$want" ] || e="$e $1=$(get "$1" "$c")(want $2 $want)"
	done
	for k in line-color line-ver-color line-wrong-color line-clear-color line-caps-lock-color separator-color layout-border-color; do
		[ "$(get "$k" "$c")" = 00000000 ] || e="$e $k=$(get "$k" "$c")"
	done
	[ "$(get indicator-radius "$c")" = "$R" ] && [ "$(get indicator-thickness "$c")" = "$TH" ] && [ "$(get font-size "$c")" = "$FS" ] &&
		[ "$(get font "$c")" = Inter ] || e="$e geometry"
	grep -qx indicator-idle-visible "$c" || e="$e idle-visible"
	grep -q '#' "$c" && [ "$(grep -c '#' "$c")" -gt 1 ] && e="$e a '#' in a value"
	grep -q '^image=' "$c" && e="$e an image with no wallpaper.conf"
	[ -z "$e" ] && ok "$name: the boards' colours and geometry" || bad "$name:$e"
	bad_keys=$(grep -v '^#' "$c" | sed 's/=.*//' | while read -r k; do printf '%s\n' $KNOWN | grep -qx -- "$k" || echo "$k"; done)
	[ -z "$bad_keys" ] || bad "$name: options swaylock does not know: $bad_keys"
done
[ "$np" -ge 3 ] && ok "every built-in palette ($np) gives a config of options swaylock knows" || bad "only $np palettes checked"

# no palette.conf yet: the system's default (Graphite)
mkdir -p "$T/none"
XDG_CONFIG_HOME=$T/none sh "$L" --config >"$T/none.conf"
[ "$(get key-hl-color "$T/none.conf")" = "$(pv ACCENT "$D/themes/palettes/ribbon.conf")" ] &&
	ok "without palette.conf the system's default palette is used" || bad "no palette.conf: key-hl-color $(get key-hl-color "$T/none.conf")"
# a malformed colour falls back to Graphite's, never into the file
mkdir -p "$T/badpal/ribbon"; sed 's/^ACCENT=.*/ACCENT=red; rm -rf ~/' "$D/themes/palettes/ribbon-fjord.conf" >"$T/badpal/ribbon/palette.conf"
XDG_CONFIG_HOME=$T/badpal sh "$L" --config >"$T/badpal.conf"
[ "$(get key-hl-color "$T/badpal.conf")" = FF7A59 ] && ! grep -q 'rm -rf' "$T/badpal.conf" &&
	ok "a malformed palette colour falls back to Graphite's" || bad "a malformed ACCENT: $(get key-hl-color "$T/badpal.conf")"

# ---- a lock, with a stand-in swaylock --------------------------------------------------------------------------
mkdir -p "$T/bin" "$T/run" "$T/h/.config/ribbon" "$T/pics"
chmod 700 "$T/run"
cat >"$T/bin/swaylock" <<'SH'
#!/bin/sh
echo "$*" >>"$LOCKLOG"
while [ $# -gt 0 ]; do [ "$1" = -C ] && cp "$2" "$LOCKLOG.conf" && ls -l "$2" | cut -c1-10 >"$LOCKLOG.mode"; shift; done
exit 0
SH
chmod +x "$T/bin/swaylock"
cp "$D/themes/palettes/ribbon-moss.conf" "$T/h/.config/ribbon/palette.conf"
lock() { : >"$T/log"; rm -f "$T/log.conf"; env HOME="$T/h" XDG_CONFIG_HOME="$T/h/.config" XDG_RUNTIME_DIR="$T/run" LOCKLOG="$T/log" PATH="$T/bin:$PATH" sh "$L"; }
wp() { printf '%s\n' "$@" >"$T/h/.config/ribbon/wallpaper.conf"; }

lock || bad "ribbon-lock exited with an error"
[ "$(cat "$T/log")" = "-f -C $T/run/ribbon-swaylock.conf" ] && ok "it runs swaylock -f -C \$XDG_RUNTIME_DIR/ribbon-swaylock.conf" || bad "swaylock ran with: $(cat "$T/log")"
[ "$(cat "$T/log.mode" 2>/dev/null)" = "-rw-------" ] && ok "the config is private (0600)" || bad "the config's mode: $(cat "$T/log.mode" 2>/dev/null)"
[ "$(get ring-color "$T/log.conf")" = "$(pv PILL "$D/themes/palettes/ribbon-moss.conf")" ] && ok "it locks in the active palette's colours (Moss)" || bad "ring-color $(get ring-color "$T/log.conf")"
find "$T/run" -maxdepth 1 -name '*.conf.*' | grep -q . && bad "a temporary config is left in XDG_RUNTIME_DIR" || ok "no temporary file is left behind"

# the desktop's picture, through a link of a plain name (swaylock runs the path through wordexp)
pic='my $(touch PWNED) pic.png'
printf 'x' >"$T/pics/$pic"
wp MODE=picture "IMAGE=$T/pics/$pic" FIT=fit 'COLOUR=#102030'
(cd "$T" && lock)
[ "$(get image "$T/log.conf")" = ":$T/run/ribbon-lock-background" ] && [ "$(readlink "$T/run/ribbon-lock-background")" = "$T/pics/$pic" ] &&
	ok "the desktop's picture is shown, through a plain-named link" || bad "image=$(get image "$T/log.conf") -> $(readlink "$T/run/ribbon-lock-background")"
[ "$(get scaling "$T/log.conf")" = fit ] && [ "$(get color "$T/log.conf")" = 102030 ] && ok "laid out as FIT says, COLOUR around it" || bad "scaling=$(get scaling "$T/log.conf") color=$(get color "$T/log.conf")"
[ ! -e "$T/PWNED" ] && ok "nothing in the picture's name is run" || bad "the picture's name ran a command"
for f in "fill fill" "centre center" "tile tile"; do
	set -- $f
	wp MODE=slideshow "IMAGE=$T/pics/$pic" "FIT=$1"; lock
	[ "$(get scaling "$T/log.conf")" = "$2" ] || bad "FIT=$1 gives scaling=$(get scaling "$T/log.conf"), not $2"
done
ok "fill, centre and tile are swaylock's fill, center and tile"
wp MODE=colour 'COLOUR=#445566'; lock
[ "$(get color "$T/log.conf")" = 445566 ] && ! grep -q '^image=' "$T/log.conf" && ok "a plain colour is the background" || bad "colour mode: $(grep '^color=\|^image=' "$T/log.conf")"
wp MODE=pattern "IMAGE=$T/pics/$pic"; lock
[ "$(get color "$T/log.conf")" = "$(pv DESK_BOTTOM "$D/themes/palettes/ribbon-moss.conf")" ] && ! grep -q '^image=' "$T/log.conf" &&
	ok "the pattern locks on DESK_BOTTOM" || bad "pattern mode: $(grep '^color=\|^image=' "$T/log.conf")"
wp MODE=picture "IMAGE=$T/pics/gone.png"; lock
grep -q '^image=' "$T/log.conf" && bad "a picture that is gone is still given to swaylock" || ok "a picture that is gone is left out"

# your own swaylock config wins and is not written over
mkdir -p "$T/h/.config/swaylock"; printf 'color=ff0000\n' >"$T/h/.config/swaylock/config"
lock
[ "$(cat "$T/log")" = "-f" ] && [ "$(cat "$T/h/.config/swaylock/config")" = "color=ff0000" ] &&
	ok "a hand-written ~/.config/swaylock/config is used and left alone" || bad "own config: swaylock ran with '$(cat "$T/log")'"

# swaylock reads ~/.swaylock/config before $XDG_CONFIG_HOME/swaylock/config: one there wins as well
rm -rf "$T/h/.config/swaylock"; mkdir -p "$T/h/.swaylock"; printf 'color=00ff00\n' >"$T/h/.swaylock/config"
lock
[ "$(cat "$T/log")" = "-f" ] && ok "a hand-written ~/.swaylock/config is used and left alone" ||
	bad "own ~/.swaylock/config: swaylock ran with '$(cat "$T/log")'"
rm -rf "$T/h/.swaylock"

# every way to lock goes through it
grep -q '\[list lock Lock {ribbon-lock}\]' "$D/shell/controls.tcl" && ok "the power menu's Lock runs ribbon-lock" || bad "controls.tcl: Lock"
[ "$(xmllint --xpath "string(//keyboard/keybind[@key='W-l']/action/@command)" "$D/xdg/labwc/rc.xml" 2>/dev/null)" = ribbon-lock ] &&
	ok "Super+L runs ribbon-lock" || bad "rc.xml: W-l"
grep -q 'timeout \$lock ribbon-lock' "$D/apps/settings/power.tcl" && grep -q 'before-sleep ribbon-lock' "$D/apps/settings/power.tcl" &&
	ok "the idle timer and sleep lock through ribbon-lock" || bad "power.tcl: swayidle's lock"
left=$(grep -rn 'swaylock -f' "$D/shell" "$D/apps" "$D/xdg" 2>/dev/null)
[ -z "$left" ] && ok "nothing runs a bare swaylock" || bad "a bare swaylock is left: $left"

[ $fails -eq 0 ] || exit 1
