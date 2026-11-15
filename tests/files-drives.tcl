# files-drives.tcl - Ribbon Files' DRIVES rows and free space (shell/files-drives.tcl), in the real shell under
# xvfb (RIBBON_SHELL_TEST=this file; tests/steps.d/64-files-drives.sh). The step starts a private system bus with
# the UDisks2 stand-in (tests/fixtures/udisks.tcl) and puts a df stub on PATH that sleeps DF_SLEEP seconds and
# logs its calls. The checks: opening and drawing a Files window does not wait for df (timed), the usage and the
# free space are drawn once df answers, an answer is reused for a few seconds; the rows are UDisks2's volumes (an
# unmounted stick gets a row without a bar; ignored, swap and internal non-system mounts get none); a click on
# an unmounted row calls Filesystem.Mount and opens where it was mounted; a failed mount says why; a card
# plugged in later shows up (InterfacesAdded). FILES_DRIVES_MODE=nobus: no UDisks2, the rows are df's.

set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 120000 {puts "  FAIL the drive checks took more than 120 s"; exit 1}
proc check {what cond {why ""}} {
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { incr ::failed; puts "  FAIL $what${why}" }
}
# wait (the event loop runs) until COND holds or MS have passed; returns whether it held
proc waitfor {ms cond} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel 1 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 30 { set ::wake 1 }; vwait ::wake
	}
	return 1
}
proc dfcalls {pat} {
	if {[catch {open $::env(DF_LOG)} fh]} { return 0 }
	set n 0
	foreach l [split [read $fh] \n] { if {[string match $pat $l]} { incr n } }
	close $fh
	return $n
}
proc slurp {f} {
	if {[catch {open $f} fh]} { return "" }
	set t [read $fh]; close $fh
	return $t
}
proc canvas_text {c} {
	set s ""
	foreach i [$c find all] { if {[$c type $i] eq "text"} { append s [$c itemcget $i -text] } }
	# text::draw splits a line into runs and leaves out the spaces between them
	return [string map {" " ""} $s]
}
proc row {label} {
	foreach d [files::drives] { if {[lindex $d 0] eq $label} { return $d } }
	return ""
}
proc labels {} { lmap d [files::drives] { lindex $d 0 } }

set mode [expr {[info exists ::env(FILES_DRIVES_MODE)] ? $::env(FILES_DRIVES_MODE) : "udisks"}]
set dir [file join $::env(HOME) folder]
file mkdir $dir

# opening a window and drawing it again while df sleeps
set t0 [clock milliseconds]
set w [files::show $dir]
update
set open_ms [expr {[clock milliseconds] - $t0}]
set t0 [clock milliseconds]
files::draw $w
set draw_ms [expr {[clock milliseconds] - $t0}]
check "a window opens without waiting for df ($open_ms ms)" {$open_ms < 1500}
check "a draw does not wait for df ($draw_ms ms)" {$draw_ms < 300}
check "no free space before df answers" {![string match "*free*" [canvas_text $w.status]]}
check "df runs in the background (both asked)" {[waitfor 2000 {[dfcalls "*used,size,target*"] == 1 && [dfcalls "*avail,target*"] == 1}]}

check "the free space is drawn when df answers" {[waitfor 15000 {[string match "*System·123.5MBfree*" [canvas_text $w.status]]}]} \
	": [canvas_text $w.status]"
check "the System row has its usage" {[waitfor 5000 {[lindex [row System] 3] eq "100000000000"}]} ": [files::drives]"
check "a gaming drive is listed" {[lindex [row Ssd] 1] eq "/mnt/games/ssd"}
for {set i 0} {$i < 5} {incr i} { files::draw $w; update }
check "df's answer is reused within its few seconds" {[dfcalls "*used,size,target*"] == 1 && [dfcalls "*avail,target*"] == 1} \
	": [dfcalls *used,size,target*] [dfcalls *avail,target*]"

if {$mode eq "nobus"} {
	check "without UDisks2 the rows are df's" {[labels] eq {System Ssd}} ": [labels]"
	puts [expr {$failed ? "  drive checks FAILED" : "  all drive checks passed"}]
	exit [expr {$failed ? 1 : 0}]
}

check "UDisks2's unmounted stick has a row" {[waitfor 5000 {[row Backup] ne ""}]} ": [files::drives]"
lassign [row Backup] l p used size obj
check "that row opens nothing and has no bar" {$p eq "" && $size eq "" && [string match */block_devices/sdb1 $obj]}
check "ignored volumes, swap and internal mounts have no row" {"Hidden" ni [labels] && "EFI" ni [labels] && "sda4" ni [labels]} \
	": [labels]"
check "the system disk is one row, named System" {[llength [lsearch -all [labels] System]] == 1 && "sda2" ni [labels]} ": [labels]"

# a click on the Backup row mounts it and opens it
proc click_row {w label} {
	files::draw $w; update
	set i [lsearch [labels] $label]
	# the five places come first
	set h [lindex $files::st($w,sidehits) [expr {[llength [files::places]] + $i}]]
	lassign $h y0 y1
	event generate $w.side <Button-1> -x 60 -y [expr {($y0 + $y1) / 2}]
	update
}
click_row $w Backup
check "a click on it calls Filesystem.Mount" {[waitfor 5000 {[string match "*mount\t*/sdb1*" [slurp $::env(UDISKS_LOG)]]}]}
check "and opens where it was mounted" {[waitfor 5000 {[files::path $w] eq [file normalize $::env(UDISKS_MNT)]}]} ": [files::path $w]"
check "the row is now the mounted drive" {[waitfor 5000 {[lindex [row Backup] 1] eq $::env(UDISKS_MNT)}]} ": [files::drives]"
check "with its usage once df answers again" {[waitfor 15000 {[lindex [row Backup] 3] eq "32000000000"}]} ": [row Backup]"

click_row $w Locked
check "a failed mount says why" {[waitfor 5000 {$files::st($w,status) eq "Couldn't mount Locked: Not permitted"}]} ": $files::st($w,status)"

package require ribbon::dbus
set client [ribbon::dbus::connect system]
$client call org.freedesktop.UDisks2 /org/ribbon/Test org.ribbon.Test Plug
check "a card plugged in later gets a row" {[waitfor 5000 {[row Camera] ne ""}]} ": [labels]"
check "the other rows keep their usage meanwhile" {[lindex [row System] 3] eq "100000000000"} ": [row System]"
check "and the sidebar is drawn again with it" {[waitfor 2000 {[string match *Camera* [canvas_text $w.side]]}]}

puts [expr {$failed ? "  drive checks FAILED" : "  all drive checks passed"}]
exit [expr {$failed ? 1 : 0}]
