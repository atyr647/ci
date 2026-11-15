# chooser.tcl - Open, Save as and Choose a folder for every Ribbon app: the Ribbon file chooser (boards Chooser-*,
# design/tools/gen_chooser.py) in place of Tk's stock tk_getOpenFile, tk_getSaveFile and tk_chooseDirectory.
#
#   chooser::open_file ?-parent W? ?-title T? ?-initialdir D? ?-filetypes TYPES? ?-multiple 0|1?
#                      ?-acceptlabel WORD? (the primary button's word in place of Open, e.g. Mail's Attach)
#   chooser::save_file ?-parent W? ?-title T? ?-initialdir D? ?-initialfile F? ?-filetypes TYPES?
#                      ?-defaultextension .EXT? ?-confirmoverwrite 0|1?
#   chooser::choose_folder ?-parent W? ?-title T? ?-initialdir D? ?-mustexist 1?
#
# The options and the answer are Tk's: a path, a list of paths with -multiple 1, "" when cancelled; -typevariable's
# variable is set to the file type in use when the chooser closed. Each call is
# modal, as Tk's are: the window runs as a program of its own (chooser-main.tcl, next to this file, on the same
# wish), centred over the asking window, and the app waits for it with its own window held (a grab) while its
# events keep being served.

namespace eval chooser {
	variable main [file join [file dirname [file normalize [info script]]] chooser-main.tcl]
	variable n 0
	variable answer
	array set answer {}
}

proc chooser::open_file {args} { run open $args }
proc chooser::save_file {args} { run save $args }
proc chooser::choose_folder {args} { run folder [dict remove $args -mustexist] }

# The asking window's toplevel: -parent's, else the toplevel with the keyboard focus, else ".".
proc chooser::toplevel_of {parent} {
	if {$parent eq "" || ![winfo exists $parent]} {
		set f [focus]
		set parent [expr {$f ne "" ? $f : "."}]
	}
	winfo toplevel $parent
}

proc chooser::run {mode opts} {
	variable main
	variable n
	variable answer
	set parent ""
	if {[dict exists $opts -parent]} { set parent [dict get $opts -parent]; set opts [dict remove $opts -parent] }
	foreach k [dict keys $opts] {
		if {$k ni {-title -initialdir -initialfile -filetypes -multiple -defaultextension -confirmoverwrite -typevariable -acceptlabel}} {
			return -code error "chooser: unknown option $k"
		}
	}
	# -typevariable: the type in use at first is the one the variable names (and it names the one in use after)
	set typevar ""
	if {[dict exists $opts -typevariable]} {
		set typevar [dict get $opts -typevariable]
		upvar #0 $typevar tv
		if {[info exists tv] && $tv ne ""} { dict set opts -initialtype $tv }
		set opts [dict remove $opts -typevariable]
	}
	set top [toplevel_of $parent]
	if {[winfo ismapped $top]} {
		dict set opts -at [list [winfo rootx $top] [winfo rooty $top] [winfo width $top] [winfo height $top]]
	}
	# the options go as one word that starts with -mode: a title or name such as "2>FILE" or "<FILE" is never taken
	# for the pipeline's redirection
	set cmd [list [info nameofexecutable] -encoding utf-8 $main -name ribbon-chooser -- [list -mode $mode {*}$opts]]
	if {[catch {::open |$cmd r} ch]} {
		puts stderr "chooser: $ch"
		return ""
	}
	set id [incr n]
	set answer($id) ""
	set answer($id,done) 0
	fconfigure $ch -blocking 0 -encoding utf-8 -translation lf
	fileevent $ch readable [list chooser::read_answer $ch $id]
	# the asking window is held while the chooser is open: its clicks and keys go nowhere (the grab takes the
	# pointer; the keys go to the hold, which has no bindings, not even its toplevel's or "all")
	set hold ""
	set keys ""
	if {[winfo ismapped $top]} {
		set hold [string trimright $top .].__chooser[incr n]
		frame $hold -width 1 -height 1
		place $hold -x 0 -y 0
		bindtags $hold [list $hold]
		update idletasks
		if {[catch {grab set $hold}]} { destroy $hold; set hold "" } else {
			set keys [focus -lastfor $top]
			focus $hold
		}
	}
	vwait chooser::answer($id,done)
	if {$hold ne ""} {
		catch {grab release $hold}
		destroy $hold
		if {$keys ne "" && [winfo exists $keys]} { focus $keys }
	}
	# the answer: the file type in use (its index in -filetypes, -1 for none) on the first line, then the paths chosen
	# (a Tcl list)
	set all [string trim $answer($id)]
	array unset answer $id*
	set nl [string first \n $all]
	set type [string range $all 0 [expr {$nl - 1}]]
	set out [expr {$nl < 0 ? "" : [string range $all [expr {$nl + 1}] end]}]
	if {$typevar ne "" && [string is integer -strict $type] && $type >= 0 && [dict exists $opts -filetypes]} {
		set types [lsearch -all -inline -not -index 0 -exact [dict get $opts -filetypes] ""]
		if {$type < [llength $types]} {
			upvar #0 $typevar tv
			set tv [lindex $types $type 0]
		}
	}
	if {$out eq "" || [catch {llength $out}]} { return "" }
	if {$mode eq "open" && [dict exists $opts -multiple] && [dict get $opts -multiple]} { return $out }
	return [lindex $out 0]
}

proc chooser::read_answer {ch id} {
	variable answer
	append answer($id) [read $ch]
	if {[eof $ch]} {
		fconfigure $ch -blocking 1
		catch {::close $ch}
		set answer($id,done) 1
	}
}
