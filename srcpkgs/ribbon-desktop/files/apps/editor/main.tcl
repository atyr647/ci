# main.tcl - Text editor (ribbon-editor, U26): the window, the joined tabs, the Well gutter, the text, open, save,
# save as, reload on external change, the status line, the open-documents list and the close sheet. Tcl/Tk,
# drawn as Editor-Final-1, -2 and -5 (design/mockups, gen_editor_final.py), in the active theme's colours.
#
#   ribbon-editor [FILE...]
#   RIBBON_EDITOR_SCENE = file: a test scene (tests/editor-scene.tcl), run instead of the first file
#
# Layout: the chrome (strip, tabs, status line, list, sheet) is one canvas drawn with the Appearance app's ui
# library. The text and the gutter are Tk widgets placed under the canvas' top layer (the strip and status line
# are on the canvas; the body is the text widget and the gutter canvas). While the list or the close sheet is
# open the text widget is unmapped and its visible lines are drawn on the canvas instead, so the overlay sits
# above the text (see editor::overlay_text).
#
# Hooks for the later units: apps/editor/hooks.tcl.

namespace eval editor {
	variable W 1240
	variable H 780
	variable WELL 72
	variable win .w
	variable page .w.ed        ;# the body frame: text widgets are packed here
	variable gut .w.g          ;# the Well gutter canvas
	variable cv .w.c           ;# the chrome canvas
	variable docs {}           ;# tab order: document ids
	variable active ""
	variable hover ""
	variable scroll 0
	variable pop 0             ;# the open-documents list is shown
	variable popq ""           ;# what has been typed into its search
	variable sheet 0           ;# the close sheet is shown
	variable quitting 0
	variable scene 0
	variable mono "Ribbon Mono"   ;# the one monospace token (shell/fonts.conf maps it to JetBrains Mono)
	variable monosize 13
	variable codefont ""
	variable pending 0
	variable shot ""
	variable tickms 2000
	variable winfocus 1        ;# the window has the keyboard focus (editor::focus_check)
	variable topof             ;# the first line shown, per text widget (drawn pages)
	variable yv                ;# the last yview, per text widget
	array set c {}
}

set ::editor::appdir [file dirname [file normalize [info script]]]

# A folder next to the editor (the repo's files/, or the installed /usr/lib/ribbon).
proc editor::find_dir {name file} {
	foreach d [list [file normalize [file join $::editor::appdir .. $name]] [file normalize [file join $::editor::appdir .. .. $name]] /usr/lib/ribbon/$name] {
		if {[file exists [file join $d $file]]} { return $d }
	}
	puts stderr "ribbon-editor: $name/$file was not found"; exit 1
}

# The chrome's sources, after the window's own procs: the tabs, the well and status, the sheet, the hooks.
foreach f {doc tabs well sheet highlight hooks gutter find goto menu split welcome diagnostics} { source -encoding utf-8 [file join $::editor::appdir $f.tcl] }

proc editor::hooks_install {} {
	find_install
	split_install
	welcome_install
	diagnostics_install
}

# The libraries: the shell's text, raster, wall and theme; Appearance's ui; rbnalpha for see-through corners.
# Each library is sourced at global level: source runs in the caller's namespace, so from inside editor::libraries
# a file's `namespace eval ui` would have built ::editor::ui (the properties app sources at top level).
proc editor::libraries {} {
	set shell [find_dir shell raster.tcl]
	set appearance [find_dir appearance ui.tcl]
	foreach d [list /usr/lib/ribbon [file dirname $shell]] { if {$d ni $::auto_path} { lappend ::auto_path $d } }
	package require rbnalpha
	foreach f {text raster wall theme} { uplevel #0 [list source -encoding utf-8 [file join $shell $f.tcl]] }
	uplevel #0 [list source -encoding utf-8 [file join $appearance ui.tcl]]
	# Open, Save as and Open folder… use Ribbon's file chooser (boards Chooser-*)
	uplevel #0 [list source -encoding utf-8 [file join $appearance chooser.tcl]]
	set ::ui::fonts(sg20) {{Ribbon Space Grotesk 600} 20 0.984 0.292}
	set ::ui::fonts(mono13) {{Ribbon Mono} 13 0.96875 0.2412}    ;# the find field's text (the code face)
}

# The colours of the active theme, in the names the code uses.
proc editor::apply_theme {} {
	variable c
	::theme::load
	foreach {k v} {bar BAR field FIELD pill PILL border BORDER fg FG muted MUTED accent ACCENT on_accent ON_ACCENT
			d1 DESK_TOP d2 DESK_BOTTOM line LINE syn_num0 SYN_NUM0 well_alpha WELL_ALPHA \
			vadd VADD vmod VMOD vdel VDEL syn_pun SYN_PUN} {
		set c($k) $::theme::c($v)
	}
	set c(d2) $::theme::c(DESK_BOTTOM)
	variable bg $c(bar)
	variable fg $c(fg)
	variable accent $c(accent)
	variable sel [well::mix $c(bar) $c(fg) 0.18]
	variable line $c(line)
	highlight::restyle
	ui::colours [dict create BAR $c(bar) FIELD $c(field) PILL $c(pill) BORDER $c(border) FG $c(fg) MUTED $c(muted) \
		ACCENT $c(accent) ON_ACCENT $c(on_accent) DESK_TOP $c(d1) DESK_BOTTOM $c(d2) \
		DESK_STRIPE $::theme::c(DESK_STRIPE) DESK_STRIPE_ALPHA $::theme::c(DESK_STRIPE_ALPHA)]
}

# Icon paths (24 grid, stroked). ui::icon has no search, split, close or save glyphs, so they are here.
namespace eval editor {
	variable paths
	array set paths {
		plus {M12 5v14M5 12h14}
		x {M6 6l12 12M18 6L6 18}
		search {M10.5 4.5a6 6 0 1 1 0 12a6 6 0 1 1 0-12M15.5 15.5L20 20}
		split {M4 4h16v16H4zM12 4v16}
		more {M5 12h.01M12 12h.01M19 12h.01}
		min {M5 12h14}
		max {M5 5h14v14H5z}
		down {M6 9l6 6 6-6}
		folder {M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z}
		folderopen {M6 14l1.45-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.55 6a2 2 0 0 1-1.94 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.93a2 2 0 0 1 1.66.9l.82 1.2a2 2 0 0 0 1.66.9H18a2 2 0 0 1 2 2v2}
		file {M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8zM14 3v5h5}
		save {M5 3h11l3 3v13H5zM8 3v5h7V3M8 21v-6h8v6}
		check {M5 12l5 5 9-10}
		braces {M8 4H6a2 2 0 0 0-2 2v4l-2 2 2 2v4a2 2 0 0 0 2 2h2M16 4h2a2 2 0 0 1 2 2v4l2 2-2 2v4a2 2 0 0 1-2 2h-2}
		hash {M4 9h16M4 15h16M10 3l-2 18M16 3l-2 18}
		gear {M12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6zM12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2}
		lines {M4 7h16M4 12h16M4 17h10}
		chev {M6 9l6 6 6-6}
		chevup {M18 15l-6-6-6 6}
		right {M9 18l6-6-6-6}
		replace {M3 7h13l-3-3 M21 17H8l3 3}
		undo {M3 7v6h6 M21 17a9 9 0 0 0-15-6.7L3 13}
	}
}

proc editor::icon {name size colour x y {sw 1.9}} {
	variable paths
	variable cv
	set i [raster::icon $paths($name) $size $sw [ui::col $colour] {} 0 0 0]
	$cv create image [expr {round($x)}] [expr {round($y)}] -image $i -anchor nw -tags page
}

proc editor::noop {args} {}

# The window's own min / max / close buttons: drawn unless labwc frames the window (rbn::framed), which has its own.
# A scene is a bare toplevel with no frame, so it always draws them.
proc editor::own_controls {} {
	variable scene
	expr {$scene || ![::rbn::framed]}
}

# The window. A scene draws it at 100,74 on a bare screen; the real window is an ARGB window (rbnalpha) whose
# corners are see-through, and labwc frames the window (title bar and buttons) when floating (rbn::framed).
proc editor::build {} {
	variable win
	variable W
	variable H
	variable cv
	variable page
	variable gut
	variable scene
	wm withdraw .
	if {$scene} {
		toplevel $win -class RibbonEditor -borderwidth 0 -highlightthickness 0
		wm overrideredirect $win 1
		wm geometry $win ${W}x${H}+100+74
	} else {
		# labwc keeps the frame on the screen: a taller page than the room under the bars is fitted (rbn::fit)
		set H [rbn::fit $H]
		if {[rbn::appwindow $win RibbonEditor $W $H -fill $::editor::c(bar)]} { set ::ui::argbwin $win }
		wm title $win "Text editor"
		wm iconname $win "Text editor"
		# the window can be resized and maximised: the strip, the Well and the status line keep their board sizes and the
		# text takes the rest (editor::resized); the board's 1240 x 780 is the start, 900 x 600 the least
		wm minsize $win 900 600
		wm protocol $win WM_DELETE_WINDOW editor::quit
		wm geometry $win ${W}x${H}+[expr {max(0, ([winfo screenwidth .] - $W) / 2)}]+[expr {max(0, ([winfo screenheight .] - $H) / 2 + 14)}]
	}
	# rbn::appwindow has already made $win.c (the window's canvas); the scene's plain toplevel has none yet
	if {![winfo exists $cv]} { canvas $cv -width $W -height $H -highlightthickness 0 -borderwidth 0 -background $::editor::c(bar) }
	place $cv -x 0 -y 0
	set ::ui::cv $cv
	set ::ui::W $W
	set ::ui::H $H
	set ::ui::ox 0; set ::ui::oy 0
	set ::ui::behind ""; set ::ui::bx 0; set ::ui::by 0
	frame $page -width [expr {$W - 72}] -height [expr {$H - 46 - 32}] -background $::editor::bg -borderwidth 0 -highlightthickness 0
	place $page -x 72 -y 46
	canvas $gut -width 72 -height [expr {$H - 46 - 32}] -highlightthickness 0 -borderwidth 0
	place $gut -x 0 -y 46
	pack propagate $page 0
	bind $cv <ButtonPress-1> {editor::chrome_press %x %y}
	bind $cv <B1-Motion> {editor::chrome_motion %x %y}
	bind $cv <ButtonRelease-1> {editor::chrome_release %x %y}
	bind $cv <Double-ButtonPress-1> {editor::chrome_double %x %y}
	bind $cv <ButtonPress-3> {editor::chrome_menu %x %y}
	bind $cv <Motion> {editor::hover %x %y}
	bind $cv <ButtonPress-2> {editor::middle %x %y}
	bind $cv <Button-4> {editor::wheel_strip -1}
	bind $cv <Button-5> {editor::wheel_strip 1}
	bind $win <KeyPress> {editor::key_top %K %A}
	bind $win <Escape> {editor::escape}
	bind $win <Return> {editor::enter}
	bind $win <Control-Tab> {editor::cmd next}
	bind $win <Control-s> {editor::cmd save}
	bind $win <Control-S> {editor::cmd saveas}
	bind $win <Control-o> {editor::cmd open}
	bind $win <Control-n> {editor::cmd new}
	bind $win <Control-w> {editor::cmd close}
	bind $win <Control-f> {editor::cmd find}
	bind $win <Control-h> {editor::cmd replace}
	bind $win <Control-l> {editor::cmd goto}
	bind $win <Control-Key-1> {split::focus_pane 0}
	bind $win <Control-Key-2> {split::focus_pane 1}
	bind $win <Control-backslash> {editor::cmd split}
	bind $win <Shift-Return> {editor::enter 1}
	bind $win <Configure> {if {"%W" eq $::editor::win} {editor::resized %w %h}}
	bind $win <FocusIn> {after idle editor::focus_check}
	bind $win <FocusOut> {after idle editor::focus_check}
	bind $win <Control-Alt-Return> {editor::cmd replaceall}
	gutter_install
}

# A press on the chrome: a field in the find bar takes the keyboard (the window has the focus, not the text).

# Text widget bindings: the editor's keys win over Tk's (Tk's Control-o is "open line"), so each stops the class.
proc editor::bind_text {w} {
	foreach {seq cmd} {
		<Control-s> save <Control-S> saveas <Control-o> open <Control-n> new <Control-w> close
		<Control-f> find <Control-h> replace <Control-backslash> split <Control-Tab> next <Control-l> goto
		<Control-Alt-Return> replaceall
	} {
		bind $w $seq "editor::cmd $cmd; break"
	}
	bind $w <ButtonPress-1> {+editor::text_press}
	bind $w <KeyRelease> {editor::touched}
	bind $w <ButtonRelease-1> {editor::touched}
	bind $w <<Modified>> {editor::touched}
	bind $w <<Undo>> {if {[find::undo_hook %W undo]} break}
	bind $w <<Redo>> {if {[find::undo_hook %W redo]} break}
}

proc editor::touched {} {
	variable active
	if {$active ne ""} { highlight::schedule $active }
	gutter::reveal
	schedule
}

# One paint at a time: a burst of keys or scroll events repaints once, when the loop is idle.
proc editor::schedule {} {
	variable pending
	if {$pending} return
	set pending 1
	after idle {editor::run_paint}
}

proc editor::run_paint {} {
	variable pending 0
	paint
}

# yscrollcommand: Tk reports the view on every geometry change, and a paint changes geometry (place forget/place),
# so only a view that really moved schedules a paint; otherwise paint and scroll report each other forever.

# ---- painting ----



# The y of the page's top: under the tab strip (46) and the find bar, when it is open.

# The top line of each document, while its text is on screen, so an overlay can draw the same lines.

# While an overlay is up the page is unmapped, so its visible lines are drawn on the canvas with the code font the
# text widget uses (same advances, so the glyphs sit where the widget would put them), in the token colours read
# back from its tags. The gutter's numbers are drawn the same way. The veil (sheet) dims everything on top.

# One line of document T as canvas text at (X, Y): runs of one colour and font, each placed by the code font's
# measured advance of the text before it.

# ---- the current-line band ----
# A Tk text tag paints only its characters, so the band is two canvas strips over the page's current row: one over
# the text's left padding, one from the end of the line to the window's right edge. Both are the LINE colour; the
# tag is not used. A press on a strip places the caret in the text (the strips are above it).
namespace eval editor {
	variable band1 .w.b1
	variable band2 .w.b2
}


proc editor::band_hide {} {
	variable band1
	variable band2
	foreach b [list $band1 $band2] { if {[winfo exists $b]} { place forget $b } }
}

# A press on a strip: the caret goes to the text at that point.
proc editor::band_click {X Y} {
	variable active
	if {$active eq ""} return
	set t [editor::tw $active]
	focus $t
	$t mark set insert [$t index @[expr {$X - [winfo rootx $t]}],[expr {$Y - [winfo rooty $t]}]]
	$t see insert
	schedule
}

proc editor::band_wheel {d} {
	variable active
	if {$active eq ""} return
	[editor::tw $active] yview scroll $d units
}

# ---- documents ----

# A document from FILE (or a new one when FILE is ""). Opens it, or activates the tab it has.



# Closing: clean documents close at once. Dirty ones are listed in the close sheet first.


# After a close: nothing open ends the program when quitting, and otherwise leaves a blank document. The Welcome page
# (U31) replaces the blank one through editor::welcome_install.







# Dispatch for the keys: name is one of the commands bound on the window and in the text.


# ---- the open-documents list, the sheet, focus ----





# A letter typed while the list is open goes into its search; Return takes the first match.


# Return: the sheet's Save, the list's first match, or (with the find bar's field focused) next, previous with SHIFT,
# or Replace in the replace field. A Return typed into the text is the text's own newline.

# A press in the text: the find fields give the keyboard back to the text, and an options menu closes.

# A click outside the list closes it (ui::press calls this when nothing in the window was hit).
namespace eval page {}


# A middle click on a tab closes it.

# The strip's empty area drags the window.



# ---- reload on external change: a clean document follows the file, a changed one says so ----


proc editor::chrome_press {x y} {
	if {[split::is_split]} {
		if {[split::on_rule $x $y]} {
			set split::drag rule
			return
		}
		set p [split::pane_at $x]
		if {$p != $split::cur} {
			split::focus_to $p
			paint
			if {$y >= [body_top]} { caret_at $x $y; return }
		}
	}
	ui::press $x $y
	if {[find::field_focus] || $::ui::focus eq "goto.q"} { focus $::editor::win }
}

proc editor::chrome_motion {x y} {
	if {$split::drag eq "rule"} { split::resize $x } else { ui::motion $x $y }
}

proc editor::chrome_release {x y} {
	if {$split::drag eq "rule"} { set split::drag ""; return }
	ui::release $x $y
}

proc editor::chrome_double {x y} {
	if {[split::on_rule $x $y]} { split::reset }
}

# A right click on the Welcome page: its card or row menu.
proc editor::chrome_menu {x y} {
	if {![llength [split::union]]} { welcome::context $x $y }
}

# A click in the text of pane P (when it is not focused): the caret goes where it was clicked.
proc editor::caret_at {x y} {
	set t [tw [split::val $split::cur active]]
	update idletasks
	set tx [expr {max(0, $x - [split::px $split::cur] - 72)}]
	set ty [expr {max(0, $y - [body_top])}]
	$t mark set insert [$t index @$tx,$ty]
	focus $t
	schedule
}

# The ⋯ menu: the Welcome page's, a split pane's, or the single window's (menu.tcl, boards Editor-R4-*).
proc editor::more_menu {x y} { menu::more $x $y }

proc editor::band {} {
	variable active
	variable band1
	variable band2
	variable W
	variable page
	if {$active eq "" || !$::editor::winfocus} { band_hide; return }
	set t [tw $active]
	if {![winfo ismapped $t] || [catch {$t dlineinfo insert} info] || $info eq ""} { band_hide; return }
	lassign $info x y w h
	set n [lindex [split [$t index insert] .] 0]
	set bb [$t bbox $n.end]
	if {$bb eq ""} { band_hide; return }
	set ex [lindex $bb 0]
	set top [expr {[body_top] + $y}]
	foreach b [list $band1 $band2] {
		if {![winfo exists $b]} {
			canvas $b -highlightthickness 0 -borderwidth 0 -background $::editor::c(line) -takefocus 0
			bind $b <ButtonPress-1> {editor::band_click %X %Y}
			bind $b <Button-4> {editor::band_wheel -3}
			bind $b <Button-5> {editor::band_wheel 3}
		}
		$b configure -background $::editor::c(line)
	}
	set px [split::px $split::cur]
	set right [expr {$px + [split::pw $split::cur]}]
	place $band1 -x [expr {$px + 72}] -y $top -width 16 -height $h
	set bx [expr {$px + 72 + $ex + 4}]
	place $band2 -x $bx -y $top -width [expr {$right - $bx}] -height $h
	raise $band1; raise $band2
}

proc editor::open_path {file} {
	set file [file normalize $file]
	foreach id [split::union] {
		if {[info exists ::doc::D($id,path)] && $::doc::D($id,path) eq $file} { activate $id; return $id }
	}
	if {![file isfile $file]} {
		set text ""; set enc utf-8; set bom 0; set eol LF
	} else {
		lassign [::doc::decode [::doc::read_file $file]] text enc bom eol
	}
	set id [::doc::new $file $text $enc $bom $eol]
	::doc::recent_add $file
	activate $id
	return $id
}

proc editor::new_doc {args} {
	set id [::doc::new "" "" utf-8 0 LF]
	activate $id
	return $id
}

# Show document ID in the focused pane (adding it to that pane's tabs).
proc editor::activate {id} {
	variable active
	variable docs
	if {$id eq "" || ![info exists ::doc::D($id,w)]} return
	if {$id ni $docs} { lappend docs $id }
	set active $id
	split::show $split::cur
	set w [tw $id]
	focus $w
	tabs::reveal $id
	schedule
	after idle [list editor::remember_top]
}

# Closing: a document shown in the other pane too only leaves this pane. Otherwise clean documents close at once and
# dirty ones are listed in the close sheet first.
proc editor::close_docs {ids} {
	set dirty {}
	set gone {}
	foreach id $ids {
		if {[split::in_other $id]} { detach $id; continue }
		lappend gone $id
		if {[::doc::dirty $id]} { lappend dirty $id }
	}
	if {[llength $dirty]} {
		sheet::show $dirty $gone
		return
	}
	foreach id $gone { force_close $id }
	after_close
}

# A tab leaves the focused pane (its document stays open in the other pane).
proc editor::detach {id} {
	set d [split::val $split::cur docs]
	set i [lsearch -exact $d $id]
	if {$i < 0} return
	set d [lreplace $d $i $i]
	if {[split::val $split::cur active] eq $id} { split::put $split::cur active [split::neighbour $d $i] }
	split::put $split::cur docs $d
	split::tidy
	split::show $split::cur
	schedule
}

proc editor::force_close {id} {
	foreach p {0 1} {
		set d [split::val $p docs]
		set i [lsearch -exact $d $id]
		if {$i < 0} continue
		set d [lreplace $d $i $i]
		if {[split::val $p active] eq $id} { split::put $p active [split::neighbour $d $i] }
		split::put $p docs $d
	}
	::doc::destroy_doc $id
	split::tidy
	split::show $split::cur
}

# After a close: with nothing open the Welcome page shows; quitting ends the program.
proc editor::after_close {} {
	variable quitting
	if {![llength [split::union]] && $quitting} { destroy $::editor::win; exit 0 }
	paint
}

proc editor::save_doc {id} {
	if {$::doc::D($id,untitled)} {
		set p [chooser::save_file -parent $::editor::win -initialdir [::doc::start_dir] -initialfile [::doc::name $id]]
		if {$p eq ""} { return 0 }
		set ok [::doc::save $id $p]
	} else {
		set ok [::doc::save $id]
	}
	schedule
	return $ok
}

proc editor::save_active {} { variable active; if {$active ne ""} { save_doc $active } }

proc editor::saveas_active {} {
	variable active
	if {$active eq ""} return
	set dir [expr {$::doc::D($active,untitled) ? [pwd] : [file dirname $::doc::D($active,path)]}]
	set p [chooser::save_file -parent $::editor::win -initialdir $dir -initialfile [::doc::name $active]]
	if {$p ne ""} { ::doc::save $active $p }
	schedule
}

# The file chooser starts in the folder Open folder… last chose (welcome.tcl), else in the current folder.
proc editor::open_dialog {} {
	set p [chooser::open_file -parent $::editor::win -initialdir [::doc::start_dir]]
	if {$p ne ""} { open_path $p }
}

proc editor::quit {args} {
	variable quitting
	set quitting 1
	split::unsplit $split::cur
	set ids $::editor::docs
	if {![llength $ids]} { destroy $::editor::win; exit 0 }
	close_docs $ids
}

proc editor::minimize {args} { wm iconify $::editor::win }

# The window's own maximise button (drawn when labwc does not frame the window): asks the window manager to maximise
# the window, or to give it back its size (EWMH _NET_WM_STATE, which labwc honours for an X window). The new size
# comes back as a <Configure> (editor::resized).
proc editor::maximize {args} {
	set w $::editor::win
	wm attributes $w -zoomed [expr {![wm attributes $w -zoomed]}]
}

# A new window size (resized or maximised): the canvas follows it and everything is drawn again for it. Below the
# minimum (900 x 600) nothing is laid out; labwc keeps to wm minsize.
proc editor::resized {w h} {
	variable W
	variable H
	variable cv
	if {$w < 900 || $h < 600 || ($w == $W && $h == $H)} return
	set W $w
	set H $h
	set ::ui::W $W
	set ::ui::H $H
	$cv configure -width $W -height $H
	place $cv -x 0 -y 0 -width $W -height $H
	foreach p {0 1} { tabs::clamp $p }
	schedule
}

# The window's focus: when it goes to another window the tabs, the strip's buttons and the position read as inactive
# (Editor-Final-7) and the current-line band goes (Tk hides the caret of a text without the focus). When it comes back,
# each document is checked against its file, so one changed on disk meanwhile is reloaded (or marked) at once.
proc editor::focus_check {} {
	variable win
	variable winfocus
	if {![winfo exists $win]} return
	# the focus is in this window (not in another program's, nor in a dialog or another toplevel of this one)
	set f [focus -displayof $win]
	set now [expr {$f ne "" && [winfo exists $f] && [winfo toplevel $f] eq $win}]
	if {$now == $winfocus} return
	set_focus $now
}

proc editor::set_focus {on} {
	variable winfocus
	set winfocus $on
	if {$on} { foreach id [split::union] { catch {::doc::check_disk $id} } }
	schedule
}

# A colour as drawn at 50 % over the strip (the board's opacity 0.5 on an inactive window's buttons).
proc editor::dim {colour} {
	variable winfocus
	if {$winfocus} { return $colour }
	well::mix $colour $::editor::c(d2) 0.5
}

# Dispatch for the keys: name is one of the commands bound on the window and in the text.
proc editor::cmd {name} {
	variable active
	switch -- $name {
		save { save_active }
		saveas { saveas_active }
		open { open_dialog }
		new { new_doc }
		close { if {$active ne ""} { close_docs [list $active] } }
		next { cycle 1 }
		find { goto::close; find_open 0 0 }
		replace { goto::close; replace_open }
		goto { goto::open }
		replaceall { find::replace_all }
		split { split::toggle }
	}
	schedule
}

proc editor::cycle {dir} {
	variable docs
	variable active
	if {![llength $docs]} return
	set i [lsearch -exact $docs $active]
	activate [lindex $docs [expr {($i + $dir + [llength $docs]) % [llength $docs]}]]
}

# ---- the open-documents list, the sheet, focus ----

proc editor::toggle_pop {} {
	variable pop
	variable popq
	set pop [expr {!$pop}]
	set popq ""
	if {$pop} { tabs::pop_reveal; focus $::editor::win } else { focus_text }
	schedule
}

proc editor::close_pop {} {
	set ::editor::pop 0
	set ::editor::popq ""
	focus_text
	schedule
}

proc editor::focus_none {} { focus $::editor::win }

proc editor::focus_text {} {
	variable active
	if {$active ne ""} { focus [tw $active] }
}

proc editor::key_top {sym char} {
	variable pop
	variable popq
	if {$::find::open && [focus] eq $::editor::win && [find::key $sym $char]} { schedule; return }
	if {$::goto::open && [focus] eq $::editor::win && [goto::key $sym $char]} { schedule; return }
	if {!$pop} return
	switch -- $sym {
		BackSpace { set popq [string range $popq 0 end-1] }
		default {
			if {[string length $char] == 1 && [string is print -strict $char]} { append popq $char }
		}
	}
	# the matches show from the first (the row Enter opens)
	set ::tabs::popscroll 0
	schedule
}

proc editor::escape {} {
	if {$::editor::sheet} { sheet::answer cancel; return }
	if {$::menu::open} { menu::hide; return }
	if {$::goto::open} { goto::close; return }
	if {$::find::open} { find::escape; return }
	if {$::editor::pop} { close_pop }
}

proc editor::enter {{shift 0}} {
	if {$::editor::sheet} { sheet::answer save; return }
	if {$::editor::pop} {
		set rows [tabs::visible_docs]
		if {[llength $rows]} { tabs::pick [lindex $rows 0] 0 0 }
		return
	}
	if {$::goto::open && [focus] eq $::editor::win} { goto::go; return }
	if {$::find::open && [focus] eq $::editor::win} { find::enter $shift }
}

# A press in the text: the find fields give the keyboard back to the text, and an options or ⋯ menu closes.
proc editor::text_press {} {
	if {$::find::open} { find::text_pressed }
	if {$::goto::open} { goto::close }
	menu::hide
}

namespace eval page {}
proc page::clicked_outside {} { editor::close_pop_if_open }
proc editor::close_pop_if_open {} {
	if {$::editor::pop} { close_pop }
	if {$::find::menu} { find::close_menu }
	menu::hide
}

proc editor::hover {x y} {
	set h [tabs::at $x $y]
	if {$h ne $::editor::hover} {
		set ::editor::hover $h
		schedule
	}
}

# A middle click on a tab closes it (in its pane).
proc editor::middle {x y} {
	set id [tabs::at $x $y]
	if {$id eq ""} return
	split::focus_to [split::pane_at $x]
	close_docs [list $id]
}

proc editor::strip_press {x y} {
	variable dragx [winfo pointerx $::editor::win]
	variable dragy [winfo pointery $::editor::win]
	variable winx [winfo rootx $::editor::win]
	variable winy [winfo rooty $::editor::win]
}

proc editor::strip_drag {x y} {
	variable dragx
	variable dragy
	variable winx
	variable winy
	set nx [expr {$winx + [winfo pointerx $::editor::win] - $dragx}]
	set ny [expr {$winy + [winfo pointery $::editor::win] - $dragy}]
	wm geometry $::editor::win +$nx+$ny
}

proc editor::wheel_strip {d} {
	variable scroll
	if {$::editor::pop} { tabs::pop_wheel $d; return }
	set scroll [expr {$scroll + 40 * $d}]
	tabs::clamp $split::cur
	schedule
}

# Tk reports a text's view on every geometry change: only a view that moved (in its own widget) schedules a paint.
proc editor::scrolled {id w args} {
	variable yv
	if {[info exists yv($w)] && $yv($w) eq $args} return
	set yv($w) $args
	if {[winfo ismapped $w]} { schedule }
}

# ---- painting ----

proc editor::paint {} {
	variable cv
	if {![winfo exists $cv]} return
	apply_theme
	ui::begin editor {}
	if {![llength [split::union]]} {
		hide_pages
		band_hide
		tabs::paint_welcome_strip
		welcome::paint
	} else {
		tabs::paint_strips
		split::draw_drop
		find::paint
		goto::paint
		foreach p [split::panes] { well::status $p }
		if {[overlay]} {
			# the pages under a list or a sheet are drawn as canvas text; a layer sits above them
			foreach p [split::panes] { overlay_text $p }
			ui::layer
			if {$::editor::sheet} { ui::fbox 0 0 $::editor::W $::editor::H -fill #000000 -alpha 0.5 }
			if {$::editor::pop} { tabs::popover {} }
			if {$::editor::sheet} { sheet::paint }
			hide_pages
			band_hide
		} else {
			# the focused pane is a Tk page; the other pane is drawn as text under a 42 % veil
			foreach p [split::panes] {
				if {$p != $split::cur} { drawn_pane $p }
			}
			place_live
		}
	}
	ui::finish
	if {[llength [split::union]] && ![overlay]} {
		well::paint
		raise [pagew $split::cur]
		raise [gutw $split::cur]
		band
		find::raise_menu
	}
	menu::lift
	remember_top
}

proc editor::pagew_live {} { pagew $split::cur }

# The focused pane's page and Well, where the body is; the other pane's are taken off the window.
proc editor::place_live {} {
	set top [body_top]
	set h [expr {$::editor::H - $top - 32}]
	foreach p {0 1} {
		if {![winfo exists [pagew $p]]} continue
		if {$p == $split::cur && [lsearch -exact [split::panes] $p] >= 0} {
			set x0 [split::px $p]
			place [pagew $p] -x [expr {$x0 + 72}] -y $top -width [expr {[split::pw $p] - 72}] -height $h
			place [gutw $p] -x $x0 -y $top -width 72 -height $h
		} else {
			place forget [pagew $p]
			place forget [gutw $p]
		}
	}
}

proc editor::hide_pages {} {
	foreach p {0 1} {
		if {[winfo exists [pagew $p]]} { place forget [pagew $p] }
		if {[winfo exists [gutw $p]]} { place forget [gutw $p] }
	}
}

# An unfocused pane: its text as canvas text, then the 42 % veil over its strip, text and status line.
proc editor::drawn_pane {p} {
	overlay_text $p
	gutter::draw_pane $p
	ui::fbox [split::px $p] 0 [split::pw $p] $::editor::H -fill #000000 -alpha 0.42
}

proc editor::overlay {} { expr {$::editor::pop || $::editor::sheet} }

# The top y of the page: under the tab strip (46) and the find bar or the Go to line row, when one is open.
proc editor::body_top {} { expr {46 + [find::height] + [goto::height]} }

# The first line of each shown document, so a drawn page starts where the Tk page does.
proc editor::remember_top {} {
	variable topof
	foreach p [split::panes] {
		set id [split::val $p active]
		if {$id eq ""} continue
		set t [tw $id $p]
		if {[winfo ismapped $t]} { set topof($t) [lindex [split [$t index @0,0] .] 0] }
	}
}

# A pane's visible lines as canvas text, in the code font (same advances as the text widget), in the token colours
# read back from its tags, clipped at the pane's edge. The gutter's numbers are drawn the same way.
proc editor::overlay_text {p} {
	variable cv
	variable codefont
	variable H
	variable topof
	set id [split::val $p active]
	if {$id eq ""} return
	set t [tw $id $p]
	set x0 [split::px $p]
	set xmax [expr {$x0 + [split::pw $p]}]
	set top [expr {[info exists topof($t)] ? $topof($t) : 1}]
	set cur [lindex [split [$t index insert] .] 0]
	set last [lindex [split [$t index end] .] 0]
	set sp1 [expr {max(0, (22 - [font metrics $codefont -linespace]) / 2)}]
	set body [body_top]
	$cv create rectangle $x0 $body [expr {$x0 + 72}] [expr {$H - 32}] -fill [well::background] -outline "" -tags page
	set rows [expr {($H - 32 - $body) / 22 + 1}]
	for {set row 0; set n $top} {$row < $rows && $n < $last} {incr row; incr n} {
		set y [expr {$body + $row * 22 + $sp1}]
		draw_code_line $t $n [expr {$x0 + 88}] $y $xmax
		$cv create text [expr {$x0 + 56}] [expr {$y + 1}] -text $n -anchor ne -font ui_i12 -tags page \
			-fill [expr {$p == $split::cur && $n == $cur ? $::editor::fg : $::editor::c(syn_num0)}]
	}
}

# One line of document T as canvas text at (X, Y), cut at XMAX: runs of one colour and font, each placed by the code
# font's measured advance of the text before it.
proc editor::draw_code_line {t n x y {xmax 100000}} {
	variable cv
	variable codefont
	variable fg
	set text [$t get $n.0 $n.end]
	set len [string length $text]
	while {$len > 0 && [font measure $codefont -displayof $cv [string range $text 0 [expr {$len - 1}]]] > $xmax - $x} {
		incr len -1
	}
	set text [string range $text 0 [expr {$len - 1}]]
	set len [string length $text]
	set runs {}
	for {set i 0} {$i < $len} {incr i} {
		set tag ""
		foreach nm [$t tag names $n.$i] { if {[string match syn_* $nm]} { set tag $nm } }
		lappend runs [expr {$tag eq "" ? [list $fg $codefont] : [list [$t tag cget $tag -foreground] [$t tag cget $tag -font]]}]
	}
	set start 0
	for {set i 1} {$i <= $len} {incr i} {
		if {$i < $len && [lindex $runs $i] eq [lindex $runs $start]} continue
		lassign [lindex $runs $start] col fnt
		set px [font measure $codefont -displayof $cv [string range $text 0 [expr {$start - 1}]]]
		$cv create text [expr {$x + $px}] $y -text [string range $text $start [expr {$i - 1}]] -anchor nw \
			-font $fnt -fill $col -tags page
		set start $i
	}
}

# ---- reload on external change: a clean document follows the file, a changed one says so ----

proc editor::tick {} {
	foreach id [split::union] { catch {::doc::check_disk $id} }
	schedule
	after $::editor::tickms editor::tick
}

# ---- start-up ----

proc editor::start {argv} {
	variable scene
	variable active
	variable docs
	variable codefont
	variable mono
	variable monosize
	set ::editor::scene [info exists ::env(RIBBON_EDITOR_SCENE)]
	editor::libraries
	hooks_install
	# the chrome's fonts, and the one monospace family for the text (the Ribbon Mono token: JetBrains Mono)
	ui::fonts
	apply_theme
	raster::init [file join [expr {[info exists ::env(XDG_CACHE_HOME)] ? $::env(XDG_CACHE_HOME) : "$::env(HOME)/.cache"}] ribbon editor]
	set codefont [font create ribbon-editor-code -family $mono -size [expr {-$monosize}]]   ;# pixels, as the boards
	build
	if {$scene} {
		uplevel #0 [list source -encoding utf-8 $::env(RIBBON_EDITOR_SCENE)]
	} else {
		set files {}
		foreach f $argv { if {$f ne "--"} { lappend files $f } }
		if {[llength $files]} {
			foreach f $files { open_path $f }
		}
		after $::editor::tickms editor::tick
	}
	paint
}

editor::start $argv
