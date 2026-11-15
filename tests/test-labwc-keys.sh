#!/bin/sh
# labwc's keys and the desktop menu (xdg/labwc/rc.xml, menu.xml): both parse; every command a key or a menu item
# runs exists (a Ribbon program in the tree, or a program from a package the templates depend on); Print and
# Shift+Print run ribbon-screenshot, the media keys run playerctl, Super+Shift+N opens Notes' quick capture, whose
# window is a panel (no compositor frame, kept out of the dock and Alt+Tab, on top); the menu opens the browser
# chosen in Default apps (not firefox by name), has Notes, ends the session with no bare Exit, and its labels are
# in sentence case. Then the files load in a headless labwc with no error about them.
set -u
cd "$(dirname "$0")/.." || exit 1
D=srcpkgs/ribbon-desktop/files
RC=$D/xdg/labwc/rc.xml
MENU=$D/xdg/labwc/menu.xml
fails=0
ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
command -v xmllint >/dev/null 2>&1 || { echo "  skip labwc's keys (no xmllint)"; exit 0; }

for f in "$RC" "$MENU"; do
	xmllint --noout "$f" 2>/dev/null && ok "$(basename "$f") is well-formed XML" || bad "$(basename "$f") does not parse"
done

# the command a key runs: key -> command (one Execute per key, outside If/then)
key_cmd() { xmllint --xpath "string(//keyboard/keybind[@key='$1']/action[@name='Execute']/@command)" "$RC" 2>/dev/null; }
want_key() {
	c=$(key_cmd "$1")
	[ "$c" = "$2" ] && ok "$1 runs '$2'" || bad "$1 runs '$c', not '$2'"
}
want_key Print "ribbon-screenshot"
want_key S-Print "ribbon-screenshot region"
want_key XF86AudioPlay "playerctl play-pause"
want_key XF86AudioPause "playerctl pause"
want_key XF86AudioStop "playerctl stop"
want_key XF86AudioNext "playerctl next"
want_key XF86AudioPrev "playerctl previous"
want_key W-S-n "ribbon-notes --capture"
want_key W-n "ribbon-shell-ctl notify-history"
want_key W-F12 "ribbon-hud cycle"
want_key W-Escape "ribbon-hud quick"
n=$(xmllint --xpath "count(//keyboard/keybind)" "$RC")
u=$(xmllint --xpath "//keyboard/keybind/@key" "$RC" | tr ' ' '\n' | grep -c . )
d=$(xmllint --xpath "//keyboard/keybind/@key" "$RC" | tr ' ' '\n' | grep . | sort | uniq -d)
[ -z "$d" ] && ok "no key is bound twice ($n keys)" || bad "keys bound twice: $d"

# Notes' quick capture: a panel
r="//windowRules/windowRule[@identifier='RibbonNotesCapture']"
[ "$(xmllint --xpath "string($r/@serverDecoration)" "$RC")" = no ] && ok "the capture panel has no compositor frame" || bad "the capture panel is framed by labwc"
[ "$(xmllint --xpath "string($r/@skipTaskbar)" "$RC")" = yes ] && [ "$(xmllint --xpath "string($r/@skipWindowSwitcher)" "$RC")" = yes ] &&
	ok "the capture panel stays out of the dock and Alt+Tab" || bad "the capture panel shows in the dock or Alt+Tab"
[ "$(xmllint --xpath "count($r/action[@name='ToggleAlwaysOnTop'])" "$RC")" = 1 ] && ok "the capture panel stays on top" || bad "the capture panel is not kept on top"
grep -q -- '--capture' "$D/apps/notes/main.tcl" && ok "ribbon-notes takes --capture" || bad "ribbon-notes has no --capture"

# every command exists: the first word of each Execute (inside sh -c '...', the first word of each part)
ribbon_bins=$(find srcpkgs/*/files/bin srcpkgs/*/files/apps/*/bin -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -u)
deps=$(sed -n '/^depends="/,/"$/p' srcpkgs/ribbon-desktop/template srcpkgs/ribbon-gaming/template srcpkgs/ribbon-base/template 2>/dev/null | tr ' "\t' '\n\n\n')
# programs from packages: program -> the package that has it
pkg_of() {
	case $1 in
		labwc) echo labwc;; grim) echo grim;; slurp) echo slurp;; wl-copy) echo wl-clipboard;;
		playerctl) echo playerctl;; wpctl) echo wireplumber;; brightnessctl) echo brightnessctl;;
		swaylock) echo swaylock;; steam) echo steam;; xdg-open|xdg-mime) echo xdg-utils;;
		sh|grep|head|pkill|date|mkdir) echo base;;
		*) echo "";;
	esac
}
check_word() {
	w=$1; where=$2
	case $w in ''|*=*) return;; esac
	if printf '%s\n' "$ribbon_bins" | grep -qx -- "$w"; then
		# in the tree is not enough: the package has to install it. apps/*/bin/* goes in by the template's
		# drop-in loop; a files/bin/ program only when its template names it
		for b in srcpkgs/*/files/bin/"$w"; do
			[ -f "$b" ] || continue
			t=${b%/files/bin/*}/template
			grep -Eq "(^|[[:space:]/\"])$w([[:space:]\";]|\$)" "$t" && return
		done
		ls srcpkgs/*/files/apps/*/bin/"$w" >/dev/null 2>&1 && return
		bad "$where runs '$w', which is in the tree but no template installs"
		missing=1
		return
	fi
	p=$(pkg_of "$w")
	if [ "$p" = base ]; then return; fi
	if [ -n "$p" ] && printf '%s\n' "$deps" | grep -qx -- "$p"; then return; fi
	bad "$where runs '$w', which no Ribbon file or dependency provides"
	missing=1
}
missing=0
W=$(mktemp)
for f in "$RC" "$MENU"; do
	xmllint --xpath "//action[@name='Execute']/@command" "$f" 2>/dev/null | sed 's/^ *command="//; s/"$//' |
		sed "s/&quot;/\"/g; s/&amp;/\\&/g" | while IFS= read -r c; do
		case $c in
			"sh -c '"*)
				inner=${c#sh -c \'}; inner=${inner%\'}
				printf '%s\n' "$inner" | sed 's/&&/\n/g; s/||/\n/g; s/|/\n/g';;
			*) printf '%s\n' "$c";;
		esac
	done | while IFS= read -r part; do set -- $part; echo "${1:-} $(basename "$f")"; done
done > "$W"
while read -r w where; do check_word "$w" "$where"; done < "$W"
nw=$(wc -l < "$W"); rm -f "$W"
[ "$missing" -eq 0 ] && ok "every command a key or menu item runs is a Ribbon program or comes with a dependency ($nw commands)"
# the shell's verbs that ribbon-shell-ctl is asked for exist (main.tcl's own, or a shell::verb)
for v in $(cat "$RC" "$MENU" | grep -o 'ribbon-shell-ctl [a-z-]*' | awk '{print $2}' | sort -u); do
	case $v in open|files|wallpaper|reload|quit) ok "ribbon-shell-ctl $v is the shell's own";; *)
		grep -q "shell::verb $v " "$D"/shell/*.tcl && ok "ribbon-shell-ctl $v is a verb of the shell" || bad "the shell has no verb $v";;
	esac
done

# the menu
if grep -q 'command="firefox' "$MENU"; then bad "the menu starts firefox by name"; else ok "the menu does not start firefox by name"; fi
[ "$(xmllint --xpath "string(//item[@label='Web browser']/action/@command)" "$MENU")" = ribbon-browser ] &&
	ok "Web browser starts the browser chosen in Default apps (ribbon-browser)" || bad "Web browser does not run ribbon-browser"
[ "$(xmllint --xpath "string(//item[@label='Notes']/action/@command)" "$MENU")" = ribbon-notes ] && ok "the menu has Notes" || bad "the menu has no Notes"
[ "$(xmllint --xpath "count(//action[@name='Exit'])" "$MENU")" = 0 ] && ok "the menu has no bare Exit" || bad "the menu still has labwc's bare Exit"
[ "$(xmllint --xpath "count(//item[@label='Log out'])" "$MENU")" = 1 ] && ok "the menu has Log out" || bad "the menu has no Log out"
[ "$(xmllint --xpath "count(//item[@label='Toggle conky'])" "$MENU")" = 1 ] && ok "Toggle conky stays (decisions row 37)" || bad "Toggle conky is gone"
caps=$(xmllint --xpath "//item/@label" "$MENU" | tr '"' '\n' | grep -v '^ *label=$' | grep . |
	grep -v -x -e HDR -e 'Toggle HDR' | grep -E '^[^ ]+ .*\b[A-Z][a-z]' || true)
[ -z "$caps" ] && ok "the menu's labels are in sentence case" || bad "labels in title case: $caps"

# the files load in labwc 0.7 (headless) without a complaint about them
if command -v labwc >/dev/null 2>&1; then
	T=$(mktemp -d); LW=
	trap 'kill $LW 2>/dev/null; rm -rf "$T"' EXIT
	mkdir -p "$T/cfg" "$T/rt"; chmod 700 "$T/rt"
	cp "$RC" "$MENU" "$T/cfg/"
	XDG_RUNTIME_DIR=$T/rt HOME=$T WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
		WAYLAND_DISPLAY='' DISPLAY='' timeout -k 2 20 labwc -C "$T/cfg" -d >"$T/log" 2>&1 & LW=$!
	i=0; while [ $i -lt 100 ] && ! find "$T/rt" -maxdepth 1 -regex '.*/wayland-[0-9]*' 2>/dev/null | grep -q .; do sleep 0.1; i=$((i + 1)); done
	sleep 0.5
	if find "$T/rt" -maxdepth 1 -regex '.*/wayland-[0-9]*' | grep -q .; then
		# labwc 0.7.1 here is older than the 0.20 Ribbon ships: two settings it does not know yet are left out
		# (adaptiveSync/allowTearing "fullscreen", and a keybind's onRelease)
		cm=$(grep '\[ERROR\]' "$T/log" | grep -v -e '(fullscreen) is not a boolean value' -e "nodename: 'onrelease'" || true)
		[ -z "$cm" ] && ok "headless labwc loads rc.xml and menu.xml without an error" || { bad "labwc complains:"; echo "$cm" | sed 's/^/       /'; }
	else
		echo "  skip labwc loading the files (it did not start: $(tail -n 2 "$T/log" | tr '\n' ' '))"
	fi
else echo "  skip labwc loading the files (no labwc)"; fi

[ $fails -eq 0 ] && echo "labwc keys and menu: all checks passed"
[ $fails -eq 0 ]
