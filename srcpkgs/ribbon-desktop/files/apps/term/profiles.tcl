# profiles.tcl - Ribbon Terminal's profiles (docs/TERMINAL.md §4, §6 "Page"): the settings behind the
# preferences tab, and the footclient overrides a new tab is started with. No Tk: the shell (shell/mod-term.tcl)
# sources it to start tabs, the preferences app (apps/term/prefs.tcl) to show and change them.
#
# A profile is a set of `footclient -o` overrides on top of foot.ini (which ribbon-theme writes from the theme), so
# tabs of every profile share one foot server. Default holds every foot setting the page shows; another profile holds
# only what it sets itself and takes the rest from Default (the page's linked rows). A colour that is "" follows the
# theme (Default) or Default (another profile). The strip's own settings (Behaviour) live in Default only.
#
# The file: $XDG_CONFIG_HOME/ribbon/terminal.conf, one Tcl list a line, nothing evaluated:
#   profile NAME KEY VALUE ...     a profile, in the order the page lists them (Default first)
#   applied NAME KEY VALUE ...     what that profile's tabs were started with (the "New tabs" tags compare with it)
# A line or a value that does not check is left out; a file that does not parse at all is read as empty.

namespace eval prof {
	variable here [file dirname [file normalize [info script]]]   ;# this file's directory, read at source time
	variable P [dict create]       ;# name -> {key value ...}, as set
	variable A [dict create]       ;# name -> {key value ...}, as applied (last Restart terminals, or first sight)
	variable order {}
	variable footv ""              ;# foot's minor version (1.N), read once
	# key -> default for Default, then the check for a value
	variable defaults {
		font {JetBrains Mono} size 14 lineh 1.2 pad 16 cursor beam blink 1 opacity 100
		scheme "" bg "" fg "" cur "" sel "" mark "" command ""
		strip always newin home newat next lastclose window ask 1 lines 50000 wheel 3 bell flash marktab 1 notify 0
	}
	# the keys a profile other than Default can set (the Profile board's rows)
	variable own_keys {font size lineh pad cursor blink bg fg cur sel mark command lines wheel bell notify}
	# the strip's own keys: they apply at once, never carry the "New tabs" tag, and only Default has them
	variable strip_keys {strip newin newat lastclose ask marktab notify}
	variable colours {black red green yellow blue magenta cyan white}
	# the keys (board Term-P-Sheet-3-Keys): id, label, foot's chord by default, how it reaches foot. "pipe CMD" is a
	# `pipe-visible=[ribbon-term-ctl CMD]` binding (the strip's), "foot ACTION" foot's own action, "fixed" not changeable.
	variable keys {
		new      {New tab}            Control+Shift+t    {pipe new}
		close    {Close tab}          Control+Shift+w    {pipe close}
		next     {Next tab}           Control+Next       {pipe next}
		prev     {Previous tab}       Control+Prior      {pipe prev}
		tabn     {Go to tab 1 to 9}   Mod1+1             fixed
		left     {Move tab left}      Control+Shift+Prior {pipe {move left}}
		right    {Move tab right}     Control+Shift+Next {pipe {move right}}
		prefs    Preferences          Control+comma      {pipe prefs}
		copy     Copy                 Control+Shift+c    {foot clipboard-copy}
		paste    Paste                Control+Shift+v    {foot clipboard-paste}
		find     {Find in scrollback} Control+Shift+r    {foot search-start}
		link     {Open a link}        Control+Shift+o    {foot show-urls-launch}
		pprev    {Previous prompt}    Control+Shift+z    {foot prompt-prev}
		pnext    {Next prompt}        Control+Shift+x    {foot prompt-next}
		bigger   {Bigger text}        Control+equal      {foot font-increase}
		smaller  {Smaller text}       Control+minus      {foot font-decrease}
	}
	foreach {k l c h} $keys { lappend defaults key_$k $c }
}
# key-ID -> {label chord how}
proc prof::keydef {id} {
	variable keys
	foreach {k l c h} $keys { if {$k eq $id} { return [list $l $c $h] } }
	return {}
}

proc prof::confdir {} {
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}]
	return [expr {[info exists ::env(XDG_CONFIG_HOME)] ? $::env(XDG_CONFIG_HOME) : "$home/.config"}]
}
proc prof::conffile {} { ::file join [confdir] ribbon terminal.conf }

# Whether VALUE is right for KEY.
proc prof::ok {key value} {
	variable colours
	switch -- $key {
		font { expr {[string length $value] > 0 && [string length $value] < 64 && ![regexp {[\n:=,]} $value]} }
		size { expr {[string is integer -strict $value] && $value >= 6 && $value <= 48} }
		lineh { expr {$value in {font 1.2 1.4}} }
		pad { expr {$value in {8 16 24}} }
		cursor { expr {$value in {block beam underline}} }
		blink - ask - marktab - notify { expr {$value in {0 1}} }
		opacity { expr {[string is integer -strict $value] && $value >= 30 && $value <= 100} }
		scheme { regexp {^([a-z0-9][a-z0-9-]{0,40})?$} $value }
		bg - fg - cur - sel - mark { expr {$value eq "" || [regexp {^#[0-9A-Fa-f]{6}$} $value] || $value in $colours} }
		command { regexp {^([A-Za-z0-9._+-]{1,32})?$} $value }
		strip { expr {$value in {always two}} }
		newin { expr {$value in {home same}} }
		newat { expr {$value in {next end}} }
		lastclose { expr {$value in {window keep}} }
		lines { expr {$value in {1000 10000 50000 100000}} }
		wheel { expr {[string is integer -strict $value] && $value >= 1 && $value <= 10} }
		bell { expr {$value in {off flash sound}} }
		default { expr {[string match key_* $key] && [regexp {^((Control|Shift|Mod1|Mod4)\+){0,3}[A-Za-z0-9_]{1,16}$} $value]} }
	}
}

proc prof::okname {name} { regexp {^[^\n\t{}\\"\[\]$;]{1,24}$} $name }

# ---- reading and writing ----------------------------------------------------------------

proc prof::load {} {
	variable P
	variable A
	variable order
	variable defaults
	set P [dict create]; set A [dict create]; set order {}
	set text ""
	catch {
		if {[::file size [conffile]] <= 65536} {
			set f [open [conffile] r]; fconfigure $f -encoding utf-8; set text [read $f]; close $f
		}
	}
	foreach line [split $text "\n"] {
		if {[string match "#*" [string trimleft $line]] || ![string is list $line] || [llength $line] < 2} continue
		set kind [lindex $line 0]; set name [lindex $line 1]; set kv [lrange $line 2 end]
		if {$kind ni {profile applied} || ![okname $name] || [llength $kv] % 2} continue
		set d [dict create]
		foreach {k v} $kv { if {[dict exists $defaults $k] && [ok $k $v]} { dict set d $k $v } }
		if {$kind eq "profile"} {
			if {[dict exists $P $name]} continue
			dict set P $name $d; lappend order $name
		} else { dict set A $name $d }
	}
	# Default is always there, first, with every key
	set d [expr {[dict exists $P Default] ? [dict get $P Default] : {}}]
	dict set P Default [dict merge $defaults $d]
	set order [linsert [lsearch -all -inline -not -exact $order Default] 0 Default]
	# a profile never applied counts as applied as it is now (nothing to restart for yet)
	foreach n $order { if {![dict exists $A $n]} { dict set A $n [resolved $n] } }
}

proc prof::save {} {
	variable P
	variable A
	variable order
	set lines [list "# Ribbon Terminal profiles: written by the terminal's preferences. One Tcl list a line."]
	foreach n $order { lappend lines [list profile $n {*}[dict get $P $n]] }
	foreach n $order { if {[dict exists $A $n]} { lappend lines [list applied $n {*}[dict get $A $n]] } }
	set path [conffile]
	::file mkdir [::file dirname $path]
	set tmp $path.[pid].tmp
	set f [open $tmp w]; fconfigure $f -encoding utf-8
	puts $f [join $lines "\n"]
	close $f
	::file rename -force $tmp $path
}

# ---- one profile ------------------------------------------------------------------------

# KEY's value for profile NAME: its own, else Default's.
proc prof::get {name key} {
	variable P
	if {[dict exists $P $name] && [dict exists [dict get $P $name] $key]} { return [dict get $P $name $key] }
	return [dict get $P Default $key]
}
# Whether NAME sets KEY itself. On Default a colour that follows the theme ("") is not its own.
proc prof::own {name key} {
	variable P
	variable own_keys
	if {$name eq "Default"} { return [expr {$key ni {bg fg cur sel mark scheme} || [dict get $P Default $key] ne ""}] }
	if {$key ni $own_keys} { return 0 }
	expr {[dict exists $P $name $key]}
}
proc prof::put {name key value} {
	variable P
	if {![ok $key $value]} { return 0 }
	dict set P $name $key $value
	save
	return 1
}
# Back to what NAME takes from elsewhere: Default's value (another profile), the theme's (a Default colour).
proc prof::drop {name key} {
	variable P
	if {$name eq "Default"} { if {$key in {bg fg cur sel mark scheme}} { dict set P Default $key "" } } else { dict unset P $name $key }
	save
}
# Every key, as NAME's tabs get it.
proc prof::resolved {name} {
	variable defaults
	set d [dict create]
	foreach k [dict keys $defaults] { dict set d $k [get $name $k] }
	return $d
}
# Whether KEY of NAME changed since its tabs were started (the "New tabs" tag).
proc prof::changed {name key} {
	variable A
	variable strip_keys
	if {$key in $strip_keys || ![dict exists $A $name $key]} { return 0 }
	expr {[dict get $A $name $key] ne [get $name $key]}
}
proc prof::applied {} {
	variable A
	variable order
	foreach n $order { dict set A $n [resolved $n] }
	save
}

# A new profile: "Profile", "Profile 2", ...; it takes everything from Default.
proc prof::create {} {
	variable P
	variable order
	set n "Profile"; set k 1
	while {[dict exists $P $n]} { set n "Profile [incr k]" }
	dict set P $n {}
	lappend order $n
	applied
	return $n
}
proc prof::delete {name} {
	variable P
	variable A
	variable order
	if {$name eq "Default"} return
	dict unset P $name; dict unset A $name
	set order [lsearch -all -inline -not -exact $order $name]
	save
}
# Default back to the built-in values (Reset profile); the strip's settings stay.
proc prof::reset_default {} {
	variable P
	variable defaults
	variable strip_keys
	set d $defaults
	foreach k $strip_keys { dict set d $k [dict get $P Default $k] }
	dict set P Default $d
	save
}
# The profile a new tab running COMMAND takes ("Opens for"): the first whose command is COMMAND's program.
proc prof::for_command {cmd} {
	variable order
	set prog [::file tail [lindex $cmd 0]]
	if {$prog eq ""} { return Default }
	foreach n $order { if {$n ne "Default" && [prof::get $n command] eq $prog} { return $n } }
	return Default
}

# ---- colours ------------------------------------------------------------------------------

# The palette directories (ribbon-theme's places).
proc prof::palette_dirs {} {
	set d {}
	if {[info exists ::env(RIBBON_PALETTES)]} { lappend d {*}$::env(RIBBON_PALETTES) }
	# the user's first (they win, as in ribbon-theme), then the installed ones, then the source tree's
	lappend d [::file join [confdir] ribbon palettes] /usr/share/ribbon/themes/palettes
	lappend d [::file normalize [::file join $::prof::here .. .. themes palettes]]
	return $d
}
proc prof::read_palette {path} {
	set p [dict create]
	catch {
		set f [open $path r]; fconfigure $f -encoding utf-8
		foreach line [split [read $f] "\n"] {
			if {[regexp {^([A-Z0-9_]+)=(.*)$} $line -> k v]} { dict set p $k [string trim $v {"}] }
		}
		close $f
	}
	return $p
}
# {id name} of every scheme, the theme's first.
proc prof::schemes {} {
	set out {}
	foreach d [palette_dirs] {
		foreach f [lsort [glob -nocomplain -directory $d *.conf]] {
			set id [::file rootname [::file tail $f]]
			if {[lsearch -exact -index 0 $out $id] >= 0} continue
			set n [expr {[dict exists [read_palette $f] NAME] ? [dict get [read_palette $f] NAME] : $id}]
			lappend out [list $id $n]
		}
	}
	return $out
}
proc prof::scheme_file {id} {
	foreach d [palette_dirs] { if {[::file readable [::file join $d $id.conf]]} { return [::file join $d $id.conf] } }
	return ""
}
# The terminal colours of a palette, as ribbon-theme's foot_ini maps them: regular 0-7 are PILL, CRIT, OK, WARN, INK,
# ACCENT2, SYN_VAR, FG; bright 0 is MUTED, bright 1-7 repeat; text FG on BAR; selection FIELD; cursor ACCENT.
proc prof::terminal_colours {p} {
	foreach {k d} {MUTED FG SYN_VAR ACCENT2 ON_ACCENT BAR} { if {![dict exists $p $k] && [dict exists $p $d]} { dict set p $k [dict get $p $d] } }
	set reg {PILL CRIT OK WARN INK ACCENT2 SYN_VAR FG}
	set c [dict create]
	foreach k $reg i {0 1 2 3 4 5 6 7} { dict set c regular$i [dict get $p $k] }
	foreach k [lreplace $reg 0 0 MUTED] i {0 1 2 3 4 5 6 7} { dict set c bright$i [dict get $p $k] }
	dict set c fg [dict get $p FG]; dict set c bg [dict get $p BAR]; dict set c sel [dict get $p FIELD]
	dict set c cur [dict get $p ACCENT]; dict set c curtext [dict get $p ON_ACCENT]; dict set c mark [dict get $p ACCENT]
	return $c
}
# The theme's palette (what ribbon-theme last applied), as a dict.
proc prof::theme_palette {} {
	set p [read_palette [::file join [confdir] ribbon palette.conf]]
	if {![dict exists $p BAR]} { set f [scheme_file ribbon]; if {$f ne ""} { set p [read_palette $f] } }
	if {![dict exists $p BAR]} { set p {BAR #1D1C1B FIELD #2A2826 PILL #36302C FG #EEE9E3 MUTED #A49D95 ACCENT #FF7A59 ACCENT2 #FFB199 INK #8AB4F8 OK #8FD694 WARN #F2C14E CRIT #FF5C5C SYN_VAR #8EC3C8 ON_ACCENT #1A0F0B} }
	return $p
}
# NAME's colours: the scheme (Default's, the theme's when none), then its own colours over it.
proc prof::colours {name} {
	set sch [get $name scheme]
	set p [expr {$sch ne "" && [scheme_file $sch] ne "" ? [read_palette [scheme_file $sch]] : [theme_palette]}]
	set c [terminal_colours $p]
	foreach k {bg fg cur sel mark} {
		set v [get $name $k]
		if {$v ne ""} { dict set c $k [hex $c $v] }
	}
	return $c
}
# A colour value as #RRGGBB: a name is that regular colour of C.
proc prof::hex {c v} {
	variable colours
	set i [lsearch -exact $colours $v]
	if {$i >= 0} { return [dict get $c regular$i] }
	return [string toupper $v]
}

# ---- foot ---------------------------------------------------------------------------------

proc prof::foot_minor {} {
	variable footv
	if {$footv eq ""} {
		set footv 99
		catch { if {[regexp {foot version: 1\.([0-9]+)} [exec foot --version 2>@1] -> m]} { set footv $m } }
	}
	return $footv
}
# The `footclient -o` arguments for a tab of profile NAME.
proc prof::footargs {name} {
	set o {}
	set sz [get $name size]
	lappend o -o "font=[get $name font]:size=$sz"
	# one step of the tab menu's Text size (foot's font-increase / font-decrease) is 1 pt
	lappend o -o "font-size-adjustment=1"
	set lh [get $name lineh]
	if {$lh ne "font"} { lappend o -o "line-height=[format %.1f [expr {$sz * $lh}]]" }
	set pd [get $name pad]
	lappend o -o "pad=${pd}x$pd"
	lappend o -o "cursor.style=[get $name cursor]" -o "cursor.blink=[expr {[get $name blink] ? "yes" : "no"}]"
	set cols [expr {[foot_minor] >= 26 ? "colors-dark" : "colors"}]
	set op [get $name opacity]
	if {$op < 100} { lappend o -o "$cols.alpha=[format %.2f [expr {$op / 100.0}]]" }
	lappend o -o "scrollback.lines=[get $name lines]" -o "scrollback.multiplier=[get $name wheel].0"
	set c [colours $name]
	set h [lambda {v} { string trimleft [string tolower $v] # }]
	if {[get $name scheme] ne ""} {
		foreach i {0 1 2 3 4 5 6 7} { lappend o -o "$cols.regular$i=[{*}$h [dict get $c regular$i]]" -o "$cols.bright$i=[{*}$h [dict get $c bright$i]]" }
	}
	if {[get $name scheme] ne "" || [get $name bg] ne ""} { lappend o -o "$cols.background=[{*}$h [dict get $c bg]]" }
	if {[get $name scheme] ne "" || [get $name fg] ne ""} { lappend o -o "$cols.foreground=[{*}$h [dict get $c fg]]" }
	if {[get $name scheme] ne "" || [get $name sel] ne ""} { lappend o -o "$cols.selection-background=[{*}$h [dict get $c sel]]" }
	if {[get $name scheme] ne "" || [get $name cur] ne ""} {
		set pair "[{*}$h [dict get $c curtext]] [{*}$h [dict get $c cur]]"
		lappend o -o [expr {[foot_minor] >= 26 ? "$cols.cursor=$pair" : "cursor.color=$pair"}]
	}
	# [bell] visual= and system= are newer than foot 1.16 (which refuses a window with an unknown key)
	if {[foot_minor] >= 20} {
		switch -- [get $name bell] {
			off { }
			flash { lappend o -o "bell.visual=yes" }
			sound { lappend o -o "bell.system=yes" }
		}
	}
	if {[get $name notify]} { lappend o -o "bell.notify=yes" }
	# the keys: foot's actions replace foot.ini's binding; the strip's are pipe bindings to ribbon-term-ctl
	variable keys
	foreach {k l c h} $keys {
		set chord [get $name key_$k]
		# a key left as it was keeps foot.ini's bindings (foot's own defaults have more than one chord for some)
		if {$chord eq $c} continue
		switch -- [lindex $h 0] {
			foot { lappend o -o "key-bindings.[lindex $h 1]=$chord" }
			pipe { lappend o -o "key-bindings.pipe-visible=\[ribbon-term-ctl [lindex $h 1]\] $chord" }
		}
	}
	return $o
}
proc prof::lambda {args body} { list apply [list $args $body] }

prof::load
