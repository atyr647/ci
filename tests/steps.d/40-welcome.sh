#!/bin/sh
# The first-login welcome (welcome/main.tcl, boards Welcome-1..4 from design/tools/gen_welcome.py):
#  - tests/test-welcome.sh: the window driven through every choice (tests/welcome-flow.tcl), the commands it would
#    run, welcome-pending replaced by welcome-done, no zenity;
#  - tests/welcome-scene.tcl: each board's state drawn where the board puts the dialog, compared with the board's crop
#    in tests/fixtures/welcome (both blurred, RMSE < 0.05), and its rows, switches and keys pressed;
#  - what a command answers shown as a note; "Not now" leaves no welcome-done; autostart runs it only while
#    welcome-pending exists.
# Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip welcome (no wish8.6 / xvfb-run)"; exit 0
fi
fails=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails + 1)); }
sh tests/test-welcome.sh || fails=$((fails + 1))
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
home() { rm -rf "${T:?}/home"; mkdir -p "$T/home/.config/ribbon"; cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"; : > "$T/home/.config/ribbon/welcome-pending"; }
welcome() { # TEST-SCRIPT [VAR=VALUE ...]: runs the welcome under xvfb (1440 x 900)
	script=$1; shift
	env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" RIBBON_SHELL_DIR="$D/shell" \
		RIBBON_WELCOME_DRYRUN="$T/cmds" RIBBON_WELCOME_LSBLK="$T/lsblk" RIBBON_WELCOME_TEST="$script" "$@" \
		timeout -k 5 120 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/welcome/main.tcl" -name ribbon-welcome >"$T/out" 2>&1
}

# the boards' states
home; rm -f "$T/cmds"; mkdir -p "$T/shots"
printf '%s\n' '/dev/sda1 part vfat 512M  /boot/efi' '/dev/sda2 part btrfs 900G  /' '/dev/sdb1 part ntfs 1T Games\x20Disk ' \
	'/dev/sdb2 part ext4 2T  ' '/dev/sdc1 part exfat 512G Media ' > "$T/lsblk"
if welcome "$PWD/tests/welcome-scene.tcl" RIBBON_WELCOME_SCENE=1 RIBBON_WELCOME_SHOTS="$T/shots" RIBBON_WELCOME_RESULT="$T/res"; then
	sed 's/^/  /' "$T/res"
else
	[ -f "$T/res" ] && sed 's/^/  /' "$T/res"; sed 's/^/       /' "$T/out"; bad "the welcome's scene"
fi
if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1; then
	for s in choose drive working note; do
		[ -s "$T/shots/$s.png" ] || { bad "no picture of the $s step"; continue; }
		convert "$T/shots/$s.png" -blur 0x2 "$T/a.png"; convert "tests/fixtures/welcome/$s.png" -blur 0x2 "$T/b.png"
		r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then ok "$s matches its board (blurred RMSE $r)"; else bad "$s against its board: RMSE ${r:-?}"; fi
	done
else
	echo "  skip the comparison with the boards (no ImageMagick)"
fi

# what the commands answer: HDR's message and a failed Flathub are notes; OK goes on
home; rm -f "$T/cmds"; : > "$T/lsblk"
cat > "$T/notes.tcl" <<'EOF'
namespace eval t {}
proc t::wait {ms} { set ::t::w 0; after $ms {set ::t::w 1}; vwait ::t::w }
proc t::fail {msg} { puts stderr "FAIL $msg"; exit 1 }
after 30000 { puts stderr "FAIL timeout"; exit 1 }
array set page::pick {hdr 1 drives 1 flathub 1 scheme 0}
page::key Return "" 0; t::wait 200
if {$page::step ne "note" || [lrange $page::note 1 2] ne {HDR {Turned on}}} { t::fail "HDR's note: $page::step $page::note" }
if {[lindex $page::note 3] ne "Log out and back in to finish."} { t::fail "HDR's message: [lindex $page::note 3]" }
page::key Return "" 0; t::wait 200
if {$page::step ne "note" || [lrange $page::note 1 2] ne {{Games drive} {No free partition}}} { t::fail "no partitions: $page::step $page::note" }
page::key Return "" 0; t::wait 200
if {$page::step ne "note" || [lrange $page::note 1 3] ne {Flathub {Not enabled} {Unable to load summary from remote flathub}}} { t::fail "Flathub's note: $page::step $page::note" }
page::key Escape "" 0; t::wait 200
t::fail "did not finish"
EOF
welcome "$T/notes.tcl" RIBBON_WELCOME_ANSWER_ribbon_hdr='ok:Log out and back in to finish.' \
	RIBBON_WELCOME_ANSWER_flatpak='fail:error: Unable to load summary from remote flathub'
if [ $? -eq 0 ] && [ -e "$T/home/.config/ribbon/welcome-done" ] && [ ! -e "$T/home/.config/ribbon/welcome-pending" ]; then
	ok "a command's answer is a note (HDR's message, no free partition, Flathub's error) and OK goes on to the end"
else bad "notes: $(tail -n 3 "$T/out")"; fi

# Not now: the marker goes, and no welcome-done (the next login asks again)
home; rm -f "$T/cmds"
printf '%s\n' 'page::key Escape "" 0' 'after 3000 {puts stderr "FAIL still open"; exit 1}' > "$T/later.tcl"
if welcome "$T/later.tcl" && [ ! -e "$T/home/.config/ribbon/welcome-pending" ] && [ ! -e "$T/home/.config/ribbon/welcome-done" ] && [ ! -e "$T/cmds" ]; then
	ok "Not now (Escape) closes it, runs nothing, removes welcome-pending and writes no welcome-done"
else bad "not now: $(tail -n 3 "$T/out")"; fi

# closing the window, and the Not now button, are Not now too
home; rm -f "$T/cmds"
printf '%s\n' 'uplevel #0 [wm protocol .w WM_DELETE_WINDOW]' 'after 3000 {puts stderr "FAIL still open"; exit 1}' > "$T/close.tcl"
if welcome "$T/close.tcl" && [ ! -e "$T/home/.config/ribbon/welcome-pending" ] && [ ! -e "$T/home/.config/ribbon/welcome-done" ] && [ ! -e "$T/cmds" ]; then
	ok "closing the window removes welcome-pending, runs nothing and writes no welcome-done"
else bad "closing the window: $(tail -n 3 "$T/out")"; fi
home; rm -f "$T/cmds"
printf '%s\n' 'page::draw_now; update' 'set b [lsearch -inline -glob -index 4 $ui::hits *not_now*]' \
	'lassign $b x0 y0 x1 y1; ui::press [expr {($x0 + $x1) / 2}] [expr {($y0 + $y1) / 2}]; ui::release 0 0' \
	'after 3000 {puts stderr "FAIL still open"; exit 1}' > "$T/notnow.tcl"
if welcome "$T/notnow.tcl" && [ ! -e "$T/home/.config/ribbon/welcome-pending" ] && [ ! -e "$T/home/.config/ribbon/welcome-done" ] && [ ! -e "$T/cmds" ]; then
	ok "the Not now button does the same"
else bad "Not now button: $(tail -n 3 "$T/out")"; fi

# the drive step offers only what ribbon-drives can mount (no LVM, RAID, ZFS or bcachefs members), and the wheel
# scrolls past the fifth
home; rm -f "$T/cmds"
printf '%s\n' '/dev/sda3 part LVM2_member 500G  ' '/dev/sdb1 part linux_raid_member 1T  ' '/dev/sdb2 part zfs_member 1T  ' \
	'/dev/sdb3 part bcachefs 1T  ' '/dev/sdc1 part ext4 100G a ' '/dev/sdc2 part xfs 100G b ' '/dev/sdc3 part btrfs 100G c ' \
	'/dev/sdc4 part ntfs 100G d ' '/dev/sdc5 part exfat 100G e ' '/dev/sdc6 part vfat 100G f ' > "$T/lsblk"
cat > "$T/drives.tcl" <<'EOF'
namespace eval t {}
proc t::fail {msg} { puts stderr "FAIL $msg"; exit 1 }
after 30000 { puts stderr "FAIL timeout"; exit 1 }
array set page::pick {hdr 0 drives 1 flathub 0 scheme 0}
page::cont; update
set names [lmap p $page::parts { lindex $p 1 }]
if {$names ne {a b c d e f}} { t::fail "offered: $names" }
page::draw_now; update
ui::scroll 200 150 1
if {$page::top != 1} { t::fail "the wheel down: top $page::top" }
ui::scroll 200 150 1
if {$page::top != 1} { t::fail "the wheel past the end: top $page::top" }
ui::scroll 200 150 -1
if {$page::top != 0} { t::fail "the wheel up: top $page::top" }
exit 0
EOF
if welcome "$T/drives.tcl"; then
	ok "the drive step offers only filesystems ribbon-drives mounts, and the wheel scrolls the sixth into view"
else bad "drive list: $(tail -n 3 "$T/out")"; fi

# started only while welcome-pending exists, and only for an installed system's first login
grep -q 'welcome-pending" \] && ribbon-welcome' "$D/xdg/labwc/autostart" && ok "labwc's autostart runs ribbon-welcome only while welcome-pending exists" ||
	bad "autostart does not gate ribbon-welcome on welcome-pending"
grep -q 'exec wish .*/usr/lib/ribbon/welcome/main.tcl' "$D/bin/ribbon-welcome" && ok "ribbon-welcome runs the Tk welcome" || bad "bin/ribbon-welcome"

[ $fails -eq 0 ] && echo "Welcome: all checks passed" || { echo "Welcome: $fails failed"; exit 1; }
