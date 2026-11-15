# notes-open.tcl - opening a Markdown file named on Notes' command line (Files' "Open with Notes"), run as a scene by
# apps/notes/main.tcl with that file as its argument: RIBBON_NOTES_SCENE=this file, RIBBON_NOTES_ROOT = the store,
# RIBBON_NOTES_OUTSIDE = the folder the outside files are in (tests/steps.d/64-notes-open.sh).
# Checks: a file outside the store is imported into its top folder and that note opens with the file's text; the
# outside file is left as it is; the same file opened again opens that note rather than a second copy; another file
# of a taken name gets a number; a note inside the store opens as itself (in its folder), with nothing copied; a file
# that cannot be read opens nothing. Prints "open: ok" and exits 0, or exits 1.
set bgerrors {}
proc bgerror {msg} { lappend ::bgerrors $msg; puts stderr "notes-open: bgerror: $msg" }
set fails 0
proc check {name ok} {
	global fails
	if {$ok} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
}
proc slurp {path} { set fh [open $path rb]; set t [read $fh]; close $fh; return $t }
set root [notes::store::root]
set out $::env(RIBBON_NOTES_OUTSIDE)
update
# 1. the file on the command line (start's own path): Plan.md, outside the store
check "the command line's outside file is imported into the store's top folder" [file exists [file join $root Plan.md]]
check "that note is the one open" [expr {$notesapp::state(folder) eq "" && $notesapp::state(note) eq "Plan"}]
check "the page shows the file's text, not an empty note" [string match "# Plan*Buy milk*" [notesapp::body_text]]
check "the imported note holds the file's text" [expr {[slurp [file join $root Plan.md]] eq [slurp [file join $out Plan.md]]}]
check "the outside file is left where it was" [file exists [file join $out Plan.md]]
check "the tree lists the imported note" [expr {"Plan" in [notes::store::notes ""]}]
# 2. the same file again: the same note, no copy
set r [notesapp::open_arg [file join $out Plan.md]]
check "the same file opened again opens that note" [expr {$r eq [list "" Plan] && $notesapp::state(note) eq "Plan"}]
check "and makes no second copy" [expr {![file exists [file join $root "Plan 2.md"]]}]
# 3. another file of the same name (another folder, other text): a number
set r [notesapp::open_arg [file join $out other Plan.md]]
check "another file of a taken name is imported as \"Plan 2\"" [expr {$r eq [list "" "Plan 2"] && [file exists [file join $root "Plan 2.md"]]}]
check "and it opens with its own text" [string match "*Other plan*" [notesapp::body_text]]
check "the first note keeps its text" [string match "*Buy milk*" [slurp [file join $root Plan.md]]]
# 4. a note in the store (in a folder) opens as itself
set before [lsort [glob -nocomplain -directory $root -types f *.md]]
set r [notesapp::open_arg [file join $root Work Ideas.md]]
check "a note inside the store opens in its folder" [expr {$r eq [list Work Ideas] && $notesapp::state(folder) eq "Work" && $notesapp::state(note) eq "Ideas"}]
check "and shows its text" [string match "*Inside the store*" [notesapp::body_text]]
check "and nothing is copied" [expr {[lsort [glob -nocomplain -directory $root -types f *.md]] eq $before}]
# 4b. a Markdown file in the store that is not a note (X.MD: the tree lists *.md only) is imported, not opened as a
# note that is not there (open_note's read failed, and Notes did not start)
if {[catch {notesapp::open_arg [file join $root Work Loud.MD]} r]} { set r "error: $r" }
check "a .MD file in the store opens with its text (imported), not as a missing note" \
	[expr {$r eq [list "" Loud] && [string match "*Upper case*" [notesapp::body_text]]}]
# 5. a file whose front matter has a title: the note is named by it
set r [notesapp::open_arg [file join $out titled.md]]
check "a titled file becomes a note named by its title" [expr {$r eq [list "" "Trip to Oslo"] && [file exists [file join $root "Trip to Oslo.md"]]}]
set r [notesapp::open_arg [file join $out titled.md]]
check "and opened again it is that note" [expr {$r eq [list "" "Trip to Oslo"] && ![file exists [file join $root "Trip to Oslo 2.md"]]}]
# 6. nothing to read: nothing opens, nothing is made
set note $notesapp::state(note)
set r [notesapp::open_arg [file join $out missing.md]]
check "a file that is not there opens nothing" [expr {$r eq {} && $notesapp::state(note) eq $note && ![file exists [file join $root missing.md]]}]
check "no background errors" [expr {![llength $bgerrors]}]
if {$fails} { puts "open: $fails check(s) failed"; exit 1 }
puts "open: ok"
exit 0
