#!/bin/sh
# ribbon-theme and GTK's dark or light preference (STACK §2.3 "Settings for GTK apps", §3.6), without arc-theme or a
# purple scheme, in a temporary HOME with GSettings on its keyfile backend (GSETTINGS_BACKEND=keyfile; dconf on a
# real system, the same keys):
#   1. apply writes org.gnome.desktop.interface color-scheme (prefer-dark for a dark scheme, prefer-light for a light
#      one) with the GTK theme, icons, cursor and font, which xdg-desktop-portal-gtk's Settings portal hands to GTK 4,
#      libadwaita, Firefox and flatpak apps;
#   2. the GTK theme is GTK's own Adwaita(-dark): every built-in palette names it, and a palette of your own that
#      names a theme that is not installed (Arc-Dark, from before) gets Adwaita-dark;
#   3. ribbon-portals.conf (xdg/xdg-desktop-portal, found through XDG_CONFIG_DIRS) picks wlr for screen capture and
#      Ribbon's chooser (then gtk) for file pickers, gtk for Settings, for XDG_CURRENT_DESKTOP=Ribbon;
#   4. the purple scheme is gone: no palette has a violet hue, `list` does not offer it, and a theme.conf that still
#      says ribbon-purple is taken as Graphite by apply, login and migrate (which ribbon-firstrun can run each login).
set -u
cd "$(dirname "$0")/.." || exit 1
D=srcpkgs/ribbon-desktop/files
RB=$D/bin/ribbon-theme
status=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; status=1; }
# the schemas where glib looks by default (XDG_DATA_DIRS is emptied below, so no GTK theme installed here counts)
SCHEMAS=${GSETTINGS_SCHEMA_DIR:-$(pkg-config --variable=schemasdir gio-2.0 2>/dev/null || echo /usr/share/glib-2.0/schemas)}
command -v gsettings >/dev/null 2>&1 && GSETTINGS_SCHEMA_DIR=$SCHEMAS gsettings list-keys org.gnome.desktop.interface 2>/dev/null | grep -qx color-scheme ||
	{ echo "  skip ribbon-theme's GSettings keys (no gsettings or no gsettings-desktop-schemas 42+)"; NOGS=1; }
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
home() { # NAME: a fresh HOME; sets H
	H=$T/$1; mkdir -p "$H/.config/ribbon/palettes"
}
rt() { # ribbon-theme ARGS... in $H, GSettings in its keyfile, no session, no login screen helper
	HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" XDG_STATE_HOME="$H/.local/state" \
		XDG_DATA_DIRS="$T/none" GSETTINGS_SCHEMA_DIR="$SCHEMAS" GSETTINGS_BACKEND=keyfile PATH="$T/bin:$PATH" \
		env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS bash "$RB" "$@"
}
gs() { # KEY: its value in $H's keyfile
	sed -n "/^\[org\/gnome\/desktop\/interface\]/,/^\[/s/^$1=//p" "$H/.config/glib-2.0/settings/keyfile" 2>/dev/null
}
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 1\n' > "$T/bin/pkexec"; chmod +x "$T/bin/pkexec"

# 1 and 2: a dark built-in, then a light palette of your own
home dark
rt apply ribbon --quiet --no-reload --no-login >/dev/null 2>&1
if [ -z "${NOGS:-}" ]; then
	[ "$(gs color-scheme)" = "'prefer-dark'" ] && [ "$(gs gtk-theme)" = "'Adwaita-dark'" ] && [ "$(gs cursor-theme)" = "'Adwaita'" ] &&
		[ "$(gs cursor-size)" = 24 ] && [ "$(gs font-name)" = "'Inter 10'" ] && [ -n "$(gs icon-theme)" ] &&
		ok "Graphite: color-scheme 'prefer-dark', gtk-theme Adwaita-dark, icons, cursor Adwaita 24, font Inter 10" ||
		bad "GSettings after apply ribbon: color-scheme $(gs color-scheme), gtk-theme $(gs gtk-theme), cursor $(gs cursor-theme) $(gs cursor-size), font $(gs font-name)"
fi
grep -qx 'gtk-theme-name=Adwaita-dark' "$H/.config/gtk-3.0/settings.ini" && grep -qx 'gtk-theme-name=Adwaita-dark' "$H/.config/gtk-4.0/settings.ini" &&
	grep -qx 'gtk-application-prefer-dark-theme=1' "$H/.config/gtk-4.0/settings.ini" &&
	ok "settings.ini (GTK 3 and 4): Adwaita-dark, prefer dark" || bad "settings.ini does not name Adwaita-dark"
n=$(grep -L '^GTK_THEME=Adwaita-dark$' $D/themes/palettes/*.conf)
[ -z "$n" ] && ok "every built-in palette names GTK_THEME=Adwaita-dark (GTK's own, no arc-theme)" || bad "palettes naming another GTK theme: $n"
home light
sed -e 's/^NAME=.*/NAME="Paper"/' -e 's/^GTK_THEME=.*/GTK_THEME=Adwaita/' $D/themes/palettes/ribbon.conf > "$H/.config/ribbon/palettes/paper.conf"
rt apply paper --quiet --no-reload --no-login >/dev/null 2>&1
if [ -z "${NOGS:-}" ]; then
	[ "$(gs color-scheme)" = "'prefer-light'" ] && [ "$(gs gtk-theme)" = "'Adwaita'" ] && ok "a light palette: color-scheme 'prefer-light', gtk-theme Adwaita" ||
		bad "a light palette: color-scheme $(gs color-scheme), gtk-theme $(gs gtk-theme)"
fi
grep -qx 'gtk-application-prefer-dark-theme=0' "$H/.config/gtk-4.0/settings.ini" && ok "  and settings.ini prefers light" || bad "a light palette: settings.ini still prefers dark"
home arc
sed -e 's/^NAME=.*/NAME="Old"/' -e 's/^GTK_THEME=.*/GTK_THEME=Arc-Dark/' $D/themes/palettes/ribbon.conf > "$H/.config/ribbon/palettes/old.conf"
rt apply old --quiet --no-reload --no-login >/dev/null 2>&1
grep -qx 'gtk-theme-name=Adwaita-dark' "$H/.config/gtk-3.0/settings.ini" && { [ -n "${NOGS:-}" ] || [ "$(gs color-scheme)" = "'prefer-dark'" ]; } &&
	ok "a palette of your own naming Arc-Dark (not installed) gets Adwaita-dark, still dark" || bad "Arc-Dark was kept: $(grep gtk-theme-name "$H/.config/gtk-3.0/settings.ini")"
mkdir -p "$H/.local/share/themes/Arc-Dark/gtk-3.0"
rt apply old --quiet --no-reload --no-login >/dev/null 2>&1
grep -qx 'gtk-theme-name=Arc-Dark' "$H/.config/gtk-3.0/settings.ini" && ok "  and keeps it when it is installed (~/.local/share/themes)" || bad "an installed Arc-Dark was replaced"

# 3. the portals
P=$D/xdg/xdg-desktop-portal/ribbon-portals.conf
pv() { sed -n "/^\[preferred\]/,/^\[/s/^$1=//p" "$P"; }
if [ "$(pv org.freedesktop.impl.portal.ScreenCast)" = wlr ] && [ "$(pv org.freedesktop.impl.portal.Screenshot)" = wlr ] &&
	[ "$(pv org.freedesktop.impl.portal.FileChooser)" = 'ribbon;gtk' ] && [ "$(pv org.freedesktop.impl.portal.Settings)" = gtk ] &&
	[ "$(pv default)" = 'wlr;gtk' ] && [ -f $D/xdg-desktop-portal/portals/ribbon.portal ] &&
	grep -q '^Interfaces=.*org.freedesktop.impl.portal.FileChooser' $D/xdg-desktop-portal/portals/ribbon.portal; then
	ok "ribbon-portals.conf: wlr for screen capture, Ribbon's chooser (gtk's without it) for file pickers, gtk for Settings, wlr then gtk otherwise"
else bad "ribbon-portals.conf does not choose the backends"; fi
grep -q 'XDG_CURRENT_DESKTOP=Ribbon' $D/bin/ribbon-session && grep -q '/usr/share/ribbon/xdg' $D/bin/ribbon-session &&
	grep -q 'dbus-update-activation-environment.*XDG_CONFIG_DIRS' $D/xdg/labwc/autostart &&
	ok "  found by xdg-desktop-portal: desktop Ribbon, /usr/share/ribbon/xdg in XDG_CONFIG_DIRS, passed to D-Bus activation" ||
	bad "xdg-desktop-portal would not find ribbon-portals.conf (desktop name, XDG_CONFIG_DIRS or the activation environment)"

# 4. no purple
[ ! -e $D/themes/palettes/ribbon-purple.conf ] && ok "ribbon-purple.conf is gone" || bad "ribbon-purple.conf still ships"
violet=$(awk -F= 'function hx(s) { s = tolower(s); return (index("0123456789abcdef", substr(s, 1, 1)) - 1) * 16 + index("0123456789abcdef", substr(s, 2, 1)) - 1 }
	/^[A-Z_0-9]+=#[0-9A-Fa-f]{6}/ {
	h = substr($2, 2, 6); r = hx(substr(h, 1, 2)) / 255; g = hx(substr(h, 3, 2)) / 255; b = hx(substr(h, 5, 2)) / 255
	mx = r; if (g > mx) mx = g; if (b > mx) mx = b; mn = r; if (g < mn) mn = g; if (b < mn) mn = b
	if (mx - mn < 0.12 || mx < 0.15) next
	if (mx == r) { hue = 60 * ((g - b) / (mx - mn)); if (hue < 0) hue += 360 } else if (mx == g) hue = 60 * ((b - r) / (mx - mn) + 2); else hue = 60 * ((r - g) / (mx - mn) + 4)
	if (hue < 0) hue += 360
	if (hue >= 255 && hue <= 300) print FILENAME ": " $0 }' $D/themes/palettes/*.conf)
[ -z "$violet" ] && ok "no palette has a violet colour (hue 255-300)" || bad "violet in a palette: $violet"
home list
rt list | grep -qx ribbon-purple && bad "list still offers ribbon-purple" || ok "list does not offer ribbon-purple"
home purple
printf 'PALETTE=ribbon-purple\nLOGIN_FOLLOWS_THEME=no\n' > "$H/.config/ribbon/theme.conf"
rt migrate >/dev/null 2>&1
grep -qx PALETTE=ribbon "$H/.config/ribbon/theme.conf" && grep -qx 'NAME="Graphite"' "$H/.config/ribbon/palette.conf" &&
	ok "migrate: a theme.conf with ribbon-purple becomes Graphite (theme.conf and the shell's palette.conf)" || bad "migrate left ribbon-purple"
cp "$H/.config/ribbon/theme.conf" "$T/before"; rt migrate >/dev/null 2>&1
cmp -s "$T/before" "$H/.config/ribbon/theme.conf" && [ ! -e "$H/.config/ribbon/theme.conf.new" ] && ok "  migrate again does nothing" || bad "a second migrate changed theme.conf"
# ... and something runs it: ribbon-firstrun (each session, from ribbon-session) on a home that already has a theme
home firstrun
printf 'PALETTE=ribbon-purple\n' > "$H/.config/ribbon/theme.conf"; : > "$H/.config/ribbon/welcome-done"
mkdir -p "$T/fr"; printf '#!/bin/sh\necho "$*" >> "%s/fr/ran"\n' "$T" > "$T/fr/ribbon-theme"; chmod +x "$T/fr/ribbon-theme"
HOME="$H" XDG_CONFIG_HOME="$H/.config" PATH="$T/fr:$PATH" sh $D/bin/ribbon-firstrun >/dev/null 2>&1
grep -q '^migrate' "$T/fr/ran" 2>/dev/null && ok "  ribbon-firstrun runs ribbon-theme migrate each session" ||
	bad "nothing runs ribbon-theme migrate at login (ribbon-firstrun ran: '$(tr '\n' ';' < "$T/fr/ran" 2>/dev/null)')"
home purple2
rt apply ribbon-purple --quiet --no-reload --no-login >/dev/null 2>&1 && grep -qx PALETTE=ribbon "$H/.config/ribbon/theme.conf" &&
	ok "apply ribbon-purple applies Graphite" || bad "apply ribbon-purple failed or kept the name"
home mine
sed 's/^NAME=.*/NAME="My purple"/' $D/themes/palettes/ribbon.conf > "$H/.config/ribbon/palettes/ribbon-purple.conf"
rt apply ribbon-purple --quiet --no-reload --no-login >/dev/null 2>&1
grep -qx PALETTE=ribbon-purple "$H/.config/ribbon/theme.conf" && ok "a palette of your own called ribbon-purple is still yours" || bad "your own ribbon-purple was replaced"
exit $status
