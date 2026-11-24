# store.tcl - the notes on disk (U33): ~/Notes/<folder>/<name>.md. A note is one UTF-8 Markdown file (LF line
# ends, written as it is given); a folder is a directory. Hidden directories are not folders: .versions/ keeps a
# folder's earlier texts of its notes, and .trash/ at the root holds the trashed notes (folders kept beneath it).
#
#   notes::store::root                        the notes folder (RIBBON_NOTES_ROOT, else ~/Notes)
#   notes::store::set_root DIR                use DIR (tests and the scenes)
#   notes::store::folders                     every folder as "Ribbon" and "Ribbon/Shell", sorted
#   notes::store::notes FOLDER                the names (no .md) in FOLDER, sorted; "" is the root
#   notes::store::note_path FOLDER NAME       the file
#   notes::store::read_note FOLDER NAME       its text
#   notes::store::write_note FOLDER NAME TEXT saves it; an earlier text that differs goes to .versions/
#   notes::store::create_note FOLDER          a new empty note: Untitled, Untitled 2, ...
#   notes::store::rename_note FOLDER OLD NEW  the versions follow the name
#   notes::store::move_note FOLDER NAME DEST  DEST is made if needed; the versions move too
#   notes::store::trash_note FOLDER NAME      moves it under .trash/FOLDER; returns its new name
#   notes::store::trashed                     {folder name} pairs in the trash
#
# Names come from the file names: no "/" in a name, and a name is never empty.

namespace eval ::notes::store {
	variable root ""
	variable keep 20      ;# earlier texts kept per note
	variable out {}
}

proc ::notes::store::root {} {
	variable root
	if {$root eq ""} {
		if {[info exists ::env(RIBBON_NOTES_ROOT)] && $::env(RIBBON_NOTES_ROOT) ne ""} {
			set root [file normalize $::env(RIBBON_NOTES_ROOT)]
		} else {
			set root [file join $::env(HOME) Notes]
		}
	}
	return $root
}

proc ::notes::store::set_root {dir} {
	variable root
	set root [file normalize $dir]
}

# The directory of a folder ("" is the root).
proc ::notes::store::dir_of {folder} {
	if {$folder eq ""} { return [root] }
	return [file join [root] {*}[split $folder /]]
}

proc ::notes::store::note_path {folder name} {
	return [file join [dir_of $folder] "$name.md"]
}

# A glob pattern that matches NAME literally.
proc ::notes::store::literal {name} {
	regsub -all {[][*?\\]} $name {\\&} pat
	return $pat
}

proc ::notes::store::folders {} {
	variable out
	set out {}
	collect ""
	return [lsort -dictionary $out]
}

proc ::notes::store::collect {rel} {
	variable out
	foreach d [glob -nocomplain -directory [dir_of $rel] -types d *] {
		set sub [expr {$rel eq "" ? [file tail $d] : "$rel/[file tail $d]"}]
		lappend out $sub
		collect $sub
	}
}

proc ::notes::store::notes {folder} {
	set names {}
	foreach f [glob -nocomplain -directory [dir_of $folder] -types f *.md] {
		lappend names [file rootname [file tail $f]]
	}
	return [lsort -dictionary $names]
}

proc ::notes::store::read_note {folder name} {
	set fh [::open [note_path $folder $name] rb]
	fconfigure $fh -encoding utf-8 -translation lf
	set text [read $fh]
	close $fh
	return $text
}

proc ::notes::store::write_note {folder name text} {
	variable keep
	set path [note_path $folder $name]
	file mkdir [dir_of $folder]
	if {[file exists $path] && [read_note $folder $name] ne $text} {
		set vdir [file join [dir_of $folder] .versions]
		file mkdir $vdir
		file copy -force $path [file join $vdir "$name.[clock milliseconds].md"]
		set old [lsort -dictionary [glob -nocomplain -directory $vdir -types f [literal $name].*.md]]
		if {[llength $old] > $keep} {
			foreach f [lrange $old 0 end-$keep] { file delete $f }
		}
	}
	set tmp "$path.[pid].tmp"
	set fh [::open $tmp w]
	fconfigure $fh -encoding utf-8 -translation lf
	puts -nonewline $fh $text
	close $fh
	file rename -force $tmp $path
}

proc ::notes::store::create_note {folder} {
	set name Untitled
	set i 1
	while {[file exists [note_path $folder $name]]} {
		incr i
		set name "Untitled $i"
	}
	write_note $folder $name ""
	return $name
}

# Moves the note and its versions; DEST and NEW NAME may equal the source's.
proc ::notes::store::relocate {folder name dest newname} {
	if {$dest eq $folder && $newname eq $name} return
	if {[file exists [note_path $dest $newname]]} {
		error "a note called $newname is already in [expr {$dest eq "" ? "the root" : $dest}]"
	}
	file mkdir [dir_of $dest]
	set vsrc [file join [dir_of $folder] .versions]
	set vdst [file join [dir_of $dest] .versions]
	file rename [note_path $folder $name] [note_path $dest $newname]
	foreach v [glob -nocomplain -directory $vsrc -types f [literal $name].*.md] {
		file mkdir $vdst
		set tail [string range [file tail $v] [string length $name] end]
		file rename $v [file join $vdst "$newname$tail"]
	}
}

proc ::notes::store::rename_note {folder old new} {
	set new [string trim $new]
	if {$new eq "" || [regexp {[/\\]} $new]} { error "a note needs a plain name" }
	relocate $folder $old $folder $new
	return $new
}

proc ::notes::store::move_note {folder name dest} {
	relocate $folder $name $dest $name
}

proc ::notes::store::trash_note {folder name} {
	set dest [file join [root] .trash {*}[expr {$folder eq "" ? {} : [split $folder /]}]]
	file mkdir $dest
	set n $name
	set i 1
	while {[file exists [file join $dest "$n.md"]]} {
		incr i
		set n "$name $i"
	}
	file rename [note_path $folder $name] [file join $dest "$n.md"]
	return $n
}

# Puts a trashed note back in its folder (the folder is made again if it is gone); a name already there gets a
# number. Returns the name it has now.
proc ::notes::store::restore_note {folder name} {
	set src [file join [root] .trash {*}[expr {$folder eq "" ? {} : [split $folder /]}] "$name.md"]
	set dir [dir_of $folder]
	file mkdir $dir
	set n $name
	set i 1
	while {[file exists [file join $dir "$n.md"]]} {
		incr i
		set n "$name $i"
	}
	file rename $src [file join $dir "$n.md"]
	return $n
}

proc ::notes::store::trashed {} {
	variable out
	set out {}
	collect_trash [file join [root] .trash] ""
	return [lsort $out]
}

proc ::notes::store::collect_trash {dir rel} {
	variable out
	foreach f [glob -nocomplain -directory $dir -types f *.md] {
		lappend out [list $rel [file rootname [file tail $f]]]
	}
	foreach d [glob -nocomplain -directory $dir -types d *] {
		collect_trash $d [expr {$rel eq "" ? [file tail $d] : "$rel/[file tail $d]"}]
	}
}

# A new folder under PARENT ("" is the root): Untitled folder, Untitled folder 2, ...; returns its name.
proc ::notes::store::create_folder {parent} {
	set name "Untitled folder"
	set i 1
	while {[file isdirectory [file join [dir_of $parent] $name]]} {
		incr i
		set name "Untitled folder $i"
	}
	file mkdir [file join [dir_of $parent] $name]
	return $name
}
