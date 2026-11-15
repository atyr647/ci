# term-prefs-scene.tcl - Ribbon Terminal's preferences (apps/term/prefs.tcl) in one of its boards' states, at the boards'
# tab area (1240 x 742), for screenshots and pixel comparison (RIBBON_TERM_PREFS_SCENE=this file, run by
# apps/term/prefs-main.tcl with XDG_CONFIG_HOME a scratch directory).
#   RIBBON_SCENE = look (Term-P-Page-1-Look) | profile (Term-P-Page-2-Profile) | behaviour | keys
#   RIBBON_TERM_PREFS_SHOT = file: take a screenshot (ImageMagick import)
#   RIBBON_TERM_PREFS_EXIT = ms: quit after drawing; any Tcl error fails
set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "look"}]
if {[info exists ::env(RIBBON_TERM_PREFS_EXIT)] || [info exists ::env(RIBBON_TERM_PREFS_SHOT)]} {
	proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
}
set ui::caretfix off
# the boards' profiles: Default with its own background and 94 % opacity, its tabs started at 13 pt (so Size carries
# the tag); Servers for ssh with its own colours and no blink; Presenting at 18 pt without blink
set prof::P [dict create]; set prof::A [dict create]; set prof::order {}
prof::load
foreach {k v} {size 14 opacity 94 bg #121110} { dict set prof::P Default $k $v }
dict set prof::P Servers [dict create command ssh bg #24130F cur red mark red blink 0]
dict set prof::P Presenting [dict create size 18 blink 0]
set prof::order {Default Servers Presenting}
prof::applied
dict set prof::A Default size 13
prof::save
# the scene's fonts list: JetBrains Mono, whatever fontconfig has
set tp::monos {{JetBrains Mono}}
switch -- $scene {
	look { set tp::sel Default }
	profile { set tp::sel Servers }
	behaviour { set tp::sel Default; set tp::seg behaviour }
	keys { set tp::sel Default; set tp::seg keys; prof::put Default key_find Mod1+f; set tp::recording left }
	flow { set tp::sel Default }
}
# the flow: the page's actions through its own procs, each checked against terminal.conf as read back
if {$scene eq "flow"} {
	set ::fails 0
	proc check {what cond} { if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr ::fails } }
	proc reread {} { prof::load }
	after 300 {
		# a linked row of Servers becomes its own (the link), then goes back (the undo)
		set tp::sel Servers; tp::link_off size; reread
		check "the link makes Servers' size its own (Default's 14)" {[prof::own Servers size] && [prof::get Servers size] == 14}
		tp::set_num size 16; reread
		check "the stepper changes Servers' own size" {[prof::get Servers size] == 16 && [prof::get Default size] == 14}
		tp::link_on size; reread
		check "the undo gives the size back to Default" {![prof::own Servers size] && [prof::get Servers size] == 14}
		# a Default colour that followed the theme becomes its own colour, then follows again
		set tp::sel Default; tp::link_off fg; reread
		check "Default's text colour starts as the theme's when made its own" {[string toupper [prof::get Default fg]] eq "#EEE9E3"}
		tp::set_val fg green; reread
		check "the colour menu's pick is kept by name" {[prof::get Default fg] eq "green" && [dict get [prof::colours Default] fg] eq "#8FD694"}
		tp::link_on fg; reread
		check "the undo makes it follow the theme again" {[prof::get Default fg] eq ""}
		# the New tabs tag follows a change from what the tabs were started with
		check "Size carries the tag (14 against 13)" {[prof::changed Default size]}
		tp::restart; reread
		check "Restart terminals clears the tags" {![prof::changed Default size]}
		# profiles: new, renamed, deleted
		tp::pick [prof::create]; reread
		check "New profile adds Profile, shown" {"Profile" in $prof::order && $tp::sel eq "Profile"}
		tp::name_start; ui::fset name Laptop; tp::name_done 1; reread
		check "the title renames it" {"Laptop" in $prof::order && "Profile" ni $prof::order && $tp::sel eq "Laptop"}
		prof::delete Laptop; reread
		check "Delete profile removes it" {"Laptop" ni $prof::order}
		# Opens for: a tab running ssh takes Servers
		check "a tab started with ssh takes Servers" {[prof::for_command {ssh pi@kitchen}] eq "Servers" && [prof::for_command {htop}] eq "Default"}
		# the keys: a recorded chord is kept; one another row has is not
		set tp::seg keys; tp::record find; tp::record_key f 8; reread
		check "recording Alt+F sets Find in scrollback" {[prof::get Default key_find] eq "Mod1+f"}
		tp::record left; tp::record_key c 5; reread
		check "Ctrl+Shift+C (Copy's) is not taken for Move tab left" {[prof::get Default key_left] eq "Control+Shift+Prior" && $tp::recording eq "left"}
		tp::record_key Escape 0
		check "Esc stops recording" {$tp::recording eq ""}
		check "the foot overrides carry the changed key only" {"key-bindings.search-start=Mod1+f" in [prof::footargs Default] && ![string match *clipboard-copy* [prof::footargs Default]]}
		# Behaviour: the row "Ask before closing a running command" (board Term-P-Sheet-2-Behaviour) is a switch, on by
		# default, whose click writes ask to terminal.conf (the strip's question, shell/mod-term.tcl, reads it)
		set tp::sel Default; set tp::seg behaviour; page::draw_now
		set sw [lsearch -inline -glob -index 4 $ui::hits "*tp::set_val ask*"]
		check "Behaviour has the switch Ask before closing a running command, on" {$sw ne "" && [prof::get Default ask] == 1 && [string match "*tp::set_val ask 0*" [lindex $sw 4]]}
		uplevel #0 [list {*}[lindex $sw 4] 0 0]; reread
		check "  its click turns it off in terminal.conf" {[prof::get Default ask] == 0}
		page::draw_now
		set sw [lsearch -inline -glob -index 4 $ui::hits "*tp::set_val ask*"]
		uplevel #0 [list {*}[lindex $sw 4] 0 0]; reread
		check "  and on again" {[prof::get Default ask] == 1}
		page::draw_now
		puts "term-prefs flow: $::fails failed"
		exit [expr {$::fails > 0}]
	}
	return
}
page::draw
if {[info exists ::env(RIBBON_TERM_PREFS_SHOT)]} {
	after 700 {
		update
		exec import -window [winfo id $tp::win] $::env(RIBBON_TERM_PREFS_SHOT)
		exit 0
	}
} elseif {[info exists ::env(RIBBON_TERM_PREFS_EXIT)]} {
	after $::env(RIBBON_TERM_PREFS_EXIT) { exit 0 }
}
