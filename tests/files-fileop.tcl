# files-fileop.tcl - the copy and move helper behind Ribbon Files (files::fileop_cmd and
# fileop_sh in srcpkgs/ribbon-desktop/files/shell/files.tcl, run by sh). Plain tclsh, no
# display; tests/steps.d/61-files-fileop.sh runs it. It kills the helper just before each
# of its steps and checks, after the kill and again after files::clear_parts, that the
# source and the destination are each the old file or the new one, never a mix. Then the
# failures a user can meet: a read-only folder, a file where a folder should be, a full
# disk, a vanished source, a name clash and a permission-denied rename. Run as nobody when
# this is root. Exits 0 when every check passes; each check prints one line.

set here [file dirname [file normalize [info script]]]
source [file join $here .. srcpkgs ribbon-desktop files shell files.tcl]

set fails 0
proc check {what cond} {
	global fails
	if {[catch {uplevel 1 [list expr $cond]} ok] || !$ok} { puts "  FAIL fileop: $what"; incr fails; return }
	puts "  ok   fileop: $what"
}
proc put {p data} {
	set fh [open $p wb]; puts -nonewline $fh $data; close $fh
}
proc content {p} {
	if {![file exists $p]} { return "" }
	set fh [open $p rb]; set d [read $fh]; close $fh
	return $d
}
proc devof {p} { file stat $p s; return $s(dev) }

# Run the helper: returns {rc output}. KILLAT, when given, is the step the helper is killed before.
proc run {op src dst {killat ""} {as ""}} {
	if {$killat ne ""} { set ::env(RIBBON_FILEOP_KILL_AT) $killat } else { catch {unset ::env(RIBBON_FILEOP_KILL_AT)} }
	set cmd [files::fileop_cmd $op $src $dst]
	if {$as ne ""} { set cmd [list {*}$as {*}$cmd] }
	set rc [catch {exec {*}$cmd 2>@1} out]
	catch {unset ::env(RIBBON_FILEOP_KILL_AT)}
	return [list [expr {$rc ? 1 : 0}] $out]
}

# Leftover .NAME.ribbon-part and .NAME.ribbon-gone names, in any of the folders.
proc leftovers {dirs} {
	set n {}
	foreach d $dirs { lappend n {*}[glob -nocomplain -directory $d .*.ribbon-part .*.ribbon-gone] }
	return $n
}

set root [exec id -u]
set nobody {}
if {$root == 0 && [llength [auto_execok setpriv]]} {
	set nobody [list setpriv --reuid=65534 --regid=65534 --clear-groups]
}
set T [string trim [exec mktemp -d]]
file attributes $T -permissions 0755
set data [string repeat "ribbon fileop test data 0123456789 " 12000]
set shm ""
if {[file isdirectory /dev/shm] && [catch {exec mktemp -d /dev/shm/fileop.XXXX} shm] == 0} {
	set shm [string trim $shm]
} else { set shm "" }

# ---- kill the helper at each step: the old file or the new one, never a mix -----------

proc killmatrix {label op sdir dstdir steps} {
	global data
	# the steps: copy = cp, sync, verify, rename, dir sync; a move across disks adds
	# gone and rm; a move on one disk is rename and dir sync
	for {set k 1} {$k <= $steps} {incr k} {
		set name "k-$op-$k.bin"
		set s [file join $sdir $name]
		put $s $data
		set d [file join $dstdir $name]
		set r [run $op $s $d $k]
		set srcok [expr {[file exists $s] ? [content $s] eq $data : ($op eq "move" && [file exists $d] && [content $d] eq $data)}]
		set dstok [expr {![file exists $d] || [content $d] eq $data}]
		files::clear_parts $sdir
		files::clear_parts $dstdir
		set after [expr {[file exists $s] ? [content $s] eq $data : ($op eq "move" && [file exists $d] && [content $d] eq $data)}]
		set left [leftovers [list $sdir $dstdir]]
		check "$label: $op killed before step $k leaves each file old or new (rc $r)" \
			{$srcok && $dstok && $after && [llength $left] == 0}
		catch {file delete -force -- $s $d}
	}
	# and the helper done: the source (copy: kept; move: gone) and the new file
	set name "k-$op-done.bin"
	set s [file join $sdir $name]; put $s $data
	set d [file join $dstdir $name]
	set r [run $op $s $d]
	check "$label: $op runs to the end (rc $r)" \
		{[lindex $r 0] == 0 && [content $d] eq $data && [expr {$op eq "copy" ? [content $s] eq $data : ![file exists $s]}]}
}

set src [file join $T src]; file mkdir $src; file attributes $src -permissions 0755
set dst [file join $T dst]; file mkdir $dst
killmatrix "same disk" move $src $dst 2

if {$shm ne "" && [devof $T] != [devof $shm]} {
	set sdst [file join $shm dst]; file mkdir $sdst
	killmatrix "across disks" copy $src $sdst 5
	killmatrix "across disks" move $src $sdst 7
} else {
	puts "  skip fileop: no second filesystem (/dev/shm) to move across"
}
if {$shm ne ""} { catch {file delete -force -- $shm} }

# Killed while cp is running: the whole group goes (sh and cp), at several moments of a
# 128 MiB copy onto another filesystem (a 256 MiB tmpfs this test mounts when it is root;
# a copy on one disk is a rename for a move, so it isn't the case that matters). Nothing in
# the destination may be a part of the file. Skipped where it can't mount or can't setsid.
proc same_bytes {a b} { expr {![catch {exec cmp -s $a $b}]} }
set big [file join $T big.bin]
exec dd if=/dev/zero of=$big bs=1M count=128 2>/dev/null
exec dd if=/dev/urandom of=$big bs=1M count=1 conv=notrunc 2>/dev/null
set xfs [file join $T xfs]; file mkdir $xfs
if {$root == 0 && ![catch {exec mount -t tmpfs -o size=256m tmpfs $xfs}] && [llength [auto_execok setsid]]} {
	set gdst [file join $xfs g]; file mkdir $gdst
	foreach ms {2 6 12 20 30 40 55 70} {
		foreach op {copy move} {
			set s [file join $src "g-$op-$ms.bin"]
			file copy -force $big $s
			set d [file join $gdst "g-$op-$ms.bin"]
			set cmd [files::fileop_cmd $op $s $d]
			set pid [exec setsid {*}$cmd &]
			after $ms
			catch {exec kill -KILL -- -$pid}
			after 150
			set srcok [expr {[file exists $s] ? [same_bytes $s $big] : ($op eq "move" && [file exists $d] && [same_bytes $d $big])}]
			set dstok [expr {![file exists $d] || [same_bytes $d $big]}]
			files::clear_parts $src
			files::clear_parts $gdst
			set left [leftovers [list $src $gdst]]
			check "killed $ms ms into a 128 MiB $op: each file is the old one or the new one" \
				{$srcok && $dstok && [llength $left] == 0}
			catch {file delete -force -- $s $d}
		}
	}
	catch {exec umount $xfs}
} else {
	puts "  skip fileop: no tmpfs to copy 128 MiB onto (root and setsid needed)"
}
catch {file delete -force -- $big}

# a tree copies whole, and a kill inside it leaves no half tree under the name
set tree [file join $src tree]; file mkdir [file join $tree sub]
put [file join $tree a.bin] $data; put [file join $tree sub b.txt] hello
set r [run copy $tree [file join $dst tree]]
check "a folder tree copies whole and checks out ([lindex $r 1])" \
	{[lindex $r 0] == 0 && [content [file join $dst tree a.bin]] eq $data && [content [file join $dst tree sub b.txt]] eq "hello"}
set r [run copy $tree [file join $dst tree2] 5]
check "a folder tree killed before its last step leaves no new name behind" \
	{![file exists [file join $dst tree2]] || [content [file join $dst tree2 a.bin]] eq $data}
files::clear_parts $dst
check "clear_parts leaves nothing behind in the folder" {[llength [leftovers [list $dst]]] == 0}

# ---- the failures ------------------------------------------------------------------

proc has {r text} { expr {[lindex $r 0] == 1 && [string first $text [lindex $r 1]] >= 0} }

# read-only folder (as nobody when this is root)
set ro [file join $T ro]; file mkdir $ro; file attributes $ro -permissions 0555
set s [file join $src ro.bin]; put $s $data
set r [run copy $s [file join $ro ro.bin] "" $nobody]
check "a read-only folder: the copy fails in one line and leaves nothing ([lindex $r 1])" \
	{[has $r "Permission denied"] && [llength [glob -nocomplain -directory $ro *]] == 0 && [llength [leftovers [list $ro]]] == 0 && [content $s] eq $data}
set r [run move $s [file join $ro ro.bin] "" $nobody]
check "a read-only folder: a move out of the folder is refused the same way ([lindex $r 1])" \
	{[lindex $r 0] == 1 && ![file exists [file join $ro ro.bin]] && [content $s] eq $data}
file attributes $ro -permissions 0755

# a file where a folder should be
set afile [file join $T afile]; put $afile "not a folder"
set r [run copy $s [file join $afile x.bin]]
check "a file where a folder should be: one line, the source kept ([lindex $r 1])" \
	{[has $r "isn't a folder"] && [content $afile] eq "not a folder" && [content $s] eq $data}

# a vanished source
set r [run copy [file join $src no-such.bin] [file join $dst gone.bin]]
check "a vanished source: one line, nothing made ([lindex $r 1])" \
	{[has $r "it is gone"] && ![file exists [file join $dst gone.bin]]}

# a name clash: never overwritten
put [file join $dst clash.bin] "theirs"
set r [run copy $s [file join $dst clash.bin]]
check "a name clash: the file there is kept, the copy refused ([lindex $r 1])" \
	{[has $r "already there"] && [content [file join $dst clash.bin]] eq "theirs" && [content $s] eq $data}
set r [run move $s [file join $dst clash.bin]]
check "a name clash on a move: both files kept" \
	{[lindex $r 0] == 1 && [content [file join $dst clash.bin]] eq "theirs" && [content $s] eq $data}

# a permission-denied rename on one disk (as nobody when this is root)
set locked [file join $T locked]; file mkdir $locked; file attributes $locked -permissions 0755
set lsrc [file join $locked l.bin]; put $lsrc $data; file attributes $locked -permissions 0555
set r [run move $lsrc [file join $dst l.bin] "" $nobody]
check "a permission-denied rename: one line, both sides as they were ([lindex $r 1])" \
	{[has $r "Permission denied"] && [content $lsrc] eq $data && ![file exists [file join $dst l.bin]]}
file attributes $locked -permissions 0755

# a full disk: a small tmpfs, if this host lets us mount one
set small [file join $T small]; file mkdir $small
if {$root != 0} {
	puts "  skip fileop: no small filesystem to fill (mounting a tmpfs needs root)"
} elseif {[catch {exec mount -t tmpfs -o size=64k tmpfs $small} err]} {
	puts "  skip fileop: no small filesystem to fill ([string trim $err])"
} else {
	set r [run copy $s [file join $small big.bin]]
	check "a full disk: one line, nothing partial left ([lindex $r 1])" \
		{[has $r "No space left on device"] && [llength [glob -nocomplain -directory $small *]] == 0 && [llength [leftovers [list $small]]] == 0 && [content $s] eq $data}
	catch {exec umount $small}
}

if {$nobody ne ""} { puts "  ok   fileop: the failures ran as nobody" }
catch {exec chmod -R u+w $T}
catch {file delete -force -- $T}

if {$fails} { puts "files fileop: $fails checks failed"; exit 1 }
puts "files fileop: all checks passed"
exit 0
