# files-ops.tcl - drive Ribbon Files' operations and check the results on
# disk (sourced by the shell via RIBBON_SHELL_TEST; exits 0 or 1).
proc bgerror {msg} { puts stderr "error: $msg\n$::errorInfo"; exit 1 }
proc check {what cond} {
	if {![uplevel 1 [list expr $cond]]} { puts stderr "FAIL $what"; exit 1 }
	puts "  ok   files: $what"
}
set root [file join $::env(HOME) ops]
file delete -force $root
file mkdir $root/a $root/b
set fh [open $root/a/note.txt w]; puts $fh hello; close $fh
set w [files::show $root/a]
check "opens a folder" {[files::path $w] eq [file normalize $root/a]}
check "lists it" {[lsearch -index 0 $files::st($w,items) note.txt] >= 0}
files::newfolder $w
check "new folder" {[file isdirectory $root/a/New\ folder]}
destroy $w.main.rename
file rename $root/a/New\ folder $root/a/renamed
files::load $w
set files::st($w,sel) note.txt
files::set_clip copy [files::selpaths $w]
files::go $w $root/b
files::paste $w
vwait files::opch
after 500 { set ::done 1 }; vwait ::done
check "copy and paste (in the background)" {[file exists $root/b/note.txt]}
files::paste $w
update
check "paste again asks: the name is taken (Files-Conflict)" {[winfo exists .filesconflict]}
files::conflict_pick keep
after 800 { set ::done 1 }; vwait ::done
check "Keep both picks a free name" {[file exists "$root/b/note (2).txt"]}
set files::st($w,sel) note.txt
files::trash $w
check "move to trash" {![file exists $root/b/note.txt] && [file exists [files::trashdir]/files/note.txt]}
files::go $w [files::trashdir]/files
set files::st($w,sel) note.txt
files::restore $w
check "restore from trash" {[file exists $root/b/note.txt]}
files::really_delete $w [list "$root/b/note (2).txt"]
check "delete for good" {![file exists "$root/b/note (2).txt"]}
files::back $w
check "back" {[files::path $w] eq [file normalize $root/b]}
files::up $w
check "up selects where we came from" {[files::path $w] eq [file normalize $root] && $files::st($w,sel) eq "b"}

# drag and drop (pure Tcl path): window to window, onto a folder, to Trash
proc drag {from name X Y} {
	set w [winfo toplevel $from]
	update
	foreach t $files::st($w,tiles) { if {[lindex $t 4] eq $name} { lassign $t x0 y0 x1 y1 } }
	set x [expr {($x0 + $x1) / 2}]; set y [expr {($y0 + $y1) / 2}]
	event generate $from <ButtonPress-1> -x $x -y $y -rootx [expr {[winfo rootx $from] + $x}] -rooty [expr {[winfo rooty $from] + $y}]
	event generate $from <B1-Motion> -x [expr {$x + 20}] -y [expr {$y + 20}] -rootx [expr {[winfo rootx $from] + $x + 20}] -rooty [expr {[winfo rooty $from] + $y + 20}]
	event generate $from <B1-Motion> -x 0 -y 0 -rootx $X -rooty $Y
	event generate $from <ButtonRelease-1> -x 0 -y 0 -rootx $X -rooty $Y
	update
}
set fh [open $root/a/drag.txt w]; puts $fh x; close $fh
file mkdir $root/b/inner
set w1 [files::show $root/a]; wm geometry $w1 700x500+0+0
set w2 [files::show $root/b]; wm geometry $w2 700x500+720+0
update; after 300 { set ::done 1 }; vwait ::done
files::load $w1; files::draw $w1; files::load $w2; files::draw $w2; update
drag $w1.main drag.txt [expr {[winfo rootx $w2.main] + 300}] [expr {[winfo rooty $w2.main] + 350}]
check "drag a file into another window (moves it)" {[file exists $root/b/drag.txt] && ![file exists $root/a/drag.txt]}
files::load $w2; files::draw $w2; update
foreach t $files::st($w2,tiles) { if {[lindex $t 4] eq "inner"} { lassign $t ix0 iy0 ix1 iy1 } }
drag $w2.main drag.txt [expr {[winfo rootx $w2.main] + ($ix0 + $ix1) / 2}] [expr {[winfo rooty $w2.main] + ($iy0 + $iy1) / 2}]
check "drop onto a folder" {[file exists $root/b/inner/drag.txt]}
files::go $w2 $root/b/inner; update
set trashrow [lindex [lsearch -inline -index 2 $files::st($w2,sidehits) "*Trash/files"] 0]
foreach h $files::st($w2,sidehits) { if {[string match *Trash/files [lindex $h 2 end]]} { lassign $h ty0 ty1 } }
drag $w2.main drag.txt [expr {[winfo rootx $w2.side] + 60}] [expr {[winfo rooty $w2.side] + ($ty0 + $ty1) / 2}]
check "drop on Trash in the sidebar" {![file exists $root/b/inner/drag.txt] && [file exists [files::trashdir]/files/drag.txt]}
exit 0
