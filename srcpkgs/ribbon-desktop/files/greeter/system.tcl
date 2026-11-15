# system.tcl - what the greeter reads from the system: the people who can
# log in, the sessions they can start, keyboard layouts, the remembered
# last login, and suspend / restart / power off.
#
# Every path can be redirected through the environment, so tests run the
# real code against fixture files:
#   RIBBON_GREETER_PASSWD    /etc/passwd
#   RIBBON_GREETER_LOGINDEFS /etc/login.defs
#   RIBBON_GREETER_SESSIONS  "/usr/share/wayland-sessions /usr/share/xsessions"
#   RIBBON_GREETER_ICONS     account pictures (/var/lib/AccountsService/icons)
#   RIBBON_GREETER_STATE     the state directory (/var/lib/greetd)
#   RIBBON_GREETER_XKB       the X keyboard config (00-keyboard.conf)
#   RIBBON_GREETER_POWER     a command prefix run instead of loginctl

namespace eval sys {
	variable state {}       ;# user, session.<user>
}

proc sys::env {name default} {
	expr {[info exists ::env($name)] && $::env($name) ne "" ? $::env($name) : $default}
}

proc sys::readfile {f} {
	set fh [open $f]
	fconfigure $fh -encoding utf-8
	set t [read $fh]
	close $fh
	return $t
}

# People who can log in: UID_MIN..UID_MAX from login.defs, a real shell,
# sorted by uid (the first account the installer made comes first).
proc sys::users {} {
	set lo 1000; set hi 60000
	catch {
		foreach l [split [readfile [env RIBBON_GREETER_LOGINDEFS /etc/login.defs]] \n] {
			regexp {^\s*UID_MIN\s+(\d+)} $l -> lo
			regexp {^\s*UID_MAX\s+(\d+)} $l -> hi
		}
	}
	set out {}
	if {[catch {readfile [env RIBBON_GREETER_PASSWD /etc/passwd]} text]} { return {} }
	foreach l [split $text \n] {
		set f [split $l :]
		if {[llength $f] < 7} continue
		lassign $f name - uid - gecos home shell
		if {![string is integer -strict $uid] || $uid < $lo || $uid > $hi} continue
		if {[string match *nologin $shell] || [string match */false $shell] || $name eq "nobody"} continue
		set full [string trim [lindex [split $gecos ,] 0]]
		if {$full eq ""} { set full $name }
		lappend out [list $uid [dict create name $name full $full letter [string toupper [string index $full 0]] home $home]]
	}
	set res {}
	foreach u [lsort -integer -index 0 $out] { lappend res [lindex $u 1] }
	return $res
}

# Your account picture, or "": AccountsService's icon for you (the
# installer puts it there, world-readable), else ~/.face if the greeter
# may read it. A PNG or GIF (what Tk reads without extensions), at most
# 10 MB.
proc sys::face {user} {
	set name [dict get $user name]
	set home [expr {[dict exists $user home] ? [dict get $user home] : ""}]
	foreach f [list [file join [env RIBBON_GREETER_ICONS /var/lib/AccountsService/icons] $name] \
			[expr {$home eq "" ? "" : [file join $home .face]}]] {
		if {$f eq ""} continue
		if {$name eq "" || ![file isfile $f] || ![file readable $f] || [file size $f] > 10000000} continue
		if {[catch {open $f rb} fh]} continue
		set head [read $fh 8]; close $fh
		if {$head eq "\x89PNG\r\n\x1a\n" || [string match GIF8* $head]} { return $f }
	}
	return ""
}

# One .desktop file's [Desktop Entry] keys (unlocalised).
proc sys::desktop {f} {
	set d [dict create]
	set in 0
	foreach l [split [readfile $f] \n] {
		set l [string trim $l]
		if {[string match {\[*\]} $l]} { set in [expr {$l eq {[Desktop Entry]}}]; continue }
		if {$in && [regexp {^([A-Za-z0-9-]+)\s*=\s*(.*)$} $l -> k v]} { dict set d $k $v }
	}
	return $d
}

# Sessions: Wayland sessions first, then X sessions (started through startx,
# so only when it is installed). Ribbon's own session comes first (it is
# the default), then Ribbon's other sessions. Each: id name exec type desktop.
proc sys::sessions {} {
	set dirs [env RIBBON_GREETER_SESSIONS "/usr/share/wayland-sessions /usr/share/xsessions"]
	set out {}
	set seen {}
	foreach dir $dirs {
		set type [expr {[string match *xsessions* $dir] ? "x11" : "wayland"}]
		if {$type eq "x11" && [auto_execok startx] eq ""} continue
		foreach f [lsort [glob -nocomplain -directory $dir *.desktop]] {
			set id [file rootname [file tail $f]]
			if {$id in $seen || [catch {desktop $f} d]} continue
			if {![dict exists $d Exec] || ![dict exists $d Name]} continue
			if {[dict exists $d Hidden] && [dict get $d Hidden] eq "true"} continue
			if {[dict exists $d NoDisplay] && [dict get $d NoDisplay] eq "true"} continue
			if {[dict exists $d TryExec] && [auto_execok [dict get $d TryExec]] eq ""} continue
			lappend seen $id
			set desk [expr {[dict exists $d DesktopNames] ? [string trimright [dict get $d DesktopNames] {;}] : ""}]
			set comment [expr {[dict exists $d Comment] ? [dict get $d Comment] : ""}]
			lappend out [dict create id $id name [dict get $d Name] exec [dict get $d Exec] type $type desktop $desk comment $comment]
		}
	}
	# Ribbon's sessions first, its own desktop at the top
	set first {}; set rest {}
	foreach d $out {
		if {[dict get $d id] eq "ribbon"} { set first [linsert $first 0 $d] } elseif {[string match "Ribbon*" [dict get $d name]]} { lappend first $d } else { lappend rest $d }
	}
	return [concat $first $rest]
}

# The session pill's words: "Ribbon" in the accent, then what kind of
# session it is ("· desktop", "· game mode"; others: what they are, from a
# few known ones or a short Comment=, else Wayland / X11).
proc sys::session_label {s} {
	set name [string trim [regsub {\s*\(.*\)\s*$} [dict get $s name] ""]]
	if {$name eq "Ribbon"} { return [list Ribbon "· desktop"] }
	if {[string match "Ribbon *" $name]} { return [list Ribbon "· [string tolower [string range $name 7 end]]"] }
	set known {labwc "plain session" gamescope-session "Big Picture (gamescope)" steam "Big Picture (gamescope)"}
	if {[dict exists $known [dict get $s id]]} { return [list $name "· [dict get $known [dict get $s id]]"] }
	set comment [expr {[dict exists $s comment] ? [string trim [dict get $s comment]] : ""}]
	if {$comment ne "" && [string length $comment] <= 24} { return [list $name "· $comment"] }
	list $name [expr {[dict get $s type] eq "x11" ? "· X11" : "· Wayland"}]
}

# greetd's start_session: the command (an X session goes through startx)
# and the session environment.
proc sys::session_start {s} {
	set cmd [desktop_exec [dict get $s exec]]
	set env [list XDG_SESSION_TYPE=[dict get $s type] XDG_SESSION_DESKTOP=[dict get $s id]]
	if {[dict get $s desktop] ne ""} { lappend env XDG_CURRENT_DESKTOP=[string map {; :} [dict get $s desktop]] }
	if {[dict get $s type] eq "x11"} { set cmd [list startx /usr/bin/env {*}$cmd] }
	list $cmd $env
}

# Exec= as a word list: quoting per the desktop entry spec, field codes dropped.
proc sys::desktop_exec {e} {
	set words {}
	set w ""; set inw 0; set q 0
	set n [string length $e]
	for {set i 0} {$i < $n} {incr i} {
		set ch [string index $e $i]
		if {$q} {
			if {$ch eq "\\" && $i + 1 < $n} { incr i; append w [string index $e $i] } elseif {$ch eq "\""} { set q 0 } else { append w $ch }
		} elseif {$ch eq "\""} { set q 1; set inw 1
		} elseif {[string is space $ch]} { if {$inw} { lappend words $w; set w ""; set inw 0 }
		} else { append w $ch; set inw 1 }
	}
	if {$inw} { lappend words $w }
	set out {}
	foreach w $words {
		if {[regexp {^%[fFuUdDnNickvm]$} $w]} continue
		lappend out [string map {%% %} $w]
	}
	return $out
}

# ---- keyboard layouts -------------------------------------------------

# The configured XKB layouts: XkbLayout in the X keyboard config (what the
# installer writes), else XKB_DEFAULT_LAYOUT (what labwc was started with).
proc sys::layouts {} {
	set ls {}
	if {![catch {readfile [env RIBBON_GREETER_XKB /etc/X11/xorg.conf.d/00-keyboard.conf]} t]} {
		regexp {Option\s+"XkbLayout"\s+"([^"]*)"} $t -> ls
	}
	if {$ls eq ""} { set ls [env XKB_DEFAULT_LAYOUT us] }
	set out {}
	foreach l [split $ls ,] { if {[string trim $l] ne ""} { lappend out [string trim $l] } }
	if {![llength $out]} { set out us }
	return $out
}

# What the pill shows: EN-GB, EN-US, DE, ...
proc sys::layout_label {l} {
	set l [regsub {\(.*\)$} $l ""]
	switch -- $l { gb { return EN-GB } us { return EN-US } ie { return EN-IE } au { return EN-AU } ca { return EN-CA } }
	string toupper $l
}

# Switch the X server (XWayland, ours alone) to layout L.
proc sys::set_layout {l} {
	if {[auto_execok setxkbmap] eq ""} { return 0 }
	expr {![catch {exec setxkbmap -layout [regsub {\(.*\)$} $l ""] {*}[expr {[regexp {\((.*)\)} $l -> v] ? [list -variant $v] : ""}] 2>/dev/null}]}
}

# ---- the remembered last login ----------------------------------------

proc sys::statefile {} { file join [env RIBBON_GREETER_STATE /var/lib/greetd] ribbon-greeter.state }

proc sys::state_load {} {
	variable state
	set state {}
	if {[catch {readfile [statefile]} t]} return
	foreach l [split $t \n] {
		if {[regexp {^([A-Za-z0-9_.@-]+)=(.*)$} $l -> k v]} { dict set state $k $v }
	}
}

proc sys::state_get {k} {
	variable state
	expr {[dict exists $state $k] ? [dict get $state $k] : ""}
}

proc sys::state_save {user session} {
	variable state
	dict set state user $user
	dict set state session.$user $session
	set f [statefile]
	set tmp $f.[pid]
	if {[catch {
		file mkdir [file dirname $f]
		set fh [open $tmp w]
		dict for {k v} $state { puts $fh $k=$v }
		close $fh
		file rename -force $tmp $f
	} err]} { puts stderr "ribbon-greeter: can't remember the last login: $err" }
}

# ---- power -------------------------------------------------------------

# loginctl (elogind) asks polkit; 50-ribbon-greeter.rules lets _greeter.
proc sys::power {what} {
	set verb [dict get {suspend suspend restart reboot poweroff poweroff} $what]
	set cmd [env RIBBON_GREETER_POWER loginctl]
	if {[catch {exec {*}$cmd $verb 2>@1} err]} { return $err }
	return ""
}
