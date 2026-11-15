# hook.tcl - RIBBON_SHELL_TEST for tests/term/run.sh: the real shell with the real ribbon-shell-watch, and a log.
set ::lg [open $::env(RTT_LOG) a]
fconfigure $::lg -buffering line
proc ::say {args} { puts $::lg "[clock milliseconds] [join $args { }]" }
proc ::cmd {line} { catch {uplevel #0 $line} r; say result $r }
proc ::kt {chord} { set ::t0 [clock microseconds]; wm::send key $chord }
shell::verb probe {apply {{} { say probe [expr {[clock microseconds] - $::t0}] }}}
proc ::tabs {} {
	say tabs groups=$term::groups {*}[lmap g $term::groups { list $g cur=$term::G($g,cur) tabs=$term::G($g,tabs) marks=[lmap n [array names term::G $g,mark,*] { lindex [split $n ,] 2 }] min=$term::G($g,min) max=$term::G($g,max) rect=$term::G($g,x),$term::G($g,y),$term::G($g,w),$term::G($g,h) }]
}
proc ::dock {} { say dock [lmap g [dock::groups] { list [lindex $g 0] n=[llength [lindex $g 1]] [lindex $g 2] }] }
set ::cf [open $::env(RTT_CMD) {RDWR NONBLOCK}]
fileevent $::cf readable {while {[gets $::cf l] >= 0} { cmd $l }}
wm::start
say hooked
proc ::wins {} { say wins [lmap id $wm::order { list [wm::get $id app] [wm::get $id state] }] }
# the tabs of the first group in the strip's order, as app-ids, and whether its strip is hidden (Show the strip)
proc ::order {} { set g [lindex $term::groups 0]; say order [lmap id $term::G($g,tabs) { wm::get $id app }] hide=$term::G($g,hide) }
# whether window ID is still there
proc ::has {id} { say has $id [info exists wm::tl($id)] }
