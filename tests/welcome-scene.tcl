# welcome-scene.tcl - the first-login welcome (welcome/main.tcl) in each Welcome-* board's state, grabbed for
# tests/steps.d/40-welcome.sh to compare with the boards (RIBBON_WELCOME_TEST=this file, RIBBON_WELCOME_SCENE=1,
# RIBBON_WELCOME_DRYRUN, RIBBON_WELCOME_LSBLK with the board's three partitions).
#   RIBBON_WELCOME_SHOTS  = dir: choose.png drive.png working.png note.png (ImageMagick import of the window)
#   RIBBON_WELCOME_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
namespace eval ws { variable fails 0; variable lines {} }
proc ws::check {what cond} {
	variable fails; variable lines
	if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails }
}
proc ws::wait {ms} { set ::ws::w 0; after $ms {set ::ws::w 1}; vwait ::ws::w }
proc ws::shot {name} {
	page::draw_now; update
	if {![info exists ::env(RIBBON_WELCOME_SHOTS)]} return
	ws::wait 300
	exec import -window [winfo id .w] [file join $::env(RIBBON_WELCOME_SHOTS) $name.png]
}
proc ws::click {x y} { page::draw_now; ui::press $x $y; ui::release $x $y; update }
after 60000 { puts stderr "FAIL timeout"; exit 1 }

# the boards' person and computer
set page::who "Ada Lovelace · hearth"

# Welcome-1-Choose: Flathub and the colour scheme on (the defaults)
ws::check "the defaults: Flathub and a colour scheme" {!$page::pick(hdr) && !$page::pick(drives) && $page::pick(flathub) && $page::pick(scheme)}
ws::shot choose
# each row's switch, and the row around it, turns its choice on and off
foreach {k y} {hdr 120 drives 168 flathub 216 scheme 264} {
	set was $page::pick($k)
	ws::click 393 $y
	ws::check "the $k switch turns it [expr {$was ? "off" : "on"}]" {$page::pick($k) != $was}
	ws::click 100 $y
	ws::check "  and a click on its label back" {$page::pick($k) == $was}
}
# the keyboard: Tab to the first switch, space turns it on
page::key Tab "" 0
ws::check "Tab reaches the HDR switch" {[lindex [ui::focused] 0] eq "hdr"}
page::key space " " 0
ws::check "  and space turns HDR on" {$page::pick(hdr)}
page::key space " " 0
set ui::focus ""; set ui::kbd 0

# Welcome-3-Working: HDR done, Flathub being added
array set page::pick {hdr 1 drives 0 flathub 1 scheme 1}
set page::busy "Adding Flathub…"
ws::shot working
ws::click 100 120
ws::check "while working the rows don't change" {$page::pick(hdr)}
ws::click 350 330
page::key Return "" 0
ws::check "  nor does Continue start again" {$page::step eq "choose" && $page::queue eq {}}
set page::busy ""

# Welcome-2-Drive: the board's three partitions, the second chosen
set page::queue {}
array set page::pick {hdr 0 drives 1 flathub 0 scheme 0}
page::cont
ws::wait 100
ws::check "Continue with the drive on opens the drive step" {$page::step eq "drive"}
ws::check "the free partitions: labelled, unlabelled, labelled" {[lmap p $page::parts { lindex $p 1 }] eq {{Games Disk} /dev/sdb2 Media}}
ws::check "  with their details" {[lindex $page::parts 0 2] eq "/dev/sdb1 · ntfs · 1 TB" && [lindex $page::parts 1 2] eq "ext4 · 2 TB" && [lindex $page::parts 2 2] eq "/dev/sdc1 · exfat · 512 GB"}
ws::click 100 150
ws::check "a click on the second row picks /dev/sdb2" {$page::part eq "/dev/sdb2"}
ws::shot drive
page::key Down "" 0
ws::check "Down picks the next partition" {$page::part eq "/dev/sdc1"}
page::key Up "" 0
ws::check "  and Up the one before" {$page::part eq "/dev/sdb2"}

# Welcome-4-Note: what ribbon-hdr answered
page::show_note sun HDR "Turned on" "Log out and back in to finish (the compositor must switch to its vulkan renderer)."
ws::shot note

if {[info exists ::env(RIBBON_WELCOME_RESULT)]} {
	set f [open $::env(RIBBON_WELCOME_RESULT) w]; puts $f [join $ws::lines \n]; close $f
} else { puts [join $ws::lines \n] }
exit [expr {$ws::fails > 0}]
