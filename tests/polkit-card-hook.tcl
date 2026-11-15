# polkit-card-hook.tcl - RIBBON_POLKIT_TEST hook for ribbon-polkit's own main.tcl with the real card (tests/polkit-card.tcl
# is the driver). It runs in the agent's process and holds no password: the driver "types" on the keyboard stand-in
# (a separate process). The hook only watches the card and prints a line whenever its state changes, and does what the
# driver asks through $POLKIT_FIX/hook.cmd: "click NAME" presses the card's button with the mouse (a canvas click),
# "wait" holds the process open (so the driver can read its memory) until hook.go exists.
# (sourced inside a proc of main.tcl: the variables are set at global level explicitly)
set ::fix $::env(POLKIT_FIX)
fconfigure stdout -buffering line
puts "hook pid [pid]"
set ::last ""
set ::cmdpos 0
proc state {} {
	set up [expr {[info exists ::card::up] ? $::card::up : 0}]
	if {!$up} { return "up=0" }
	list up=1 choose=$::card::choose chosen=$::card::chosen count=$::card::count busy=$::card::busy focus=$::ui::focus \
		msg=[lindex $::card::msg 0] prompt=[expr {$::card::prompting}] echo=$::card::echo ph=$::card::ph
}
proc tick {} {
	global last cmdpos fix
	set s [state]
	if {$s ne $last} { set last $s; puts "state $s" }
	if {![catch {open $fix/hook.cmd} f]} {
		seek $f $cmdpos; set data [read $f]; set cmdpos [tell $f]; close $f
		foreach line [split $data \n] {
			switch -- [lindex $line 0] {
				click {
					foreach fo $::ui::focusables {
						if {[lindex $fo 0] eq [lindex $line 1]} {
							lassign $fo - - x y w h
							event generate .pk.c <ButtonPress-1> -x [expr {int($x + $w / 2)}] -y [expr {int($y + $h / 2)}]
							puts "clicked [lindex $line 1]"
						}
					}
				}
				wait { puts "waiting"; vwait ::go }
				size { puts "size [winfo width .pk.c]x[winfo height .pk.c] scrim=$::card::scrim" }
			}
		}
	}
	if {[file exists $fix/hook.go]} { set ::go 1 }
	after 40 tick
}
tick
