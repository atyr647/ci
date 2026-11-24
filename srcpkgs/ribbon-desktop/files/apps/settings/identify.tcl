# identify.tcl - Settings → Display, Identify: a number on each output for a few
# seconds. Run by display::identify with wish:
#   wish identify.tcl X Y W H N ...   (one group of five per output, logical pixels)
# Each number is an override-redirect window at the output's place, so it needs no
# focus and the compositor puts it where the output is. It closes itself.
# The colours are the theme's (shell/theme.tcl: the bar surface and its text).

set dir [file dirname [file normalize [info script]]]
foreach d [list [file join $dir .. shell] [file join $dir .. .. shell] /usr/lib/ribbon/shell] {
	if {[file exists [file join $d theme.tcl]]} { source -encoding utf-8 [file join $d theme.tcl]; break }
}
theme::load
set bg $theme::c(BAR)
set fg $theme::c(FG)

wm withdraw .
foreach {x y w h n} $argv {
	set t .o$n
	toplevel $t -background $bg -borderwidth 0 -highlightthickness 0
	wm overrideredirect $t 1
	wm geometry $t ${w}x${h}+${x}+${y}
	set size [expr {int(min($w, $h) * 0.42)}]
	label $t.n -text $n -font [list {Space Grotesk} -$size bold] -foreground $fg -background $bg
	place $t.n -relx 0.5 -rely 0.5 -anchor center
	bind $t <ButtonPress-1> exit
}
after 3000 exit
