# settings-display.tcl - Settings → Display's logic with no display (U11): the JSON
# reader, the outputs, the wlr-randr command line, the mode lists, the kanshi profile,
# the main display file, and the background runner. Run: tclsh8.6 tests/settings-display.tcl DIR
# (DIR = the files/ folder); exits non-zero on the first failed check.
set D [lindex $argv 0]
set fails 0
proc check {what ok} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
namespace eval page { proc draw {} {} }
set home [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] ribbon-display-[pid]]
file mkdir $home
set ::env(HOME) $home
set ::env(XDG_CONFIG_HOME) [file join $home cfg]
source [file join $D apps settings display.tcl]

set fh [open [file join [file dirname [file dirname [file dirname $D]]] tests fixtures display-outputs.json]]
fconfigure $fh -encoding utf-8
set json [read $fh]
close $fh

set outs [display::parse $json]
set ::display::outs $outs
set ::display::loaded 1
check "two outputs read from wlr-randr --json" [expr {[llength $outs] == 2}]
set dp [display::out DP-1]
check "DP-1 is 2560x1440 at 164.998 Hz, on" [expr {[dict get $dp w] == 2560 && [dict get $dp h] == 1440 && [dict get $dp r] eq "164.998" && [dict get $dp on] == 1}]
check "eDP-1 sits at 2560,0 and is scaled 2" [expr {[dict get [display::out eDP-1] x] == 2560 && [dict get [display::out eDP-1] scale] == 2}]
check "the subtitle names the layout" [expr {[display::subtitle] eq "2 displays · arranged side by side"}]

# wlr-randr 0.3 has no --json: its plain listing reads into the same outputs as the JSON
proc fixture {name} {
	set fh [open [file join [file dirname [file dirname [file dirname $::D]]] tests fixtures $name]]
	fconfigure $fh -encoding utf-8
	set t [read $fh]
	close $fh
	set t
}
set touts [display::parse [fixture display-outputs.txt]]
check "the plain wlr-randr listing reads as the JSON does (both outputs, every field)" [expr {$touts eq $outs}]
if {$touts ne $outs} { puts "       json: $outs\n       text: $touts" }
set hl [display::parse [fixture display-outputs-headless.txt]]
set h1 [lindex $hl 0]
check "a real wlr-randr 0.3 listing (headless labwc): two outputs, HEADLESS-1 1920x1080 at 60 Hz, 1280,0, scale 1.25" \
	[expr {[llength $hl] == 2 && [dict get $h1 name] eq "HEADLESS-1" && [dict get $h1 w] == 1920 && [dict get $h1 h] == 1080
		&& [dict get $h1 r] eq "60.000" && [dict get $h1 x] == 1280 && [dict get $h1 y] == 0 && [dict get $h1 scale] == 1.25
		&& [dict get $h1 make] eq "" && [dict get $h1 on] == 1 && [dict get $h1 adaptive] == 0}]
set h2 [lindex $hl 1]
check "a mode with no rate is rate 0 and is set by its size alone (1280x720, HEADLESS-2)" [expr {[dict get $h2 w] == 1280 && [dict get $h2 r] == 0
	&& [lsearch -inline [display::layout_argv [list [dict remove $h2 modes]]] 1280x720*] eq "1280x720"}]
check "an output that is off has no modes listed but is kept (0x0 is not a mode)" \
	[expr {[llength [display::parse "X-1 \"x\"\n  Enabled: no\n  Modes:\n    0x0 px\n  Position: 0,0\n"]] == 1}]

check "resolutions, largest first" [expr {[lindex [display::res_items DP-1] 0 0] eq "2560x1440"}]
set rates [lmap r [display::rate_items DP-1 2560 1440] {lindex $r 0}]
check "refresh rates at 2560x1440, fastest first" [expr {$rates eq {164.998 144.000}}]
check "a refresh of 165 shows as 165 Hz" [expr {[display::hz 165.000] eq "165 Hz"}]

set cfg [display::now_cfg]
check "an unchanged layout passes no --adaptive-sync" [expr {[string first adaptive [join [display::layout_argv $cfg]]] < 0}]
check "the command line for the layout as it is" [expr {[display::layout_argv $cfg] eq {wlr-randr --output DP-1 --on --mode 2560x1440@164.998Hz --pos 0,0 --scale 1.000000 --transform normal --output eDP-1 --on --mode 2880x1800@90.000Hz --pos 2560,0 --scale 2.000000 --transform normal}}]

display::set_val DP-1 scale 1.25
display::set_val DP-1 adaptive 0
set want [display::want_cfg]
set line [display::layout_argv $want]
check "a scale of 125 % is --scale 1.25" [expr {[lsearch -exact $line 1.25] >= 0}]
check "turning adaptive sync off passes --adaptive-sync disabled for DP-1 only" [expr {[llength [lsearch -all -exact $line --adaptive-sync]] == 1 && [lindex $line [expr {[lsearch -exact $line --adaptive-sync] + 1}]] eq "disabled"}]
set back [display::layout_argv [display::now_cfg]]
check "the state before the edit puts back the scale 1.000000" [expr {[lsearch -exact $back 1.000000] >= 0}]
display::discard

set blk [display::profile_block]
check "the kanshi profile is named for the outputs on" [expr {[lindex $blk 0] eq "ribbon-DP-1_eDP-1"}]
check "the profile block holds the mode and position" [expr {[string first "output DP-1 enable mode 2560x1440@164.998Hz" [lindex $blk 1]] >= 0}]

display::save_profile
set kf [file join $home cfg kanshi config]
check "the profile is written under kanshi's config" [file exists $kf]
display::save_profile
set fh [open $kf]; set kc [read $fh]; close $fh
set n [llength [regexp -all -inline {profile ribbon-} $kc]]
check "saving again replaces the ribbon profile, not adds one" [expr {$n == 1}]

set ::display::main eDP-1
display::save_main
check "the main display is kept in display.conf" [expr {[display::main_conf] eq "eDP-1"}]
check "a missing main falls back to the first enabled output" [expr {[display::main_default] eq "eDP-1"}]

set hdr [display::json {{"a": [1, true, null], "b": {"c": "x\"y"}}}]
check "the JSON reader keeps lists, dicts, literals and escapes" [expr {[lindex [dict get $hdr a] 1] eq "true" && [dict get $hdr b c] eq {x"y}}]

set ::res ""
proc ::res_done {code out} { set ::res "$code [string trim $out]" }
display::run {sh -c {echo hi; exit 3}} ::res_done
after 2000 {set ::res timeout}
vwait ::res
check "a command runs in the background and reports its code and output" [expr {$::res eq "3 hi"}]

file delete -force $home
if {$fails} { puts "$fails check(s) failed"; exit 1 }
puts "all display checks passed"
