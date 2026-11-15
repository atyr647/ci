# portal-choices.tcl - xdg-desktop-portal's side of the FileChooser with an app's choices (tests/steps.d/62-chooser-w3.sh
# through tests/chooser/portal-choices.sh): the choices reach the chooser (tests/chooser/choices-flow.tcl) and their
# values come back. tclsh8.6 portal-choices.tcl HOME; prints ok/FAIL lines.
package require ribbon::dbus
set H [lindex $argv 0]
set fails 0
proc check {what cond} {
	global fails
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
set bus [ribbon::dbus::connect session]
set N org.freedesktop.impl.portal.desktop.ribbon
set O /org/freedesktop/portal/desktop
set I org.freedesktop.impl.portal.FileChooser
proc ay {p} { return "[encoding convertto utf-8 $p]\0" }
proc flow {f} { set fh [open $::env(CHOOSER_FLOW_FILE) w]; puts -nonewline $fh $f; close $fh }
set choices [list a(ssa(ss)s) {{enc Encoding {{utf8 {Unicode (UTF-8)}} {latin1 {Western (ISO-8859-1)}}} utf8} {ext {Automatic file name extension} {} true}}]

flow save-changed
set r [$bus call -timeout 60000 $N $O $I SaveFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/c1 org.example.App "" "Save" \
	[dict create current_folder [list ay [ay $H/Documents]] choices $choices]]
set res [ribbon::dbus::strip a{sv} [lindex $r 1]]
check "SaveFile with choices: the file, and each choice's value as the chooser left it" \
	{[lindex $r 0] == 0 && [dict get $res uris] eq [list "file://$H/Documents/letter.txt"] && [dict get $res choices] eq {{enc latin1} {ext false}}}

flow open-defaults
set r [$bus call -timeout 60000 $N $O $I OpenFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/c2 org.example.App "" "Open" \
	[dict create choices [list a(ssa(ss)s) {{ro {Open read-only} {} false}}]]]
set res [ribbon::dbus::strip a{sv} [lindex $r 1]]
check "OpenFile with a checkbox left alone: its default comes back" \
	{[lindex $r 0] == 0 && [dict exists $res choices] && [dict get $res choices] eq {{ro false}}}

# a choice whose id or option has a line break cannot add a path to the answer (the chooser's answer is lines: a
# line break in it would end the choices' line, and what followed would be read as files the user chose)
foreach {what ch} [list \
	"an option" [list {c Charset {{"{\n/etc/passwd\n}" X} {y Y}} "{\n/etc/passwd\n}"}] \
	"an id" [list {"{\n/etc/passwd\n}" Charset {} true}]] {
	flow open-defaults
	set r [$bus call -timeout 60000 $N $O $I OpenFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/c5 org.example.App "" "Open" \
		[dict create choices [list a(ssa(ss)s) $ch]]]
	set res [ribbon::dbus::strip a{sv} [lindex $r 1]]
	check "a line break in $what of a choice adds no file to the answer" \
		{[lindex $r 0] == 0 && [dict get $res uris] eq [list "file://$H/Pictures/Iceland/V%C3%ADk.jpg"]}
}

flow cancel
set r [$bus call -timeout 60000 $N $O $I OpenFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/c3 org.example.App "" "Open" \
	[dict create choices $choices]]
check "cancelled with choices: response 1, no results" {[lindex $r 0] == 1 && ![dict exists [lindex $r 1] choices]}

flow cancel
set r [$bus call -timeout 60000 $N $O $I OpenFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/c4 org.example.App "" "Open" {}]
check "without choices the results have none" {[lindex $r 0] == 1}
exit [expr {$fails > 0}]
