# settings-datetime-real-scene.tcl - Settings → Date and time with the REAL datetime.tcl reading this machine (its
# /etc/localtime, its /usr/share/zoneinfo, its dinit directories if any): the page draws, the zone dropdown holds every
# real zone, opens on the system's own, scrolls, jumps to typed text, and a pick asks for that zone. Only dt::helper is
# stood in for (nothing is changed on the machine). Sourced by apps/settings/main.tcl through RIBBON_SETTINGS_SCENE.
#   RIBBON_DT_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
namespace eval rscene { variable fails 0; variable lines {}; variable calls {} }
proc rscene::check {what cond} { variable fails; variable lines; if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails } }
proc rscene::click {x y} { page::draw_now; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; update; page::draw_now; update }
proc rscene::key {sym {char ""}} { page::draw_now; settings::key $sym $char 0; update; page::draw_now; update }
proc dt::helper {args} { lappend ::rscene::calls $args; return 1 }

settings::select datetime
page::draw_now; update
set m [dt::model]
set zones [dt::zones]
rscene::check "the page draws from this machine: zone '[dict get $m zone]' ([dict get $m abbr]), [llength $zones] zones, time service [expr {[dict get $m ntp_available] ? "known" : "none"}]" {[dict get $m name] ne "" && [llength $zones] > 300}
# the Time zone row is the first without a time service, the second with one
set y [expr {[dict get $m ntp_available] ? 301 : 253}]
set t0 [clock milliseconds]
rscene::click 549 $y
set ms [expr {[clock milliseconds] - $t0}]
rscene::check "the zone list opens with every zone (drawn in $ms ms)" {$sctl::pop eq "dt-zone" && [llength [dict get $sctl::popd items]] >= [llength $zones] && $ms < 3000}
rscene::check "  on the system's own zone" {[dict get $m zone] eq "" || [lindex [dict get $sctl::popd items] [dict get $sctl::popd idx] 0] eq [dict get $m zone]}
set top [dict get $sctl::popd top]
ui::scroll [expr {549 + $ui::ox}] [expr {$y + 120 + $ui::oy}] 1; update; page::draw_now; update
rscene::check "  it scrolls under the wheel" {[dict get $sctl::popd top] != $top || $top + 9 >= [llength [dict get $sctl::popd items]]}
foreach ch {t o k y o} { rscene::key $ch $ch }
rscene::check "  and jumps to what is typed (tokyo: Asia/Tokyo)" {[lindex [dict get $sctl::popd items] [dict get $sctl::popd idx] 0] eq "Asia/Tokyo"}
rscene::key Return
rscene::check "Return asks the helper for that zone" {[lindex $rscene::calls end] eq {zone Asia/Tokyo} || [dict get $m zone] eq "Asia/Tokyo"}
if {[info exists ::env(RIBBON_DT_RESULT)]} { set f [open $::env(RIBBON_DT_RESULT) w]; puts $f [join $rscene::lines \n]; close $f } else { puts [join $rscene::lines \n] }
exit [expr {$rscene::fails > 0}]
