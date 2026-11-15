# apppages.tcl - an app's pages: Overview (Props-A-Rail, Props-A11-Held),
# Permissions (Props-A2-Permissions), Storage (Props-A5-Storage), Libraries
# (Props-A6-Libraries) and Signature (Props-A7-Signature). What they show is
# kit's (kitlink.tcl); the kit actions in the footer go through kitlink.tcl
# to kit's own verbs. What kit can't say is left out, never made up.

namespace eval ap {
	variable E0 {}    ;# the permissions the app has (when the page opened, or last applied)
	variable E {}     ;# ... as edited
	variable DRV ""   ;# the drive the kit is on {label free size}
	variable liboff 0 ;# the first library row shown
}

proc ap::start {} {
	variable E0
	variable E
	variable DRV ""
	variable liboff 0
	if {[dict get $page::K notkit]} { set E0 {}; set E {}; return }
	if {[dict get $page::K programdir] ne ""} { set DRV [ap::drive [dict get $page::K programdir]] }
	set E0 [perms::effective $page::K]
	set E $E0
}

# Back to what is installed now (after grab, mend or toss).
proc ap::reload {} {
	set K $page::K
	if {[dict get $K file] ne ""} {
		set n [kitlink::kitfile [dict get $K file]]
	} else {
		set n [kitlink::installed [dict get $K name]]
	}
	if {$n eq ""} { return 0 }
	set p $page::S(page)
	page::open_app $n
	if {$p in [page::keys]} { set page::S(page) $p }
	return 1
}

proc ap::update {} { page::kit_do Grab [ap::target] ap::after }
proc ap::repair {} { page::kit_do Mend [dict get $page::K name] ap::after }
# Uninstall (Kit-Sheet-3): kit's toss plan and its data questions on one sheet, asked before
# anything goes; Yes runs kit toss, whose data questions the checkboxes answer.
proc ap::uninstall {} {
	lassign [kitlink::toss_plan [dict get $page::K name]] code rows data said
	if {$code != 0} { dlg::message "Couldn't uninstall it" [expr {$said ne "" ? $said : "kit stopped with code $code."}]; return }
	if {![llength $rows]} { dlg::message [dict get $page::K title] $said; return }
	page::plan_sheet $rows Uninstall? 1 [dict create data $data done ap::toss_go]
}
proc ap::toss_go {yes data} {
	if {!$yes} return
	set kitlink::data [dict create]
	foreach d $data { dict set kitlink::data [dict get $d name] [dict get $d on] }
	page::kit_do Toss [dict get $page::K name] ap::tossed
	set kitlink::data {}
}
proc ap::run {} { kitlink::run [dict get $page::K file] }
# What Update and Install hand to grab: the .kit file when it was opened, else the name.
proc ap::target {} {
	expr {[dict get $page::K file] ne "" && ![dict get $page::K installed] ? [dict get $page::K file] : [dict get $page::K name]}
}
proc ap::after {code} { if {$code == 0} { reload } }
proc ap::tossed {code} {
	if {$code != 0} return
	if {[dict get $page::K file] ne "" && ![catch {page::open_app [kitlink::kitfile [dict get $page::K file]]}]} return
	set page::dialog [dict create kind message title "[dict get $page::K title] is uninstalled" text "" label OK script page::quit]
	set ui::focus dok
}

# The footer every kit page has: Uninstall, Repair, Update; for a .kit that
# isn't installed, Run and Install.
proc ap::kit_footer {} {
	set K $page::K
	# no kit here (its library or Mk4tcl missing): nothing to offer
	# not a kit: Open starts it (Props-A9-NotKit), no kit actions
	if {[dict get $K notkit]} { page::footer [expr {[dict exists $K entry] && [dict exists [dict get $K entry] Exec] ? {{open Open primary ap::launch ext}} : {}}]; return }
	if {![kitlink::usable]} { page::footer {}; return }
	if {![dict get $K installed]} {
		set b [list [list install [expr {[dict get $K installedversion] ne "" ? "Update" : "Install"}] primary ap::update download]]
		if {[kitlink::kitcmd] ne ""} { lappend b {run Run field ap::run play} }
		page::footer $b
		return
	}
	# a held kit (Props-A11-Held): Update names the version it goes forward to, which lets the
	# hold go (kit grab KIT); Rewind is not offered, it is where it was taken back to
	set up Update
	if {[dict get $K held] && [dict get $K heldnew] ne ""} { set up "Update to [dict get [dict get $K heldnew] new]" }
	set b [list [list update $up primary ap::update download] {repair Repair field ap::repair wrench}]
	if {![dict get $K held] && [kitlink::previous [dict get $K name]]} { lappend b {rewind Rewind field ap::rewind undo} }
	page::footer $b {button {uninstall Uninstall ghost ap::uninstall trash}}
}

# Rewind: back to the earlier version (kit's history), after a confirm.
# Rewind (Kit-Sheet-4): kit rewind KIT asks "Rewind?" over its plan, on the sheet.
proc ap::rewind {} { page::kit_do Rewind [dict get $page::K name] ap::after }

# The status strip at the top of an Overview: ICON in a 36 px square (the soft accent when ACCENT),
# TITLE, the DETAIL runs {text colour}, and on the right TAG then the RIGHT texts, 14 apart.
proc ap::strip {y icon title detail right tag accent} {
	array set c [array get ui::c]
	ui::box 270 $y 790 64 -fill $c(field) -radius 12
	ui::ring 270 $y 790 64 12 $c(border) 1
	ui::box 284 [expr {$y + 14}] 36 36 -fill [expr {$accent ? $c(soft) : $c(pill)}] -radius 10
	ui::icon $icon 17 [expr {$accent ? $c(accent) : $c(fg)}] 293.5 [expr {$y + 23.5}] 2
	set ty [expr {$y + 23.5}]
	set x [expr {334 + [ui::text 334 $ty $title i14s $c(fg)] + 14}]
	foreach d $detail { lassign $d t col; set x [expr {$x + [ui::text $x $ty $t i14 $col w 0 {} 1]}] }
	set rx 1042
	foreach t [lreverse $right] { set rx [expr {$rx - [ui::text $rx [expr {$y + 24}] $t i13 $c(muted) e 0 {} 1] - 14}] }
	if {$tag ne ""} { ui::badge [expr {$rx - [ui::measure i11s $tag] - 14}] [expr {$y + 22}] $tag [expr {$tag eq "security"}] }
}

# "Ribbon kits · 31.0.1": the newest version the last index lists, or "Not listed".
proc ap::listed {} {
	set v ""
	foreach r [kitlink::index_records [dict get $page::K name]] {
		if {$v eq "" || [::kit::vcmp [dict get $r version] $v] > 0} { set v [dict get $r version] }
	}
	expr {$v eq "" ? "Not listed" : "Ribbon kits · $v"}
}

# A launcher entry's categories in words: "Utility · Text editor" (desktop and toolkit names left out).
proc ap::categories {cats} {
	set out {}
	foreach k [split $cats ";"] {
		if {$k eq "" || [string match X-* $k] || $k in {GTK Qt KDE GNOME XFCE LXQt Motif Java}} continue
		set w [regsub -all {([a-z])([A-Z])} $k {\1 \2}]
		lappend out "[string index $w 0][string tolower [string range $w 1 end]]"
	}
	join $out " · "
}

# A MIME type in words, from shared-mime-info: "Plain text", "Tcl script".
proc ap::type_name {m} {
	set t [regsub { document$} [facts::mime_comment $m] ""]
	return "[string toupper [string index $t 0]][string range $t 1 end]"
}

# Open: start the app as its launcher entry says (the field codes left out, in a terminal when it asks for one).
proc ap::launch {} {
	set e [dict get $page::K entry]
	set cmd [string map {%% %} [regsub -all {%[fFuUdDnNickvm]} [dict get $e Exec] ""]]
	if {[dict exists $e Terminal] && [string tolower [dict get $e Terminal]] eq "true"} { set cmd "ribbon-terminal -e $cmd" }
	exec sh -c "exec $cmd" >/dev/null 2>@1 &
}

# "Firefox 134.0.1 · kit from Ribbon kits"
proc ap::subtitle {} {
	set K $page::K
	if {[dict get $K notkit]} { return "Launcher entry · not a kit" }
	if {![dict get $K installed] && [dict get $K file] ne "" && [dict get $K installedversion] eq ""} {
		return "[file tail [dict get $K file]] · in [file tail [file dirname [dict get $K file]]]"
	}
	set s "[dict get $K title] [dict get $K version] · kit from [dict get $K source]"
}

proc ap::keyshort {v} {
	expr {[string length $v] < 30 ? $v : "[string range $v 0 5]…[string range $v end-5 end]"}
}

# "1 hour old"
proc ap::age {secs} {
	if {$secs eq ""} { return "" }
	foreach {unit n} {day 86400 hour 3600 minute 60} {
		if {$secs >= $n} { set k [expr {$secs / $n}]; return "$k $unit[expr {$k == 1 ? "" : "s"}] old" }
	}
	return "just now"
}

proc ap::sig_runs {} {
	set K $page::K
	switch -- [dict get $K sigstate] {
		valid { return {{i check} {t Valid}} }
		"" { return {} }
		invalid { return [list [list i warn $ui::c(accent)] {t {Not valid}}] }
		revoked { return [list [list i warn $ui::c(accent)] [list t "Key revoked [facts::date [dict get $K revoked]]"]] }
		unsigned { return {{t {Not signed}}} }
		untrusted { return [list {t {Signed by a key you don't trust}}] }
		default { return [list [list t [string totitle [dict get $K sigstate]]]] }
	}
}

# ---- Overview ---------------------------------------------------------------------------

proc page::draw_overview {} {
	variable K
	variable TOP
	array set c [array get ui::c]
	head Overview [ap::subtitle]
	set y $TOP
	set u [dict get $K update]
	set kitfile [expr {![dict get $K installed] && ![dict get $K notkit] && [dict get $K file] ne "" && [dict get $K installedversion] eq ""}]
	if {$u ne ""} {
		# a security update takes the accent (the shield on the soft accent, the tag in the accent)
		set sec [dict get $u security]
		set right [list [kitlink::fmtsize [dict get $u bytes]]]
		if {[dict get $u released] ne ""} { lappend right "Released [dict get $u released]" }
		ap::strip $y [expr {$sec ? "shield" : "download"}] [expr {$sec ? "Security update" : "Update waiting"}] \
			[list [list "[dict get $K version] → " $c(muted)] [list [dict get $u new] $c(fg)]] $right [expr {$sec ? "security" : ""}] $sec
		set y [expr {$y + 64 + 24}]
	} elseif {$kitfile} {
		# Props-A8-KitFile: a .kit that isn't installed; released when it was signed
		set right [list [kitlink::fmtsize [dict get $K size]]]
		if {[dict get $K sealed] ne ""} { lappend right "Released [string trim [clock format [dict get $K sealed] -format {%e %b}]]" }
		ap::strip $y file "Not installed" [list [list [dict get $K version] $c(muted)]] $right "" 0
		set y [expr {$y + 64 + 24}]
	} elseif {[dict get $K held]} {
		# Props-A11-Held: where it is held, what it was taken back from, what is waiting
		ui::box 270 $y 790 64 -fill $c(field) -radius 12
		ui::ring 270 $y 790 64 12 $c(border) 1
		ui::box 284 [expr {$y + 14}] 36 36 -fill $c(pill) -radius 10
		ui::icon pause 17 $c(fg) 293.5 [expr {$y + 23.5}] 2
		set ty [expr {$y + 23.5}]
		set x [expr {334 + [ui::text 334 $ty "Held at [dict get $K version]" i14s $c(fg) w 0 {} 1] + 14}]
		if {[dict get $K heldfrom] ne ""} {
			set t "Rewound from [dict get $K heldfrom]"
			if {[dict get $K heldwhen] ne ""} { append t " · [string trim [clock format [dict get $K heldwhen] -format {%e %b}]]" }
			ui::text $x $ty $t i14 $c(muted) w 0 {} 1
		}
		set rx 1042
		set hn [dict get $K heldnew]
		if {$hn ne ""} {
			set rx [expr {$rx - [ui::text $rx [expr {$y + 24}] "[dict get $hn new] waiting · [kitlink::fmtsize [dict get $hn bytes]]" i13 $c(muted) e 0 {} 1] - 14}]
		}
		ui::badge [expr {$rx - [ui::measure i11s held] - 14}] [expr {$y + 22}] held 0
		set y [expr {$y + 64 + 24}]
	}
	if {[dict get $K notkit]} {
		# Props-A9-NotKit: what its launcher entry says, and the types it opens
		set e [dict get $K entry]
		set rows [list [list Name [list [list t [dict get $K title]]]]]
		foreach {k key} {Description Comment Command Exec} {
			if {[dict exists $e $key]} { lappend rows [list $k [list [list t [page::clip i13 [dict get $e $key] 600]]]] }
		}
		set cats [ap::categories [dict get $K cats]]
		if {$cats ne ""} { lappend rows [list Categories [list [list t $cats]]] }
		lappend rows [list Terminal [list [list t [expr {[dict exists $e Terminal] && [string tolower [dict get $e Terminal]] eq "true" ? "Yes" : "No"}]]]]
		if {[dict get $K desktop] ne ""} {
			lappend rows [list Entry [list [list t [page::clip i13 [facts::tilde [dict get $K desktop]] 600]]] [list ext [list ap::show [file dirname [dict get $K desktop]]]]]
		}
		ui::label 270 $y {Launcher entry}
		set y [expr {[w::facts 270 [expr {$y + 22}] 790 $rows 44 96] + 22}]
		set types [expr {[dict exists $e MimeType] ? [lmap m [split [dict get $e MimeType] ";"] { if {$m eq ""} continue; set m }] : {}}]
		if {[llength $types]} {
			ui::label 270 $y Opens
			w::chips 270 [expr {$y + 22}] 790 [lmap m $types { list [expr {[string match text/* $m] || [string match *script $m] ? "doc" : [kindicon $m]}] [ap::type_name $m] "" "" }]
		}
		ap::kit_footer
		return
	}
	# the kit and its signature, side by side
	if {[dict get $K installed]} {
		set inst "For you · [facts::date [dict get $K when]]"
	} elseif {[dict get $K installedversion] ne ""} {
		set inst "[dict get $K installedversion] installed"
	} else { set inst "Not installed" }
	set left [list [list Version [list [list t [dict get $K version]]]] [list Size [list [list t [kitlink::fmtsize [dict get $K size]]]]]]
	if {$kitfile} {
		# where the file is, who it installs for, whether Ribbon kits lists it
		set dir [file dirname [dict get $K file]]
		lappend left [list File [list [list t [page::clip i13 [facts::tilde $dir] 220]]] [list ext [list ap::show $dir]]] \
			[list Installs [list [list t [expr {[dict get $K kitkind] eq "system" ? "For everyone" : "For you"}]]]] \
			[list Listed [list [list t [ap::listed]]]]
	} else {
		lappend left [list Installed [list [list t $inst]]]
		if {[dict get $K installed]} { lappend left [list {App data} [list [list t [kitlink::fmtsize [expr {[dict get $K data] eq "" ? 0 : [dict get $K data]}]]]]] }
		lappend left [list Source [list [list t [dict get $K source]]]]
	}
	lappend left [list Kit [list [list t [dict get $K short]]]]
	set right [list [list Signer [list [list t [expr {[dict get $K signer] ne "" ? [dict get $K signer] : "Unknown"}]]]]]
	if {[dict get $K key] ne "" || [dict get $K keyid] ne ""} {
		lappend right [list Key [list [list t [ap::keyshort [expr {[dict get $K key] ne "" ? [dict get $K key] : [dict get $K keyid]}]]]]]
	}
	lappend right [list Signature [ap::sig_runs]]
	if {[dict get $K checked] ne ""} {
		# a .kit's signature is checked as the page opens
		set when [expr {$kitfile && [clock seconds] - [dict get $K checked] < 60 ? "Just now" : [facts::when [dict get $K checked]]}]
		lappend right [list Checked [list [list t $when]]]
	}
	if {[dict get $K chunks] ne ""} {
		lappend right [list Chunks [expr {[dict get $K installed] ? [list {i check} [list t "[facts::commas [dict get $K chunks]] intact"]] : [list [list t [facts::commas [dict get $K chunks]]]]}]]
	}
	if {$kitfile} {
		if {[dict get $K sealed] ne ""} { lappend right [list Seal [list [list t "Signed [facts::date [dict get $K sealed]]"]]] }
	} elseif {[dict get $K indexage] ne ""} { lappend right [list Index [list [list t [ap::age [dict get $K indexage]]]]] }
	ui::label 270 $y Kit
	set y1 [w::facts 270 [expr {$y + 22}] 379 $left]
	ui::label 681 $y Signature
	set y2 [w::facts 681 [expr {$y + 22}] 379 $right]
	set y [expr {max($y1, $y2) + 24}]
	set chips [lmap a [perms::allowed $ap::E0] { lassign $a i l s; list $i $l $s [list page::go permissions] }]
	if {[llength $chips]} {
		# what a .kit asks for before it is installed; what is allowed once it is
		ui::label 270 $y [expr {[dict get $K installed] ? "Allowed" : "Requests"}]
		w::chips 270 [expr {$y + 22}] 790 $chips
		set y [expr {$y + 22 + 32 + 24}]
	}
	set libs [lmap l [dict get $K libs] { list "" [lindex $l 0] [lindex $l 1] [list page::go libraries] }]
	if {[llength $libs]} {
		ui::label 270 $y {Shared libraries}
		w::chips 270 [expr {$y + 22}] 790 $libs
	}
	ap::kit_footer
}

# ---- Permissions ----------------------------------------------------------------------------

proc ap::set_ {key v} {
	variable E
	set E [perms::set_ $E $key $v]
	page::draw
}
proc ap::flip {key} {
	variable E
	set v [perms::get $E $key]
	if {$key eq "network"} { set v [expr {$v eq "yes" ? "no" : "yes"}] } else { set v [expr {!$v}] }
	set_ $key $v
}
proc ap::undo {key} {
	variable E0
	set_ $key [perms::get $E0 $key]
}
proc ap::revert {} {
	variable E0
	variable E $E0
	page::draw
}
proc ap::apply {} {
	variable E0
	variable E
	set K $page::K
	if {[catch {kitlink::grants_write [dict get $K name] [perms::grants $K $E]} err]} {
		dlg::message "Can't save the permissions" $err
		return
	}
	dict set page::K grants [kitlink::grants_read [dict get $K name]]
	set E0 [perms::effective $page::K]
	set E $E0
	page::draw
}
proc ap::add_folder {} {
	set d [chooser::choose_folder -parent $app::win -title "Add a folder" -initialdir [facts::home] -mustexist 1]
	if {$d eq ""} return
	set h [facts::home]
	if {[string first $h/ $d] == 0} { set d [string range $d [string length $h/] end] }
	set_ folder:$d ro
}

proc page::draw_permissions {} {
	array set c [array get ui::c]
	variable TOP
	head Permissions [ap::subtitle]
	set E $ap::E
	set changed [perms::changed $ap::E0 $E]
	set acc {{none None} {ro {Read only}} {rw {Read & write}}}
	set rows {}
	foreach r [perms::rows $E] {
		lassign $r key label icon
		lappend rows [list $key $label $icon dd $acc]
	}
	set y [ap::perm_section 270 $TOP Files $rows $changed 1]
	set y [ap::perm_section 270 [expr {$y + 22}] Network {{network Network globe sw} {nested {Nested sandboxes} box sw}} $changed]
	set y [ap::perm_section 681 $TOP Devices [list \
		[list display Display monitor dd {{none None} {wayland Wayland} {x11 X11}}] \
		[list audio Audio vol dd {{0 Off x} {1 Playback vol} {mic {Playback and microphone} mic}}] \
		{gpu GPU chip sw} {camera Camera camera sw} {input Controllers pad sw} {screencast {Screen share} cast sw}] $changed 0 1]
	ap::perm_section 681 [expr {$y + 22}] Desktop {{notifications Notifications bell sw} {autostart {Start at login} power sw}} $changed
	set n [llength $changed]
	page::footer {{apply Apply primary ap::apply check} {revert Revert ghost ap::revert undo}} \
		[expr {$n ? [list text "$n change[expr {$n == 1 ? "" : "s"}]"] : ""}]
}

# A section of permission rows {key label icon sw|dd ?items?}, 48 tall;
# FILES adds "Add a folder…"; the last row has no line unless LASTLINE.
proc ap::perm_section {x y title rows changed {files 0} {lastline 0}} {
	array set c [array get ui::c]
	variable E
	ui::label $x $y $title
	set y [expr {$y + 22}]
	set n 0
	foreach r $rows {
		lassign $r key label icon kind items
		set ch [expr {$key in $changed}]
		set last [expr {!$files && !$lastline && $n == [llength $rows] - 1}]
		ui::icon $icon 16 [expr {$ch ? $c(fg) : $c(muted)}] [expr {$x + 1}] [expr {$y + 16}]
		ui::text [expr {$x + 30}] [expr {$y + 16}] $label [expr {$ch ? "i13s" : "i13m"}] $c(fg)
		set v [perms::get $E $key]
		if {$kind eq "sw"} {
			set cx [expr {$x + 379 - 38}]
			w::switch_ $key $cx [expr {$y + 13}] [expr {$v eq "yes" || $v eq "1"}] [list ap::flip $key]
		} else {
			set cx [expr {$x + 379 - 132}]
			w::dropdown $key $cx [expr {$y + 8}] 132 32 $items $v [list ap::set_ $key]
		}
		if {$ch} { w::undo [expr {$cx - 36}] [expr {$y + 11}] [list ap::undo $key] }
		if {!$last} { ui::hline $x [expr {$x + 379}] [expr {$y + 47}] $c(border) }
		set y [expr {$y + 48}]
		incr n
	}
	if {$files} {
		ui::icon plus 15 $c(muted) [expr {$x + 1.5}] [expr {$y + 16.5}] 2
		ui::text [expr {$x + 30}] [expr {$y + 16}] "Add a folder…" i13 $c(muted)
		ui::hit $x $y 379 48 {apply {{x y} { ap::add_folder }}}
		ui::focusable addfolder button $x [expr {$y + 8}] 160 32 8 ap::add_folder
		set y [expr {$y + 48}]
	}
	return $y
}

# ---- Storage (Props-A5-Storage) -----------------------------------------------------------------

# What the page shows, from the kit's facts K: {total libs nlibs rows} with rows
# {kind title path bytes}: the program (its store entry), each place it keeps data (without the
# caches inside), the caches, and the shared libraries it is locked to (totalled apart).
proc ap::storage {K} {
	set rows {}
	set total 0
	if {[dict get $K programsize] ne ""} {
		lappend rows [list program Program [dict get $K programdir] [dict get $K programsize]]
		incr total [dict get $K programsize]
	}
	foreach p [dict get $K datapaths] b [dict get $K datasizes] {
		if {$p eq "" || $b eq ""} continue
		lappend rows [list data {Profile and settings} $p $b]
		incr total $b
	}
	foreach p [dict get $K caches] b [dict get $K cachesizes] {
		if {$p eq "" || $b eq ""} continue
		lappend rows [list cache Cache $p $b]
		incr total $b
	}
	set libs 0; set n 0
	foreach l [dict get $K libs] {
		incr n
		if {[lindex $l 5] ne ""} { incr libs [lindex $l 5] }
	}
	if {$n} { lappend rows [list libs {Shared libraries} "$n librar[expr {$n == 1 ? "y" : "ies"}]" $libs] }
	dict create total $total libs $libs nlibs $n rows $rows
}

# The drive PATH is on: {label free size} in bytes, or "".
proc ap::drive {path} {
	while {$path ne "/" && ![file exists $path]} { set path [file dirname $path] }
	if {[catch {exec df -B1 --output=target,avail,size -- $path 2>/dev/null} df]} { return "" }
	lassign [lindex [split $df \n] 1] target avail size
	if {![string is integer -strict $avail] || ![string is integer -strict $size]} { return "" }
	list [lindex [facts::drive $path] 0] $avail $size
}

proc ap::show {p} { exec {*}[expr {[auto_execok ribbon-files] ne "" ? "ribbon-files" : "xdg-open"}] $p >/dev/null 2>@1 & }

# Clear: the cache directory DIR of this kit is emptied, and the page counts again.
proc ap::clear {dir} {
	if {[catch {kitlink::clear_cache [dict get $page::K name] $dir} err]} {
		dlg::message "Can't clear the cache" $err
		return
	}
	reload
	page::draw
}

# A 32 px square button of the rows: ICON, FIELD, radius 8.
proc ap::rowbutton {id x y icon script} {
	array set c [array get ui::c]
	ui::box $x $y 32 32 -fill $c(field) -radius 8
	ui::icon $icon 14 $c(fg) [expr {$x + 9}] [expr {$y + 9}] 2
	ui::hit $x $y 32 32 [list apply {{s x y} { uplevel #0 $s }} $script]
	ui::focusable $id button $x $y 32 32 8 $script
}

proc page::draw_storage {} {
	variable K
	variable TOP
	array set c [array get ui::c]
	head Storage [ap::subtitle]
	set S [ap::storage $K]
	ui::label 270 $TOP {Space used}
	set tw [ui::text 270 [expr {$TOP + 17}] [kitlink::fmtsize [dict get $S total]] sg34 $c(fg) w -0.68 {} 1]
	if {[dict get $S nlibs]} {
		ui::text [expr {270 + $tw + 12}] [expr {$TOP + 37}] "+ [kitlink::fmtsize [dict get $S libs]] of shared libraries" i13 $c(muted) w 0 {} 1
	}
	# the bar: the program, its data, its caches, 3 px apart
	array set part {program 0 data 0 cache 0}
	foreach r [dict get $S rows] { lassign $r kind - - b; if {$kind ne "libs"} { incr part($kind) $b } }
	set segs {}
	foreach {kind col} [list program $c(accent) data $c(muted) cache $c(border)] { if {$part($kind) > 0} { lappend segs [list $part($kind) $col] } }
	set by [expr {$TOP + 70}]
	if {![llength $segs]} { ui::box 270 $by 790 10 -fill $c(border) -radius 3 }
	set avail [expr {790 - 3 * ([llength $segs] - 1)}]
	set x 270.0
	foreach s $segs {
		lassign $s b col
		set w [expr {$avail * double($b) / [dict get $S total]}]
		ui::box $x $by [expr {max($w, 1)}] 10 -fill $col -radius 3
		set x [expr {$x + $w + 3}]
	}
	ui::label 270 [expr {$TOP + 106}] {On disk}
	set y [expr {$TOP + 128}]
	set n 0; set nc 0
	set rows [dict get $S rows]
	foreach r $rows {
		lassign $r kind title path b
		set sq [expr {$y + 27}]
		switch -- $kind {
			program { ui::box 274 $sq 10 10 -fill $c(accent) -radius 3 }
			data { ui::box 274 $sq 10 10 -fill $c(muted) -radius 3 }
			cache { ui::box 274 $sq 10 10 -fill $c(border) -radius 3 }
			libs { ui::ring 274 $sq 10 10 3 $c(muted) 1.5 }
		}
		ui::text 302 [expr {$y + 15}] $title i13s $c(fg)
		ui::text 302 [expr {$y + 34}] [clip i12 [expr {$kind eq "libs" ? $path : [facts::tilde $path]}] 600] i12 $c(muted)
		ui::text 974 [expr {$y + 24}] [kitlink::fmtsize $b] i13 $c(fg) e 0 {} 1
		switch -- $kind {
			cache {
				set bw [expr {12 + [ui::measure i13 Clear] + 8 + 13 + 12}]
				set bx [expr {1060 - $bw}]
				ui::box $bx [expr {$y + 16}] $bw 32 -fill $c(field) -radius 8
				ui::text [expr {$bx + 12}] [expr {$y + 24}] Clear i13 $c(fg)
				ui::icon trash 13 $c(fg) [expr {$bx + $bw - 25}] [expr {$y + 25.5}] 2
				ui::hit $bx [expr {$y + 16}] $bw 32 [list apply {{d x y} { ap::clear $d }} $path]
				ui::focusable clear$nc button $bx [expr {$y + 16}] $bw 32 8 [list ap::clear $path]
				incr nc
			}
			libs { ap::rowbutton golibs 1028 [expr {$y + 16}] chevr {page::go libraries} }
			default { ap::rowbutton open$n 1028 [expr {$y + 16}] ext [list ap::show $path] }
		}
		if {$n < [llength $rows] - 1} { ui::hline 270 1060 [expr {$y + 63}] $c(border) }
		set y [expr {$y + 64}]
		incr n
	}
	set d $ap::DRV
	if {$d ne "" && $y + 22 + 52 <= 648} {
		lassign $d label free size
		ui::label 270 [expr {$y + 22}] Drive
		ui::text 270 [expr {$y + 58}] $label i13 $c(muted)
		set x [expr {394 + [ui::text 394 [expr {$y + 58}] "[kitlink::fmtsize $free] free" i13 $c(fg) w 0 {} 1] + 8}]
		ui::text $x [expr {$y + 58}] "of [kitlink::fmtsize $size]" i13 $c(muted) w 0 {} 1
	}
	ap::kit_footer
}

# ---- Libraries (Props-A6-Libraries) ---------------------------------------------------------

# The range a kit accepts, as the board writes it: ">=1.14" is "≥ 1.14", ">=7 <8" is "7.x",
# ">=1.6 <1.7" is "1.6.x"; anything else as the manifest has it.
proc ap::accepts {range} {
	set r [string trim [join $range]]
	if {[regexp {^>=\s*([0-9]+(?:\.[0-9]+)*)\s+<\s*([0-9]+(?:\.[0-9]+)*)$} $r -> lo hi]} {
		set a [split $lo .]; set b [split $hi .]
		for {set n 1} {$n <= [llength $a]} {incr n} {
			set head [lrange $a 0 [expr {$n - 1}]]
			set up [lreplace $head end end [expr {[scan [lindex $head end] %d] + 1}]]
			if {$up eq $b && [lsearch -not -regexp [lrange $a $n end] {^0+$}] < 0} { return "[join $head .].x" }
		}
	}
	set out {}
	foreach part [regexp -all -inline {(?:>=|<=|>|<|=)?\s*[^\s<>=]+} $r] {
		regexp {^(>=|<=|>|<|=)?\s*(.*)$} $part -> op v
		lappend out [string trim "[dict get {>= ≥ <= ≤ > > < < = {} {} {}} $op] $v"]
	}
	join $out " "
}

# "22 kits", or "Firefox only" when nothing else is locked to it.
proc ap::usedby {n} {
	if {$n eq ""} { return "" }
	if {$n <= 1} { return [list "[dict get $page::K title] only" 1] }
	list "$n kits" 0
}

proc ap::libscroll {max d} {
	variable liboff
	set o [expr {max(0, min($max, $liboff + $d))}]
	if {$o != $liboff} { set liboff $o; page::draw }
}
proc ap::libkey {max sym} {
	switch -- $sym {
		Up { libscroll $max -1 } Down { libscroll $max 1 }
		Prior { libscroll $max -12 } Next { libscroll $max 12 }
		default { return 0 }
	}
	return 1
}

proc page::draw_libraries {} {
	variable K
	variable TOP
	array set c [array get ui::c]
	head Libraries [ap::subtitle]
	set libs [dict get $K libs]
	set n [llength $libs]
	ui::label 270 [expr {$TOP + 2}] {Shared libraries}
	set total 0; set sized 0
	foreach l $libs { if {[lindex $l 5] ne ""} { incr total [lindex $l 5]; set sized 1 } }
	set note "$n librar[expr {$n == 1 ? "y" : "ies"}]"
	if {$sized} { append note " · [kitlink::fmtsize $total]" }
	ui::text 1060 $TOP $note i13 $c(muted) e 0 {} 1
	set y [expr {$TOP + 24}]
	# the columns a kit that isn't installed has nothing for (what is used, by whom, how big) are left out
	set inst [dict get $K installed]
	ui::label 270 [expr {$y + 8}] Library
	if {$inst} { ui::label 588 [expr {$y + 8}] Version }
	ui::label [expr {$inst ? 724 : 588}] [expr {$y + 8}] Accepts
	if {$inst} {
		ui::label 860 [expr {$y + 8}] {Used by}
		ui::text 1060 [expr {$y + 8}] SIZE i11s $c(muted) e 1.32
	}
	ui::hline 270 1060 [expr {$y + 29}] $c(border)
	set y [expr {$y + 30}]
	set max [expr {max(0, $n - 12)}]
	set ap::liboff [expr {min($ap::liboff, $max)}]
	set shown [lrange $libs $ap::liboff [expr {$ap::liboff + 11}]]
	set i 0
	foreach l $shown {
		lassign $l short ver range full users size
		ui::icon layers 14 $c(muted) 270 [expr {$y + 12}] 1.9
		ui::text 294 [expr {$y + 11}] [clip i13m $short 280] i13m $c(fg)
		if {$inst} { ui::text 588 [expr {$y + 11}] $ver i13 $c(fg) w 0 {} 1 }
		ui::text [expr {$inst ? 724 : 588}] [expr {$y + 11}] [ap::accepts $range] i13 $c(muted) w 0 {} 1
		if {$inst} {
			lassign [ap::usedby $users] ut only
			ui::text 860 [expr {$y + 11}] $ut i13 [expr {$only ? $c(fg) : $c(muted)}] w 0 {} 1
			if {$size ne ""} { ui::text 1060 [expr {$y + 11}] [kitlink::fmtsize $size] i13 $c(fg) e 0 {} 1 }
		}
		# rules between the rows, none under the last one shown
		if {[incr i] < [llength $shown]} { ui::hline 270 1060 [expr {$y + 37}] $c(border) }
		set y [expr {$y + 38}]
	}
	if {$max} {
		ui::wheel 270 [expr {$TOP + 54}] 790 456 [list ap::libscroll $max]
		ui::focusable libs list 270 [expr {$TOP + 54}] 790 456 8 [list ap::libkey $max]
	}
	ap::kit_footer
}

# ---- Signature (Props-A7-Signature) -----------------------------------------------------------

# The chain of trust, top down: {icon title sub ok} tiles. The root that signs the key list
# (when kit has one), the key that signed this kit, the kit's seal, its chunks.
proc ap::chain {K} {
	set now [clock seconds]
	set out {}
	set st [dict get $K sigstate]
	if {[dict get $K listserial] ne ""} {
		set sub "Signed key list [dict get $K listserial]"
		set exp [dict get $K listexpires]
		set ok 1
		if {$exp ne "" && $exp > 0} {
			set ok [expr {$now < $exp}]
			append sub " · [expr {$ok ? "Expires" : "Expired"}] [facts::date $exp]"
		}
		lappend out [list key [expr {[dict get $K rootname] ne "" ? [dict get $K rootname] : "Root key"}] $sub $ok]
	}
	if {[dict get $K keyid] ne ""} {
		set parts {}
		if {[llength [dict get $K keyroles]]} { lappend parts [ap::roles [dict get $K keyroles]] }
		set ok [expr {$st ni {untrusted revoked}}]
		if {[dict get $K revoked] ne ""} {
			lappend parts "Revoked [facts::date [dict get $K revoked]]"
		} elseif {[dict get $K keyuntil] ne ""} {
			set live [expr {$now < [dict get $K keyuntil] && ([dict get $K keyfrom] eq "" || $now >= [dict get $K keyfrom])}]
			if {!$live} { set ok 0 }
			lappend parts "[expr {$now < [dict get $K keyuntil] ? "Valid until" : "Ended"}] [facts::date [dict get $K keyuntil]]"
		} elseif {$st eq "untrusted"} { lappend parts "Not a key you trust" }
		lappend out [list key [expr {[dict get $K signer] ne "" ? [dict get $K signer] : [dict get $K keyid]}] [join $parts " · "] $ok]
	}
	set sub Seal
	switch -- $st {
		unsigned - "" { append sub " · Not signed" }
		invalid { append sub " · Signature not valid" }
		default { if {[dict get $K sealed] ne ""} { append sub " · Signed [facts::date [dict get $K sealed]]" } }
	}
	lappend out [list box "[dict get $K title] [dict get $K version]" $sub [expr {$st in {valid revoked}}]]
	if {[dict get $K chunks] ne ""} {
		set nc [dict get $K chunks]
		set sub ""; set ok ""
		if {[dict get $K installed]} {
			set sub "Every chunk intact"
			if {[dict get $K checked] ne ""} { append sub " · Checked [ap::lcfirst [facts::when [dict get $K checked]]]" }
			set ok 1
		}
		lappend out [list layers "[facts::commas $nc] chunk[expr {$nc == 1 ? "" : "s"}]" $sub $ok]
	}
	return $out
}
proc ap::roles {roles} { join [lmap r $roles { dict get {app {App kits} system {System kits} index {The index}} $r }] {, } }
# "Today, 09:12" inside a sentence: "today, 09:12"
proc ap::lcfirst {s} { expr {[regexp {^(Today|Yesterday)} $s] ? "[string tolower [string index $s 0]][string range $s 1 end]" : $s} }
# "9f2c 7d1e … 41ab"
proc ap::hashshort {h} {
	expr {[string length $h] < 16 ? $h : "[string range $h 0 3] [string range $h 4 7] … [string range $h end-3 end]"}
}

proc page::draw_signature {} {
	variable K
	variable TOP
	array set c [array get ui::c]
	head Signature [ap::subtitle]
	ui::label 270 $TOP {Chain of trust}
	set chain [ap::chain $K]
	set y [expr {$TOP + 28}]
	set i 0
	foreach t $chain {
		lassign $t icon title sub ok
		w::tile 270 $y $icon 44 19 12
		if {$i < [llength $chain] - 1} { ui::box 291 [expr {$y + 52}] 2 40 -fill $c(border) -radius 1 }
		ui::text 328 [expr {$y + ($sub eq "" ? 13 : 3)}] [clip i14s $title 290] i14s $c(fg)
		ui::text 328 [expr {$y + 23}] [clip i12 $sub 290] i12 $c(muted) w 0 {} 1
		if {$ok ne ""} {
			if {$ok} { ui::icon check 16 $c(accent) 633 [expr {$y + 13}] 2.4 } else { ui::icon warn 16 $c(accent) 633 [expr {$y + 13}] 2 }
		}
		set y [expr {$y + 100}]
		incr i
	}
	# the details: only what kit says
	set rows [list [list Signer [list [list t [expr {[dict get $K signer] ne "" ? [dict get $K signer] : "Unknown"}]]]]]
	if {[dict get $K key] ne "" || [dict get $K keyid] ne ""} {
		lappend rows [list Key [list [list t [ap::keyshort [expr {[dict get $K key] ne "" ? [dict get $K key] : [dict get $K keyid]}]]]]]
	}
	if {[llength [dict get $K keyroles]]} { lappend rows [list Role [list [list t [ap::roles [dict get $K keyroles]]]]] }
	if {[dict get $K keyuntil] ne ""} {
		lappend rows [list Valid [list [list t "[facts::date [dict get $K keyfrom]] – [facts::date [dict get $K keyuntil]]"]]]
	}
	lappend rows [list Signature [ap::sig_runs]]
	if {[dict get $K listserial] ne ""} {
		lappend rows [list Revoked [list [list t [expr {[dict get $K revoked] ne "" ? [facts::date [dict get $K revoked]] : "None"}]]]]
	}
	if {[dict get $K manifest] ne ""} { lappend rows [list Manifest [list [list t [ap::hashshort [dict get $K manifest]]]]] }
	if {[dict get $K checked] ne ""} { lappend rows [list Checked [list [list t [facts::when [dict get $K checked]]]]] }
	set idx {}
	if {[dict get $K indexage] ne ""} { lappend idx [ap::age [dict get $K indexage]] }
	if {[dict get $K listserial] ne ""} { lappend idx "key list [dict get $K listserial]" }
	if {[llength $idx]} { lappend rows [list Index [list [list t [join $idx " · "]]]] }
	ui::label 681 $TOP Details
	w::facts 681 [expr {$TOP + 22}] 379 $rows 44 96
	ap::kit_footer
}
