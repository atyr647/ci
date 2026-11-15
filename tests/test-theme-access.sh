#!/bin/sh
# ribbon-theme and Settings → Accessibility's access.conf (apps/settings/access.tcl writes it, then runs
# `ribbon-theme access`), in a temporary HOME with GSettings on its keyfile backend:
#   1. no access.conf: the defaults (text 100 %: Xft.dpi 96, foot 13; cursor 24), nothing hard-coded past them;
#   2. TEXT_SCALE=150 CURSOR_SIZE=48 HIGH_CONTRAST=yes REDUCE_MOTION=yes: GTK 3 and 4's settings.ini (gtk-xft-dpi,
#      cursor size, HighContrastInverse on a dark palette, animations off), the X resources, GSettings
#      (text-scaling-factor, cursor-size, enable-animations, a11y high-contrast), foot's font size and labwc's
#      environment in the ribbon/xdg layer (XCURSOR_SIZE);
#   3. a later `apply` of a scheme keeps them; values out of range or junk are the defaults;
#   4. headless labwc 0.7+ with ribbon-session's layers (--merge-config) starts its clients with XCURSOR_SIZE=48 and
#      the theme from the layer below (skips without labwc).
set -u
cd "$(dirname "$0")/.." || exit 1
D=srcpkgs/ribbon-desktop/files
RB=$D/bin/ribbon-theme
status=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; status=1; }
SCHEMAS=${GSETTINGS_SCHEMA_DIR:-$(pkg-config --variable=schemasdir gio-2.0 2>/dev/null || echo /usr/share/glib-2.0/schemas)}
command -v gsettings >/dev/null 2>&1 && GSETTINGS_SCHEMA_DIR=$SCHEMAS gsettings list-keys org.gnome.desktop.interface 2>/dev/null | grep -qx text-scaling-factor ||
	{ echo "  skip ribbon-theme's GSettings keys (no gsettings or no gsettings-desktop-schemas)"; NOGS=1; }
T=$(mktemp -d) || exit 1
LP=
trap '[ -n "$LP" ] && kill $LP 2>/dev/null; rm -rf "$T"' EXIT
H=$T/home; mkdir -p "$H/.config/ribbon"
rt() {
	HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" XDG_STATE_HOME="$H/.local/state" \
		XDG_DATA_DIRS="$T/none" GSETTINGS_SCHEMA_DIR="$SCHEMAS" GSETTINGS_BACKEND=keyfile PATH="$T/bin:$PATH" \
		env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS bash "$RB" "$@"
}
gs() { # SCHEMA-PATH KEY
	sed -n "/^\[$(printf '%s' "$1" | sed 's|/|\\/|g')\]/,/^\[/s/^$2=//p" "$H/.config/glib-2.0/settings/keyfile" 2>/dev/null
}
ini() { grep -qx "$1" "$H/.config/gtk-3.0/settings.ini" && grep -qx "$1" "$H/.config/gtk-4.0/settings.ini"; }
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 1\n' > "$T/bin/pkexec"; chmod +x "$T/bin/pkexec"
ENVF=$H/.local/state/ribbon/xdg/labwc/environment

# 1. the defaults
rt apply ribbon --quiet --no-reload --no-login >/dev/null 2>&1
ini gtk-xft-dpi=98304 && ini gtk-cursor-theme-size=24 && ini gtk-enable-animations=1 && ini gtk-theme-name=Adwaita-dark &&
	grep -qx 'Xft.dpi: 96' "$H/.config/ribbon/Xresources" && grep -qx 'Xcursor.size: 24' "$H/.config/ribbon/Xresources" &&
	grep -qx 'font=JetBrains Mono:size=13' "$H/.config/foot/foot.ini" && grep -qx 'XCURSOR_SIZE=24' "$ENVF" &&
	ok "no access.conf: Xft.dpi 96, cursor 24, animations on, foot 13, labwc's XCURSOR_SIZE=24" ||
	bad "the defaults: $(cat "$H/.config/gtk-3.0/settings.ini" "$ENVF" 2>&1 | tr '\n' ' ')"

# 2. everything on
printf 'TEXT_SCALE=150\nCURSOR_SIZE=48\nHIGH_CONTRAST=yes\nREDUCE_MOTION=yes\n' > "$H/.config/ribbon/access.conf"
rt access --no-reload >/dev/null 2>&1
ini gtk-xft-dpi=147456 && ini gtk-cursor-theme-size=48 && ini gtk-enable-animations=0 && ini gtk-theme-name=HighContrastInverse &&
	ok "settings.ini (GTK 3 and 4): gtk-xft-dpi 144 × 1024, cursor 48, animations off, HighContrastInverse (a dark palette)" ||
	bad "settings.ini after access: $(cat "$H/.config/gtk-3.0/settings.ini" | tr '\n' ' ')"
grep -qx 'Xft.dpi: 144' "$H/.config/ribbon/Xresources" && grep -qx 'Xcursor.size: 48' "$H/.config/ribbon/Xresources" &&
	ok "X resources: Xft.dpi 144, Xcursor.size 48" || bad "Xresources: $(tr '\n' ' ' < "$H/.config/ribbon/Xresources")"
grep -qx 'font=JetBrains Mono:size=20' "$H/.config/foot/foot.ini" && ok "foot's font: 13 × 150 % = 20" || bad "foot.ini: $(grep '^font' "$H/.config/foot/foot.ini")"
grep -qx 'XCURSOR_SIZE=48' "$ENVF" && [ "$(grep -c . "$ENVF")" = 2 ] && ok "labwc's environment in the ribbon/xdg layer: XCURSOR_SIZE=48" || bad "labwc environment: $(cat "$ENVF")"
if [ -z "${NOGS:-}" ]; then
	[ "$(gs org/gnome/desktop/interface text-scaling-factor)" = 1.5 ] && [ "$(gs org/gnome/desktop/interface cursor-size)" = 48 ] &&
		[ "$(gs org/gnome/desktop/interface enable-animations)" = false ] &&
		ok "GSettings: text-scaling-factor 1.5, cursor-size 48, enable-animations false" ||
		bad "GSettings: $(gs org/gnome/desktop/interface text-scaling-factor) $(gs org/gnome/desktop/interface cursor-size) $(gs org/gnome/desktop/interface enable-animations)"
	if GSETTINGS_SCHEMA_DIR=$SCHEMAS gsettings list-keys org.gnome.desktop.a11y.interface 2>/dev/null | grep -qx high-contrast; then
		[ "$(gs org/gnome/desktop/a11y/interface high-contrast)" = true ] && ok "GSettings: a11y high-contrast true" || bad "a11y high-contrast: $(gs org/gnome/desktop/a11y/interface high-contrast)"
	fi
fi

# 3. apply keeps them; junk is the default
rt apply ribbon --quiet --no-reload --no-login >/dev/null 2>&1
ini gtk-cursor-theme-size=48 && ini gtk-xft-dpi=147456 && grep -qx 'font=JetBrains Mono:size=20' "$H/.config/foot/foot.ini" && grep -qx 'XCURSOR_SIZE=48' "$ENVF" &&
	ok "apply of a scheme keeps the cursor and text size (no hard-coded 24 or 96)" || bad "apply undid access.conf"
printf 'TEXT_SCALE="125"\nCURSOR_SIZE=999\nHIGH_CONTRAST=maybe\nREDUCE_MOTION=$(touch %s/pwned)\n' "$T" > "$H/.config/ribbon/access.conf"
rt access --no-reload >/dev/null 2>&1
ini gtk-xft-dpi=122880 && ini gtk-cursor-theme-size=24 && ini gtk-theme-name=Adwaita-dark && ini gtk-enable-animations=1 && [ ! -e "$T/pwned" ] &&
	grep -qx 'font=JetBrains Mono:size=16' "$H/.config/foot/foot.ini" &&
	ok "quoted 125 is read (Xft.dpi 120, foot 16); 999, maybe and a command are the defaults, never run" || bad "junk in access.conf: $(cat "$H/.config/gtk-3.0/settings.ini" | tr '\n' ' ')"

# 4. labwc reads the layer
if command -v labwc >/dev/null 2>&1; then
	printf 'CURSOR_SIZE=48\n' > "$H/.config/ribbon/access.conf"
	rt access --no-reload >/dev/null 2>&1
	R=$T/lw; mkdir -p "$R/rt" "$R/ribbonxdg/labwc" "$R/etc/labwc"; chmod 700 "$R/rt"
	cp "$D/xdg/labwc/environment" "$R/etc/labwc/environment"
	printf '#!/bin/sh\nenv | grep "^XCURSOR_" | sort > %s/env.out\n' "$R" > "$R/ribbonxdg/labwc/autostart"
	state=$H/.local/state
	env -i PATH="$PATH" HOME="$H" XDG_RUNTIME_DIR="$R/rt" XDG_CONFIG_HOME="$H/.config" \
		XDG_CONFIG_DIRS="$state/ribbon/xdg:$R/ribbonxdg:$R/etc" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
		timeout -k 2 20 labwc --merge-config >"$R/log" 2>&1 &
	LP=$!
	i=0; while [ $i -lt 100 ] && [ ! -s "$R/env.out" ]; do sleep 0.1; i=$((i + 1)); done
	kill $LP 2>/dev/null; wait $LP 2>/dev/null; LP=
	[ "$(tr '\n' ' ' < "$R/env.out" 2>/dev/null)" = "XCURSOR_SIZE=48 XCURSOR_THEME=Adwaita " ] &&
		ok "headless labwc (--merge-config, ribbon-session's layers): its clients get XCURSOR_SIZE=48 and the Adwaita theme" ||
		bad "labwc's clients: $(cat "$R/env.out" 2>/dev/null) $(tail -3 "$R/log")"
else
	echo "  skip labwc's environment (no labwc)"
fi
exit $status
