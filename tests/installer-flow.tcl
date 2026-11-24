# installer-flow.tcl - drive the Tk installer through every page with key
# presses and clicks, against the fake backend, and check what it collects
# (RIBBON_INSTALLER_SCENE=this file). Exits 0 when the install reaches Done.
set here [file dirname [file normalize [info script]]]
set ::env(RIBBON_INSTALLER_FAKE) [file join $here installer-fake-backend.sh]
set ::env(RIBBON_FAKE_DELAY) 0.01
proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
set ::fails 0
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr ::fails }
}
proc key {sym {char ""}} { update; page::key $sym $char 0; update }
proc type {text} { foreach ch [split $text ""] { update; page::key [expr {$ch eq " " ? "space" : $ch}] $ch 0 }; update }
# window coordinates for the pages' bodies, as on the 1440 x 900 boards
# (where page::head ends at 119), moved to where page::head ends in this
# layout (the compact Inst-C* one too); fb: the footer's buttons
proc by {y} { expr {[page::head_end] + $y - 119} }
proc fb {{d 17}} { expr {$page::FB + $d} }
# click at window coordinates
proc click {x y} { update; ui::press [expr {$x + $ui::ox}] [expr {$y + $ui::oy}]; ui::release [expr {$x + $ui::ox}] [expr {$y + $ui::oy}]; update }
proc drag {x0 x1 y} { update; ui::press [expr {$x0 + $ui::ox}] [expr {$y + $ui::oy}]; ui::motion [expr {$x1 + $ui::ox}] [expr {$y + $ui::oy}]; ui::release [expr {$x1 + $ui::ox}] [expr {$y + $ui::oy}]; update }
set S page::S

page::probed [exec {*}[backend::cmd probe]]
# manual partitioning: New on free space through the dialog, Edit, Delete
set page::S(mode) manual
page::go manual
click 400 [by [expr {196 + 40 * 3 + 20}]]
check "select the free row" {$page::S(mansel) == 3}
click 330 [by [expr {196 + 40 * 4 + 12 + 19}]]
check "New opens the dialog" {[dict get $page::dialog kind] eq "new"}
key BackSpace; key BackSpace; key BackSpace; key BackSpace; key BackSpace; key BackSpace
type 400
key Tab; key Tab
check "Tab reaches the mount field" {$ui::focus eq "dmount"}
key Return
set r [lindex [page::plan_rows] 3]
check "a new 400 GB / partition" {[dict get $r kind] eq "new" && abs([dict get $r size] - 400000000000) < 1048576 && [dict get $r mount] eq "/"}
check "the rest stays free" {[dict get [lindex [page::plan_rows] 4] kind] eq "free"}
check "status: ready" {[lindex [page::plan_status] 0] == 1}
set page::S(mansel) 2
page::part_edit
ui::fset dmount /
page::dialog_save
check "an existing partition kept as it is can't be /" {[dict get $page::dialog err] eq "/ must be Btrfs" && [dict get [lindex [page::plan_rows] 2] mount] eq ""}
page::dialog_fs btrfs
key Escape
check "Esc cancels the dialog" {$page::dialog eq "" && [dict get [lindex [page::plan_rows] 2] fs] eq "ntfs"}
set page::S(mansel) 3
page::part_delete
check "Delete returns the space" {[llength [page::plan_rows]] == 4 && [dict get [lindex [page::plan_rows] 3] kind] eq "free"}
check "status: needs /" {[lindex [page::plan_status] 0] == 0}
page::next
check "Continue stays without /" {$page::S(page) eq "manual"}
set page::S(mode) erase
page::reset_plan

page::go welcome
# welcome: typing goes to the language search; arrows pick
update
type deu
check "language search filters" {[lindex $page::S(langres) 0 0] eq "Deutsch" && [llength $page::S(langres)] == 1}
check "the match is chosen" {$page::S(lang) eq "de_DE.UTF-8"}
key BackSpace; key BackSpace; key BackSpace
key Down
check "Down moves the language" {$page::S(lang) ne "de_DE.UTF-8"}
click 306 [by [expr {214 + 38 + 10}]]
check "a click picks English (UK)" {$page::S(lang) eq "en_GB.UTF-8"}
click 900 [by 300]
check "Try it first is a choice" {$page::S(welcome) eq "try"}
click 900 [by 200]
key Return
check "Enter continues to Keyboard" {$page::S(page) eq "keyboard"}
# keyboard: the test field has the focus; the zone search filters
type "£@"
check "the test field takes typing" {[ui::fval keytest] eq "£@"}
click 800 [by 185]
type tokyo
check "zone search finds Tokyo" {$page::S(tz) eq "Asia/Tokyo"}
key Escape
key Tab
check "Tab moves the focus" {$ui::focus ne ""}
click 400 [by [expr {166 + 38 * 3 + 10}]]
check "layout click (German)" {[lindex $data::layouts [expr {$page::S(layout) * 3}]] eq "German"}
click 1100 700
key Return
check "on to the disk page" {$page::S(page) eq "disk"}
# disk: alongside Windows, and the games drive
click 800 [by [expr {166 + 60 + 10 + 30}]]
check "mode radios" {$page::S(mode) eq "alongside"}
click 400 [by 351]
check "games drive toggle" {$page::S(games) == 1}
click 1000 [fb]
check "Continue goes to alongside" {$page::S(page) eq "alongside"}
# alongside: drag the divider; fields follow; limits hold
drag 700 1050 [by 180]
check "drag clamps to Ribbon's minimum (40 GB)" {[ui::fval ribbon] == 40}
drag 1050 300 [by 180]
check "drag clamps to Windows' minimum (440 GB)" {[ui::fval keep] == 440}
click 400 [by 280]
key BackSpace; key BackSpace; key BackSpace
type 600
check "typing GB moves the share" {$page::S(keep) == 600000000000 && [ui::fval ribbon] == 400}
key Return
check "on to disk set-up" {$page::S(page) eq "setup"}
# set-up: the filesystem cards (bcachefs picks its boot loader; no ZFS
# card next to Windows: ZFS needs the whole disk), back to btrfs;
# passphrase twice
check "alongside: Btrfs and bcachefs cards, no ZFS" {[page::fs_opts] eq {btrfs bcachefs} && [llength [lsearch -all [lmap f $ui::focusables { lindex $f 0 }] fs-*]] == 2}
click 500 [by 280]
check "bcachefs card" {$page::S(fs) eq "bcachefs" && $page::S(boot) eq "limine"}
click 500 [by 200]
check "Btrfs card" {$page::S(fs) eq "btrfs" && $page::S(boot) eq "limine"}
type "correct horse"
key Tab
check "Tab to the repeat field" {$ui::focus eq "pass2"}
type "correct horse"
key Return
check "on to hardware" {$page::S(page) eq "hardware"}
# hardware: driver series, swap custom with a size, GRUB
click [expr {466 + 3 + 145 * 2 + 20}] [by 420]
check "NVIDIA series segment" {[dict get $page::S(drivers) gpu0] eq "470"}
click [expr {294 + 3 + 84 * 3 + 20}] [by 500]
check "swap Custom focuses the size" {$page::S(swap) eq "custom" && $ui::focus eq "swapgb"}
key BackSpace; key BackSpace; type 16
check "custom swap size" {$page::S(swapsize) == 16000000000}
click 1000 [by 500]
check "GRUB" {$page::S(boot) eq "grub"}
click 1020 [by 160]
check "driver can be skipped" {![dict exists $page::S(drivers) gpu0]}
click 1020 [by 160]
key Return
check "on to apps" {$page::S(page) eq "apps"}
click 380 [by 170]
check "app tile toggles" {"steam" ni $page::S(apps)}
key Return
# you: the user name follows the name
check "on to you" {$page::S(page) eq "you"}
type "Zoë Brontë"
check "user name derived" {[ui::fval username] eq "zoe" && [ui::fval hostname] eq "zoe-desktop"}
key Return
check "an empty password stops Continue" {$page::S(page) eq "you" && $ui::focus eq "upass1"}
type "s3cret-Pass"
key Tab
type "s3cret-Pass"
key Return
check "on to the summary" {$page::S(page) eq "summary"}
set rows [page::summary_rows]
check "summary: keyboard" {[string match "*German keyboard · Asia/Tokyo" [lindex $rows 2]]}
check "summary: alongside" {[string match "*alongside Windows (it keeps 600 GB)" [lindex $rows 6]]}
# Change jumps back and returns
click 1040 [by [expr {134 + 52 * 4 + 20}]]
check "Change jumps to apps" {$page::S(page) eq "apps"}
key Return
check "and Continue comes back" {$page::S(page) eq "summary"}
set a [page::answers]
check "answers: games drive" {[dict get $a games] eq {{dev /dev/sda1 name games}}}
check "answers: swap" {[dict get $a swap] eq {mode custom size 16000000000}}
check "answers: no secrets in the file" {![string match *s3cret* $a] && ![string match *horse* $a]}
# install against the fake backend
key Return
check "installing" {$page::S(page) eq "progress"}
proc wait_done {n} {
	if {$page::S(page) eq "done"} {
		check "progress reached Done" 1
		check "the log has lines" {[llength $page::S(log)] > 5}
		exit [expr {$::fails ? 1 : 0}]
	}
	if {$n > 300 || $page::S(err) ne ""} { puts "  FAIL install did not finish ($page::S(err))"; exit 1 }
	after 50 [list wait_done [incr n]]
}
wait_done 0
