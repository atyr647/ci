# welcome-flow.tcl - drives the welcome window (RIBBON_WELCOME_TEST=this file,
# RIBBON_WELCOME_DRYRUN=FILE, RIBBON_WELCOME_LSBLK=FILE): picks every
# choice, the second partition, and checks the commands it would run.
# RIBBON_WELCOME_SHOT=DIR keeps a screenshot of each step (ImageMagick import).
namespace eval t {}
proc t::wait {ms} { set ::t::w 0; after $ms {set ::t::w 1}; vwait ::t::w }
proc t::shot {name} {
	if {![info exists ::env(RIBBON_WELCOME_SHOT)]} return
	update; t::wait 500
	catch {exec import -window root [file join $::env(RIBBON_WELCOME_SHOT) $name.png]}
}
proc t::click {x y} { ui::press $x $y; ui::release $x $y; t::wait 150 }
proc t::fail {msg} { puts stderr "FAIL $msg"; exit 1 }
after 40000 { puts stderr "FAIL timeout"; exit 1 }
t::wait 300
if {$page::step ne "choose"} { t::fail "starts on $page::step" }
if {$page::pick(hdr) || $page::pick(drives) || !$page::pick(flathub) || !$page::pick(scheme)} { t::fail "defaults" }
t::shot choose
# turn HDR and the drive on: click their rows (the first and second)
t::click 100 110
t::click 100 166
if {!$page::pick(hdr) || !$page::pick(drives)} { t::fail "row clicks" }
# Continue: Return with nothing focused
page::key Return "" 0
t::wait 300
if {$page::step ne "drive"} { t::fail "no drive step ($page::step)" }
if {[llength $page::parts] != 2} { t::fail "partitions: $page::parts" }
t::shot drive
# the second partition, then Mount
t::click 100 166
if {$page::part ne "/dev/sdb2"} { t::fail "picked $page::part" }
page::key Return "" 0
t::wait 300
if {$page::step ne "note"} { t::fail "no note after mounting ($page::step)" }
t::shot note
page::key Return "" 0
t::wait 300
t::fail "did not finish"
