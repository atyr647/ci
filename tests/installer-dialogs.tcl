# installer-dialogs.tcl - the installer's dialogs, error and edge states
# (Inst-11 .. Inst-15, Inst-5b) doing their jobs against the fake backend
# (RIBBON_INSTALLER_SCENE=this file; tests/steps.d/93-installer-dialogs.sh):
#   - the New and Edit partition sheets: only the sheet takes clicks, swap has
#     no mount point, a refused Save says why and changes nothing, Save adds;
#   - Windows not ready: the strip and Check again (the backend asked afresh),
#     Continue going to Check again until it is ready;
#   - Summary and Manual refused by the backend's check;
#   - the probe refused (as a dismissed pkexec): its page, and Try again;
#   - five or more disks and ten or more partitions scroll, clear of the footer;
#   - the error screen's log breaks at spaces;
#   - app::place on small, narrow and short screens, and app::output on the
#     main one of two outputs.
# Prints "  ok ..." / "  FAIL ..."; exits 1 on a failure. Runs at any screen size.
set here [file dirname [file normalize [info script]]]
set ::env(RIBBON_INSTALLER_FAKE) [file join $here installer-fake-backend.sh]
proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
set ::fails 0
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr ::fails }
}
proc settle {} { update; page::draw_now; update }
proc click {x y} { settle; ui::press [expr {$x + $ui::ox}] [expr {$y + $ui::oy}]; ui::release [expr {$x + $ui::ox}] [expr {$y + $ui::oy}]; settle }
proc key {sym {char ""}} { settle; page::key $sym $char 0; settle }
proc ids {} { lmap f $ui::focusables { lindex $f 0 } }
proc fpos {id} { lrange [lsearch -inline -index 0 $ui::focusables $id] 2 5 }
# click the middle of a Tab stop
proc press {id} { lassign [fpos $id] x y w h; click [expr {$x + $w / 2}] [expr {$y + $h / 2}] }
proc wait_for {cond {ms 5000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]] && [clock milliseconds] < $end} { after 20; update }
	uplevel #0 [list expr $cond]
}
# nothing the page column draws reaches the footer's line (16 px clear)
proc clear_of_footer {} {
	foreach f $ui::focusables { lassign $f id - x y w h; if {$x >= 250 && $y < $page::FL && $y + $h > $page::FL - 16} { return 0 } }
	foreach h $ui::hits { lassign $h x0 y0 x1 y1; if {$x0 >= 250 && $y0 < $page::FL && $y1 - $y0 < 600 && $y1 > $page::FL - 16} { return 0 } }
	return 1
}

page::probed [exec {*}[backend::cmd probe]]
set FL $page::FL

# ---- the partition sheets ---------------------------------------------------------
set page::S(mode) manual
page::go manual
set page::S(mansel) 3
settle
page::part_new
settle
check "New opens the sheet over a 50 % scrim" {[dict get $page::dialog kind] eq "new" && $ui::dim == 0 && "dsave" in [ids]}
lassign [fpos dsave] sx sy sw sh
check "the sheet's Save is in a 640 wide sheet centred on the window" {$sx + $sw == 870 - 28 && $sx > 230}
click 300 [expr {[page::head_end] + 32 + 38 + 20}]
check "a click on the page behind does nothing" {$page::dialog ne "" && $page::S(mansel) == 3}
check "New asks the size, the format and the mount point" {[lsearch -all -inline -regexp [ids] {^d(size|fs|mount)$}] eq {dsize dfs dmount}}
lassign [fpos dfs] fx fy fw fh
click [expr {$fx + $fw - 20}] [expr {$fy + 19}]
check "swap: the format is swap and there is no mount point" {[dict get $page::dialog fs] eq "swap" && "dmount" ni [ids]}
lassign [fpos dfs] fx fy fw fh
click [expr {$fx + 20}] [expr {$fy + 19}]
check "back to Btrfs: the mount point is asked again" {[dict get $page::dialog fs] eq "btrfs" && "dmount" in [ids]}
ui::fset dsize 200
ui::fset dmount home
press dsave
check "a refused Save says why and changes nothing" {$page::dialog ne "" && [dict get $page::dialog err] eq "A mount point starts with /" && [llength [page::plan_rows]] == 4}
ui::fset dmount /
press dsave
check "Save adds a 200 GB / partition and closes the sheet" {$page::dialog eq "" && [dict get [lindex [page::plan_rows] 3] mount] eq "/" && abs([dict get [lindex [page::plan_rows] 3] size] - 200e9) < 2e6}
set page::S(mansel) 2
page::part_edit
settle
check "Edit of Windows' partition: no size field, the erase box" {"dsize" ni [ids] && "dformat" in [ids] && "dmount" in [ids]}
ui::fset dmount /
press dsave
check "/ on NTFS kept as it is is refused, with the reason in the footer" {[dict get $page::dialog err] eq "/ must be Btrfs" && [dict get [lindex [page::plan_rows] 2] mount] eq ""}
press dcancel
check "Cancel closes the sheet" {$page::dialog eq ""}

# ---- the plan refused by the backend's check (Inst-13b) ------------------------------------
set ::env(RIBBON_FAKE_CHECK) "an EFI partition at /boot/efi needs GRUB; with Limine the EFI partition goes at /boot (it holds the kernels)"
page::next
settle
check "Continue with a plan the backend refuses stays on Manual, saying why" {$page::S(page) eq "manual" && [string match "an EFI*" $page::S(manmsg)]}
check "... and the page still ends clear of the footer" {[clear_of_footer]}
unset ::env(RIBBON_FAKE_CHECK)

# ---- ten or more partitions scroll ------------------------------------------------------------
set rows {}
for {set i 1} {$i <= 14} {incr i} {
	lappend rows [dict create kind part dev /dev/nvme0n1p$i start [expr {$i * 10000000000}] size 9000000000 fs ext4 format 0 mount "" note ""]
}
dict set page::S(plan) $page::S(mandisk) $rows
set page::S(mansel) 0
set page::S(mantop) 0
set ui::focus parts
settle
set nhit [llength [lsearch -all -index 4 -glob $ui::hits {page::row_click*}]]
check "14 partitions: $nhit rows drawn, the tools row clear of the footer" {$nhit < 14 && $nhit >= 3 && [clear_of_footer]}
for {set k 0} {$k < 20} {incr k} { key Down }
check "Down to the last partition scrolls it into view" {$page::S(mansel) == 13 && $page::S(mantop) > 0 && [lsearch -index 4 $ui::hits {page::row_click 13}] >= 0}
set page::S(mantop) 0
lassign [fpos parts] px py
ui::scroll [expr {$ui::ox + $px + 100}] [expr {$ui::oy + $py + 20}] 1
settle
check "the wheel scrolls the partitions" {$page::S(mantop) == 1}
page::reset_plan

# ---- five or more disks scroll ---------------------------------------------------------------
set disks0 [dict get $page::probe disks]
set d0 [lindex $disks0 0]
set many {}
for {set i 0} {$i < 7} {incr i} { lappend many [dict merge $d0 [dict create dev /dev/sd[string index abcdefg $i] model "Disk $i" parts {} free {} os {}]] }
dict set page::probe disks $many
set page::S(disk) /dev/sda
set page::S(disktop) 0
page::go disk
settle
set cards [lsearch -all -inline -glob [ids] disk-*]
check "7 disks: [llength $cards] cards drawn, clear of the footer" {[llength $cards] < 7 && [llength $cards] >= 1 && [clear_of_footer]}
set ui::focus [lindex $cards end]
key Down
check "Down past the last card scrolls the next one into view" {$page::S(disktop) == 1 && $ui::focus eq "disk-/dev/sd[string index abcdefg [llength $cards]]" && $ui::focus in [ids]}
key space
check "Space picks it" {$page::S(disk) eq "/dev/sd[string index abcdefg [llength $cards]]"}
lassign [fpos $ui::focus] cx cy
ui::scroll [expr {$ui::ox + $cx + 50}] [expr {$ui::oy + $cy + 20}] -1
settle
check "the wheel scrolls the disks" {$page::S(disktop) == 0}
dict set page::probe disks $disks0
set page::S(disk) [dict get $d0 dev]
page::reset_alongside
page::reset_plan

# ---- Windows not ready (Inst-12) ---------------------------------------------------------------
set page::S(mode) alongside
page::go alongside
set ::env(RIBBON_FAKE_UNSAFE) 1
page::windows_ready
settle
check "Windows hibernated: the strip and Check again" {"recheck" in [ids] && ![dict get [page::shareable] resize safe]}
key Return
check "Continue stays, and goes to Check again" {$page::S(page) eq "alongside" && $ui::focus eq "recheck"}
unset ::env(RIBBON_FAKE_UNSAFE)
press recheck
check "Check again asks the backend afresh: ready, the strip is gone" {[dict get [page::shareable] resize safe] && "recheck" ni [ids]}
key Return
check "and Continue goes on" {$page::S(page) eq "setup"}
set page::S(mode) erase

# ---- Summary refused by the backend's check (Inst-13) -----------------------------------------
ui::fset fullname "Alex Tyrone"; page::derive_user
foreach f {upass1 upass2} { ui::fset $f pw }
ui::fset pass1 x; ui::fset pass2 x
page::go you
set ::env(RIBBON_FAKE_CHECK) "the user name 'alex' is used by the system; pick another"
key Return
check "at Summary the backend's refusal is shown" {$page::S(page) eq "summary" && [string match "the user name*" $page::S(checkmsg)]}
key Return
check "and Erase and install does not start" {$page::S(page) eq "summary" && !$page::S(started)}
unset ::env(RIBBON_FAKE_CHECK)

# ---- the error screen's log ---------------------------------------------------------------------
set page::S(log) {}
page::go progress
page::progress_line "LOG rsync: write failed: No space left on device (28)"
page::progress_line "ERROR {rsync failed: no space left on the disk}"
settle
check "the error screen: Close, no Back" {"close" in [ids] && "back" ni [ids] && $page::S(err) ne ""}
set shown {}
foreach l $page::S(log) {
	set l [regsub -all {\s+} [string trim $l] " "]
	while {[string length $l] > 46} { set k [string last " " $l 45]; if {$k < 8} { set k 46 }; lappend shown [string range $l 0 [expr {$k - 1}]]; set l "  [string trimleft [string range $l $k end]]" }
	lappend shown $l
}
check "a long log line breaks at a space" {[lindex $shown 0] eq "rsync: write failed: No space left on device" && [lindex $shown 1] eq "  (28)"}
set page::S(err) ""

# ---- where the window goes ------------------------------------------------------------------------
set H0 $ui::H
foreach {sw sh compact x y why} {
	1440 900 0 170 104 "the boards' place"
	1366 768 1 133 64 "between the bars and the dock"
	1280 720 1 90 54 "clear of the top bars (the dock's margin taken)"
	1024 768 1 -76 64 "narrower than 1100: the right edge (Continue) on screen"
	1366 660 1 133 20 "under 694: the footer kept on screen"
} {
	page::layout $compact
	lassign [app::place $sw $sh] px py
	set cont [expr {$px + 1060}]
	check "${sw}x$sh: the window at $px, $py ($why)" {$px == $x && $py == $y && $cont <= $sw && $py + $page::FB + 38 <= $sh}
}
page::layout [expr {$H0 != 720}]
# two outputs side by side: the main one (the first, or display.conf's) holds the window
set json {[{"name":"DP-1","enabled":true,"modes":[{"width":1920,"height":1080,"current":true}],"position":{"x":0,"y":0},"scale":1.0,"transform":"normal"},
{"name":"HDMI-A-1","enabled":true,"modes":[{"width":1366,"height":768,"current":true}],"position":{"x":1920,"y":0},"scale":1.0,"transform":"normal"}]}
set ::env(RIBBON_SCREEN) 3286x1080
set display::trusted 1
proc display::screen {} { list 3286 1080 }
unset ::env(RIBBON_SCREEN)
set cfg [file join $::env(XDG_RUNTIME_DIR) dialogs-cfg-[pid]]
file delete -force $cfg
set ::env(XDG_CONFIG_HOME) $cfg
display::take $json
check "two outputs: the window's output is the main one, not both" {[app::output] eq {0 0 1920 1080}}
file mkdir [file join $::env(XDG_CONFIG_HOME) ribbon]
set fh [open [file join $::env(XDG_CONFIG_HOME) ribbon display.conf] w]; puts $fh "main HDMI-A-1"; close $fh
display::take $json
lassign [app::output] ox oy ow oh
page::layout [page::compact_for $oh]
lassign [app::place $ow $oh] px py
check "with HDMI-A-1 the main output the window is on it: [expr {$ox + $px}], [expr {$oy + $py}]" {$ox == 1920 && $ox + $px == 1920 + 133 && $oy + $py == 64}
file delete -force $cfg
page::layout [expr {$H0 != 720}]

# ---- the probe refused (Inst-15) ------------------------------------------------------------------
set ::env(RIBBON_FAKE_PROBE_FAIL) 1
page::go welcome
backend::start_probe page::probed page::probe_failed
check "a dismissed password prompt: the page that says so" {[wait_for {$page::S(page) eq "noprobe"}] && [lindex $page::S(probefail) 0] eq "Permission to look at the disks and hardware was refused." && [string match "*Request dismissed*" [lindex $page::S(probefail) 1]]}
settle
check "its buttons: Try again and Close" {"continue" in [ids] && "close" in [ids]}
unset ::env(RIBBON_FAKE_PROBE_FAIL)
dict set page::probe disks {}
press continue
check "Try again runs the check again: the computer is read" {[wait_for {[llength [page::disks]] > 0}] && $page::S(page) eq "welcome"}

exit [expr {$::fails ? 1 : 0}]
