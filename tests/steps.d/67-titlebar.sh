#!/bin/sh
# The title bar: Ribbon's own app windows take the compositor's title bar when floating (labwc frames them:
# no serverDecoration="no" rule for them in rc.xml), the rules that must stay stay, each app's window has the
# title and class of its .desktop file, and rbn::appwindow has one switch (rbn::framed, RIBBON_OWN_FRAME=1
# for the app's own frame). The runtime part needs wish8.6 and xvfb-run; without them it is skipped. Under a real
# compositor (tests/test-titlebar-labwc.sh: headless labwc with XWayland, Ribbon's rc.xml and window theme) each app
# window is started and its frame read from a grim shot: labwc's title bar with the title and buttons, the border,
# and none for a class with a serverDecoration="no" rule; skipped without labwc, Xwayland or grim.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
RC=srcpkgs/ribbon-desktop/files/xdg/labwc/rc.xml
D=srcpkgs/ribbon-desktop/files

if xmllint --noout "$RC" 2>/dev/null; then ok "rc.xml is well-formed"; else bad "rc.xml is not well-formed"; fi

# Ribbon's own apps: no rule, so labwc draws the title bar, the border and the buttons when floating
for c in RibbonSettings RibbonAppearance RibbonProperties RibbonEditor RibbonMonitor RibbonNotes RibbonImageViewer; do
	if grep -q "identifier=\"$c\"" "$RC"; then bad "$c has a windowRule in rc.xml: it must take the compositor title bar"
	else ok "$c takes the compositor title bar"; fi
done
# the rules that stay: shell surfaces, the installer (its own frame), games, the appearance sheet
for c in RibbonShellInput RibbonInstaller RibbonAppearanceSheet 'gamescope\*' 'steam_app_\*'; do
	if grep -q "identifier=\"$c\"[^>]*serverDecoration=\"no\"" "$RC"; then ok "$c keeps serverDecoration=\"no\""
	else bad "$c lost its serverDecoration=\"no\" rule"; fi
done
# the maximized window: no title bar (the shell's top strip has the buttons)
grep -q '<maximizedDecoration>none</maximizedDecoration>' "$RC" && ok "maximized windows have no title bar" \
	|| bad "maximizedDecoration is not none"

# title and class: each window's wm title is its .desktop Name, and its class its StartupWMClass
pairs="
Settings|RibbonSettings|apps/settings/applications/ribbon-settings.desktop|apps/settings/main.tcl
Appearance|RibbonAppearance|applications/ribbon-appearance.desktop|appearance/main.tcl
Properties|RibbonProperties|applications/ribbon-properties.desktop|properties/main.tcl
Text editor|RibbonEditor|apps/editor/applications/ribbon-editor.desktop|apps/editor/main.tcl
System monitor|RibbonMonitor|apps/monitor/applications/ribbon-monitor.desktop|apps/monitor/main.tcl
Notes|RibbonNotes|apps/notes/applications/ribbon-notes.desktop|apps/notes/main.tcl
Image Viewer|RibbonImageViewer|apps/viewer/org.ribbon.imageviewer.desktop|apps/viewer/main.tcl
"
while IFS='|' read -r title cls desk src; do
	[ -n "$title" ] || continue
	f=$D/$desk
	if [ -f "$f" ] && grep -qx "Name=$title" "$f" && grep -qx "StartupWMClass=$cls" "$f" \
		&& grep -q -- "-class $cls " "$D/$src" && grep -qF "wm title" "$D/$src"; then
		ok "$title: window class $cls, title from $(basename "$desk")"
	else
		bad "$title: class $cls or title does not match $desk ($src)"
	fi
done <<PAIRS
$pairs
PAIRS

# the one switch: the installer keeps its own frame by passing -ownframe 1; the others take the default
# (its height follows the screen since the small-screen boards, and its width under 1100 since dde6d44: any size, -ownframe 1)
grep -q 'rbn::appwindow [^ ]* RibbonInstaller [^ ]* [^ ]* .*-ownframe 1' srcpkgs/ribbon-installer/files/tk/main.tcl \
	&& ok "the installer keeps its own frame (-ownframe 1)" || bad "the installer does not pass -ownframe 1"

# the framed windows draw their own controls and corners only when they are not framed by labwc
T2=srcpkgs/ribbon-desktop/files/apps/editor/tabs.tcl
[ "$(grep -c 'if {!\[editor::own_controls\]} return' "$T2")" -ge 2 ] && ok "the editor's header draws no min/max/close when framed (unsplit strip and welcome zone)" \
	|| bad "the editor's header still draws its own min/max/close when framed"
grep -q 'proc editor::own_controls' "$D/apps/editor/main.tcl" && ok "editor::own_controls is the one switch" || bad "editor::own_controls missing"
grep -q 'proc viewer::own_frame' "$D/apps/viewer/main.tcl" && grep -q 'if {!\[viewer::own_frame\]}' "$D/apps/viewer/main.tcl" \
	&& ok "the image viewer draws its rounded frame only when not framed" || bad "the image viewer's frame is not switched by framing"
grep -q 'ui::outer_radius 16' "$D/appearance/pages.tcl" && grep -q 'ui::outer_radius 16' "$D/properties/pages.tcl" \
	&& ok "Appearance, Settings and Properties window bodies use square outer corners when framed" \
	|| bad "a window body still has rounded outer corners when framed"
grep -q 'proc rbn::squared' "$D/rbnalpha/rbnalpha.tcl" && ok "rbn::squared records the windows labwc frames" || bad "rbn::squared missing"

# runtime: rbn::framed follows RIBBON_OWN_FRAME, and appwindow makes a window of the given class
if command -v wish8.6 >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1; then
	T=$(mktemp -d)
	cat > "$T/check.tcl" <<EOF
source -encoding utf-8 $PWD/$D/rbnalpha/rbnalpha.tcl
puts "framed=[rbn::framed]"
set w .settings
set r [rbn::appwindow \$w RibbonSettings 1100 720 -fill #1d1c1b]
puts "class=[winfo class \$w] own=\$r"
puts "squared=[rbn::squared \$w]"
puts "fit800=[rbn::fit 800] fit720=[rbn::fit 720]"
puts "done"
exit
EOF
	out=$(timeout 60 xvfb-run -a env -u RIBBON_OWN_FRAME wish8.6 -encoding utf-8 "$T/check.tcl" 2>&1)
	own=$(timeout 60 xvfb-run -a env RIBBON_OWN_FRAME=1 wish8.6 -encoding utf-8 "$T/check.tcl" 2>&1)
	if echo "$out" | grep -q '^framed=1$' && echo "$out" | grep -q '^class=RibbonSettings own=0$' && echo "$out" | grep -q '^squared=1$' && echo "$out" | grep -q '^done$'; then
		ok "rbn::framed is on by default; a framed app window has class RibbonSettings and no own frame"
	else
		bad "rbn::framed default: $(echo "$out" | tail -3)"
	fi
	if echo "$own" | grep -q '^framed=0$'; then ok "RIBBON_OWN_FRAME=1 turns the compositor framing off"
	else bad "RIBBON_OWN_FRAME=1 does not turn framing off"; fi
	# labwc keeps a 900-high screen's frame between the bars (54 + 54) with its 41 px title and 1 px border:
	# the tallest client is 750, so a 800-high app is fitted to 750 and a 720-high one keeps 720
	fit=$(timeout 60 xvfb-run -a -s "-screen 0 1440x900x24" env -u RIBBON_OWN_FRAME wish8.6 -encoding utf-8 "$T/check.tcl" 2>&1)
	if echo "$fit" | grep -q '^fit800=750 fit720=720$'; then ok "rbn::fit keeps a framed app inside the room labwc leaves (750 on 900 high)"
	else bad "rbn::fit: $(echo "$fit" | grep '^fit' || echo "$fit" | tail -2)"; fi
	ownfit=$(timeout 60 xvfb-run -a -s "-screen 0 1440x900x24" env RIBBON_OWN_FRAME=1 wish8.6 -encoding utf-8 "$T/check.tcl" 2>&1)
	if echo "$ownfit" | grep -q '^fit800=800 fit720=720$'; then ok "rbn::fit leaves an own-frame window at its design height"
	else bad "rbn::fit own frame: $(echo "$ownfit" | grep '^fit' || echo "$ownfit" | tail -2)"; fi
	rm -rf "$T"
else
	echo "  skip titlebar runtime (no wish8.6 / xvfb-run)"
fi

grep -q 'proc rbn::fit' "$D/rbnalpha/rbnalpha.tcl" && grep -q 'rbn::fit' "$D/apps/editor/main.tcl" && grep -q 'rbn::fit' "$D/apps/notes/main.tcl" && grep -q 'rbn::fit' "$D/apps/viewer/main.tcl" && ok "the editor, notes and viewer fit their height under the bars" || bad "rbn::fit not used by editor, notes and viewer"

# the frames under labwc
sh tests/test-titlebar-labwc.sh > "${TMPDIR:-/tmp}/titlebar-labwc.$$" 2>&1
grep -v '^title bars under labwc' "${TMPDIR:-/tmp}/titlebar-labwc.$$"
fails=$((fails + $(grep -c '^  FAIL' "${TMPDIR:-/tmp}/titlebar-labwc.$$")))
rm -f "${TMPDIR:-/tmp}/titlebar-labwc.$$"

[ $fails -eq 0 ] && echo "titlebar: all checks passed" || echo "titlebar: $fails checks failed"
[ $fails -eq 0 ]
