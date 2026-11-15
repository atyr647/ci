# mod-margin.tcl - labwc's margin for the bars and the dock on the main display only (U11).
#
# Windows are placed and maximised between the bars (54 px) and the dock (54 px). labwc keeps that room with
# <margin top= bottom=>, and a <margin> with no output="" applies to every output, so a second monitor, which has
# no bars, would lose 108 px for nothing. Ribbon's rc.xml therefore has no margin, and this module writes one for
# the main display (display.tcl) into a layer of its own that labwc merges (--merge-config):
#
#   $XDG_STATE_HOME/ribbon/xdg-display/labwc/rc.xml    <margin top="54" bottom="54" output="NAME" />
#
# (ribbon-session puts that folder on XDG_CONFIG_DIRS; margins from every layer add up, so no other layer may
# carry one). It is written when the shell starts and whenever the main display changes (Settings → Display's
# Keep, a monitor plugged in or out), and labwc is told to read its configuration again. labwc before 0.8 takes
# a changed margin only when the output layout changes, so the main output is then committed again where it is
# (wlr-randr --pos, no mode change): the margin moves at once on every labwc.
#
# With no output known (plain X, or a compositor whose outputs do not span the X screen) the margin has no
# output="": the whole screen is the main display. Only under labwc (LABWC_PID); RIBBON_MARGIN_RC names the file
# for the tests, which also stand in for labwc and wlr-randr with RIBBON_MARGIN_RELOAD (a command, or "").

namespace eval margin {
	variable written ""     ;# what the file holds, as last written or read
	variable top 54         ;# the bars
	variable bottom 54      ;# the dock
}

proc margin::file {} {
	if {[info exists ::env(RIBBON_MARGIN_RC)]} { return $::env(RIBBON_MARGIN_RC) }
	set st [expr {[info exists ::env(XDG_STATE_HOME)] && $::env(XDG_STATE_HOME) ne ""
		? $::env(XDG_STATE_HOME) : [::file join $::env(HOME) .local state]}]
	::file join $st ribbon xdg-display labwc rc.xml
}

# The layer's text for the main output NAME ("" for every output).
proc margin::text {name} {
	variable top; variable bottom
	set out [expr {$name eq "" ? "" : " output=\"[string map {& &amp; < &lt; > &gt; \" &quot;} $name]\""}]
	return "<?xml version=\"1.0\"?>\n<!-- written by the Ribbon shell (mod-margin.tcl): the bars' and the dock's room on the main display -->\n<labwc_config>\n  <margin top=\"$top\" bottom=\"$bottom\"$out />\n</labwc_config>\n"
}

# Only the shell (not Ribbon Files run on its own, which has no bars), only under labwc or a test.
proc margin::active {} {
	if {[info exists ::files::standalone] && $::files::standalone} { return 0 }
	expr {[info exists ::env(LABWC_PID)] || [info exists ::env(RIBBON_MARGIN_RC)]}
}

# Write the layer for the main display as it is now; labwc reads it again when it changed. 1 when written.
proc margin::apply {} {
	variable written
	if {![active]} { return 0 }
	set name [display::main]
	set t [text $name]
	set f [margin::file]
	if {$written eq "" && ![catch {::open $f r} fh]} { set written [::read $fh]; ::close $fh }
	if {$t eq $written} { return 0 }
	set tmp $f.[pid].tmp
	if {[catch {
		::file mkdir [::file dirname $f]
		set fh [::open $tmp w]
		puts -nonewline $fh $t
		::close $fh
		::file rename -force $tmp $f
	} err]} {
		catch {::file delete $tmp}
		puts stderr "margin: $f: $err"
		return 0
	}
	set written $t
	reload $name
	return 1
}

# labwc reads its configuration again (SIGHUP, as `labwc --reconfigure` sends), then the main output is committed
# where it is, which makes labwc before 0.8 lay out the outputs' usable areas with the new margin. The signal is
# sent first and synchronously: labwc handles it before wlr-randr, a new client, gets as far as its request.
proc margin::reload {name} {
	if {[info exists ::env(RIBBON_MARGIN_RELOAD)]} {
		if {$::env(RIBBON_MARGIN_RELOAD) ne ""} { catch {exec sh -c $::env(RIBBON_MARGIN_RELOAD) margin $name >/dev/null 2>@1 &} }
		return
	}
	if {![info exists ::env(LABWC_PID)]} return
	catch {exec kill -HUP $::env(LABWC_PID)}
	if {$name eq "" || ![info exists ::env(WAYLAND_DISPLAY)] || [auto_execok wlr-randr] eq ""} return
	set o [lsearch -index 0 -inline [display::outputs] $name]
	if {$o eq ""} return
	lassign $o - x y
	catch {exec wlr-randr --output $name --pos $x,$y >/dev/null 2>/dev/null &}
}

# Each time display.tcl reads the outputs: the main output can change while its rectangle does not (the main
# monitor unplugged and the other laid out where it was), which display::on_change does not report. apply does
# nothing when the text is the same.
proc margin::follow {args} {
	variable busy
	if {[info exists busy]} return
	set busy 1
	catch {margin::apply}
	unset busy
}
trace add execution display::take leave margin::follow
after idle margin::apply
