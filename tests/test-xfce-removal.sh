#!/bin/bash
# Xfce removal (U44): no Xfce package in any template's depends nor in the base-neutral lists a non-Void install
# reads (build/install/deps.map, build/install/manifests, build/packages/*.list), nothing under any srcpkgs/*/files
# runs an Xfce binary, and what xfsettingsd gave GTK and XWayland apps now comes from ribbon-theme (GTK 3 and 4
# settings.ini, the X resources, the cursor variables) and labwc (key repeat), run in a temporary HOME.
# Also the GTK tools Settings replaced (STACK S6: wdisplays, pavucontrol, nm-applet/nm-connection-editor, blueman)
# and arc-theme (the generated gtk.css on GTK's own Adwaita): no dependency list names them and nothing runs them.
set -u
cd "$(dirname "$0")/.." || exit 1
RB=srcpkgs/ribbon-desktop/files/bin/ribbon-theme
FILES=srcpkgs/ribbon-desktop/files
status=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; status=1; }
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# 1. No Xfce package in any template's depends (xfconf too: only xfsettingsd and Xfce apps used it).
hits=$(for t in srcpkgs/*/template; do
	awk -v t="$t" '/^(depends|makedepends|hostmakedepends|checkdepends)=/ { on = 1 }
		on { for (i = 1; i <= NF; i++) if ($i ~ /^(xfce|xfconf|Thunar|thunar|exo$|libxfce|garcon|tumbler|xfwm|xfdesktop|xfsettingsd)/) print t ": " $i }
		on && /"/ { n = gsub(/"/, "\""); if (/^(depends|makedepends|hostmakedepends|checkdepends)=.*"[^"]*"/ || (on && /"$/ && !/="/)) on = 0 }' "$t"
done)
if [ -z "$hits" ]; then ok "no Xfce package in any template's depends"; else bad "Xfce packages in depends: $hits"; fi
# ... nor in deps.map (Void and base-neutral names), the install manifests, or the ISO's package lists
XFCE_RE='(^|[^a-z])(xfce|xfconf|thunar|libxfce|garcon|tumbler|xfwm|xfdesktop|xfsettingsd)|(^|[^a-z-])exo($|[^a-z-])'
hits=$( { awk -F'|' '!/^#/ && NF >= 2 { print FILENAME ":" NR ": " $1 "|" $2 }' build/install/deps.map
	grep -Hn -v '^[[:space:]]*#' build/install/manifests/*.manifest
	grep -Hn -v '^[[:space:]]*#' build/packages/*.list; } 2>/dev/null | grep -Ei "$XFCE_RE" || true)
if [ -z "$hits" ]; then ok "no Xfce name in deps.map, build/install/manifests or build/packages/*.list"; else bad "Xfce in the neutral lists: $hits"; fi

# 2. Nothing under files/ runs an Xfce binary (a command word, not a path or a comment).
cmds='xfsettingsd|xfconf-query|xfce4-[a-z-]+|xfce-polkit|xfdesktop|xfwm4|xfce4-session|exo-open|thunar|Thunar'
run=$(grep -rEn --exclude-dir=.git "(^[[:space:]]*|command=\"|exec |&& |\|\| |; |\| |\\$\()($cmds)([[:space:];&|)\"']|$)" srcpkgs/*/files 2>/dev/null \
	| grep -Ev ':[0-9]+:[[:space:]]*(#|//|<!--)' | grep -v 'xfce4/\(panel\|xfconf\)' \
	| grep -Ev ':[0-9]+:[[:space:]]*[a-z0-9 |-]+\)[[:space:]]' || true)   # a case pattern names a terminal, it runs nothing
if [ -z "$run" ]; then ok "no file under any srcpkgs/*/files runs an Xfce binary"; else bad "Xfce binary run: $run"; fi
if [ ! -e "$FILES/xdg/xfce4" ] && ! grep -q 'xfce' srcpkgs/ribbon-desktop/template; then ok "no xdg/xfce4 tree and no Xfce word in the template"; else bad "xdg/xfce4 or an Xfce word is left in the template"; fi
if grep -q 'XFCE' "$FILES/bin/ribbon-session" "$FILES/sessions/ribbon.desktop" "$FILES/shell/apps.tcl"; then bad "XFCE still in the session or apps.tcl"
else ok "XDG_CURRENT_DESKTOP, DesktopNames and apps.tcl have no XFCE"; fi

# 2b. The GTK tools Settings replaced, and arc-theme: in no template's depends, deps.map, manifest or package list,
# and no file under srcpkgs/*/files names one outside a comment (a Tcl launch such as `apps::run blueman-manager` or
# `[list footer "Sound settings" pavucontrol]` has no shell command word before it; the shell's own check is steps.d/47).
gone='wdisplays|pavucontrol|network-manager-applet|nm-applet|nm-connection-editor|blueman|blueman-manager|blueman-applet|arc-theme'
hits=$( { for t in srcpkgs/*/template; do sed -n '/^depends="/,/"/p' "$t" | grep -v '^[[:space:]]*#' | sed "s|^|$t: |"; done
	awk -F'|' '!/^#/ && NF >= 2 { print FILENAME ":" NR ": " $1 }' build/install/deps.map
	grep -Hn -v '^[[:space:]]*#' build/install/manifests/*.manifest build/packages/*.list; } 2>/dev/null | grep -Ew -- "$gone" || true)
if [ -z "$hits" ]; then ok "wdisplays, pavucontrol, network-manager-applet, blueman and arc-theme are no dependency anywhere"; else bad "a replaced GTK tool is still a dependency: $hits"; fi
run=$(grep -rEnw --exclude-dir=.git -- "$gone" srcpkgs/*/files 2>/dev/null \
	| grep -Ev ':[0-9]+:[[:space:]]*(#|//|<!--)' || true)
if [ -z "$run" ]; then ok "nothing under srcpkgs/*/files runs one of them"; else bad "a replaced GTK tool is run: $run"; fi

# 3. ribbon-theme apply in a temporary HOME: settings.ini (3 and 4), Xresources, no xfconf.
home="$tmp/home"; mkdir -p "$home/.config/gtk-3.0"
printf '[Settings]\ngtk-theme-name=Mine\ngtk-enable-animations=false\n[Other]\nx=1\n' > "$home/.config/gtk-3.0/settings.ini"
bin="$tmp/bin"; mkdir -p "$bin"
printf '#!/bin/sh\necho "$@" >> "%s/xfconf.log"\n' "$tmp" > "$bin/xfconf-query"; chmod +x "$bin/xfconf-query"
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" PATH="$bin:$PATH" \
	env -u WAYLAND_DISPLAY bash "$RB" apply ribbon --quiet --no-login --no-reload >/dev/null 2>&1
for g in gtk-3.0 gtk-4.0; do
	f="$home/.config/$g/settings.ini"
	want=0
	for kv in 'gtk-theme-name=Adwaita-dark' 'gtk-font-name=Inter 10' 'gtk-cursor-theme-name=Adwaita' \
		'gtk-cursor-theme-size=24' 'gtk-application-prefer-dark-theme=1' 'gtk-xft-antialias=1' 'gtk-xft-hintstyle=hintslight' \
		'gtk-xft-rgba=rgb' 'gtk-xft-dpi=98304'; do
		grep -qxF -- "$kv" "$f" 2>/dev/null || { want=1; echo "       $g missing: $kv"; }
	done
	# Ribbon's folder-icon theme when Papirus-Dark is installed (not in this container), else the palette's name
	grep -qE '^gtk-icon-theme-name=(Ribbon|Papirus-Dark)$' "$f" || want=1
	if [ "$want" = 0 ] && [ "$(grep -c '^\[Settings\]' "$f")" = 1 ]; then ok "$g/settings.ini has the theme, icons, font, cursor, dark and Xft keys"; else bad "$g/settings.ini wrong"; fi
done
# a theme that is not on the system (no Papirus here) falls back to the palette's icon theme; the user's own keys stay
if grep -qx 'gtk-enable-animations=false' "$home/.config/gtk-3.0/settings.ini" && grep -qx 'x=1' "$home/.config/gtk-3.0/settings.ini" \
	&& [ "$(grep -c '^gtk-theme-name=' "$home/.config/gtk-3.0/settings.ini")" = 1 ]; then ok "the user's own settings.ini keys stay, ours replace theirs"; else bad "settings.ini merge"; fi
x="$home/.config/ribbon/Xresources"
want=0
for kv in 'Xft.dpi: 96' 'Xft.antialias: 1' 'Xft.hinting: 1' 'Xft.hintstyle: hintslight' 'Xft.rgba: rgb' 'Xcursor.theme: Adwaita' 'Xcursor.size: 24'; do
	grep -qxF -- "$kv" "$x" 2>/dev/null || { want=1; echo "       Xresources missing: $kv"; }
done
if [ "$want" = 0 ]; then ok "Xresources has Xft.dpi, antialias, hinting, rgba and the cursor"; else bad "Xresources wrong"; fi
if [ ! -e "$tmp/xfconf.log" ]; then ok "ribbon-theme never calls xfconf-query"; else bad "xfconf-query was called"; fi

# 4. A dark/light theme flag follows GTK_THEME; a second apply replaces, not appends.
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
	env -u WAYLAND_DISPLAY bash "$RB" apply ribbon-amber --quiet --no-login --no-reload >/dev/null 2>&1
if [ "$(grep -c '^gtk-xft-dpi=' "$home/.config/gtk-4.0/settings.ini")" = 1 ]; then ok "a second apply replaces the keys"; else bad "second apply duplicated keys"; fi

# 5. The cursor for Wayland and XWayland clients (labwc's environment) matches, and the key repeat is in rc.xml.
if grep -qx 'XCURSOR_THEME=Adwaita' "$FILES/xdg/labwc/environment" && grep -qx 'XCURSOR_SIZE=24' "$FILES/xdg/labwc/environment"; then
	ok "labwc environment sets XCURSOR_THEME=Adwaita and XCURSOR_SIZE=24"; else bad "labwc environment cursor"; fi
if python3 - <<'PY'
import xml.dom.minidom as m
k = m.parse('srcpkgs/ribbon-desktop/files/xdg/labwc/rc.xml').getElementsByTagName('keyboard')[0]
v = lambda t: k.getElementsByTagName(t)[0].firstChild.data
assert v('repeatDelay') == '500' and v('repeatRate') == '20'
PY
then ok "rc.xml <keyboard> sets repeatDelay 500 and repeatRate 20"; else bad "rc.xml key repeat"; fi

# 6. The autostart starts the replacements and not xfsettingsd; the X resources load only with xrdb.
a="$FILES/xdg/labwc/autostart"
if grep -q 'ribbon-polkit' "$a" && grep -q 'power-idle.tcl' "$a" && grep -q 'ribbon-shell' "$a" && grep -q 'xrdb -nocpp -merge' "$a" \
	&& ! grep -q 'xfsettingsd' "$a"; then ok "autostart: shell (notifications), polkit agent, power-idle, xrdb; no xfsettingsd"; else bad "autostart"; fi

# 7. ribbon reset gtk no longer backs up Xfce's xsettings.xml; it re-runs ribbon-theme for the current scheme (needs a
# non-root user and /usr/lib/ribbon/common.sh, so it is read, not run, here).
rr=srcpkgs/ribbon-tools/files/bin/ribbon-reset
if ! grep -q 'xsettings.xml' "$rr" && sed -n '/^reset_gtk/,/^}/p' "$rr" | grep -q 'ribbon-theme apply'; then
	ok "ribbon reset gtk writes settings.ini again through ribbon-theme"; else bad "ribbon-reset gtk"; fi
exit $status
