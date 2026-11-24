# notes-capture.tcl - the quick-capture flow (U35), run as a scene by apps/notes/main.tcl:
#   RIBBON_NOTES_SCENE=this file, RIBBON_NOTES_FIXTURES = a folder made here.
# Checks: a panel saves a note to Inbox with its title as the heading and the checkboxes as Markdown; Discard
# writes nothing; a running Notes listens on its socket, and "ribbon-notes --capture" hands the request to it (the
# panel opens, and the client exits 0). Prints "capture: ok" and exits 0, or the failing check and exits 1.
set dir $::env(RIBBON_NOTES_FIXTURES)
file delete -force $dir
file mkdir [file join $dir Inbox]
notes::store::set_root $dir
notes::index::refresh
set fails 0
proc check {name ok} {
	global fails
	if {$ok} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
}
proc settle {ms} {
	after $ms [list set ::settled 1]
	vwait ::settled
}

# a panel saves to Inbox
notesapp::cap_open 0
$notesapp::cap(title) insert 0 "Groceries for Sunday"
$notesapp::cap(body) insert 1.0 "- \[x\] Oat milk\n- \[ \] Lemons"
notesapp::cap_restyle
check "the body keeps its Markdown (boxes are drawn, not stored)" \
	[expr {[$notesapp::cap(body) get 1.0 end-1c] eq "- \[x\] Oat milk\n- \[ \] Lemons"}]
notesapp::cap_save
check "Save closes the panel" [expr {![winfo exists .cap]}]
set f [file join $dir Inbox "Groceries for Sunday.md"]
check "Save writes Inbox/Groceries for Sunday.md" [file exists $f]
set fh [open $f r]; fconfigure $fh -encoding utf-8; set text [read $fh]; close $fh
check "the note is the heading and the checklist" \
	[expr {$text eq "# Groceries for Sunday\n\n- \[x\] Oat milk\n- \[ \] Lemons\n"}]

# a JPEG attachment: the thumbnail goes through ffmpeg, is 64 x 44 and has rounded corners; Save copies the file
if {[auto_execok ffmpeg] ne ""} {
	exec tclsh8.6 [file join [file dirname [file normalize [info script]]] make-picture.tcl] photo-ember-2 240 160 [file join $dir shot.png]
	exec ffmpeg -nostdin -v error -y -i [file join $dir shot.png] -q:v 2 [file join $dir shot.jpg]
	notesapp::cap_open 0
	$notesapp::cap(title) insert 0 "With picture"
	notesapp::cap_attach_set [file join $dir shot.jpg]
	check "a JPEG attachment gets a thumbnail through ffmpeg" [expr {$notesapp::cap(thumb) ne "" && [image width $notesapp::cap(thumb)] == 64 && [image height $notesapp::cap(thumb)] == 44}]
	set th $notesapp::cap(thumb)
	check "the thumbnail's corner is the card colour (rounded), its middle the picture" \
		[expr {[$th get 0 0] eq [raster::rgb $notesapp::c(field)] && [$th get 32 22] ne [raster::rgb $notesapp::c(field)]}]
	notesapp::cap_save
	check "Save copies the JPEG beside the note" [file exists [file join $dir Inbox shot.jpg]]
} else {
	puts "  skip JPEG attachment (no ffmpeg)"
}

# Discard writes nothing
notesapp::cap_open 0
$notesapp::cap(title) insert 0 "Not kept"
notesapp::cap_discard
check "Discard writes no note" [expr {![file exists [file join $dir Inbox "Not kept.md"]]}]

# the folder pill: its menu lists the folders, and the chosen one is where Save writes
file mkdir [file join $dir Ribbon Shell]
notesapp::cap_open 0
notesapp::cap_pick_folder
set labels {}
for {set i 0} {$i <= [.cap.fm index last]} {incr i} { lappend labels [.cap.fm entrycget $i -label] }
.cap.fm unpost
check "the folder menu lists the folders ($labels)" [expr {"Ribbon/Shell" in $labels && "Inbox" in $labels}]
notesapp::cap_set_folder Ribbon/Shell
check "choosing a folder sets the pill" [expr {$notesapp::cap(folder) eq "Ribbon/Shell"}]
$notesapp::cap(title) insert 0 "Shell note"
notesapp::cap_save
check "Save writes to the chosen folder" [file exists [file join $dir Ribbon Shell "Shell note.md"]]
check "and not to Inbox" [expr {![file exists [file join $dir Inbox "Shell note.md"]]}]

# tags: "+ Tag" takes a name ("#" optional, lower case); a chip removes; Save writes them on a last line
notesapp::cap_open 0
notesapp::cap_tag_add
$notesapp::cap(tagentry) insert 0 "#Home"
notesapp::cap_tag_commit
check "a typed tag is added in lower case" [expr {$notesapp::cap(tags) eq {home}}]
notesapp::cap_tag_add
$notesapp::cap(tagentry) insert 0 "home"
notesapp::cap_tag_commit
notesapp::cap_tag_add
$notesapp::cap(tagentry) insert 0 "9lives"
notesapp::cap_tag_commit
check "a repeat or an invalid tag is not added" [expr {$notesapp::cap(tags) eq {home}}]
notesapp::cap_tag_add
$notesapp::cap(tagentry) insert 0 "recipes"
notesapp::cap_tag_cancel
check "Escape drops the entry" [expr {$notesapp::cap(tagentry) eq "" && $notesapp::cap(tags) eq {home}}]
notesapp::cap_tag_add
$notesapp::cap(tagentry) insert 0 "recipes"
notesapp::cap_tag_commit
notesapp::cap_tag_remove home
check "a chip click takes the tag off" [expr {$notesapp::cap(tags) eq {recipes}}]
notesapp::cap_tag_add
$notesapp::cap(tagentry) insert 0 "home"
notesapp::cap_tag_commit
$notesapp::cap(title) insert 0 "Tagged"
notesapp::cap_save
set f [file join $dir Inbox "Tagged.md"]
set fh [open $f r]; fconfigure $fh -encoding utf-8; set text [read $fh]; close $fh
check "Save writes the tags on a last line ($text)" [expr {$text eq "# Tagged\n\n#recipes #home\n"}]

# a picture: the card, then Save copies it next to the note and writes it as a Markdown image
set png [file join $dir pic.png]
exec tclsh8.6 [file join [file dirname [file normalize [info script]]] make-picture.tcl] photo-dusk-1 240 160 $png
notesapp::cap_open 0
notesapp::cap_attach_set $png
check "a picture shows as the card" [expr {$notesapp::cap(attach) eq $png}]
$notesapp::cap(title) insert 0 "Picture note"
notesapp::cap_save
set f [file join $dir Inbox "Picture note.md"]
set fh [open $f r]; fconfigure $fh -encoding utf-8; set text [read $fh]; close $fh
check "Save copies the picture into the folder" [file exists [file join $dir Inbox pic.png]]
check "and writes it into the note ($text)" [expr {$text eq "# Picture note\n\n!\[pic\](pic.png)\n"}]
notesapp::cap_open 0
notesapp::cap_attach_set $png
notesapp::cap_attach_clear
check "the card's remove clears the picture" [expr {$notesapp::cap(attach) eq ""}]
notesapp::cap_close

# Image and Link: a link takes the clipboard's web address, or a placeholder to fill in
notesapp::cap_open 0
clipboard clear
notesapp::cap_insert_link
check "Link without a web address in the clipboard inserts a placeholder" \
	[expr {[string first {[link text](https://)} [$notesapp::cap(body) get 1.0 end]] >= 0}]
notesapp::cap_close
notesapp::cap_open 0
clipboard clear
clipboard append https://example.org/notes
notesapp::cap_insert_link
check "Link takes the clipboard's address" \
	[expr {[string first {[https://example.org/notes](https://example.org/notes)} [$notesapp::cap(body) get 1.0 end]] >= 0}]
notesapp::cap_close

# a click on a box checks or unchecks its line (the body text stays Markdown)
notesapp::cap_open 0
$notesapp::cap(body) insert 1.0 "- \[ \] Lemons\n- \[x\] Milk\nNo box here"
notesapp::cap_restyle
update
lassign [$notesapp::cap(body) bbox 1.0] bx by bw bh
event generate $notesapp::cap(body) <ButtonRelease-1> -x [expr {$bx + 3}] -y [expr {$by + $bh / 2}]
update
check "a click on the box checks the line" \
	[expr {[$notesapp::cap(body) get 1.0 1.end] eq "- \[x\] Lemons"}]
lassign [$notesapp::cap(body) bbox 2.0] bx by bw bh
event generate $notesapp::cap(body) <ButtonRelease-1> -x [expr {$bx + 3}] -y [expr {$by + $bh / 2}]
update
check "a second click unchecks it" [expr {[$notesapp::cap(body) get 2.0 2.end] eq "- \[ \] Milk"}]
notesapp::cap_close

# standalone: with no running Notes and no socket, "ribbon-notes --capture" opens the panel itself; Save or
# Discard closes it and the process exits 0. A wrapper drives the panel from the event loop.
proc standalone {name action} {
	global dir here
	set sdir [file join $dir $name]
	file mkdir [file join $sdir notes Inbox] [file join $sdir home] [file join $sdir run]
	set w [file join $sdir drive.tcl]
	set fh [open $w w]
	fconfigure $fh -encoding utf-8
	puts $fh "set argv {-- --capture}"
	puts $fh "after 400 {"
	puts $fh "\t\$::notesapp::cap(title) insert 0 {Standalone}"
	puts $fh "\t\$::notesapp::cap(body) insert 1.0 {- \[ \] Milk}"
	puts $fh "\t::notesapp::cap_restyle"
	puts $fh "\t::notesapp::$action"
	puts $fh "}"
	puts $fh "source -encoding utf-8 [file join $here .. srcpkgs ribbon-desktop files apps notes main.tcl]"
	close $fh
	set rc [catch {exec env -u RIBBON_NOTES_SCENE HOME=[file join $sdir home] RIBBON_NOTES_ROOT=[file join $sdir notes] \
		XDG_RUNTIME_DIR=[file join $sdir run] XDG_STATE_HOME=[file join $sdir home] XDG_CACHE_HOME=[file join $sdir home] \
		timeout 30 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 $w} out]
	return [list $rc $out [file join $sdir notes Inbox "Standalone.md"]]
}
set here [file dirname [file normalize [info script]]]
lassign [standalone sa-save cap_save] rc out f
check "standalone --capture saves and exits 0 ($out)" [expr {!$rc}]
check "standalone Save writes the note to Inbox" [file exists $f]
lassign [standalone sa-discard cap_discard] rc out f
check "standalone --capture discards and exits 0 ($out)" [expr {!$rc}]
check "standalone Discard writes nothing" [expr {![file exists $f]}]

# a running Notes takes "ribbon-notes --capture" over its socket (the unix_sockets package, which CI builds from its
# tarball; the app captures standalone without it, as above)
if {[catch {package require unix_sockets}]} {
	puts "  skip the hand-off to a running Notes (no unix_sockets for Tcl: UNIX_SOCKETS_DIR on TCLLIBPATH)"
	if {$fails} { puts "capture: $fails check(s) failed"; exit 1 }
	puts "capture: ok"
	exit 0
}
set sock [notesapp::cap_sock]
file delete -force $sock
notesapp::cap_listen
check "the running Notes listens on its socket" [file exists $sock]
set rc [catch {exec timeout 30 wish8.6 -encoding utf-8 [file normalize [file join [file dirname [info script]] .. srcpkgs ribbon-desktop files apps notes main.tcl]] -- --capture} out]
check "the client hands off and exits 0 ($out)" [expr {!$rc}]
settle 400
check "the running Notes opens the panel" [winfo exists .cap]
notesapp::cap_close
settle 50

if {$fails} { puts "capture: $fails check(s) failed"; exit 1 }
puts "capture: ok"
exit 0
