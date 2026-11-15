# settings-updates-kit.tcl -- a stand-in for kit and kit-updater for tests/settings-updates*.tcl (never the network).
# It prints kit's --tcl lines (docs/KIT-CLI.md, scripting) with the boards' fixture: five kits waiting, the
# history of Settings-A3-Updates, and kit-updater --set writing ~/.config/kit/updates.conf the way kit-updater does.
#   tclsh8.6 settings-updates-kit.tcl check --tcl | check --tcl --yes | rewind --tcl | rewind --tcl --yes
#   tclsh8.6 settings-updates-kit.tcl --set KEY=VALUE
# SETTINGS_UPDATES_STUB_LOG=FILE appends each call's argv to FILE (the flow test reads it).

fconfigure stdout -encoding utf-8
set now [clock seconds]
if {[info exists ::env(SETTINGS_UPDATES_STUB_LOG)]} {
	set fh [open $::env(SETTINGS_UPDATES_STUB_LOG) a]; puts $fh $argv; close $fh
}

proc row {name old new bytes tags {action update}} {
	dict create name $name fullname org.test.$name action $action old $old new $new bytes $bytes tags $tags note ""
}

if {[lindex $argv 0] eq "--set"} {
	# kit-updater --set KEY=VALUE: the value must be one kit-updater accepts (the page sends only such values)
	regexp {^([a-z]+)=(.*)$} [lindex $argv 1] -> k v
	set path [file join [expr {[info exists ::env(XDG_CONFIG_HOME)] ? $::env(XDG_CONFIG_HOME) : "$::env(HOME)/.config"}] kit updates.conf]
	set s [dict create notify yes download no install off interval 6h]
	if {![catch {open $path r} fh]} {
		fconfigure $fh -encoding utf-8
		foreach l [split [read $fh] \n] { if {[regexp {^\s*([a-z]+)\s*=\s*(.*?)\s*$} $l -> kk vv]} { dict set s $kk $vv } }
		close $fh
	}
	dict set s $k $v
	file mkdir [file dirname $path]
	set out "# kit's automatic updates (docs/KIT-CLI.md); written by Settings and kit-updater --set\n"
	dict for {kk vv} $s { append out "$kk = $vv\n" }
	set fh [open $path w]; fconfigure $fh -encoding utf-8; puts -nonewline $fh $out; close $fh
	exit 0
}

set ups [list \
	[row firefox 134.0.1 134.0.2 12000000 security] \
	[row ffmpeg 7.1 7.1.1 4000000 {}] \
	[row mesa 25.2.7 25.2.8 16000000 {}] \
	[row openssl 3.0.13 3.0.14 1000000 security] \
	[row linux 6.18.58 6.18.60 14000000 restart]]
set question "Update? (takes effect at restart)"
set hist [list \
	[dict create id 4 time [expr {$now - 600}] icon up title "Updated 5 kits" sub "firefox, ffmpeg, mesa, openssl, linux" cursor 1] \
	[dict create id 3 time [expr {$now - 86400}] icon undo title "Rewound MK Studio" sub "1.5.0 \u2192 1.4.0 \u00b7 held" cursor 0] \
	[dict create id 2 time [expr {$now - 90000}] icon up title "Updated MK Studio" sub "1.4.0 \u2192 1.5.0" cursor 0] \
	[dict create id 1 time [expr {$now - 180000}] icon trash title "Uninstalled Krita" sub "krita 5.2.6 \u00b7 data kept" cursor 0]]

switch -- "[lindex $argv 0] [lindex $argv 1] [lindex $argv 2]" {
	"check --tcl " {
		puts [list plan [dict create rows $ups question $question checked $now]]
	}
	"check --tcl --yes" {
		puts [list done [dict create rows [lmap r $ups { dict create name [dict get $r name] old [dict get $r new] action done bytes "" tags {} new switched }] \
			lines {} stale {} restart {{linux 6.18.60}} time [expr {$now + 5}]]]
	}
	"rewind --tcl " {
		set rr [list \
			[row firefox 134.0.2 134.0.1 0 security] [row ffmpeg 7.1.1 7.1 0 {}] [row mesa 25.2.8 25.2.7 0 {}] \
			[row openssl 3.0.14 3.0.13 0 security] [row linux 6.18.60 6.18.58 0 restart]]
		puts [list plan [dict create rows $rr question "Rewind?" history $hist]]
	}
	"rewind --tcl --yes" {
		puts [list done [dict create rows {} lines {} stale {} restart {} time [expr {$now + 5}]]]
	}
	default {
		puts stderr "kit: unknown stub call: $argv"
		exit 2
	}
}
exit 0
