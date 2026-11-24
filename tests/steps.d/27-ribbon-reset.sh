#!/bin/bash
# ribbon-reset (srcpkgs/ribbon-tools/files/bin/ribbon-reset) in a fake home: what it backs up before it replaces anything.
# Review finding of 17 Nov: `reset theme` backed up gtk-3.0/gtk.css and gtk-4.0/gtk.css into one folder by their basename,
# so the second copy overwrote the first and both originals were deleted. And `reset all` backed up the whole gtk-3.0 folder
# and, after ribbon-theme wrote a default gtk.css, backed that up over the person's own copy.
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
mkdir -p "$T/lib" "$T/bin" "$T/home"
cp srcpkgs/ribbon-tools/files/lib/*.sh srcpkgs/ribbon-tools/files/lib/pkg-names.* "$T/lib/" 2>/dev/null
sed "s|/usr/lib/ribbon/common.sh|$T/lib/common.sh|" srcpkgs/ribbon-tools/files/bin/ribbon-reset > "$T/ribbon-reset"
# not root (the tool refuses root), and a ribbon-theme that writes the defaults the way the real one does
cat > "$T/bin/id" <<'SH'
#!/bin/sh
echo 1000
SH
cat > "$T/bin/ribbon-theme" <<'SH'
#!/bin/sh
[ "$1" = apply ] || exit 0
mkdir -p "$XDG_CONFIG_HOME/gtk-3.0" "$XDG_CONFIG_HOME/gtk-4.0" "$XDG_CONFIG_HOME/ribbon"
echo "default css 3" > "$XDG_CONFIG_HOME/gtk-3.0/gtk.css"
echo "default css 4" > "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
echo "default settings" > "$XDG_CONFIG_HOME/gtk-3.0/settings.ini"
SH
chmod +x "$T/bin/id" "$T/bin/ribbon-theme"
H=$T/home
export XDG_CONFIG_HOME=$H/config XDG_STATE_HOME=$H/state HOME=$H
unset WAYLAND_DISPLAY
mine() {
	rm -rf "$H/config" "$H/state"
	mkdir -p "$XDG_CONFIG_HOME/gtk-3.0" "$XDG_CONFIG_HOME/gtk-4.0" "$XDG_CONFIG_HOME/ribbon"
	echo "my css 3" > "$XDG_CONFIG_HOME/gtk-3.0/gtk.css"
	echo "my css 4" > "$XDG_CONFIG_HOME/gtk-4.0/gtk.css"
	echo "my settings" > "$XDG_CONFIG_HOME/gtk-3.0/settings.ini"
	echo "PALETTE=ribbon" > "$XDG_CONFIG_HOME/ribbon/theme.conf"
}
reset() { PATH=$T/bin:$PATH bash "$T/ribbon-reset" "$@" >"$T/out" 2>&1; }
bk() { for d in "$XDG_STATE_HOME"/ribbon/reset-backups/*/; do echo "${d%/}"; return; done; }

mine
reset theme; rc=$?
b=$(bk)
if [ $rc = 0 ] && [ "$(cat "$b/gtk-3.0/gtk.css" 2>/dev/null)" = "my css 3" ] && [ "$(cat "$b/gtk-4.0/gtk.css" 2>/dev/null)" = "my css 4" ]; then
	ok "reset theme: both gtk.css files are in the backup, each under its own folder"
else bad "reset theme backup: rc=$rc $(find "$XDG_STATE_HOME" -type f 2>&1) $(cat "$T/out")"; fi
[ "$(cat "$XDG_CONFIG_HOME/gtk-3.0/gtk.css")" = "default css 3" ] && ok "  and the defaults were written again" || bad "defaults not written"

mine
reset all; rc=$?
b=$(bk)
if [ $rc = 0 ] && [ "$(cat "$b/gtk-3.0/gtk.css" 2>/dev/null)" = "my css 3" ] && [ "$(cat "$b/gtk-4.0/gtk.css" 2>/dev/null)" = "my css 4" ] && [ "$(cat "$b/gtk-3.0/settings.ini" 2>/dev/null)" = "my settings" ]; then
	ok "reset all: the person's own files are what the backup holds, not the defaults the first part had written"
else bad "reset all backup: rc=$rc gtk3=$(cat "$b/gtk-3.0/gtk.css" 2>&1) $(cat "$T/out")"; fi

mine
reset gtk; rc=$?
b=$(bk)
[ $rc = 0 ] && [ "$(cat "$b/gtk-3.0/settings.ini" 2>/dev/null)" = "my settings" ] && [ "$(cat "$b/ribbon/Xresources" 2>/dev/null || echo none)" = none ] && ok "reset gtk: the whole gtk-3.0 and gtk-4.0 folders are backed up with their own names" || bad "reset gtk: $(find "$XDG_STATE_HOME" -type f)"

mine
mkdir -p "$XDG_STATE_HOME"; echo "in the way" > "$XDG_STATE_HOME/ribbon"   # the backup folder cannot be made, even for root
reset theme; rc=$?
if [ $rc != 0 ] && [ "$(cat "$XDG_CONFIG_HOME/gtk-3.0/gtk.css")" = "my css 3" ] && [ "$(cat "$XDG_CONFIG_HOME/gtk-4.0/gtk.css")" = "my css 4" ]; then
	ok "a backup that cannot be made stops the reset: exit $rc, the person's files are where they were, nothing was overwritten"
else bad "failed backup: rc=$rc css3=$(cat "$XDG_CONFIG_HOME/gtk-3.0/gtk.css") $(cat "$T/out")"; fi
exit $fail
