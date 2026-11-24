# settings-bluetooth-scene.tcl - Settings → Bluetooth (page-bluetooth.tcl) in its boards' states (Settings-A6-Bluetooth,
# and -A6b-Bluetooth-Pair with RIBBON_SCENE=pair), with bt.tcl's and sound.tcl's models stood in for (the page's drawing
# and its hits are what is checked here; bt.tcl itself is tests/settings-bluetooth.tcl). Sourced by apps/settings/main.tcl
# through RIBBON_SETTINGS_SCENE.
#   RIBBON_BT_SHOT   = file: a grab of the window (ImageMagick import)
#   RIBBON_BT_RESULT = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
set ui::caretfix off
namespace eval bscene { variable fails 0; variable lines {}; variable calls {} }
proc bscene::check {what cond} { variable fails; variable lines; if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails } }
proc bscene::click {x y} { page::draw_now; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; update; page::draw_now; update }

set bscene::M [dict create available 1 powered 1 discovering 1 alias ribbon adapter /org/bluez/hci0 devices [list \
	{path /d/wh name WH-1000XM5 address 88:C9:E8:3A:71:0F kind headphones kindlabel Headphones paired 1 connected 1 trusted 1 battery 80 rssi {}} \
	{path /d/mx name {MX Master 3S} address D4:11:22:33:44:55 kind mouse kindlabel Mouse paired 1 connected 1 trusted 1 battery 55 rssi {}} \
	{path /d/px name {Pixel 8} address 3C:01:02:03:04:05 kind phone kindlabel Phone paired 1 connected 0 trusted 0 battery {} rssi {}} \
	{path /d/ds name DualSense address A0:AB:51:00:00:01 kind pad kindlabel Controller paired 1 connected 0 trusted 1 battery {} rssi {}} \
	{path /d/k3 name {Keychron K3} address DC:2C:26:00:00:02 kind kbd kindlabel Keyboard paired 0 connected 0 trusted 0 battery {} rssi -50} \
	{path /d/jbl name {JBL Flip 6} address 00:42:79:00:00:03 kind speaker kindlabel Speaker paired 0 connected 0 trusted 0 battery {} rssi -60} \
	{path /d/tv name {Living room TV} address 64:E4:A5:00:00:04 kind monitor kindlabel Display paired 0 connected 0 trusted 0 battery {} rssi -70}]]
set bscene::bar {88:C9:E8:3A:71:0F}
set bscene::profile sound
set bt::pairing {}
set bt::error ""
proc bt::model {} { return $::bscene::M }
proc bt::start {} {}
proc bt::subtitle {} { return "2 connected" }
proc bt::scan {on} { lappend ::bscene::calls [list scan $on] }
proc bscene::edit {path key value} {
	set l {}
	foreach d [dict get $::bscene::M devices] { if {[dict get $d path] eq $path} { dict set d $key $value }; lappend l $d }
	dict set ::bscene::M devices $l
}
proc bt::set_power {on} { lappend ::bscene::calls [list power $on]; dict set ::bscene::M powered $on }
proc bt::connect {p} { lappend ::bscene::calls [list connect $p]; bscene::edit $p connected 1 }
proc bt::disconnect {p} { lappend ::bscene::calls [list disconnect $p]; bscene::edit $p connected 0 }
proc bt::forget {p} { lappend ::bscene::calls [list forget $p]; bscene::edit $p paired 0 }
proc bt::set_trusted {p on} { lappend ::bscene::calls [list trusted $p $on]; bscene::edit $p trusted $on }
proc bt::pair {p} { lappend ::bscene::calls [list pair $p]; set ::bt::pairing [dict create path $p name {Keychron K3} kindlabel Keyboard kind code code 402917 entered 0]; btp::changed }
proc bt::pair_answer {yes} { lappend ::bscene::calls [list answer $yes]; set ::bt::pairing {}; btp::changed }
proc bt::pair_cancel {} { lappend ::bscene::calls cancel; set ::bt::pairing {}; btp::changed }
proc bt::bar_battery {a} { expr {$a in $::bscene::bar} }
proc bt::set_bar_battery {a on} { lappend ::bscene::calls [list bar $a $on]; set ::bscene::bar [expr {$on ? [list $a] : {}}] }
proc snd::model {} { return [dict create available 1 sinks {} sources {} streams {} cards [list [dict create name bluez_card.88 address 88:C9:E8:3A:71:0F profile $::bscene::profile codec {High quality (LDAC)} profiles {sound calls}]]] }
proc snd::start {} {}
proc snd::set_card_profile {a p} { lappend ::bscene::calls [list profile $a $p]; set ::bscene::profile $p }

set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "main"}]
settings::select bluetooth
if {$scene eq "pair"} { bt::pair /d/k3 }
page::draw_now; update; page::draw_now; update
if {[info exists ::env(RIBBON_BT_SHOT)]} { after 500; update; exec import -window [winfo id $::settings::win] $::env(RIBBON_BT_SHOT) }

if {$scene eq "pair"} {
	bscene::click 400 331
	bscene::check "under the sheet the list takes no clicks" {[lindex $bscene::calls end] eq {pair /d/k3}}
	bscene::click 740 492
	bscene::check "the sheet's Cancel cancels the pairing" {[lindex $bscene::calls end] eq "cancel" && $bt::pairing eq {}}
	bscene::check "the window is no longer shaded" {$page::shade == 0}
	set bt::pairing [dict create path /d/px name {Pixel 8} kindlabel Phone kind confirm code 118294 entered 0]; btp::changed
	page::draw_now; update; page::draw_now; update
	bscene::click 750 492
	bscene::check "a code to compare has Pair, which says yes" {[lindex $bscene::calls end] eq {answer 1}}
} else {
	bscene::click 400 227
	bscene::check "a click on MX Master 3S shows it" {$btp::sel eq "/d/mx"}
	bscene::click 400 175
	bscene::click 1040 393
	bscene::check "Connect automatically turns off for the headset" {[lindex $bscene::calls end] eq {trusted /d/wh 0}}
	bscene::click 1015 441
	bscene::check "Use for: Calls sets the card's profile" {[lindex $bscene::calls end] eq {profile 88:C9:E8:3A:71:0F calls}}
	bscene::click 1040 489
	bscene::check "Show battery in the bar turns off" {[lindex $bscene::calls end] eq {bar 88:C9:E8:3A:71:0F 0}}
	bscene::click 1000 684
	bscene::check "Disconnect disconnects the chosen device" {[lindex $bscene::calls end] eq {disconnect /d/wh}}
	bscene::click 1000 684
	bscene::check "  and the button is then Connect" {[lindex $bscene::calls end] eq {connect /d/wh}}
	bscene::click 400 421
	bscene::check "a click on a device nearby pairs it" {[lindex $bscene::calls end] eq {pair /d/k3} && $page::shade == 0.5}
	bt::pair_cancel
	bscene::click 890 684
	bscene::check "Forget forgets the chosen device" {[lindex $bscene::calls end] eq {forget /d/wh}}
	bscene::click 529 130
	bscene::check "the switch turns Bluetooth off" {[lindex $bscene::calls end] eq {power 0}}
	dict set bscene::M available 0
	page::draw_now; update
	bscene::check "the page draws with no adapter" 1
}
if {[info exists ::env(RIBBON_BT_RESULT)]} { set f [open $::env(RIBBON_BT_RESULT) w]; puts $f [join $bscene::lines \n]; close $f } else { puts [join $bscene::lines \n] }
exit [expr {$bscene::fails > 0}]
