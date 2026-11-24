#!/bin/sh
# The shell's ways into Settings: the quick panels' footers, "Pair a new device" and the desktop menu open Ribbon's
# own Settings pages, not the GTK tools they opened before those pages existed; and the game overlay's daemon is
# started with the session.
set -u
cd "$(dirname "$0")/../.." || exit 1
D=srcpkgs/ribbon-desktop/files
fails=0
ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
for page in sound network bluetooth; do
	grep -q "ribbon-settings --page $page" "$D/shell/controls.tcl" && ok "the $page panel's footer opens Settings → $page" || bad "no ribbon-settings --page $page in the quick panels"
done
grep -q 'command="ribbon-settings --page display"' "$D/xdg/labwc/menu.xml" && ok "the desktop menu's Displays opens Settings → Display" || bad "menu.xml: Displays"
if grep -n 'pavucontrol\|blueman-manager\|nm-connection-editor\|wdisplays' "$D"/shell/*.tcl "$D/xdg/labwc/menu.xml" "$D/xdg/labwc/rc.xml" "$D/xdg/labwc/autostart"; then
	bad "a GTK settings tool is still started by the shell or the session (lines above)"
else ok "no GTK settings tool is started by the shell or the session"; fi
grep -q '^service ribbon-hud .*hud/main.tcl -name ribbon-hud --auto$' "$D/xdg/labwc/autostart" && ok "the session starts the game overlay's daemon" || bad "autostart does not start ribbon-hud"
grep -q 'vbin "${FILESDIR}/ribbon-gamescope"' srcpkgs/ribbon-gaming/template && ok "ribbon-gamescope is installed" || bad "ribbon-gaming does not install ribbon-gamescope"
# a folder opened from the launcher goes to the folder app chosen in Settings → Default apps
if command -v tclsh8.6 >/dev/null 2>&1; then
	T=$(mktemp -d)
	if tclsh8.6 tests/open-folder-choice.tcl "$PWD/$D" "$T" >"$T/out" 2>&1; then ok "the launcher opens folders in the folder app chosen in Settings (Ribbon Files unless another is)"
	else sed 's/^/       /' "$T/out"; bad "the launcher ignores the chosen folder app"; fi
	rm -rf "$T"
else echo "  skip the chosen folder app (no tclsh8.6)"; fi
# the live ISO offers the installer, not the first-login welcome; both windows have names in the bar
grep -q '\[ ! -e /etc/ribbon/live \]' "$D/bin/ribbon-firstrun" && ok "the welcome is not offered on the live ISO" || bad "ribbon-firstrun queues the welcome on the live ISO"
grep -q 'ribboninstaller Installer ribbonwelcome Welcome' "$D/shell/apps.tcl" && ok "the installer and the welcome have names in the bar" || bad "apps::label has no name for the installer or the welcome"
[ $fails -eq 0 ] || exit 1
