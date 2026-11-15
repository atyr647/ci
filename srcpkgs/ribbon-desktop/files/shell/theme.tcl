# theme.tcl - colours, fonts and icon outlines for the Ribbon shell.
# (Text drawing is text.tcl.)

namespace eval theme {
	variable c
	variable id ribbon
	# Line icons (24 x 24 outlines, drawn with round caps and joins).
	variable icon
	array set icon {
		search   {M4 11a7 7 0 1 0 14 0a7 7 0 1 0 -14 0 M21 21l-4.3-4.3}
		down     {M6 9l6 6 6-6}
		up-chev  {M18 15l-6-6-6 6}
		up       {M12 19V5 M5 12l7-7 7 7}
		grid     {M4 4h6v6H4z M14 4h6v6h-6z M4 14h6v6H4z M14 14h6v6h-6z}
		folder   {M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z}
		file     {M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z M14 3v5h5}
		image    {M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8.5 10a1.5 1.5 0 1 0 0-3a1.5 1.5 0 1 0 0 3z M21 15l-5-5L5 21}
		music    {M9 18V5l12-2v13 M6 21a3 3 0 1 0 0-6a3 3 0 1 0 0 6z M18 19a3 3 0 1 0 0-6a3 3 0 1 0 0 6z}
		terminal {M4 17l6-6-6-6 M12 19h8}
		game     {M6 11h4 M8 9v4 M15 12h.01 M18 10h.01 M17.3 5H6.7a4 4 0 0 0-3.96 3.43l-.9 6.3A3 3 0 0 0 4.8 18c.94 0 1.83-.44 2.4-1.2l.8-1.1a2 2 0 0 1 1.6-.8h4.8a2 2 0 0 1 1.6.8l.8 1.1c.57.76 1.46 1.2 2.4 1.2a3 3 0 0 0 2.96-3.27l-.9-6.3A4 4 0 0 0 17.3 5z}
		globe    {M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0 M2 12h20 M12 2a15 15 0 0 1 0 20 M12 2a15 15 0 0 0 0 20}
		star     {M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01z}
		pulse    {M22 12h-4l-3 9L9 3l-3 9H2}
		lock     {M5 11h14v10H5z M8 11V7a4 4 0 0 1 8 0v4}
		moon     {M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z}
		logout   {M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4 M16 17l5-5-5-5 M21 12H9}
		rotate   {M23 4v6h-6 M20.49 15a9 9 0 1 1-2.12-9.36L23 10}
		power    {M18.36 6.64a9 9 0 1 1-12.73 0 M12 2v10}
		code     {M16 18l6-6-6-6 M8 6l-6 6 6 6}
		sliders  {M4 21v-7 M4 10V3 M12 21v-9 M12 8V3 M20 21v-5 M20 12V3 M1 14h6 M9 8h6 M17 16h6}
		pkg      {M21 16V8l-9-5-9 5v8l9 5 9-5z M3.3 7L12 12l8.7-5 M12 22V12}
		wifi     {M5 12.55a11 11 0 0 1 14 0 M1.42 9a16 16 0 0 1 21.16 0 M8.53 16.11a6 6 0 0 1 6.95 0 M12 20h.01}
		wifi-off {M1 1l22 22 M16.72 11.06A10.94 10.94 0 0 1 19 12.55 M5 12.55a10.94 10.94 0 0 1 5.17-2.39 M10.71 5.05A16 16 0 0 1 22.58 9 M1.42 9a15.91 15.91 0 0 1 4.7-2.88 M8.53 16.11a6 6 0 0 1 6.95 0 M12 20h.01}
		volume   {M11 5L6 9H2v6h4l5 4z M15.54 8.46a5 5 0 0 1 0 7.07 M19.07 4.93a10 10 0 0 1 0 14.14}
		volume-x {M11 5L6 9H2v6h4l5 4z M23 9l-6 6 M17 9l6 6}
		camera   {M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z M12 17a4 4 0 1 0 0-8a4 4 0 1 0 0 8z}
		calendar {M5 4h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z M16 2v4 M8 2v4 M3 10h18}
		battery  {M3 8h14a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2H3a1 1 0 0 1-1-1V9a1 1 0 0 1 1-1z M22 11v2}
		left     {M15 18l-6-6 6-6}
		right    {M9 18l6-6-6-6}
		list     {M8 6h13 M8 12h13 M8 18h13 M3 6h.01 M3 12h.01 M3 18h.01}
		home     {M3 10l9-7 9 7v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z M9 22V12h6v10}
		download {M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4 M7 10l5 5 5-5 M12 15V3}
		trash    {M3 6h18 M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6 M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2}
		drive    {M22 12H2 M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z M6 16h.01 M10 16h.01}
		disc     {M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0 M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0}
		film     {M4 3h16a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z M7 3v18 M17 3v18 M3 12h18 M3 7.5h4 M3 16.5h4 M17 7.5h4 M17 16.5h4}
		archive  {M21 8v13H3V8 M1 3h22v5H1z M10 12h4}
		copy     {M9 9h11v11H9z M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1}
		scissors {M3 6a3 3 0 1 0 6 0a3 3 0 1 0 -6 0 M3 18a3 3 0 1 0 6 0a3 3 0 1 0 -6 0 M20 4L8.12 15.88 M14.47 14.48L20 20 M8.12 8.12L12 12}
		paste    {M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2 M9 2h6v4H9z}
		edit     {M12 20h9 M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z}
		plus     {M12 5v14 M5 12h14}
		undo     {M3 7v6h6 M21 17a9 9 0 0 0-15-6.7L3 13}
		x        {M18 6L6 18 M6 6l12 12}
		eye      {M1 12C1 12 5 4 12 4C19 4 23 12 23 12C23 12 19 20 12 20C5 20 1 12 1 12z M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0}
		check    {M20 6L9 17l-5-5}
		mic      {M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z M19 10v2a7 7 0 0 1-14 0v-2 M12 19v3}
		mic-off  {M1 1l22 22 M9 9v3a3 3 0 0 0 5.12 2.12 M15 9.34V5a3 3 0 0 0-5.94-.6 M17 16.95A7 7 0 0 1 5 12v-2 M19 10v2a7 7 0 0 1-.11 1.23 M12 19v3}
		headphones {M3 18v-6a9 9 0 0 1 18 0v6 M21 19a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3z M3 19a2 2 0 0 0 2 2h1a2 2 0 0 0 2-2v-3a2 2 0 0 0-2-2H3z}
		monitor  {M4 3h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z M8 21h8 M12 17v4}
		mouse    {M12 2a6 6 0 0 1 6 6v8a6 6 0 0 1-12 0V8a6 6 0 0 1 6-6z M12 6v4}
		keyboard {M4 5h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z M6 9h.01 M10 9h.01 M14 9h.01 M18 9h.01 M7 15h10}
		phone    {M7 2h10a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z M12 18h.01}
		bt       {M7 7l10 10-5 5V2l5 5L7 17}
		sun      {M8 12a4 4 0 1 0 8 0a4 4 0 1 0 -8 0 M12 2v2 M12 20v2 M4.93 4.93l1.41 1.41 M17.66 17.66l1.41 1.41 M2 12h2 M20 12h2 M4.93 19.07l1.41-1.41 M17.66 6.34l1.41-1.41}
		leaf     {M11 20A7 7 0 0 1 9.8 6.1C15.5 5 17 4.48 19 2c1 2 2 4.18 2 8 0 5.5-4.78 10-10 10z M2 21c0-3 1.85-5.36 5.08-6}
		scale    {M12 3v18 M8 21h8 M4 7h16 M4 7l-3 6a3 3 0 0 0 6 0z M20 7l-3 6a3 3 0 0 0 6 0z}
		zap      {M13 2L3 14h9l-1 8 10-12h-9l1-8z}
		restore  {M8 4h12v12 M4 8h12v12H4z}
		minus    {M5 12h14}
		square   {M5 5h14v14H5z}
		ws       {M3 5h18v14H3z M3 9h18}
		link     {M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71 M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71}
		info     {M12 22a10 10 0 1 0 0-20a10 10 0 1 0 0 20z M12 16v-4 M12 8h.01}
		restart  {M1 4v6h6 M3.51 15a9 9 0 1 0 2.13-9.36L1 10}
		clock    {M12 22a10 10 0 1 0 0-20a10 10 0 1 0 0 20z M12 6v6l4 2}
		ext      {M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6 M15 3h6v6 M10 14L21 3}
	}
}

# Load the active palette (written by ribbon-theme apply).
proc theme::load {} {
	variable c
	variable id
	array unset c
	# Graphite, the default, in case a palette lacks a key.
	array set c {
		BAR #1D1C1B FIELD #2A2826 PILL #36302C BORDER #3B3835 FG #EEE9E3
		MUTED #A49D95 ACCENT #FF7A59 ON_ACCENT #1A0F0B WIN #232120
		DESK_TOP #2B2825 DESK_BOTTOM #121110 DESK_STRIPE #FFFFFF
		DESK_STRIPE_ALPHA 0.03 BAR_SHADOW {6 20 0.35 #000000}
		WARN #F2C14E ERR #EC6A5E LINE #242220 VADD #8DB07C VMOD #7EA6C4 VDEL #E07A6A
		MATCH #EEE9E3 MATCH_ALPHA 0.10 WELL #000000 WELL_ALPHA 0.20
		SYN_KW #E3B580 SYN_FN #F2ECE5 SYN_VAR #8EC3C8 SYN_STR #A9C79A SYN_NUM #F29B7E
		SYN_COM #7A746D SYN_OPT #BDB4AA SYN_PUN #8F877F SYN_NUM0 #5E5852
	}
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] ? $::env(XDG_CONFIG_HOME) : "$home/.config"}]
	foreach f [list $cfg/ribbon/palette.conf /usr/share/ribbon/themes/palettes/ribbon.conf] {
		if {![file readable $f]} continue
		set fh [open $f]; set text [read $fh]; close $fh
		foreach line [split $text \n] {
			if {[regexp {^\s*([A-Z_0-9]+)=(.*)$} $line -> k v]} {
				set c($k) [string trim [string trim $v] \"']
			}
		}
		if {[regexp {^# id: (\S+)} $text -> pid]} { set id $pid }
		break
	}
	if {![info exists c(ON_ACCENT)] || $c(ON_ACCENT) eq ""} { set c(ON_ACCENT) $c(BAR) }
	if {![info exists c(WIN)] || $c(WIN) eq ""} { set c(WIN) $c(FIELD) }
	if {![info exists c(POP_SHADOW)]} { set c(POP_SHADOW) {24 60 0.5 #000000} }
	if {![info exists c(MENU_SHADOW)]} { set c(MENU_SHADOW) {18 40 0.45 #000000} }
	# your own wallpaper picture, if you chose one (the login screen and
	# Appearance draw it); what plays, and how the bars sit over a video
	namespace eval ::wall { variable image "" }
	set ::wall::image ""
	variable wallmode ""
	variable bars ""
	if {![catch {open $cfg/ribbon/wallpaper.conf} fh]} {
		set text [read $fh]
		close $fh
		regexp -line {^IMAGE=(.*)$} $text -> ::wall::image
		regexp -line {^MODE=([a-z]+)$} $text -> wallmode
		regexp -line {^BARS=([a-z-]+)$} $text -> bars
	}
}

# The shell's fonts (text.tcl: the family names carry the mockups' weights).
proc theme::fonts {} {
	foreach {name family size} {
		f13 {Ribbon Inter 400} 13   f13m {Ribbon Inter 500} 13   f13s {Ribbon Inter 600} 13
		f12 {Ribbon Inter 400} 12   f12m {Ribbon Inter 500} 12   f12s {Ribbon Inter 600} 12
		f11 {Ribbon Inter 400} 11   f11s {Ribbon Inter 600} 11
		fbig {Ribbon Space Grotesk 600} 26   f20g {Ribbon Space Grotesk 600} 20
	} {
		text::font $name $family $size
	}
}

# A line icon photo: name, pixel size, stroke width (viewBox units), colour,
# and the fractional part of where it lands, so it matches sub-pixel layout.
proc theme::icon {name size stroke colour {fx 0} {fy 0} {extra {}} {fill 0}} {
	variable icon
	raster::icon $icon($name) $size $stroke $colour $extra \
		[expr {round($fx * 4) / 4.0}] [expr {round($fy * 4) / 4.0}] $fill
}

# Solid strips instead of floating bars while a video plays (wallpaper.conf
# BARS=solid); see-through, the default, floats the bars over it.
proc theme::solid_bars {} {
	variable wallmode
	variable bars
	expr {$wallmode eq "video" && $bars eq "solid"}
}

# The shell's looks (rbnalpha): the bars, panels hanging from them, menus.
proc theme::look {kind args} {
	variable c
	switch $kind {
		bar { set l [list -fill $c(BAR) -radius 12 -ring [list $c(BORDER) 1] -shadow $c(BAR_SHADOW)] }
		pop { set l [list -fill $c(BAR) -radius 12 -ring [list $c(BORDER) 1] -shadow $c(POP_SHADOW)] }
		menu { set l [list -fill $c(BAR) -radius 10 -ring [list $c(BORDER) 1] -shadow $c(MENU_SHADOW)] }
	}
	dict merge $l $args
}
