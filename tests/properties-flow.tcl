# properties-flow.tcl - drive Properties with clicks and keys and check
# what it changes: a file renamed, its access and owner changed with
# Apply (through pkexec, stubbed, only where it is needed) and Revert, the
# app that opens it, a folder counted; an app's permissions edited, undone,
# reverted and applied to kit's grants file; and, when kit's library and
# Mk4tcl are there, a .kit installed, repaired and uninstalled through
# kit's own grab, mend and toss with the prompt drawn as a sheet; its Storage
# page's Clear emptying its cache; and (PROPS_KIT2, a 2.0 in a pinned signed
# index) updated, rewound and held at 1.0 (Props-A11-Held), then taken
# forward again by "Update to 2.0".
# RIBBON_PROPERTIES_SCENE=this file; tests/test-properties.sh sets up the
# home (tests/properties-fixture.tcl), the pkexec stub and the kit.
# Exits 1 if a check fails.
proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
set ::fails 0
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr ::fails }
}
proc key {sym {char ""} {state 0}} { update; page::key $sym $char $state; update }
proc type {text} { foreach ch [split $text ""] { update; page::key [expr {$ch eq " " ? "space" : $ch}] $ch 0 }; update }
proc click {x y} { update; ui::press [expr {$x + $ui::ox}] [expr {$y + $ui::oy}]; ui::release [expr {$x + $ui::ox}] [expr {$y + $ui::oy}]; update }
proc slurp {f} { set fh [open $f]; fconfigure $fh -encoding utf-8; set d [read $fh]; close $fh; return $d }
# the middle of what Tab reaches as ID
proc at {id} {
	update
	set f [lsearch -inline -index 0 $ui::focusables $id]
	if {$f eq ""} { error "nothing called $id on the page" }
	lassign $f - - x y w h
	list [expr {$x + $w / 2.0}] [expr {$y + $h / 2.0}]
}
proc press {id} { click {*}[at $id] }
# the open menu's item LABEL
proc pick {label} {
	update
	set m $page::menu
	set i [lsearch -index 1 [dict get $m items] $label]
	if {$i < 0} { error "no $label in the menu" }
	set h [expr {12 + 32 * [llength [dict get $m items]]}]
	set y [dict get $m y]
	if {$y + $h > 712} { set y [expr {[dict get $m top] - 8 - $h}] }
	click [expr {[dict get $m x] - 60}] [expr {$y + 6 + 32 * $i + 16}]
}
# kit's prompt: once its sheet is up, record it and press ID (pyes / pno)
proc answer {id {n 0}} {
	if {$page::dialog ne "" && [dict get $page::dialog kind] eq "plan"} {
		set ::sheet $page::dialog
		press $id
		return
	}
	if {$n < 200 && ($page::dialog eq "" || [dict get $page::dialog kind] eq "plan")} { after 50 [list answer $id [incr n]] }
}
# a click on whatever runs SCRIPT (chips have no focus)
proc hit {pattern} {
	update
	foreach h [lreverse $ui::hits] {
		lassign $h x0 y0 x1 y1 s
		if {[string match $pattern $s]} { click [expr {($x0 + $x1) / 2.0}] [expr {($y0 + $y1) / 2.0}]; return }
	}
	error "nothing on the page runs $pattern"
}
proc settle {} {
	set n 0
	while {$page::S(busy) && $n < 600} { after 50; update; incr n }
	update
}
proc pklog {} { expr {[file exists $::env(PKEXEC_LOG)] ? [slurp $::env(PKEXEC_LOG)] : ""} }
proc mode {p} { format %03o [expr {[file attributes $p -permissions] & 0777}] }

set home $::env(HOME)
set dir [file join $home Pictures Iceland]
set photo [file join $dir Jökulsárlón.jpg]

# ---- a file -------------------------------------------------------------------------------
page::open path $photo
page::draw
update
file stat $photo st
check "a picture: General only in the rail (its Photo page was ruled out)" {[page::keys] eq {general}}
check "  its real size, name and owner" {[dict get $page::F size] == $st(size) && [dict get $page::F name] eq "Jökulsárlón.jpg" &&
	[dict get $page::F owner] eq [file attributes $photo -owner]}
check "  its type from its contents (a PNG, whatever the name)" {[dict get $page::F mime] eq "image/png" && $page::S(sub) eq "PNG image"}
check "  its dimensions" {$fp::dims eq {379 204}}
check "  opens with the default from mimeapps.list, then the others" {[lindex $fp::handlers 0] eq "org.ribbon.imageviewer.desktop" &&
	[lrange [lindex $fp::handlers 1] 0 2] eq {darkroom.desktop firefox.desktop paint.desktop}}

# rename: the name field, Enter applies
press name
key u u 4
type "Glacier lagoon.jpg"
key Return
settle
set new [file join $dir {Glacier lagoon.jpg}]
check "rename: the file has its new name" {[file exists $new] && ![file exists $photo]}
check "  the window shows it" {$page::S(title) eq "Glacier lagoon" && [ui::fval name] eq "Glacier lagoon.jpg"}
check "  no pkexec for your own folder" {[pklog] eq ""}

# access: Group none, Everyone read & write; Revert first
file attributes $new -permissions 0644
page::open_file $new
page::draw
press g
check "a dropdown opens its menu" {[dict size $page::menu] && [dict get $page::menu id] eq "g"}
pick None
check "  the choice is made" {$fp::E(g) eq "none" && ![dict size $page::menu]}
press revert
check "Revert puts it back" {$fp::E(g) eq "ro"}
press g; pick None
press o; pick {Read & write}
# as someone who doesn't own the file: chmod through pkexec
proc fp::uid {} { return 1000 }
press apply
settle
check "Apply: Group none, Everyone read & write (0606)" {[mode $new] eq "606"}
check "  through pkexec, the file not being yours" {[string match "*chmod 0606 -- $new*" [pklog]]}
check "  the page shows what is on disk" {$fp::E0(g) eq "none" && $fp::E0(o) eq "rw"}

# your own file: no pkexec
set mine [file join $dir notes.txt]
set fh [open $mine w]; puts $fh "notes"; close $fh
file attributes $mine -owner 1000 -permissions 0600
set before [pklog]
page::open path $mine
page::draw
press g; pick {Read only}
press apply
settle
check "your own file: chmod without pkexec" {[mode $mine] eq "640" && [pklog] eq $before}
check "  a text file has only General" {[page::keys] eq {general}}

# a new owner: always through pkexec
proc facts::users {} { return {root nobody} }
page::draw
press owner
pick nobody
press apply
settle
check "Owner: chown through pkexec" {[file attributes $mine -owner] eq "nobody" && [string match "*chown -- nobody $mine*" [pklog]]}
proc fp::uid {} { exec id -u }

# opens with: a chip makes it the app; Apply writes mimeapps.list
page::open_file $new
page::draw
hit "*fp::set_ opens darkroom.desktop*"
check "a chip chooses the app" {$fp::E(opens) eq "darkroom.desktop"}
press apply
settle
check "  Apply makes it the default for the type" {[regexp -line {^image/png=darkroom.desktop$} [slurp [file join $::env(XDG_CONFIG_HOME) mimeapps.list]]]}
check "  the other defaults are kept" {[regexp -line {^image/jpeg=org.ribbon.imageviewer.desktop$} [slurp [file join $::env(XDG_CONFIG_HOME) mimeapps.list]]]}
check "  and it shows" {[lindex $fp::handlers 0] eq "darkroom.desktop"}

# a name that can't be
press name
key u u 4
type "a/b"
key Return
check "a name with a slash is refused" {$page::dialog ne "" && [file exists $new]}
key Escape

# ---- a folder ---------------------------------------------------------------------------------
page::open path $dir
page::draw
set n 0
while {$facts::W(busy) && $n < 400} { after 20; update; incr n }
set files [glob -directory $dir *]
set bytes 0; foreach f $files { incr bytes [file size $f] }
check "a folder: General only (its Contents page was ruled out)" {[page::keys] eq {general}}
check "  counted: its files and their size" {$facts::W(files) == [llength $files] && $facts::W(bytes) == $bytes}
check "  the newest pictures, newest first" {[file tail [lindex $facts::W(newest) 0 1]] eq "Fjallsárlón.png"}
check "  no Photo or Contents page to draw" {[info commands page::draw_photo] eq "" && [info commands page::draw_contents] eq ""}

# ---- an app's permissions --------------------------------------------------------------------------
set K [kitlink::empty]
set K [dict merge $K [dict create name org.example.notes short notes title Notes kind {Note taker} version 1.0 \
	perms {{network yes} {folders {Downloads rw}} {display wayland}} installed 1 notkit 0]]
page::open_app $K
page::go permissions
page::draw
update
press folder:Pictures
pick {Read only}
press input
check "two changes: the count, the rows marked" {[lsort [perms::changed $ap::E0 $ap::E]] eq {folder:Pictures input}}
hit "*ap::undo input*"
check "a row's undo puts that one back" {[perms::changed $ap::E0 $ap::E] eq {folder:Pictures}}
press revert
check "Revert: no changes" {[perms::changed $ap::E0 $ap::E] eq {}}
press folder:Pictures; pick {Read only}
press input
press apply
set gf [file join $::env(XDG_CONFIG_HOME) kit grants org.example.notes]
check "Apply writes kit's grants file" {[file exists $gf] && [slurp $gf] eq "ribbon-kit-grants 1\nperm\tfolders\tDownloads rw Pictures ro\nperm\tinput\t1\n"}
check "  and the page has them as applied" {[perms::changed $ap::E0 $ap::E] eq {} && [perms::get $ap::E0 folder:Pictures] eq "ro"}
check "  the Overview lists them" {[lsearch -index 1 [perms::allowed $ap::E0] Pictures] >= 0 && [lsearch -index 1 [perms::allowed $ap::E0] Controllers] >= 0}
press display; pick None
press apply
check "a grant can take away what the kit asks for" {[string match "*perm\tdisplay\tnone*" [slurp $gf]]}
press display; pick Wayland
press input
press folder:Pictures; pick None
press apply
check "back to what the kit asks for: no grants file" {![file exists $gf]}

# ---- it follows the active theme ----------------------------------------------------------------
set pf [page::palette_file]
set before $ui::c(accent)
page::watch_theme
file copy -force [file join $::appdir .. themes palettes ribbon-fjord.conf] $pf
file mtime $pf [expr {[clock seconds] + 5}]
page::watch_theme
update
check "a new palette from ribbon-theme: the window redraws in it" {$before ne $ui::c(accent) && [string toupper $ui::c(accent)] eq "#5FE3C0"}

# ---- kit itself: install a .kit, repair it, uninstall it ----------------------------------------------
if {[info exists ::env(PROPS_KIT)] && [kitlink::load]} {
	set kf $::env(PROPS_KIT)
	page::open path $kf
	page::go overview
	page::draw
	update
	check "a .kit file: its facts from the file" {[dict get $page::K name] eq "org.example.notes" && ![dict get $page::K installed] &&
		[dict get $page::K title] eq "Notes" && [dict get $page::K sigstate] eq "valid"}
	check "  Install and Run in its footer" {[lsearch -index 0 $ui::focusables install] >= 0 && [lsearch -index 0 $ui::focusables run] >= 0}
	# Props-A8: the File row's link shows the folder the .kit is in
	rename ap::show ap::show_real
	proc ap::show {p} { set ::shown $p }
	set ::shown ""
	hit "*ap::show *"
	check "  its File row opens the folder it is in" {$::shown eq [file dirname [file normalize $kf]]}
	rename ap::show {}
	rename ap::show_real ap::show
	# kit's prompt comes up as a sheet; its button answers
	set ::sheet ""
	after 50 {answer pyes}
	press install
	settle
	if {$::sheet ne "" && [dict get $::sheet kind] ne "plan"} { puts "       ([dict get $::sheet title]: [dict get $::sheet text])" }
	if {$page::dialog ne "" && [dict get $page::dialog kind] ne "plan"} { puts "       ([dict get $page::dialog title]: [dict get $page::dialog text])" }
	if {$::sheet eq ""} { puts "       (no sheet; [expr {$page::dialog ne "" ? [dict get $page::dialog text] : "no dialog"}])"; set ::sheet {kind none question {} rows {{action none}}} }
	check "Install: kit's prompt as a sheet, its question on the button" {[dict get $::sheet kind] eq "plan" && [dict get $::sheet question] eq "Install?" &&
		[dict get [lindex [dict get $::sheet rows] 0] action] eq "install"}
	check "  installed by kit's grab" {[dict get $page::K installed] && [::kit::store::findLive [::kit::store::load] org.example.notes] ne ""}
	check "  Uninstall, Repair, Update now" {[lsearch -index 0 $ui::focusables uninstall] >= 0 && [lsearch -index 0 $ui::focusables repair] >= 0}
	page::draw; update
	check "  the launcher entry kit made starts it with kit run" {[kitlink::for_exec [slurp [file join $::env(XDG_DATA_HOME) applications kit-org.example.notes.desktop]]] eq "org.example.notes"}
	press repair
	settle
	check "Repair: kit's mend says it is fine" {$page::dialog ne "" && [string match "*ok*" [dict get $page::dialog text]]}
	key Escape
	press uninstall
	check "Uninstall asks first, on one sheet: kit's toss plan, Uninstall? on the button (Kit-Sheet-3)" {$page::dialog ne "" &&
		[dict get $page::dialog kind] eq "plan" && [dict get $page::dialog question] eq "Uninstall?" &&
		[lmap r [dict get $page::dialog rows] { list [dict get $r fullname] [dict get $r action] }] eq {{org.example.notes remove}}}
	check "  nothing is removed before Yes" {[::kit::store::findLive [::kit::store::load] org.example.notes] ne ""}
	press pyes
	settle
	check "  tossed by kit's toss" {[::kit::store::findLive [::kit::store::load] org.example.notes] eq ""}
	check "  the window shows the .kit file again" {![dict get $page::K installed] && [lsearch -index 0 $ui::focusables install] >= 0}
	# Cancel on the sheet: nothing installed, kit says you said no
	after 50 {answer pno}
	press install
	settle
	check "Cancel on the sheet installs nothing" {![dict get $page::K installed] && [::kit::store::findLive [::kit::store::load] org.example.notes] eq ""}

	# what each footer offers: page::footer's buttons, recorded as it draws them
	rename page::footer page::footer_drawn
	proc page::footer {b args} { set ::footer [lmap x $b { lindex $x 1 }]; page::footer_drawn $b {*}$args }

	# Storage (Props-A5): the program, its data and its cache, with Clear emptying the cache
	after 50 {answer pyes}
	press install
	settle
	set ad [::kit::path appdata org.example.notes]
	file mkdir $ad/.cache/thumbs
	foreach f {a b thumbs/c} { set fh [open $ad/.cache/$f w]; puts $fh [string repeat x 5000]; close $fh }
	set fh [open $ad/notes.db w]; puts $fh data; close $fh
	ap::reload
	page::go storage
	update
	set sto [ap::storage $page::K]
	check "Storage: the program, its data and its cache, each with its size" {[lmap r [dict get $sto rows] { lindex $r 0 }] eq {program data cache} &&
		[lindex [dict get $sto rows] 2 2] eq "$ad/.cache" && [lindex [dict get $sto rows] 2 3] >= 15000 && [lindex [dict get $sto rows] 1 3] < 1000 &&
		[lindex [dict get $sto rows] 0 3] > 0}
	press clear0
	update
	if {$page::dialog ne ""} { puts "       ([dict get $page::dialog title]: [dict get $page::dialog text])" }
	check "  Clear empties the cache; the folder and the app's own data stay" {[file isdirectory $ad/.cache] &&
		![llength [lmap f [glob -nocomplain -tails -directory $ad/.cache * .*] { if {$f in {. ..}} continue; set f }]] && [file exists $ad/notes.db] && $page::S(page) eq "storage"}
	check "  and the page counts again: no cache left to clear" {[lsearch -index 0 $ui::focusables clear0] < 0 || [lindex [dict get [ap::storage $page::K] rows] 2 3] == 0}

	# held (Props-A11): 1.0, updated to 2.0, then Rewind takes it back and holds it at 1.0
	if {[info exists ::env(PROPS_KIT2)]} {
		page::open path $::env(PROPS_KIT2)
		page::draw
		update
		check "a newer .kit of an installed kit: Update" {[dict get $page::K installedversion] eq "1.0" && [lsearch -index 0 $ui::focusables install] >= 0}
		after 50 {answer pyes}
		press install
		settle
		check "a newer .kit updates it (kit grab FILE)" {[dict get $page::K installed] && [dict get $page::K version] eq "2.0"}
		page::open kit org.example.notes
		page::draw; update
		check "  Rewind is offered" {[lsearch -index 0 $ui::focusables rewind] >= 0}
		set ::sheet ""
		after 50 {answer pyes}
		press rewind
		settle
		page::draw; update
		check "  kit's prompt as a sheet: Rewind?" {$::sheet ne "" && [dict get $::sheet question] eq "Rewind?"}
		check "  back at 1.0 and held there" {[dict get $page::K version] eq "1.0" && [dict get $page::K held] &&
			"org.example.notes" in [dict get [::kit::store::load] holds]}
		check "  the held strip: rewound from 2.0, 2.0 waiting in the index" {[dict get $page::K heldfrom] eq "2.0" && [dict get $page::K heldwhen] ne "" &&
			[dict get [dict get $page::K heldnew] new] eq "2.0"}
		check "  the footer: Update to 2.0 and Repair, no Rewind" {$::footer eq {{Update to 2.0} Repair} && [lsearch -index 0 $ui::focusables rewind] < 0}
		set ::sheet ""
		after 50 {answer pyes}
		press update
		settle
		check "Update to 2.0: kit's prompt, Update?" {$::sheet ne "" && [dict get $::sheet question] eq "Update?"}
		check "  at 2.0, the hold let go (kit grab KIT)" {[dict get $page::K version] eq "2.0" && ![dict get $page::K held] &&
			"org.example.notes" ni [dict get [::kit::store::load] holds] && [lindex $::footer 0] eq "Update"}
	} else {
		puts "  skip the held kit (no second .kit: PROPS_KIT2 unset)"
	}
	# a message left open (Esc with none open would close the window)
	if {$page::dialog ne ""} { key Escape }
	page::open kit org.example.notes
	page::draw
	press uninstall
	update
	set dq [expr {$page::dialog ne "" && [dict get $page::dialog kind] eq "plan" ? [dict get $page::dialog data] : {}}]
	check "Uninstall with data: toss's own question as a checkbox on the sheet, off" {[llength $dq] == 1 &&
		[string match "Also remove its data in *?" [dict get [lindex $dq 0] q]] && ![dict get [lindex $dq 0] on] && [dict get $page::dialog question] eq "Uninstall?"}
	press pyes
	settle
	check "  uninstalled; the box was off, so its data stays" {[::kit::store::findLive [::kit::store::load] org.example.notes] eq "" && [file exists $ad/notes.db]}
	# again, with the box ticked: kit's toss is answered yes and the data goes
	set page::dialog ""
	page::open path $::env(PROPS_KIT)
	page::draw
	after 50 {answer pyes}
	press install
	settle
	page::open kit org.example.notes
	page::draw
	press uninstall
	update
	press pdata0
	check "  the box ticks" {$page::dialog ne "" && [dict get [lindex [dict get $page::dialog data] 0] on]}
	press pyes
	settle
	check "  uninstalled with the box ticked: kit's toss removes its data too" {[::kit::store::findLive [::kit::store::load] org.example.notes] eq "" && ![file exists $ad/notes.db]}
	set page::dialog ""
	rename page::footer {}
	rename page::footer_drawn page::footer
} else {
	puts "  skip kit's grab, mend and toss (no kit library or Mk4tcl: PROPS_KIT unset)"
}

# who signed: kittrust's key list names the key, its role and its validity
if {[info exists ::env(PROPS_TRUST)] && [kitlink::load]} {
	set ::kit::conf(keys) [list $::env(PROPS_TRUST)]
	unset -nocomplain kitlink::trusted
	set fh [open $::env(PROPS_TRUST_PUB)]; set pk [lindex [split [string trim [read $fh]] \n] end]; close $fh
	::kit::kitfmt
	set t [kitlink::trust [::kitfmt::PubKeyId $pk]]
	check "kittrust: the key's name, role, validity and repository" {[dict get $t name] eq "ribbon-release" && [dict get $t keyroles] eq "app" &&
		[dict get $t keyuntil] > [clock seconds] && [dict get $t repository] eq "org.ribbon.test" && [dict get $t key] eq $pk}
	check "  a key it doesn't list: nothing" {[kitlink::trust 0123456789ABCDEF] eq {}}
	set K [dict merge [kitlink::empty] [dict create name org.example.signed short signed title Signed version 1 installed 1 notkit 0 sigstate valid \
		keyid [::kitfmt::PubKeyId $pk] signer x]]
	set t [kitlink::trust [::kitfmt::PubKeyId $pk]]
	foreach k {key keyroles keyfrom keyuntil repository revoked} { dict set K $k [dict get $t $k] }
	page::open_app $K
	page::go signature
	page::draw
	update
} else {
	puts "  skip kittrust's key list (no kit library or minisign)"
}

# no kit here (its library or Mk4tcl missing): a .kit is shown as a file, an
# app's pages offer no kit actions, and nothing says why
set broken [file join $dir broken.kit]
set fh [open $broken w]; puts $fh "not a kit"; close $fh
page::open path $broken
page::draw
update
check "a .kit kit can't read: its General page, as a file" {$page::S(kind) eq "file" && [page::keys] eq {general} && $page::dialog eq ""}
set kitlink::usable 0
set K [dict merge [kitlink::empty] [dict create name org.example.notes short notes title Notes version 1.0 installed 1 notkit 0]]
page::open_app $K
page::draw
update
check "  an app without kit: no Update, Repair, Uninstall" {[lsearch -index 0 $ui::focusables update] < 0 && [lsearch -index 0 $ui::focusables uninstall] < 0 && $page::dialog eq ""}
unset kitlink::usable

# an app that is not a kit (Props-A9-NotKit): Open starts it as its launcher entry says, field codes left out
set ran [file join $dir opened-by-props]
file delete $ran
set fh [open [file join $dir props-flow-open.desktop] w]
puts $fh "\[Desktop Entry\]\nType=Application\nName=Toucher\nExec=sh -c 'echo \"\$0\" > \"\$1\"' 100%% [list $ran] %U\nTerminal=false\nMimeType=text/plain;"
close $fh
page::open app [file join $dir props-flow-open.desktop]
page::draw
update
check "a launcher entry, not a kit: Open on its page" {[dict get $page::K notkit] && [lsearch -index 0 $ui::focusables open] >= 0}
press open
set t0 [clock milliseconds]
while {![file exists $ran] && [clock milliseconds] - $t0 < 5000} { after 50 {set ::tick 1}; vwait ::tick }
check "  Open starts it, field codes left out and %% as %" {[file exists $ran] && [string trim [slurp $ran]] eq "100%"}

# keys: Alt+2 goes to the second page, Ctrl+W closes
page::open_app [dict merge [kitlink::empty] [dict create name org.example.notes short notes title Notes version 1.0 installed 1 notkit 0]]
page::draw
key 2 2 8
check "Alt+2: the second page" {$page::S(page) eq "permissions"}

update
# the end reached (test-properties.sh looks for it: a window that closed early is no pass)
puts "flow: the end"
exit [expr {$::fails ? 1 : 0}]
