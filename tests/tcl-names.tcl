# tcl-names.tcl - the Tcl programs that start another tclsh or wish find it by its unversioned name, or else by the
# name of this Tcl's version: never by a hard-coded 8.6 (STACK.md §4, T0). Run by tests/steps.d/12-tcl-names.sh:
#   tclsh tests/tcl-names.tcl FILESDIR CASE WORKDIR
# with PATH set by the step to one of its bins. CASE:
#   plain     PATH has tclsh and wish (no versioned names): each helper picks them
#   versioned PATH has only tclshX.Y and wishX.Y (X.Y = this Tcl's version): each helper picks those
#   monitor   the System monitor's .desktop reading: a versioned interpreter (wish9.0, tclsh8.6, python3.12) is a
#             wrapper, as tclsh and wish are, so a script's .desktop names no app by it
# Prints "ok ..." or "FAIL ..." lines; exits 1 on a failure.
lassign $argv files case work
set fails 0
proc check {what got want} {
	if {$got eq $want} { puts "  ok   $what" } else { puts "  FAIL $what: got {$got}, want {$want}"; incr ::fails }
}
proc first {name} { lindex [auto_execok $name] 0 }

switch -- $case {
	plain - versioned {
		if {$case eq "plain"} {
			set tclsh [first tclsh]; set wish [first wish]
		} else {
			set tclsh [first tclsh[info tclversion]]; set wish [first wish[info tclversion]]
		}
		if {$tclsh eq "" || $wish eq ""} { puts "  FAIL $case: the step's PATH has no tclsh or wish"; exit 1 }
		set tag "($case names: [file tail $tclsh], [file tail $wish])"

		# the FileChooser portal starts the chooser on wish
		package provide ribbon::dbus 1.0   ;# the portal's bus is not used here
		unset -nocomplain ::env(RIBBON_CHOOSER_WISH)
		source -encoding utf-8 [file join $files appearance chooser-portal.tcl]
		check "the FileChooser portal runs the chooser on wish $tag" [portal::wish] [list $wish]
		set ::env(RIBBON_CHOOSER_WISH) /opt/w/wish
		check "RIBBON_CHOOSER_WISH still names the chooser's wish" [portal::wish] /opt/w/wish
		unset ::env(RIBBON_CHOOSER_WISH)

		# the Catalogue runs kitq.tcl on tclsh
		unset -nocomplain ::env(CATALOGUE_TCLSH)
		source -encoding utf-8 [file join $files apps catalogue source.tcl]
		check "the Catalogue runs kitq.tcl on tclsh $tag" [cat::tclsh] $tclsh

		# Properties runs a kit through kit's script on tclsh when no kit command is on PATH
		source -encoding utf-8 [file join $files properties kitlink.tcl]
		set self [file join $work kit]
		close [open $self w]
		proc kitlink::load {} { return 1 }
		namespace eval ::kit {}
		proc ::kit::selfCmd {} { return $::self }
		check "Properties runs kit's script on tclsh $tag" [kitlink::kitcmd] [list $tclsh $self]

		# Settings → Display, Identify: identify.tcl runs on the wish that runs Settings
		source -encoding utf-8 [file join $files apps settings display.tcl]
		set display::outs [list [dict create name A on 1 scale 1 w 1920 h 1080 x 0 y 0 transform normal]]
		set ran {}
		proc display::run {argv done} { set ::ran $argv }
		display::identify
		check "Identify runs identify.tcl on the running program, not a named wish" \
			[lrange $ran 0 3] [list [info nameofexecutable] -encoding utf-8 [file join $files apps settings identify.tcl]]
	}
	monitor {
		namespace eval monitor {}
		source -encoding utf-8 [file join $files apps monitor proc.tcl]
		source -encoding utf-8 [file join $files apps monitor group.tcl]
		set d [file join $work applications]
		file mkdir $d
		foreach {id exec} {
			foot {foot}
			a {wish9.0 /opt/a/main.tcl}
			b {tclsh8.6 /opt/b/run.tcl}
			c {wish /opt/c/main.tcl}
			e {env LANG=C python3.12 /opt/e/e.py}
			f {perl5.40 /opt/f/f.pl}
			g {/usr/bin/tclsh9.1 /opt/g/g.tcl}
		} {
			set f [open [file join $d $id.desktop] w]
			puts $f "\[Desktop Entry\]\nName=$id\nExec=$exec"
			close $f
		}
		check "a script run by a versioned interpreter names no app; foot does" \
			[lsort [dict keys [monitor::group::desktops [list $d]]]] foot
	}
}
exit [expr {$fails > 0}]
