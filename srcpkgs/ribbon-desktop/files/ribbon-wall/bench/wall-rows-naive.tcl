# time the shell's existing per-pixel wall::rows (shell/wall.tcl) on 54 rows
# (the bar strip) and on 108 rows of a W-wide screen, then extrapolate.
set sh [file join [file dirname [file normalize [info script]]] .. .. shell]
source $sh/raster.tcl; source $sh/wall.tcl
set pal {DESK_TOP #2B2825 DESK_BOTTOM #121110 DESK_STRIPE #FFFFFF DESK_STRIPE_ALPHA 0.03}
foreach {W H} {1920 1080 3840 2160 7680 4320} {
	set t [clock microseconds]
	set rows [wall::rows $pal 0 0 $W 54 $W $H]
	set dt [expr {([clock microseconds] - $t) / 1e6}]
	puts [format "naive wall::rows %dx%d: strip (54 rows) %.2f s; full screen ~%.1f s" $W $H $dt [expr {$dt * $H / 54.0}]]
}
