# text-access.tcl - shell/text.tcl's text::access (Settings → Accessibility as Ribbon's own apps and the shell take
# it) with no display: tclsh8.6 tests/text-access.tcl ROOT (ROOT: ribbon-desktop/files). Exits 1 on any failure.
set D [lindex $argv 0]
set fails 0
proc check {what cond} { global fails; if {[uplevel #0 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails } }
set T [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] text-access-[pid]]
file mkdir [file join $T ribbon]
set ::env(XDG_CONFIG_HOME) $T
source -encoding utf-8 [file join $D shell text.tcl]
proc spit {text} {
	# as access.tcl writes: a new file renamed over the old one
	set f [file join $::T ribbon access.conf]
	set h [open $f.new w]; puts -nonewline $h $text; close $h; file rename -force $f.new $f
}
check "no access.conf: neither" {[text::access] eq {contrast 0 motion 0} && ![text::reduce_motion] && ![text::high_contrast]}
spit "TEXT_SCALE=150\nHIGH_CONTRAST=yes\nREDUCE_MOTION=\"yes\"\n"
check "HIGH_CONTRAST=yes and a quoted REDUCE_MOTION=\"yes\": both" {[text::high_contrast] && [text::reduce_motion]}
spit "TEXT_SCALE=150\nHIGH_CONTRAST=no\nREDUCE_MOTION=yes\n"
check "a change in the same second is seen (the file is a new one)" {![text::high_contrast] && [text::reduce_motion]}
spit "HIGH_CONTRAST=maybe\nREDUCE_MOTION=yes; rm -rf /\n"
check "values that are not yes or no: neither" {![text::high_contrast] && ![text::reduce_motion]}
file delete [file join $T ribbon access.conf]
check "the file gone: neither" {![text::high_contrast] && ![text::reduce_motion]}
file delete -force $T
if {$fails} { puts "text::access: $fails failed"; exit 1 }
puts "text::access: all passed"
