# nav.tcl - the folder the Image Viewer walks: the pictures of a folder that the
# stage can draw (stage.tcl's decoders; no SVG or HEIC: nothing here shows them yet)
# and, when mpv can play them (video.tcl; the viewer sets nav::play), its videos, in Files' order (folders first, then names in dictionary order), and
# Delete to the trash in the freedesktop layout (~/.local/share/Trash/files and
# info, the same as Files uses). No Tk.

namespace eval nav {
	variable image {png jpg jpeg webp gif bmp avif tif tiff ppm pgm}
	variable video {mp4 m4v mkv webm mov avi}
	variable play 0     ;# videos are walked too
}

# "image", "video" or "" for a file name.
proc nav::kind {name} {
	variable image; variable video; variable play
	set e [string tolower [file extension $name]]
	set e [string range $e 1 end]
	if {$e in $image} { return image }
	if {$play && $e in $video} { return video }
	return ""
}

# The folder DIR's media files, as paths, in Files' order.
proc nav::items {dir} {
	set names {}
	foreach p [glob -nocomplain -types f -directory $dir *] {
		set n [file tail $p]
		if {[nav::kind $n] ne ""} { lappend names $n }
	}
	return [lmap n [lsort -dictionary $names] { file join $dir $n }]
}

# The index of PATH in ITEMS, or -1.
proc nav::index {items path} {
	lsearch -exact $items $path
}

# The index N steps from I (DIR is 1 or -1), wrapping round the folder.
proc nav::step {i dir n} {
	if {$n <= 0} { return -1 }
	return [expr {(($i + $dir) % $n + $n) % $n}]
}

# Move PATH to the trash (freedesktop layout). Returns the trashed name, or ""
# when it could not be moved.
proc nav::bin {path} {
	set base [expr {[info exists ::env(XDG_DATA_HOME)] ? $::env(XDG_DATA_HOME) : "$::env(HOME)/.local/share"}]
	set dir [file join $base Trash]
	file mkdir [file join $dir files] [file join $dir info]
	set name [file tail $path]
	set dest $name
	set n 1
	while {[file exists [file join $dir files $dest]] || [file exists [file join $dir info $dest.trashinfo]]} {
		incr n
		set dest "[file rootname $name] $n[file extension $name]"
	}
	set info [file join $dir info $dest.trashinfo]
	set fh [open $info w]
	fconfigure $fh -encoding utf-8
	puts $fh "\[Trash Info\]"
	puts $fh "Path=[nav::escape [file normalize $path]]"
	puts $fh "DeletionDate=[clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S}]"
	close $fh
	if {[catch {file rename -- $path [file join $dir files $dest]}]} {
		file delete -force $info
		return ""
	}
	return $dest
}

# The Path= value of a .trashinfo file: spaces and percent signs escaped as URLs.
proc nav::escape {p} {
	set out ""
	foreach ch [split $p ""] {
		if {[regexp {[A-Za-z0-9/._~-]} $ch]} { append out $ch } else {
			binary scan [encoding convertto utf-8 $ch] cu* bytes
			foreach b $bytes { append out [::format %%%02X $b] }
		}
	}
	return $out
}
