# portal.tcl - xdg-desktop-portal's side of the FileChooser (tests/steps.d/62-chooser.sh): the calls the frontend makes
# on org.freedesktop.impl.portal.desktop.ribbon (D-Bus activated from the shipped .service file on a private session
# bus), with the chooser told what to do by tests/chooser/flow.tcl. tclsh8.6 portal.tcl HOME; prints ok/FAIL lines.
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
set k 0
proc ay {p} { return "[encoding convertto utf-8 $p]\0" }
# what the next chooser does (tests/chooser/flow.tcl reads it from CHOOSER_FLOW_FILE: the service's environment is fixed)
proc flow {f} {
	set fh [open $::env(CHOOSER_FLOW_FILE) w]; puts -nonewline $fh $f; close $fh
}

flow open-one
set r [$bus call -timeout 60000 $N $O $I OpenFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/a org.example.App x11:1 "Open a picture" \
	[dict create current_folder [list ay [ay $H/Pictures]] filters [list a(sa(us)) {{Pictures {{1 image/jpeg} {0 *.png}}}}] \
	accept_label {s _Upload}]]
set res [ribbon::dbus::strip a{sv} [lindex $r 1]]
check "OpenFile: the button says Upload; the chosen picture comes back as a file:// URI, encoded" {[lindex $r 0] == 0 && [dict get $res uris] eq [list "file://$H/Pictures/Iceland/J%C3%B6kuls%C3%A1rl%C3%B3n.jpg"]}

flow open-many
set r [$bus call -timeout 60000 $N $O $I OpenFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/b org.example.App "" "Open" \
	[dict create multiple {b 1} filters [list a(sa(us)) {{Pictures {{0 *.jpg}}}}] current_filter [list (sa(us)) {Pictures {{0 *.jpg}}}]]]
set res [ribbon::dbus::strip a{sv} [lindex $r 1]]
check "  multiple: both, and the filter in use comes back" {[lindex $r 0] == 0 && [llength [dict get $res uris]] == 2 && [lindex [dict get $res current_filter] 0] eq "Pictures"}

flow open-type2
set r [$bus call -timeout 60000 $N $O $I OpenFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/b2 org.example.App "" "Open" \
	[dict create current_folder [list ay [ay $H/Pictures]] filters [list a(sa(us)) {{JPEG {{0 *.jpg}}} {PNG {{0 *.png}}}}] current_filter [list (sa(us)) {JPEG {{0 *.jpg}}}]]]
set res [ribbon::dbus::strip a{sv} [lindex $r 1]]
check "  the filter changed in the chooser is the current_filter that comes back" {[lindex $r 0] == 0 && [dict exists $res current_filter] && [dict get $res current_filter] eq {PNG {{0 *.png}}}}

# what the app sends is never the chooser's pipeline: a title like a redirection is a title
set victim [file join $H victim]
set fh [open $victim w]; puts -nonewline $fh precious; close $fh
flow cancel
set r [$bus call -timeout 60000 $N $O $I OpenFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/b3 org.example.App "" "2>$victim" \
	[dict create accept_label {s |} current_name {s <x}]]
set fh [open $victim]; set v [read $fh]; close $fh
check "  a title like a redirection overwrites nothing (cancelled: response 1)" {$v eq "precious" && [lindex $r 0] == 1}

flow cancel
set r [$bus call -timeout 60000 $N $O $I OpenFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/c org.example.App "" "Open" {}]
check "  cancelled: response 1, no URIs" {[lindex $r 0] == 1 && ![dict exists [lindex $r 1] uris]}

flow folder-chosen
set r [$bus call -timeout 60000 $N $O $I OpenFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/d org.example.App "" "Folder" \
	[dict create directory {b 1} current_folder [list ay [ay $H/Pictures]]]]
set res [ribbon::dbus::strip a{sv} [lindex $r 1]]
check "  directory: the folder chosen" {[lindex $r 0] == 0 && [dict get $res uris] eq [list "file://$H/Pictures/Iceland"]}

flow save-new
set r [$bus call -timeout 60000 $N $O $I SaveFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/e org.example.App "" "Save" \
	[dict create current_folder [list ay [ay $H/Documents]] current_name {s draft.txt}]]
set res [ribbon::dbus::strip a{sv} [lindex $r 1]]
check "SaveFile: the name typed, in the folder asked for" {[lindex $r 0] == 0 && [dict get $res uris] eq [list "file://$H/Documents/new.md"]}

flow save-as-is
set r [$bus call -timeout 60000 $N $O $I SaveFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/e2 org.example.App "" "Save" \
	[dict create current_file [list ay [ay $H/Documents/~plan.md]]]]
set res [ribbon::dbus::strip a{sv} [lindex $r 1]]
check "  current_file: its folder, its name as it is (~plan.md)" {[lindex $r 0] == 0 && [dict get $res uris] eq [list "file://$H/Documents/~plan.md"]}

flow folder-here
set r [$bus call -timeout 60000 $N $O $I SaveFiles osssa{sv} /org/freedesktop/portal/desktop/request/1_1/f org.example.App "" "Save" \
	[dict create current_folder [list ay [ay $H/Pictures]] files [list aay [list [ay a.txt] [ay "b c.txt"] [ay ~old.txt]]]]]
set res [ribbon::dbus::strip a{sv} [lindex $r 1]]
check "SaveFiles: each file's name in the folder chosen (~old.txt as itself)" {[lindex $r 0] == 0 && [dict get $res uris] eq [list "file://$H/Pictures/Lisbon/a.txt" "file://$H/Pictures/Lisbon/b%20c.txt" "file://$H/Pictures/Lisbon/~old.txt"]}

# Close on the request while the chooser is open: response 2, the chooser gone
flow wait
set got ""
$bus call -command {apply {{args} { set ::got $args }}} -timeout 60000 $N $O $I OpenFile osssa{sv} /org/freedesktop/portal/desktop/request/1_1/g org.example.App "" "Close-test" {}
after 2500 { set ::slept 1 }; vwait ::slept
set intro [$bus call $N /org/freedesktop/portal/desktop/request/1_1/g org.freedesktop.DBus.Introspectable Introspect]
check "while open, the handle carries org.freedesktop.impl.portal.Request" {[string match *org.freedesktop.impl.portal.Request* $intro]}
$bus call $N /org/freedesktop/portal/desktop/request/1_1/g org.freedesktop.impl.portal.Request Close
if {$got eq ""} { after 10000 { set ::got timeout }; vwait ::got }
check "  Close there answers the call with response 2" {[lindex $got 0] eq "ok" && [lindex $got 1 0] == 2}
after 500 { set ::slept 1 }; vwait ::slept
check "  and the chooser is gone" {[catch {exec pgrep -f "chooser-main.tcl.*-title Close-test"}]}
set v [$bus call $N $O org.freedesktop.DBus.Properties Get ss $I version]
check "the interface is version 4" {[lindex $v 0 1] == 4}
exit [expr {$fails > 0}]
