# files-drives.tcl - Ribbon Files' drives: the sidebar's DRIVES rows and the
# free space in the status bar (sourced by files.tcl).
#
# Nothing here runs on the draw path. The volumes come from UDisks2
# (org.freedesktop.UDisks2 on the system bus, through ribbon::dbus), read in a
# coroutine and read again on its InterfacesAdded, InterfacesRemoved and
# PropertiesChanged. The usage figures come from df, run in the background
# through a pipe and kept for a few seconds. A draw takes what is known now;
# when an answer arrives with something new, the windows draw again.
#
# A drive that is not mounted gets its row without the usage bar; a click on
# it mounts it with UDisks2's Filesystem.Mount (polkit asks when it must) and
# opens the folder it was mounted on. Without UDisks2 (no system bus, no
# service) the rows are the mounted drives df lists, as before.

namespace eval files {
	variable dfc            ;# df answers: key -> {milliseconds output}
	variable dfrun          ;# df running: key -> {pipe output timer}
	variable dfttl 5000     ;# an answer is good for this long
	variable dfwait 10000   ;# a df that has not answered by then is let go (a hung network mount)
	variable dfback 60000   ;# and that key is not asked again for this long
	variable dfredraw ""
	variable ud {}          ;# the UDisks2 volumes: a list of dicts (ud_volumes)
	variable udbusy 0
	variable udagain 0
	variable udseq 0
	variable udbus ""       ;# the connection the signals are listened on
	array set dfc {}
	array set dfrun {}
}

# ---- df, in the background -----------------------------------------------------

# df's output for KEY (run with ARGV), as last read: "" before the first answer. A stale or
# missing answer starts a df; this never waits for one.
proc files::df_ask {key argv} {
	variable dfc
	variable dfrun
	variable dfttl
	if {[info exists dfc($key)]} { lassign $dfc($key) t out } else { set t 0; set out "" }
	if {[clock milliseconds] - $t >= $dfttl && ![info exists dfrun($key)]} { df_start $key $argv }
	return $out
}

# KEY's answer is out of date (a drive was mounted): the next draw asks again, and shows the old
# answer until the new one comes, so the other rows keep their usage bars.
proc files::df_forget {key} {
	variable dfc
	if {[info exists dfc($key)]} { lset dfc($key) 0 0 }
}

proc files::df_start {key argv} {
	variable dfc
	variable dfrun
	variable dfwait
	# answers for folders not shown for a minute go
	set now [clock milliseconds]
	foreach k [array names dfc path:*] { if {$now - [lindex $dfc($k) 0] > 60000} { unset dfc($k) } }
	if {[catch {::open |[list df {*}$argv 2>/dev/null] r} fh]} {
		set dfc($key) [list $now [expr {[info exists dfc($key)] ? [lindex $dfc($key) 1] : ""}]]
		return
	}
	fconfigure $fh -blocking 0 -translation lf -encoding utf-8
	set dfrun($key) [list $fh "" [after $dfwait [list files::df_done $key 1]]]
	fileevent $fh readable [list files::df_read $key]
}

proc files::df_read {key} {
	variable dfrun
	lassign $dfrun($key) fh out timer
	append out [read $fh]
	lset dfrun($key) 1 $out
	if {[eof $fh]} { df_done $key 0 }
}

# df has answered (or, LATE, has not answered in time and is let go).
proc files::df_done {key late} {
	variable dfc
	variable dfrun
	variable dfback
	variable dfttl
	variable dfredraw
	if {![info exists dfrun($key)]} return
	lassign $dfrun($key) fh out timer
	unset dfrun($key)
	after cancel $timer
	catch {fileevent $fh readable {}}
	set old [expr {[info exists dfc($key)] ? [lindex $dfc($key) 1] : ""}]
	if {$late} {
		# a non-blocking close does not wait for the process
		catch {::close $fh}
		set dfc($key) [list [expr {[clock milliseconds] + $dfback - $dfttl}] $old]
		return
	}
	# df exits 1 when one file system could not be read, and still prints the others
	fconfigure $fh -blocking 1
	catch {::close $fh}
	set dfc($key) [list [clock milliseconds] $out]
	if {$out ne $old && $dfredraw eq ""} { set dfredraw [after idle files::df_changed] }
}

# Something the sidebar or the status bar shows has changed: draw them again.
proc files::df_changed {} {
	variable dfredraw
	set dfredraw ""
	foreach w [windows] {
		if {![winfo exists $w]} continue
		sidebar $w
		statusbar $w
	}
}

# The free space where PATH is: {bytes mount-point}, or {} until df has answered.
proc files::free_space {path} {
	set out [df_ask path:$path [list -B1 --output=avail,target -- $path]]
	if {[regexp {\n\s*(\d+)\s+([^\n]+)} $out -> avail target]} { return [list $avail $target] }
	return {}
}

# The mounted local file systems: mount point -> {used size}.
proc files::df_mounts {} {
	set out [df_ask all {-l -B1 --output=used,size,target}]
	set m [dict create]
	foreach line [lrange [split $out \n] 1 end] {
		if {[regexp {^\s*(\d+)\s+(\d+)\s+(.+)$} $line -> used size target]} { dict set m $target [list $used $size] }
	}
	return $m
}

# ---- the rows --------------------------------------------------------------------

# The DRIVES rows: {label path used size udisks-object}. PATH is "" for a drive that is not
# mounted; USED and SIZE are "" until df has answered for it.
proc files::drives {} {
	variable ud
	ud_start
	set m [df_mounts]
	set rows {}
	set shown {}
	dict for {target us} $m {
		lassign $us used size
		set label [mount_label $target]
		if {$label eq "" || $size <= 0} continue
		lappend rows [list $label $target $used $size ""]
		lappend shown $target
	}
	foreach v $ud {
		set mps [dict get $v mounts]
		set target [lindex $mps 0]
		if {$target ne ""} {
			set i [lsearch -exact $shown $target]
			if {$i >= 0} {
				# a known row: removable media take UDisks2's name for it
				if {![dict get $v system]} { lset rows $i 0 [dict get $v label] }
				lset rows $i 4 [dict get $v obj]
				continue
			}
			# mounted somewhere the df rows leave out, or df has not answered yet: the System disk
			# and gaming drives keep their names, internal disks mounted elsewhere get no row
			set label [mount_label $target]
			if {$label eq "" && [dict get $v system]} continue
			if {$label eq "" || ![dict get $v system]} { set label [dict get $v label] }
			lassign [expr {[dict exists $m $target] ? [dict get $m $target] : {"" ""}}] used size
			lappend rows [list $label $target $used $size [dict get $v obj]]
			lappend shown $target
		} elseif {![dict get $v system]} {
			lappend rows [list [dict get $v label] "" "" "" [dict get $v obj]]
		}
	}
	return $rows
}

# The row's name for a mount point, or "" for one that is not shown: the system disk, gaming
# drives (ribbon drives add) and removable media.
proc files::mount_label {target} {
	if {$target eq "/"} { return System }
	if {[string match /mnt/games/* $target]} { return [string totitle [file tail $target]] }
	if {[string match /run/media/*/* $target] || [string match /media/* $target]} { return [file tail $target] }
	return ""
}

# ---- UDisks2 ---------------------------------------------------------------------

proc files::ud_start {} {
	variable udstarted
	if {[info exists udstarted]} return
	set udstarted 1
	after idle files::ud_load
}

proc files::ud_bus {} {
	if {[catch {shell::bus system} bus]} { return "" }
	return $bus
}

proc files::ud_load {} {
	variable udbusy
	variable udagain
	variable udseq
	if {$udbusy} { set udagain 1; return }
	set bus [ud_bus]
	if {$bus eq ""} return
	set udbusy 1
	coroutine ::files::udread[incr udseq] files::ud_run $bus
}

proc files::ud_run {bus} {
	variable udbusy
	variable udagain
	variable ud
	while {1} {
		set udagain 0
		ud_listen $bus
		set new {}
		if {![catch {$bus call org.freedesktop.UDisks2 /org/freedesktop/UDisks2 org.freedesktop.DBus.ObjectManager GetManagedObjects} r]} {
			set new [ud_volumes [ribbon::dbus::strip a{oa{sa{sv}}} [lindex $r 0]]]
		}
		if {$new ne $ud} {
			set ud $new
			# a drive mounted or unmounted elsewhere: df's list is out of date too
			df_forget all
			after idle files::df_changed
		}
		if {!$udagain} break
	}
	set udbusy 0
}

proc files::ud_listen {bus} {
	variable udbus
	if {$udbus eq $bus} return
	set udbus $bus
	catch {
		$bus listen -sender org.freedesktop.UDisks2 -interface org.freedesktop.DBus.ObjectManager -member InterfacesAdded files::ud_changed
		$bus listen -sender org.freedesktop.UDisks2 -interface org.freedesktop.DBus.ObjectManager -member InterfacesRemoved files::ud_changed
		$bus listen -sender org.freedesktop.UDisks2 -path_namespace /org/freedesktop/UDisks2/block_devices \
			-interface org.freedesktop.DBus.Properties -member PropertiesChanged files::ud_changed
	}
}

proc files::ud_changed {args} { ud_load }

proc files::ud_prop {props name def} {
	if {[dict exists $props $name]} { return [dict get $props $name] }
	return $def
}

# A byte-string property (ay, NUL-terminated) as text.
proc files::ud_text {bytes} { encoding convertfrom utf-8 [string trimright $bytes \0] }

# The volumes worth a row, from GetManagedObjects: each a dict of obj (the block device's
# object), label, mounts (the mount points) and system (HintSystem: an internal disk).
proc files::ud_volumes {objs} {
	set B org.freedesktop.UDisks2.Block
	set F org.freedesktop.UDisks2.Filesystem
	set D org.freedesktop.UDisks2.Drive
	set out {}
	foreach path [lsort -dictionary [dict keys $objs]] {
		set ifs [dict get $objs $path]
		if {![dict exists $ifs $B] || ![dict exists $ifs $F]} continue
		set b [dict get $ifs $B]
		if {[ud_prop $b HintIgnore 0]} continue
		set mps [lmap m [ud_prop [dict get $ifs $F] MountPoints {}] { ud_text $m }]
		set label [ud_prop $b HintName ""]
		if {$label eq ""} { set label [ud_prop $b IdLabel ""] }
		if {$label eq "" && [llength $mps]} { set label [file tail [lindex $mps 0]] }
		set drive [ud_prop $b Drive /]
		if {$label eq "" && [dict exists $objs $drive $D]} { set label [string trim [ud_prop [dict get $objs $drive $D] Model ""]] }
		if {$label eq ""} { set label [file tail [ud_text [ud_prop $b PreferredDevice [ud_prop $b Device ""]]]] }
		lappend out [dict create obj $path label $label mounts $mps system [ud_prop $b HintSystem 1]]
	}
	return $out
}

# A click on a drive that is not mounted: mount it, then open it in W.
proc files::drive_mount {w obj label} {
	variable st
	set bus [ud_bus]
	if {$bus eq "" || $obj eq ""} { status_fail $w "Couldn't mount $label"; return }
	set st($w,status) "Mounting $label…"
	toolbar $w
	if {[catch {$bus call -interactive 1 -timeout 120000 -command [list files::drive_mounted $w $label] \
		org.freedesktop.UDisks2 $obj org.freedesktop.UDisks2.Filesystem Mount a{sv} {}} err]} {
		drive_mounted $w $label error [list "" $err]
	}
}

proc files::drive_mounted {w label status values} {
	variable st
	if {![winfo exists $w]} return
	if {$st($w,status) eq "Mounting $label…"} { set st($w,status) "" }
	if {$status ne "ok"} {
		lassign $values name text
		# the password prompt was closed: nothing to say
		if {$name eq "org.freedesktop.UDisks2.Error.NotAuthorizedDismissed"} { toolbar $w; return }
		status_fail $w "Couldn't mount $label[expr {$text ne "" ? ": [string trim $text]" : ""}]"
		return
	}
	df_forget all
	ud_load
	go $w [lindex $values 0]
}
