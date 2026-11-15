# greeter-scene.tcl - put the Ribbon login screen into one of the mockup
# states with fixture data, for screenshots and pixel comparison
# (RIBBON_GREETER_TEST=this file).
#   RIBBON_GREETER_SCENE = password | wrong | users | session | picture | pictures
# Greet-1-Password, Greet-2-Wrong, Greet-3-Users and Greet-4-Session in
# design/mockups; picture(s): Greet-1 and Greet-3 with account pictures.
set scene [expr {[info exists ::env(RIBBON_GREETER_SCENE)] ? $::env(RIBBON_GREETER_SCENE) : "password"}]
set fx [file normalize [file join [file dirname [info script]] fixtures greeter]]
set repo [file dirname [file dirname [file normalize [info script]]]]

# the system as in the mockup: three people, Alex last logged in, the
# Ribbon session (and four others for the session menu), British and US
# layouts, Wi-Fi on, 82 % battery
set ::env(RIBBON_GREETER_PASSWD) $fx/passwd
set ::env(RIBBON_GREETER_SESSIONS) [list [file join $repo srcpkgs ribbon-desktop files sessions] $fx/sessions]
# account pictures: none, or made here (picture scenes)
set ::env(RIBBON_GREETER_ICONS) [file join [file dirname [sys::statefile]] icons]
set ::env(RIBBON_GREETER_XKB) $fx/00-keyboard.conf
set st [sys::statefile]
file mkdir [file dirname $st]
set fh [open $st w]; puts $fh "user=alex\nsession.alex=ribbon"; close $fh
unset -nocomplain ::env(GREETD_SOCK)
login::start
set status::wifi on
set status::battery 82
set login::time 00:27
set login::date "Sunday 31 May"

switch -- $scene {
	password {
		set login::prompt "Password: "
		set login::secret 12345678
	}
	wrong {
		# a wrong password, then eight more letters typed with Caps Lock on
		set login::msgs {{error {That password didn't work}}}
		set login::secret ABCDEFGH
		set login::caps 1
	}
	users {
		login::picker
	}
	session {
		# the menu open on the pill, "game mode" highlighted, desktop kept
		set login::prompt "Password: "
		login::session_open
		login::session_move 1
	}
	picture - pictures {
		# a 300 x 200 PNG (a GIF for sam): the middle square shows
		file mkdir $::env(RIBBON_GREETER_ICONS)
		foreach {who fmt c1 c2} {alex png #2E6FD8 #F2C14E sam gif #3A9D5D #EEE9E3} {
			set p [image create photo -width 300 -height 200]
			$p put $c1 -to 0 0 300 200
			$p put $c2 -to 100 50 200 150
			$p write [file join $::env(RIBBON_GREETER_ICONS) $who] -format $fmt
			image delete $p
		}
		if {$scene eq "pictures"} { login::picker } else { set login::prompt "Password: "; set login::secret 12345678 }
	}
}
ui::redraw

# The login theme (ribbon-login-theme on a fake /etc, RIBBON_GREETER_ETC):
#   RIBBON_GREETER_EXPECT = "picture #RRGGBB": the background is the login
#     picture, scaled and cropped to the screen, that colour at the corners
#     and the middle (the test picture's other colours are cropped away);
#     "pattern": the ribbon stripes in the palette in use
#   RIBBON_GREETER_ACCENT = #RRGGBB: the palette's accent
#   RIBBON_GREETER_SHOT = file: a screenshot (ImageMagick import)
proc check_theme {} {
	set W $ui::W; set H $ui::H
	set pts [list 0 0 [expr {$W - 1}] 0 0 [expr {$H - 1}] [expr {$W - 1}] [expr {$H - 1}] [expr {$W / 2}] [expr {$H / 2}]]
	set fail {}
	if {[info exists ::env(RIBBON_GREETER_EXPECT)]} {
		lassign $::env(RIBBON_GREETER_EXPECT) kind colour
		foreach {x y} $pts {
			set got [$ui::wallimg get $x $y]
			if {$kind eq "picture"} {
				set want [raster::rgb $colour]
			} else {
				set want [lrange [lindex [wall::rows [array get theme::c] $x $y 1 1 $W $H] 0] 0 2]
			}
			if {$got ne $want} { lappend fail "background at $x,$y is {$got}, not {$want} ($kind)" }
		}
		if {$kind eq "picture" && $wall::full eq ""} { lappend fail "no login picture" }
		if {$kind eq "pattern" && $wall::full ne ""} { lappend fail "a picture instead of the pattern" }
	}
	if {[info exists ::env(RIBBON_GREETER_ACCENT)] && $theme::c(ACCENT) ne $::env(RIBBON_GREETER_ACCENT)} {
		lappend fail "accent is $theme::c(ACCENT), not $::env(RIBBON_GREETER_ACCENT)"
	}
	foreach f $fail { puts stderr "FAIL $f" }
	return [expr {[llength $fail] == 0}]
}

if {[info exists ::env(RIBBON_GREETER_SHOT)]} {
	after 400 {
		update
		exec import -window root $::env(RIBBON_GREETER_SHOT)
		if {![info exists ::env(RIBBON_GREETER_EXIT)]} { exit [expr {[check_theme] ? 0 : 1}] }
	}
}

# for tests/run.sh: quit after drawing; any background error fails
if {[info exists ::env(RIBBON_GREETER_EXIT)]} {
	proc bgerror {msg} { puts stderr $msg; exit 1 }
	after $::env(RIBBON_GREETER_EXIT) { update; exit [expr {[check_theme] ? 0 : 1}] }
}
