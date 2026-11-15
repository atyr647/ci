# all.tcl -- run every kitfmt test:   KITFMT_MK4TCL=<dir with Mk4tcl> tclsh tests/all.tcl
package require tcltest 2
namespace import ::tcltest::*
set tmp [expr {[info exists env(TMPDIR)] && [file isdirectory $env(TMPDIR)] ? $env(TMPDIR) : "/tmp"}]
configure -testdir [file dirname [file normalize [info script]]] -tmpdir $tmp {*}$argv
set failed 0
proc ::tcltest::cleanupTestsHook {} { variable numTests ; upvar 0 ::failed f ; incr f $numTests(Failed) }
runAllTests
exit [expr {$failed ? 1 : 0}]
