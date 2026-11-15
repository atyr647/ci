# files-trash.tcl - Ribbon Files' trash as the freedesktop.org Trash spec has it (shell/files-trash.tcl), in the
# real shell under xvfb (RIBBON_SHELL_TEST=this file; tests/steps.d/64-files-trash.sh). TRASH_VOLS names three
# folders that are other drives than HOME: tmpfs mounts in a mount namespace, or (TRASH_FAKE=1, where no
# namespace can be made) plain folders the test reports as other drives. VOL2 has a shared .Trash with the sticky
# bit, VOL3 one without it. The checks: a file on another drive goes to that drive's trash by a rename (no copy,
# nothing in the home trash), into .Trash/UID or .Trash-UID as the spec says; its .trashinfo is whole, with a
# Path relative to the drive's top; a clash gets a free name; a failed move leaves no .trashinfo; the Trash lists
# every drive's trash; Restore and Delete for good work there; emptying a trash of 50,000 files keeps the event
# loop running.

set failed 0
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
after 240000 {puts "  FAIL the trash checks took more than 240 s"; exit 1}
proc check {what cond {why ""}} {
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { incr ::failed; puts "  FAIL $what$why" }
}
proc waitfor {ms cond} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel 1 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 30 { set ::wake 1 }; vwait ::wake
	}
	return 1
}
proc idle_ops {} { expr {$files::opch eq "" && ![llength $files::ops]} }
proc slurp {f} {
	if {[catch {open $f} fh]} { return "" }
	fconfigure $fh -encoding utf-8
	set t [read $fh]; close $fh
	return $t
}
proc put {f {text x}} { file mkdir [file dirname $f]; set fh [open $f w]; puts $fh $text; close $fh }
proc trash_in {w dir names} {
	files::go $w $dir
	set files::st($w,sel) $names
	files::trash $w
}

lassign $::env(TRASH_VOLS) v1 v2 v3
set fake [expr {[info exists ::env(TRASH_FAKE)] && $::env(TRASH_FAKE)}]
if {$fake} {
	# each VOL is a drive of its own: another device number, and listed among the mounts
	rename files::devof files::devof_real
	proc files::devof {p} {
		set p [file normalize $p]
		foreach v [lsort -decreasing [list {*}$::env(TRASH_VOLS)]] {
			if {$p eq $v || [string first $v/ $p] == 0} { return fake:$v }
		}
		files::devof_real $p
	}
	rename files::local_mounts files::local_mounts_real
	proc files::local_mounts {} { concat [files::local_mounts_real] $::env(TRASH_VOLS) }
}
set u [files::uid]
set home [file normalize [files::trashdir]]
set w [files::show $v1]

# another drive: its own trash, by a rename
put $v1/a.txt hello
put "$v1/My Dir/inner/deep.txt"
trash_in $w $v1 {a.txt "My Dir"}
set t1 $v1/.Trash-$u
check "a file on another drive goes to its .Trash-UID" {[file exists $t1/files/a.txt] && ![file exists $v1/a.txt]}
check "by a rename: nothing copied in the background" {[idle_ops]}
check "and nothing in the home trash" {![file exists $home/files/a.txt] && ![file exists "$home/files/My Dir"]}
check "a folder too, with what is in it" {[file exists "$t1/files/My Dir/inner/deep.txt"]}
file stat $t1 st1
check ".Trash-UID is made 0700" {($st1(mode) & 0o7777) == 0o700} ": [format %o $st1(mode)]"
set info [slurp $t1/info/a.txt.trashinfo]
check "the .trashinfo is whole" {[regexp {^\[Trash Info\]\nPath=a\.txt\nDeletionDate=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\n$} $info]} ": $info"
check "its Path is relative to the drive's top, escaped" {[string match "*Path=My%20Dir\n*" [slurp "$t1/info/My Dir.trashinfo"]]}

# a clash in that trash: a free name in both files/ and info/
put $v1/sub/a.txt again
trash_in $w $v1/sub {a.txt}
check "a clash gets a free name" {[file exists "$t1/files/a (2).txt"] && [string match "*Path=sub/a.txt\n*" [slurp "$t1/info/a (2).txt.trashinfo"]]}

# a shared .Trash with the sticky bit: .Trash/UID; one without it is not used
put $v2/b.txt
trash_in $w $v2 {b.txt}
check "a sticky shared .Trash is used as .Trash/UID" {[file exists $v2/.Trash/$u/files/b.txt] && ![file exists $v2/.Trash-$u]}
check "with a Path relative to the drive's top" {[string match "*Path=b.txt\n*" [slurp $v2/.Trash/$u/info/b.txt.trashinfo]]}
put $v3/c.txt
trash_in $w $v3 {c.txt}
check "a shared .Trash without the sticky bit is not used" {[file exists $v3/.Trash-$u/files/c.txt] && ![file exists $v3/.Trash/$u]}

# the home drive: the home trash, with an absolute Path
put $::env(HOME)/docs/a.txt home
trash_in $w $::env(HOME)/docs {a.txt}
check "a file on the home drive goes to the home trash" {[file exists $home/files/a.txt]}
check "with an absolute Path" {[string match "*Path=[file normalize $::env(HOME)]/docs/a.txt\n*" [slurp $home/info/a.txt.trashinfo]]}

# a link to a file on another drive is the link that goes, by a rename
put $v2/target.txt big
file link -symbolic $v1/link.txt $v2/target.txt
trash_in $w $v1 {link.txt}
check "a link is trashed by a rename, not copied" {[idle_ops] && [file type $t1/files/link.txt] eq "link" && [file exists $v2/target.txt]}
waitfor 10000 {[idle_ops]}
catch {file delete -- $t1/files/link.txt $t1/info/link.txt.trashinfo $v2/target.txt}

# a move that fails takes its .trashinfo away again
trash_in $w $v1 {ghost.txt}
check "a failed move finishes" {[waitfor 20000 {[idle_ops]}]}
check "and leaves no .trashinfo" {![llength [glob -nocomplain -directory $t1/info ghost*]]}
set parts {}
foreach d [list $home $t1 $v2/.Trash/$u $v3/.Trash-$u] { lappend parts {*}[glob -nocomplain -directory $d/info -types hidden *.part] }
check "no half-written .trashinfo is left" {![llength $parts]} ": $parts"

# the Trash lists every drive's trash
files::go $w $home/files
set names [lmap it $files::st($w,items) { lindex $it 0 }]
check "the Trash lists every trash folder" {[llength $names] == 6 && "b.txt" in $names && "c.txt" in $names && "My Dir" in $names} ": $names"
set key ""
foreach n $names { if {[files::itempath $w $n] eq "$t1/files/a.txt"} { set key $n } }
check "a clash between trash folders is listed under another name" {$key ne "" && $key ne "a.txt"} ": $names"

# Restore puts it back where it was, from any trash
set files::st($w,sel) [list $key "My Dir" b.txt]
files::restore $w
check "restore from a drive's trash" {[slurp $v1/a.txt] eq "hello\n" && ![file exists $t1/files/a.txt] && ![file exists $t1/info/a.txt.trashinfo]}
check "a folder too" {[file exists "$v1/My Dir/inner/deep.txt"]}
check "from a .Trash/UID" {[file exists $v2/b.txt] && ![file exists $v2/.Trash/$u/info/b.txt.trashinfo]}
check "by a rename" {[idle_ops]}
check "the home trash's item stays" {[file exists $home/files/a.txt]}

# Delete for good, in a drive's trash
files::go $w $home/files
files::really_delete $w [list [files::itempath $w c.txt]]
check "delete for good in a drive's trash, with its record" {![file exists $v3/.Trash-$u/files/c.txt] && ![file exists $v3/.Trash-$u/info/c.txt.trashinfo]}

# a big folder deleted for good goes to the background
exec sh -c {mkdir -p "$1" && cd "$1" && seq 1 20000 | xargs touch} sh $v1/huge
trash_in $w $v1 {huge}
files::go $w $home/files
set t0 [clock milliseconds]
files::really_delete $w [list [files::itempath $w huge]]
set ms [expr {[clock milliseconds] - $t0}]
check "deleting a folder of 20,000 files for good does not stall ($ms ms)" {$ms < 300}
check "and it goes" {[waitfor 60000 {![file exists $t1/files/huge] && [idle_ops]}]}
check "with its record" {![file exists $t1/info/huge.trashinfo]}

# empty a trash of 50,000 files: the event loop keeps running
exec sh -c {mkdir -p "$1" && cd "$1" && seq 1 25000 | xargs touch} sh $v1/big
exec sh -c {mkdir -p "$1" && cd "$1" && seq 1 25000 | xargs touch} sh $::env(HOME)/bigdir
trash_in $w $v1 {big}
trash_in $w $::env(HOME) {bigdir}
check "the folders are in the trash" {[file isdirectory $t1/files/big] && [waitfor 60000 {[file isdirectory $home/files/bigdir] && [idle_ops]}]}
set ::last [clock milliseconds]; set ::gap 0
proc tick {} {
	set now [clock milliseconds]
	if {$now - $::last > $::gap} { set ::gap [expr {$now - $::last}] }
	set ::last $now
	set ::tick [after 20 tick]
}
tick
set t0 [clock milliseconds]
files::empty_trash_now $w
set ms [expr {[clock milliseconds] - $t0}]
check "emptying the trash returns at once ($ms ms)" {$ms < 300}
check "the trash empties" {[waitfor 120000 {[idle_ops]}]}
after cancel $::tick
check "the event loop ran all along (longest gap $::gap ms)" {$::gap < 400}
set left {}
foreach d [files::trash_dirs] { lappend left {*}[glob -nocomplain -directory $d/files *] {*}[glob -nocomplain -directory $d/info *] }
check "every trash folder is empty" {![llength $left]} ": $left"

# a drive's trash is read from the drive, which anyone may have written: a record cannot restore a file
# outside that drive, and a trash folder that is a link (or sits in a shared .Trash without the sticky bit)
# is neither listed nor emptied
put $t1/files/evil1.txt one
put $t1/info/evil1.txt.trashinfo "\[Trash Info\]\nPath=../escaped.txt\nDeletionDate=2026-01-01T00:00:00"
put $t1/files/evil2.txt two
put $t1/info/evil2.txt.trashinfo "\[Trash Info\]\nPath=[file normalize $::env(HOME)]/planted.txt\nDeletionDate=2026-01-01T00:00:00"
put $v1/.Trash-$u/files/fine.txt three
put $v1/.Trash-$u/info/fine.txt.trashinfo "\[Trash Info\]\nPath=back/fine.txt\nDeletionDate=2026-01-01T00:00:00"
files::go $w $home/files
set files::st($w,sel) {evil1.txt evil2.txt fine.txt}
files::restore $w
waitfor 10000 {[idle_ops]}
check "a drive's trash record cannot restore outside the drive" {![file exists [file dirname $v1]/escaped.txt] && ![file exists $::env(HOME)/planted.txt]}
check "and those items stay in the trash" {[file exists $t1/files/evil1.txt] && [file exists $t1/files/evil2.txt]}
check "a record inside the drive still restores" {[file exists $v1/back/fine.txt]}
put $::env(HOME)/victim/files/keep.txt mine
file mkdir $::env(HOME)/victim/info
file link -symbolic $v2/.Trash-$u $::env(HOME)/victim
file mkdir $v3/.Trash/$u/files $v3/.Trash/$u/info
put $v3/.Trash/$u/files/unsafe.txt
files::go $w $home/files
set names [lmap it $files::st($w,items) { lindex $it 0 }]
check "a trash folder that is a link is not listed" {"keep.txt" ni $names} ": $names"
check "nor .Trash/UID in a .Trash without the sticky bit" {"unsafe.txt" ni $names} ": $names"
files::empty_trash_now $w
waitfor 30000 {[idle_ops]}
check "and emptying the trash leaves what it points at" {[file exists $::env(HOME)/victim/files/keep.txt]}
check "nor empties that .Trash/UID" {[file exists $v3/.Trash/$u/files/unsafe.txt]}

puts [expr {$failed ? "  trash checks FAILED" : "  all trash checks passed"}]
exit [expr {$failed ? 1 : 0}]
