# files-trash.tcl - Ribbon Files' trash, as the freedesktop.org Trash spec
# has it (sourced by files.tcl).
#
# A file on the drive the home trash ($XDG_DATA_HOME/Trash) is on goes there.
# A file on another drive goes to that drive's own trash, so trashing it is a
# rename and never a copy: $topdir/.Trash/$uid when the drive has a shared
# .Trash (a folder, not a link, with the sticky bit), else $topdir/.Trash-$uid
# (made 0700). Only when neither can be made does it go to the home trash,
# copied in the background as any move between drives is.
#
# The .trashinfo file is written first, whole, under its final name in one
# step (a hard link, or on a drive without them an exclusive create replaced by
# a rename), so the name is reserved before the file moves and no reader sees
# half of one; it goes again if the move fails. Its Path is absolute in the
# home trash and relative to the drive's top folder in a drive's trash (as
# GLib writes it), so a drive keeps its trash when it is mounted elsewhere.
#
# The Trash place lists every trash folder on the local drives; Restore,
# Delete for good and Empty trash work on each item where it is. Emptying and
# deleting folders run in the background (rm), so the shell never stalls.

namespace eval files {}

# The user's numeric id, from the kernel (/proc/self/status).
proc files::uid {} {
	variable uid
	if {[info exists uid]} { return $uid }
	if {![catch {::open /proc/self/status} fh]} {
		set t [::read $fh]; ::close $fh
		if {[regexp -line {^Uid:\s+(\d+)} $t -> u]} { return [set uid $u] }
	}
	if {[catch {exec id -u} u]} { set u 0 }
	return [set uid $u]
}

proc files::devof {p} {
	if {[catch {file stat $p s}]} { return "" }
	return $s(dev)
}

# The top folder of the drive DIR is on (its mount point).
proc files::topdir {dir} {
	set dev [devof $dir]
	while {1} {
		set up [file dirname $dir]
		if {$up eq $dir || [devof $up] ne $dev} { return $dir }
		set dir $up
	}
}

proc files::trash_view {path} { expr {$path eq [file normalize [trashdir]/files]} }

# The trash folder for P.
proc files::trash_for {p} {
	set home [file normalize [trashdir]]
	set dir [file dirname [file normalize $p]]
	set dev [devof $dir]
	if {$dev eq "" || $dev eq [devof $home]} { return $home }
	set top [topdir $dir]
	set u [uid]
	set shared [file join $top .Trash]
	if {[trash_shared_ok $shared]} {
		if {[trash_make [file join $shared $u] $dev]} { return [file join $shared $u] }
	}
	if {[trash_make [file join $top .Trash-$u] $dev]} { return [file join $top .Trash-$u] }
	return $home
}

# A shared .Trash the spec lets us use: a folder, not a link, with the sticky bit.
proc files::trash_shared_ok {shared} {
	expr {![catch {file lstat $shared s}] && $s(type) eq "directory" && ($s(mode) & 0o1000)}
}

# A drive's trash folder T that can be listed and emptied: the user's own folder, not a link, and
# its files/ and info/ folders, not links (anyone may have written the drive).
proc files::trash_own {t} {
	if {[catch {file lstat $t s}] || $s(type) ne "directory" || $s(uid) != [uid]} { return 0 }
	foreach d {files info} { if {[catch {file lstat $t/$d s}] || $s(type) ne "directory"} { return 0 } }
	return 1
}

# Make the trash folder T (0700, with files/ and info/) on the drive DEV, or find it made. 1 when it can be used.
proc files::trash_make {t dev} {
	if {[catch {
		if {![file exists $t]} {
			file mkdir $t
			file attributes $t -permissions 0700
		}
		file lstat $t s
		if {$s(type) ne "directory" || $s(uid) != [uid]} { error "not ours" }
		file mkdir $t/files $t/info
	}]} { return 0 }
	expr {[devof $t] eq $dev}
}

# The folder a relative Path in T's .trashinfo files starts from: the drive's top folder for a
# drive's trash, $XDG_DATA_HOME for the home trash.
proc files::trash_base {t} {
	if {[string match .Trash-* [file tail $t]]} { return [file dirname $t] }
	if {[file tail [file dirname $t]] eq ".Trash"} { return [file dirname [file dirname $t]] }
	file dirname $t
}

# The trash folder an item P (T/files/NAME) is in, or "".
proc files::trash_of {p} {
	set f [file dirname $p]
	if {[file tail $f] ne "files"} { return "" }
	set t [file dirname $f]
	if {$t eq [file normalize [trashdir]] || [string match .Trash-* [file tail $t]] || [file tail [file dirname $t]] eq ".Trash"} { return $t }
	return ""
}

# Write P's .trashinfo in T under a name free in both files/ and info/; returns the name, or "".
proc files::trash_claim {t p} {
	variable pending
	set p [file normalize $p]
	set path $p
	if {$t ne [file normalize [trashdir]]} {
		set base [trash_base $t]
		set pre [expr {$base eq "/" ? "/" : "$base/"}]
		if {[string first $pre $p] == 0} { set path [string range $p [string length $pre] end] }
	}
	set body "\[Trash Info\]\nPath=[uri $path]\nDeletionDate=[clock format [clock seconds] -format %Y-%m-%dT%H:%M:%S]\n"
	set tail [file tail $p]
	set root [file rootname $tail]; set ext [file extension $tail]
	if {[file isdirectory $p] || $root eq ""} { set root $tail; set ext "" }
	for {set i 1} {$i < 100000} {incr i} {
		set name [expr {$i == 1 ? $tail : "$root ($i)$ext"}]
		if {![catch {file lstat $t/files/$name s}] || [file exists $t/info/$name.trashinfo] || "$t/files/$name" in $pending} continue
		switch -- [trash_write $t/info/$name.trashinfo $body] {
			ok { return $name }
			fail { return "" }
		}
	}
	return ""
}

# Put BODY in INFO in one step, only if INFO does not exist: ok, taken or fail.
proc files::trash_write {info body} {
	set part [file join [file dirname $info] .[file tail $info].[pid].part]
	if {[catch {
		set fh [::open $part {WRONLY CREAT TRUNC}]
		fconfigure $fh -encoding utf-8 -translation lf
		puts -nonewline $fh $body
		::close $fh
	}]} { catch {::file delete -- $part}; return fail }
	if {![catch {file link -hard $info $part}]} { ::file delete -- $part; return ok }
	if {[file exists $info]} { ::file delete -- $part; return taken }
	# no hard links on this drive (FAT): reserve the name, then put the whole file in its place
	if {[catch {::close [::open $info {WRONLY CREAT EXCL}]}]} {
		::file delete -- $part
		return [expr {[file exists $info] ? "taken" : "fail"}]
	}
	if {[catch {::file rename -force -- $part $info}]} { catch {::file delete -- $part $info}; return fail }
	return ok
}

# Where an item in T's files/ came from, or "" when its .trashinfo can't be read.
proc files::trash_orig {t name} {
	if {[catch {::open $t/info/$name.trashinfo} fh]} { return "" }
	fconfigure $fh -encoding utf-8
	set text [::read $fh]; ::close $fh
	if {![regexp -line {^Path=(.+)$} $text -> orig]} { return "" }
	set orig [urldecode [string trim $orig]]
	if {[file pathtype $orig] ne "absolute"} { set orig [file join [trash_base $t] $orig] }
	set orig [file normalize $orig]
	# a drive's trash restores only onto that drive: its records are whatever the drive holds
	if {$t ne [file normalize [trashdir]]} {
		set base [file normalize [trash_base $t]]
		set pre [expr {$base eq "/" ? "/" : "$base/"}]
		if {[string first $pre $orig] != 0} { return "" }
	}
	return $orig
}

# The mount points of the local drives (/proc/self/mounts): network and kernel file systems are
# left out, so listing the trash never touches a mount that can hang.
proc files::local_mounts {} {
	if {[catch {::open /proc/self/mounts} fh]} { return {} }
	set text [::read $fh]; ::close $fh
	set skip {proc sysfs devtmpfs devpts cgroup cgroup2 securityfs pstore bpf tracefs debugfs configfs fusectl
		mqueue hugetlbfs autofs binfmt_misc efivarfs rpc_pipefs nsfs nfs nfs4 cifs smb3 smbfs ncpfs 9p afs ceph
		glusterfs davfs coda}
	set out {}
	foreach line [split $text \n] {
		lassign [split $line " "] dev mp type
		if {$mp eq "" || $type in $skip || [string match fuse.* $type]} continue
		# spaces and the like are octal escapes (\040)
		set mp [subst -nocommands -novariables $mp]
		if {$mp ni $out} { lappend out $mp }
	}
	return $out
}

# Every trash folder there is: the home one first, then each drive's (one per folder, though a
# drive be mounted twice).
proc files::trash_dirs {} {
	set home [file normalize [trashdir]]
	set out [list $home]
	set seen {}
	if {![catch {file stat $home s}]} { lappend seen $s(dev):$s(ino) }
	set u [uid]
	foreach mp [local_mounts] {
		set ts [list [file join $mp .Trash-$u]]
		if {[trash_shared_ok [file join $mp .Trash]]} { set ts [linsert $ts 0 [file join $mp .Trash $u]] }
		foreach t $ts {
			if {![trash_own $t]} continue
			if {[catch {file stat $t s}] || "$s(dev):$s(ino)" in $seen} continue
			lappend seen $s(dev):$s(ino)
			lappend out $t
		}
	}
	return $out
}

# What the Trash lists: {name path name path ...}. Items in a drive's trash whose name is taken
# are listed as "name (2)" and so on.
proc files::trash_items {hidden} {
	set out {}
	set taken {}
	foreach t [trash_dirs] {
		set paths [glob -nocomplain -directory $t/files *]
		if {$hidden} { lappend paths {*}[glob -nocomplain -directory $t/files -types hidden *] }
		foreach p $paths {
			set name [file tail $p]
			if {$name in {. ..}} continue
			set key $name
			set root [file rootname $name]; set ext [file extension $name]
			if {$root eq "" || [file isdirectory $p]} { set root $name; set ext "" }
			for {set i 2} {[dict exists $taken $key]} {incr i} { set key "$root ($i)$ext" }
			dict set taken $key 1
			lappend out $key $p
		}
	}
	return $out
}

# ---- the commands ---------------------------------------------------------------

proc files::trash {w} {
	variable st
	set paths [selpaths $w]
	if {![llength $paths]} return
	if {[trash_view $st($w,path)]} { delete_forever $w; return }
	foreach p $paths {
		set t [trash_for $p]
		set name [trash_claim $t $p]
		if {$name eq ""} { status_fail $w "Couldn't move [file tail $p] to the trash"; continue }
		# the .trashinfo is in place first; it goes again if the move fails
		transfer $w move $p $t/files/$name [list openwith::forget $p] [list ::file delete -- $t/info/$name.trashinfo]
	}
	set st($w,sel) {}
	load $w; draw $w
}

proc files::restore {w} {
	variable st
	foreach p [selpaths $w] {
		set t [trash_of $p]
		if {$t eq ""} continue
		set n [file tail $p]
		set orig [trash_orig $t $n]
		if {$orig eq ""} { status_fail $w "Couldn't restore $n: its trash record is missing"; continue }
		if {[catch {file mkdir [file dirname $orig]} err]} {
			status_fail $w "Couldn't restore [file tail $orig]: [reason $err]"
			continue
		}
		set dst [file join [file dirname $orig] [freename [file dirname $orig] [file tail $orig]]]
		# the .trashinfo goes only when the file is back
		transfer $w move $p $dst [list ::file delete -- $t/info/$n.trashinfo]
	}
	set st($w,sel) {}
	load $w; draw $w
}

# Every trash folder's contents, then its records, deleted by rm in the background.
namespace eval files {
	variable empty_sh {
for t in "$@"; do
	find "$t/files" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || { echo "Couldn't empty the trash"; exit 1; }
	find "$t/info" -mindepth 1 -maxdepth 1 -name '*.trashinfo' -exec rm -f -- {} +
	rm -f -- "$t/directorysizes"
done
}
}

proc files::empty_trash {w} {
	confirm $w "Empty the trash?" "Everything in it is deleted for good." "Empty trash" [list files::empty_trash_now $w]
}

proc files::empty_trash_now {w} {
	variable empty_sh
	queue $w Emptying Trash [list sh -c $empty_sh ribbon-empty-trash {*}[trash_dirs]] "" "" files::refresh_all
}

proc files::really_delete {w paths} {
	foreach p $paths {
		set t [trash_of $p]
		set info [expr {$t ne "" ? "$t/info/[file tail $p].trashinfo" : ""}]
		openwith::forget $p
		# a folder can hold any number of files: rm deletes it in the background
		if {[file isdirectory $p] && [file type $p] ne "link"} {
			queue $w Deleting [file tail $p] [list rm -rf -- $p] "" $p [expr {$info ne "" ? [list ::file delete -- $info] : ""}]
			continue
		}
		if {[catch {::file delete -force -- $p}]} {
			queue $w Deleting [file tail $p] [list rm -rf -- $p] "" $p [expr {$info ne "" ? [list ::file delete -- $info] : ""}]
			continue
		}
		if {$info ne ""} { catch {::file delete -- $info} }
	}
	refresh_all
}
