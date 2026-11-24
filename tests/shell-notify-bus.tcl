# shell-notify-bus.tcl - the real shell on a private session bus (RIBBON_SHELL_TEST=this file, under xvfb;
# tests/test-notify-bus.sh is the client). Every arrival is written to NOTIFY_BUS_LOG as the popup shows it
# (app, summary, body, icon); an entry with actions has its first keycap clicked, as a person would.
interp bgerror {} {apply {{msg opts} { puts "  FAIL background error: [dict get $opts -errorinfo]"; exit 1 }}}
proc note {line} { set f [open $::env(NOTIFY_BUS_LOG) a]; puts $f $line; close $f }
proc arrived {kind id} {
	if {$kind ne "arrived"} return
	set e [notify::find $id]
	note "arrived $id app=[dict get $e app] summary=[dict get $e summary] body=[dict get $e body] icon=[notify::icon_of $e] value=[dict get $e value] done=[expr {[dict get $e value] ne "" ? [notify::done $e] : ""}]"
	if {[llength [dict get $e actions]] && [dict get $e summary] ne "leave me"} { after 400 [list click $id] }
}
proc click {id} {
	foreach h $notify::hits {
		lassign $h x0 y0 x1 y1 script
		if {[lindex $script 1] == $id} {
			# the click goes through the surface's own binding
			event generate .notify <ButtonPress-1> -x [expr {int($x0) + 3}] -y [expr {int($y0) + 3}]
			note "clicked $id"
			return
		}
	}
	note "no keycap for $id"
}
notify::onchange arrived
after 500 {note "status $notify::status"}
after 40000 exit
