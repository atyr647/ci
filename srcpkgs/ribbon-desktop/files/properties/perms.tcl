# perms.tcl - an app's permissions: what its kit requests (KIT-FORMAT.md
# 4.2, vocabulary 1.0), what you grant (kitlink.tcl's grants file), and
# what the app gets: your grant where there is one, else the request.
#
# Kit's names, and the values the Permissions page offers:
#   network  no|yes            home     none|ro|rw
#   folders  a flat list "Folder ro|rw ..." (an XDG name such as Downloads,
#            or a path: /mnt/games are the game drives, /run/media removable media)
#   display  none|wayland|x11  audio    0|1|mic (1 playback, mic with the microphone)
#   gpu input camera  0|1
# and the desktop's own (no kit requests them in format 1.0; you grant them):
#   screencast notifications autostart nested  0|1

namespace eval perms {
	variable defaults {network no home none folders {} display none audio 0 gpu 0 input 0 camera 0
		screencast 0 notifications 0 autostart 0 nested 0}
	# the folder rows every app has, in the page's order: key label icon
	variable fixed {Home {Home home} Documents {Documents file} Downloads {Downloads download} Pictures {Pictures image}
		/mnt/games {{Game drives} pad} /run/media {{Removable media} disk}}
}

proc perms::norm {k v} {
	switch -- $k {
		network { return [expr {[string tolower $v] in {yes 1 true on} ? "yes" : "no"}] }
		home { return [expr {$v in {ro rw} ? $v : "none"}] }
		display { set v [string tolower $v]; return [expr {$v in {wayland x11} ? $v : ($v eq "both" ? "wayland" : "none")}] }
		audio { return [expr {$v eq "mic" ? "mic" : ([string tolower $v] in {1 yes true on playback} ? 1 : 0)}] }
		folders {
			set out {}
			foreach {d m} $v { if {$d ne ""} { lappend out $d [expr {$m eq "rw" ? "rw" : "ro"}] } }
			return $out
		}
		default { return [expr {[string tolower $v] in {1 yes true on} ? 1 : 0}] }
	}
}

# What the kit asks for, every name filled in.
proc perms::requested {K} {
	variable defaults
	set r $defaults
	foreach p [dict get $K perms] {
		lassign $p k v
		if {[dict exists $defaults $k]} { dict set r $k [norm $k $v] }
		# dbus: a request for the notification service counts as one
		if {$k eq "dbus" && [string match *org.freedesktop.Notifications* $v]} { dict set r notifications 1 }
	}
	return $r
}

# What the app gets.
proc perms::effective {K} {
	set r [requested $K]
	dict for {k v} [dict get $K grants] { if {[dict exists $r $k]} { dict set r $k [norm $k $v] } }
	return $r
}

# The grants that make EDITED what the app gets: only what differs from
# the request.
proc perms::grants {K edited} {
	set r [requested $K]
	set g {}
	dict for {k v} $edited {
		if {$k eq "folders"} {
			if {[lsort -stride 2 $v] ne [lsort -stride 2 [dict get $r folders]]} { dict set g folders $v }
		} elseif {[dict get $r $k] ne $v} { dict set g $k $v }
	}
	return $g
}

# ---- the editor's rows: one value per row ------------------------------------------

# A row's key: a permission name, or "folder:<key>" for a folder.
proc perms::rows {E} {
	variable fixed
	set out {}
	dict for {k li} $fixed { lappend out [list folder:$k {*}$li] }
	foreach {d m} [dict get $E folders] {
		if {[dict exists $fixed $d] || $d eq "Home"} continue
		lappend out [list folder:$d [file tail $d] folder]
	}
	return $out
}

proc perms::get {E key} {
	if {$key eq "folder:Home"} { return [dict get $E home] }
	if {[string match folder:* $key]} {
		set d [string range $key 7 end]
		foreach {k m} [dict get $E folders] { if {$k eq $d} { return $m } }
		return none
	}
	dict get $E $key
}

proc perms::set_ {E key v} {
	if {$key eq "folder:Home"} { dict set E home $v; return $E }
	if {[string match folder:* $key]} {
		set d [string range $key 7 end]
		set out {}; set done 0
		foreach {k m} [dict get $E folders] {
			if {$k eq $d} { set done 1; if {$v ne "none"} { lappend out $k $v }; continue }
			lappend out $k $m
		}
		if {!$done && $v ne "none"} { lappend out $d $v }
		dict set E folders $out
		return $E
	}
	dict set E $key $v
	return $E
}

# What has changed between two value sets: the row keys.
proc perms::changed {A B} {
	set out {}
	set keys [dict keys $A]
	foreach k $keys {
		if {$k eq "folders"} continue
		if {[dict get $A $k] ne [dict get $B $k]} { lappend out $k }
	}
	set ds {}
	foreach {d m} [concat [dict get $A folders] [dict get $B folders]] { if {$d ni $ds} { lappend ds $d } }
	foreach d $ds { if {[get $A folder:$d] ne [get $B folder:$d]} { lappend out folder:$d } }
	if {"home" in $out} { set out [lreplace $out [lsearch $out home] [lsearch $out home] folder:Home] }
	return $out
}

# The Overview's chips: what the app is allowed, {icon label state}.
proc perms::allowed {E} {
	variable fixed
	set out {}
	if {[dict get $E network] eq "yes"} { lappend out {globe Network ""} }
	if {[dict get $E home] ne "none"} { lappend out [list home Home [access [dict get $E home]]] }
	foreach {d m} [dict get $E folders] {
		set icon folder; set label [file tail $d]
		if {[dict exists $fixed $d]} { lassign [dict get $fixed $d] label icon }
		lappend out [list $icon $label [access $m]]
	}
	set disp [dict get $E display]
	if {$disp ne "none"} { lappend out [list monitor Display [expr {$disp eq "x11" ? "X11" : "Wayland"}]] }
	switch -- [dict get $E audio] { 1 { lappend out {vol Audio playback} } mic { lappend out {vol Audio {playback and microphone}} } }
	if {[dict get $E gpu]} { lappend out {chip GPU ""} }
	if {[dict get $E input]} { lappend out {pad Controllers ""} }
	if {[dict get $E camera]} { lappend out {camera Camera ""} }
	if {[dict get $E screencast]} { lappend out {cast {Screen share} ""} }
	if {[dict get $E notifications]} { lappend out {bell Notifications ""} }
	if {[dict get $E nested]} { lappend out {box {Nested sandboxes} ""} }
	if {[dict get $E autostart]} { lappend out {power {Start at login} ""} }
	return $out
}

proc perms::access {m} { expr {$m eq "rw" ? "read & write" : "read only"} }
