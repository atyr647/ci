# hook.tcl - RIBBON_SHELL_TEST for run.sh (U19): the real shell under a real compositor, with the real
# ribbon-shell-watch, and a log of what the switcher does (ALTTAB_LOG). Stands in for tests/shell-scene.tcl.
set ::lg [open $::env(ALTTAB_LOG) a]
fconfigure $::lg -buffering line
proc ::say {args} { puts $::lg "[clock milliseconds] [join $args { }]" }
foreach p {alttab::reveal alttab::finish alttab::step alttab::fan alttab::fanstep alttab::move alttab::kill alttab::close alttab::open} {
	trace add execution $p enter [list apply {{p cmd op} { say call [string map {alttab:: {}} $p] [lrange $cmd 1 end] }} $p]
}
trace add execution wm::send enter {apply {{cmd op} { say send [lrange $cmd 1 end] }}}
trace add execution alttab::key enter {apply {{cmd op} { say key [lrange $cmd 1 end] }}}
trace add execution alttab::altup enter {apply {{cmd op} { say altup }}}
trace add execution alttab::got_shot leave {apply {{cmd code res op} { say shot-done [expr {$alttab::bg ne ""}] }}}
trace add execution alttab::got_cap enter {apply {{cmd op} { say cap-reply [lrange $cmd 1 end] }}}
trace add execution alttab::got_cap leave {apply {{cmd code res op} { say cap-done [llength [array names alttab::ph]] }}}
trace add variable wm::focus write {apply {{n1 n2 op} { say focus [wm::get $wm::focus app] }}}
proc ::state {} { say state on=$alttab::on shown=$alttab::shown sel=$alttab::sel fan=$alttab::fan caps=$alttab::hcaps apps=[llength $alttab::apps] }
proc ::cmd {line} { catch {uplevel #0 $line} r; say result $r }
# commands from run.sh arrive on stdin of a fifo
set ::cf [open $::env(ALTTAB_CMD) {RDWR NONBLOCK}]
fileevent $::cf readable {while {[gets $::cf l] >= 0} { cmd $l }}
wm::start
say hooked
# PROFILE runs on a labwc that does not report held keys (0.7): the helper calls every open a tap, so ignore altup
if {[info exists ::env(ALTTAB_PROFILE)]} { proc alttab::altup {} {} }
