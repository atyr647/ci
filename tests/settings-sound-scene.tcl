# settings-sound-scene.tcl - Settings → Sound (page-sound.tcl) in its board's state (Settings-A5-Sound), with sound.tcl's
# model stood in for (the page's drawing and its hits are what is checked here; sound.tcl itself is tests/settings-sound.tcl).
# Sourced by apps/settings/main.tcl through RIBBON_SETTINGS_SCENE.
#   RIBBON_SOUND_SHOT   = file: a grab of the window (ImageMagick import)
#   RIBBON_SOUND_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
set ui::caretfix off
namespace eval sscene { variable fails 0; variable lines {}; variable calls {} }
proc sscene::check {what cond} { variable fails; variable lines; if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails } }
proc sscene::click {x y} { page::draw_now; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; update }

# the board's devices and streams
set sscene::M [dict create available 1 \
	sinks [list \
		{id 1 name alsa_output.analog label Speakers sub {Built-in audio} kind speaker volume 64 muted 0 balance 0 default 1 address {}} \
		{id 2 name alsa_output.hdmi label {LG UltraGear} sub HDMI kind monitor volume 100 muted 0 balance 0 default 0 address {}} \
		{id 3 name bluez_output.88 label WH-1000XM5 sub Bluetooth kind headphones volume 50 muted 0 balance 0 default 0 address 88:C9:E8:3A:71:0F}] \
	sources [list \
		{id 4 name alsa_input.analog label Microphone sub {Built-in audio} kind mic volume 80 muted 0 balance 0 default 1 address {}} \
		{id 5 name bluez_input.88 label WH-1000XM5 sub Bluetooth kind headphones volume 100 muted 0 balance 0 default 0 address 88:C9:E8:3A:71:0F}] \
	streams [list {id 10 app Firefox icon globe volume 100 muted 0} {id 11 app Steam icon game volume 45 muted 0}] \
	cards {}]
array set sscene::conf {OVER no ALERTS yes BAR yes ALERT_VOLUME 70}
set snd::level 35
proc snd::model {} { return $::sscene::M }
proc snd::start {} {}
proc snd::stop {} {}
proc snd::level_start {} {}
proc snd::level_stop {} {}
proc snd::setting {k} { return $::sscene::conf($k) }
proc snd::conf_set {k v} { set ::sscene::conf($k) $v; lappend ::sscene::calls [list conf $k $v] }
proc snd::subtitle {} { foreach s [dict get $::sscene::M sinks] { if {[dict get $s default]} { return "[dict get $s label] · [dict get $s volume]%" } } }
proc sscene::edit {list id key value} {
	set l {}
	foreach d [dict get $::sscene::M $list] { if {[dict get $d id] eq $id} { dict set d $key $value }; lappend l $d }
	dict set ::sscene::M $list $l
}
proc snd::set_default {kind id} {
	lappend ::sscene::calls [list default $kind $id]
	set list [expr {$kind eq "sink" ? "sinks" : "sources"}]
	foreach d [dict get $::sscene::M $list] { sscene::edit $list [dict get $d id] default [expr {[dict get $d id] eq $id}] }
}
proc snd::set_volume {kind id v} { lappend ::sscene::calls [list volume $kind $id $v]; sscene::edit [dict get {sink sinks source sources stream streams} $kind] $id volume $v }
proc snd::set_mute {kind id on} { lappend ::sscene::calls [list mute $kind $id $on]; sscene::edit [dict get {sink sinks source sources stream streams} $kind] $id muted $on }
proc snd::set_balance {id b} { lappend ::sscene::calls [list balance $id $b]; sscene::edit sinks $id balance $b }

settings::select sound
page::draw_now
update
if {[info exists ::env(RIBBON_SOUND_SHOT)]} { after 500; update; exec import -window [winfo id $::settings::win] $::env(RIBBON_SOUND_SHOT) }

# the hits, as clicks
sscene::click 400 219
sscene::check "a click on LG UltraGear makes it the output" {[lindex $sscene::calls end] eq {default sink 2}}
snd::set_default sink 1
sscene::click 543 331
sscene::check "a press at the middle of the output's slider sets 50%" {[lindex $sscene::calls end] eq {volume sink 1 50}}
sscene::click 422 331
sscene::check "the output's mute button mutes it" {[lindex $sscene::calls end] eq {mute sink 1 1}}
sscene::click 450 379
sscene::check "the balance's left end is all the way left" {[lindex $sscene::calls end] eq {balance 1 -100}}
sscene::click 572 379
sscene::check "near the middle the balance is the middle" {[lindex $sscene::calls end] eq {balance 1 0}}
sscene::click 400 525
sscene::check "a click on the headset under Input makes it the input" {[lindex $sscene::calls end] eq {default source 5}}
snd::set_default source 4
sscene::click 919 213
sscene::check "Steam's slider sets Steam's volume (25%)" {[lindex $sscene::calls end] eq {volume stream 11 25}}
sscene::click 862 261
sscene::check "the alerts' mute turns Sound for alerts off" {$sscene::conf(ALERTS) eq "no"}
sscene::click 948 261
sscene::check "the alerts' slider sets their volume (50%)" {$sscene::conf(ALERT_VOLUME) == 50}
sscene::click 1040 355
sscene::check "Louder than 100% turns on" {$sscene::conf(OVER) eq "yes"}
sscene::click 636 331
sscene::check "  and the output's slider then ends at 150%" {[lindex $sscene::calls end] eq {volume sink 1 150}}
sscene::click 1040 451
sscene::check "Volume in the bar turns off" {$sscene::conf(BAR) eq "no"}
dict set sscene::M available 0
page::draw_now; update
sscene::check "the page draws with no sound server" 1

if {[info exists ::env(RIBBON_SOUND_RESULT)]} { set f [open $::env(RIBBON_SOUND_RESULT) w]; puts $f [join $sscene::lines \n]; close $f } else { puts [join $sscene::lines \n] }
exit [expr {$sscene::fails > 0}]
