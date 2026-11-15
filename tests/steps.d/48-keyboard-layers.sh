#!/bin/sh
# Where the keyboard layout comes from in the session (labwc --merge-config reads XDG_CONFIG_DIRS from the last to
# the first, later files winning): the layout chosen at install is in the lowest layer (/etc/xdg), Ribbon's own
# defaults set none, and Settings' xdg-input layer is above both, so a layout chosen in Settings is the one used.
set -u
cd "$(dirname "$0")/../.." || exit 1
D=srcpkgs/ribbon-desktop/files
I=srcpkgs/ribbon-installer/files/bin/ribbon-install
fails=0
ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
if grep -q '^XKB_DEFAULT_' "$D/xdg/labwc/environment"; then bad "Ribbon's labwc environment sets a layout (it would hide the installer's)"
else ok "Ribbon's labwc environment sets no layout"; fi
grep -q 'd="$TARGET/etc/xdg/labwc/environment.d"' "$I" && ok "the installer writes the layout to /etc/xdg/labwc/environment.d" || bad "the installer does not write /etc/xdg/labwc/environment.d"
if grep -n 'home/$USER_/.local/state/ribbon/xdg/labwc' "$I"; then bad "the installer still writes a per-user layout above Settings' layer"; else ok "no per-user layout above Settings' layer"; fi
dirs=$(sed -n 's/^export XDG_CONFIG_DIRS="\(.*\)"$/\1/p' "$D/bin/ribbon-session" | head -1)
case $dirs in
	*'ribbon/xdg-input:/usr/share/ribbon/xdg:/etc/xdg') ok "session layers: Settings' xdg-input over Ribbon's defaults over /etc/xdg" ;;
	*) bad "ribbon-session's XDG_CONFIG_DIRS is not ...xdg-input:/usr/share/ribbon/xdg:/etc/xdg ($dirs)" ;;
esac
[ $fails -eq 0 ] || exit 1
