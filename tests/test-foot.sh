#!/bin/bash
# foot (U05): ribbon-theme writes foot.ini from each palette (golden values
# computed here from the palette file), replaces it atomically, sends OSC
# colours to the ptys of running foot windows, and the session's terminal
# entries (apps.tcl, rc.xml, menu.xml) use foot.
set -u
cd "$(dirname "$0")/.." || exit 1
RB=srcpkgs/ribbon-desktop/files/bin/ribbon-theme
PAL=srcpkgs/ribbon-desktop/files/themes/palettes
status=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; status=1; }
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# Golden foot.ini from a palette file, written independently of ribbon-theme.
golden() { # palette-file
	python3 - "$1" <<'PY'
import os, sys
pal = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    k, v = line.split('=', 1)
    pal[k] = v.strip().strip('"')
def c(k, default=None):
    v = pal.get(k, default)
    return v.lstrip('#').upper()
bar, fg, field = c('BAR'), c('FG'), c('FIELD')
on_acc, acc = c('ON_ACCENT', bar), c('ACCENT')
muted = c('MUTED', fg)
hues = [c('PILL'), c('CRIT'), c('OK'), c('WARN'), c('INK'), c('ACCENT2'), c('SYN_VAR', c('ACCENT2')), fg]
# what ribbon-theme writes follows the installed foot (see foot_ini there)
import re, shutil, subprocess
m = re.search(r'foot version: 1\.(\d+)', subprocess.run(['foot', '--version'], capture_output=True, text=True).stdout) if shutil.which('foot') else None
v = None if m is None else int(m.group(1))
new = v is None or v >= 20
dark = v is None or v >= 26
print("[main]")
print("font=JetBrains Mono:size=13")
print("pad=14x12")
print("resize-by-cells=no" if new else "")
print("")
print("[colors-dark]" if dark else "[colors]")
print("foreground=" + fg)
print("background=" + bar)
print("selection-foreground=" + fg)
print("selection-background=" + field)
for i, h in enumerate(hues):
    print("regular%d=%s" % (i, h))
print("bright0=" + muted)
for i, h in enumerate(hues[1:], 1):
    print("bright%d=%s" % (i, h))
if dark:
    print("cursor=" + on_acc + " " + acc)
else:
    print("")
    print("[cursor]")
    print("color=" + on_acc + " " + acc)
print("")
print("[csd]")
print("preferred=none")
print("")
print("[key-bindings]")
for n in range(1, 10):
    print("pipe-visible=[ribbon-term-ctl tab %d] Mod1+%d" % (n, n))
print("pipe-visible=[ribbon-term-ctl new] Control+Shift+t")
print("pipe-visible=[ribbon-term-ctl close] Control+Shift+w")
print("pipe-visible=[ribbon-term-ctl next] Control+Page_Down")
print("pipe-visible=[ribbon-term-ctl prev] Control+Page_Up")
# [desktop-notifications] needs foot 1.20 (ribbon-theme leaves it out on 1.16)
if new:
    print("")
    print("[desktop-notifications]")
    print("command=ribbon-term-ctl activity-app ${app-id}")
PY
}

# 1. Every palette: the foot.ini that ribbon-theme apply writes.
for p in "$PAL"/*.conf; do
	n=$(basename "$p" .conf)
	home="$tmp/home-$n"; mkdir -p "$home"
	if ! HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
		env -u WAYLAND_DISPLAY bash "$RB" apply "$n" --quiet --no-login --no-reload >/dev/null 2>&1; then
		bad "apply $n failed"; continue
	fi
	golden "$p" > "$tmp/want-$n.ini"
	if diff <(grep -v '^#' "$home/.config/foot/foot.ini") "$tmp/want-$n.ini" >"$tmp/diff-$n" 2>&1; then
		ok "foot.ini for $n matches the golden values"
	else
		bad "foot.ini for $n differs from the golden values"; sed 's/^/       /' "$tmp/diff-$n" | head -20
	fi
done

# 1b. foot itself accepts the generated file (the cursor and font lines), when a foot binary is here.
if command -v foot >/dev/null 2>&1; then
	if foot --check-config -c "$tmp/home-ribbon/.config/foot/foot.ini" >/dev/null 2>&1; then
		ok "foot --check-config accepts foot.ini (ribbon)"
	else bad "foot --check-config rejects foot.ini (ribbon)"; fi
fi

# 2. Atomic replace: a new inode each apply, and no temp files left beside it.
home="$tmp/home-atomic"; mkdir -p "$home"
run_apply() { HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
	env -u WAYLAND_DISPLAY bash "$RB" apply "$1" --quiet --no-login --no-reload >/dev/null 2>&1; }
run_apply ribbon-fjord
f="$home/.config/foot/foot.ini"
ino1=$(stat -c %i "$f")
run_apply ribbon-moss
ino2=$(stat -c %i "$f")
if [ "$ino1" != "$ino2" ]; then ok "apply replaces foot.ini by rename (inode $ino1 -> $ino2)"; else bad "foot.ini was rewritten in place"; fi
left=''
for f in "$home/.config/foot"/.* "$home/.config/foot"/*; do
	case "$(basename "$f")" in foot.ini|.|..|'*'|'.*') continue ;; esac
	left="$left $(basename "$f")"
done
if [ -z "$left" ]; then ok "no temp files left in ~/.config/foot"; else bad "temp files left:$left"; fi

# 3. A palette change rewrites the colours (ribbon -> ribbon-amber, with the golden).
home="$tmp/home-change"; mkdir -p "$home"
run_apply2() { HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
	env -u WAYLAND_DISPLAY bash "$RB" apply "$1" --quiet --no-login --no-reload >/dev/null 2>&1; }
run_apply2 ribbon
run_apply2 ribbon-amber
golden "$PAL/ribbon-amber.conf" > "$tmp/want-change.ini"
if diff <(grep -v '^#' "$home/.config/foot/foot.ini") "$tmp/want-change.ini" >/dev/null; then
	ok "palette change ribbon -> ribbon-amber rewrites foot.ini"
else bad "palette change did not rewrite foot.ini"; fi

# 4. Running windows: OSC sequences to the ptys (stubbed as plain files).
home="$tmp/home-osc"; mkdir -p "$home"
printf '' > "$tmp/pty1"; printf '' > "$tmp/pty2"
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
	RIBBON_FOOT_PTYS="$tmp/pty1 $tmp/pty2" env -u WAYLAND_DISPLAY bash "$RB" apply ribbon-fjord --quiet --no-login >/dev/null 2>&1
want_bg=$'\033]11;rgb:0f/1c/21\007'      # fjord BAR #0F1C21
want_fg=$'\033]10;rgb:e2/ef/f1\007'      # fjord FG #E2EFF1
want_cur=$'\033]12;rgb:5f/e3/c0\007'     # fjord ACCENT #5FE3C0
want_c0=$'\033]4;0;rgb:17/33/2f\007'     # fjord PILL #17332F
want_c8=$'\033]4;8;rgb:8f/a9/af\007'     # fjord MUTED #8FA9AF
want_c15=$'\033]4;15;rgb:e2/ef/f1\007'   # bright 7 = FG
for t in "$tmp/pty1" "$tmp/pty2"; do
	missing=0
	for w in "$want_bg" "$want_fg" "$want_cur" "$want_c0" "$want_c8" "$want_c15"; do
		grep -qaF -- "$w" "$t" || missing=$((missing + 1))
	done
	if [ "$missing" -eq 0 ]; then ok "OSC colours reach $(basename "$t")"; else bad "$missing OSC colours missing in $(basename "$t")"; fi
done
: > "$tmp/pty1"
HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
	RIBBON_FOOT_PTYS="$tmp/pty1" env -u WAYLAND_DISPLAY bash "$RB" apply ribbon --quiet --no-login --no-reload >/dev/null 2>&1
if [ ! -s "$tmp/pty1" ]; then ok "--no-reload sends no OSC"; else bad "--no-reload still sent OSC"; fi

# 5. render-from (package build) writes foot.ini and no xfce terminal theme.
out="$tmp/render"
bash "$RB" render-from srcpkgs/ribbon-desktop/files/themes ribbon "$out" >/dev/null 2>&1
if [ -s "$out/foot.ini" ] && [ ! -e "$out/terminal.theme" ]; then ok "render writes foot.ini, not terminal.theme"; else bad "render output wrong"; fi

# 6. A terminal app runs in the chosen terminal (ribbon-terminal: a tab of Ribbon Terminal, on foot, by default), in the
# launcher and in Files; foot's windows are labelled Terminal.
if grep -q 'set cmd "ribbon-terminal -e $cmd"' srcpkgs/ribbon-desktop/files/shell/apps.tcl \
	&& grep -q 'set cmd "ribbon-terminal -e $cmd"' srcpkgs/ribbon-desktop/files/shell/files.tcl \
	&& ! grep -q '"foot -e\|foot --working-directory' srcpkgs/ribbon-desktop/files/shell/apps.tcl srcpkgs/ribbon-desktop/files/shell/files.tcl \
	&& grep -q 'foot Terminal org.codeberg.dnkl.foot Terminal' srcpkgs/ribbon-desktop/files/shell/apps.tcl; then
	ok "the shell runs terminal apps with ribbon-terminal -e"
else bad "apps.tcl / files.tcl terminal entries"; fi
python3 - <<'PY' && ok "rc.xml W-Return and menu.xml Terminal run ribbon-terminal" || { bad "rc.xml/menu.xml terminal command"; status=1; }
import xml.dom.minidom as m, sys
rc = m.parse('srcpkgs/ribbon-desktop/files/xdg/labwc/rc.xml')
hit = [k for k in rc.getElementsByTagName('keybind') if k.getAttribute('key') == 'W-Return']
assert len(hit) == 1 and hit[0].getElementsByTagName('action')[0].getAttribute('command') == 'ribbon-terminal'
menu = m.parse('srcpkgs/ribbon-desktop/files/xdg/labwc/menu.xml')
items = [i for i in menu.getElementsByTagName('item') if i.getAttribute('label') == 'Terminal']
assert len(items) == 1 and items[0].getElementsByTagName('action')[0].getAttribute('command') == 'ribbon-terminal'
PY
if grep -q 'xfce4-terminal' "$RB" srcpkgs/ribbon-desktop/files/xdg/labwc/rc.xml srcpkgs/ribbon-desktop/files/xdg/labwc/menu.xml srcpkgs/ribbon-desktop/files/shell/apps.tcl; then
	bad "xfce4-terminal still referenced in a unit file"
else ok "no xfce4-terminal in ribbon-theme, apps.tcl, rc.xml, menu.xml"; fi

# 7. Tcl still parses (apps.tcl).
if command -v tclsh8.6 >/dev/null 2>&1; then
	if tclsh8.6 <<'TCL' | grep -q '^complete=1$'; then ok "apps.tcl is a complete Tcl script"; else bad "apps.tcl does not parse"; fi
set f [open srcpkgs/ribbon-desktop/files/shell/apps.tcl]; set src [read $f]; close $f
puts "complete=[info complete $src]"
TCL
else echo "  skip apps.tcl parse (no tclsh8.6)"; fi

# 8. Whether a running foot reloads foot.ini: not tested here (no foot binary
# in the container); foot reads it at start-up, OSC covers open windows.
command -v foot >/dev/null 2>&1 && echo "  note foot present: check a palette change in a running window by hand"

exit $status
