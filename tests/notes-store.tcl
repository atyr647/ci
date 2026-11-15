# notes-store.tcl - the notes model (U33) without a window: the store round trip on disk, the front matter,
# the line kinds and inline spans, tags and titles, the index's refresh by mtime, search with snippets, rename,
# move and trash with their versions. Run by tests/steps.d/64-notes.sh with tclsh8.6; exits 1 on a failure.
set here [file dirname [file normalize [info script]]]
set app [file join $here .. srcpkgs ribbon-desktop files apps notes]
set root [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] notes-store-[pid]]
file delete -force $root
set ::env(RIBBON_NOTES_ROOT) $root
foreach f {store markdown index} { source [file join $app $f.tcl] }

set fails 0
proc ok {name cond} {
	global fails
	if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
}

# ---- the store: the round trip is byte-exact --------------------------------------------------------
set tricky "---\npinned: true\n---\n# Notes app, first cut\nEdited today #design été — ☃\n\n## Must have\n- \[x\] Search titles and text\n- \[ \] Paste an image; it is kept next to the note\n\n!\[one-bar\](one-bar.png)\n\nInline `code` and **bold** and *it* and \[a link\](https://ribbon.example/x).\n\n```tcl\nproc x {} { return 1 }\n```\n"
notes::store::write_note "Ribbon" "Notes app, first cut" $tricky
set back [notes::store::read_note "Ribbon" "Notes app, first cut"]
ok "store round trip returns the text it was given" [expr {$back eq $tricky}]
set fh [open [notes::store::note_path "Ribbon" "Notes app, first cut"] rb]
set bytes [read $fh]
close $fh
ok "the file is the UTF-8 bytes of the text, LF ends" [expr {[encoding convertfrom utf-8 $bytes] eq $tricky}]
ok "a folder's notes are listed by name" [expr {[notes::store::notes "Ribbon"] eq {{Notes app, first cut}}}]

# ---- front matter ------------------------------------------------------------------------------------
set p [notes::md::parse $tricky]
ok "pinned: true in the front matter is pinned" [dict get $p pinned]
ok "building the parse gives the text back" [expr {[notes::md::build [dict get $p pinned] [dict get $p has_fm] [dict get $p fm] [dict get $p body]] eq $tricky}]
set q [notes::md::parse "# No front matter\n\nbody\n"]
ok "no front matter: not pinned, body is the whole text" [expr {![dict get $q pinned] && ![dict get $q has_fm] && [dict get $q body] eq "# No front matter\n\nbody\n"}]
set r [notes::md::build 1 0 {} "plain\n"]
ok "pinning a plain note adds the front matter" [expr {$r eq "---\npinned: true\n---\nplain\n"}]
set s [notes::md::build 0 1 {{pinned: true}} "plain\n"]
ok "unpinning writes pinned: false in place" [expr {$s eq "---\npinned: false\n---\nplain\n"}]
set t [notes::md::parse "---\ntags: x\npinned: yes\n---\nbody"]
ok "a front matter key other than pinned is kept, pinned: yes reads as pinned" [expr {[dict get $t pinned] && [lindex [dict get $t fm] 0] eq "tags: x"}]

# ---- line kinds, spans, tags, title -----------------------------------------------------------------
set kinds [notes::md::lines [dict get $p body]]
set kk {}
foreach e $kinds { lappend kk [lindex $e 0] }
ok "line kinds: heading, box, image, fence and code" [expr {[lindex $kk 0] eq "h" && [lindex $kk 3] eq "h" && [lindex $kk 4] eq "box" && [lindex $kk 5] eq "box" && [lindex $kk 7] eq "image" && [lindex $kk 11] eq "fence" && [lindex $kk 12] eq "code"}]
ok "a done box is done" [expr {[lindex [lindex $kinds 4] 1] == 1 && [lindex [lindex $kinds 5] 1] == 0}]
ok "an image line gives alt and path" [expr {[lindex [lindex $kinds 7] 0] eq "image" && [lindex [lindex $kinds 7] 1] eq "one-bar" && [lindex [lindex $kinds 7] 2] eq "one-bar.png"}]
set sp [notes::md::spans "Inline `code` and **bold** and *it* and \[a link\](https://ribbon.example/x)."]
set got {}
foreach s $sp { lappend got [lindex $s 2] }
ok "inline spans: code, bold, italic and link with elided marks" [expr {[lsearch $got code] >= 0 && [lsearch $got bold] >= 0 && [lsearch $got italic] >= 0 && [lsearch $got link] >= 0 && [llength [lsearch -all $got elide]] == 8}]
set line "Inline `code` and **bold**"
set cs [lindex [lsearch -inline -exact -index 2 -all [notes::md::spans $line] code] 0]
ok "the code span covers the text between the backticks" [expr {[string range $line [lindex $cs 0] [expr {[lindex $cs 1] - 1}]] eq "code"}]
set bs [lindex [lsearch -inline -exact -index 2 -all [notes::md::spans $line] bold] 0]
ok "the bold span covers the text between the stars" [expr {[string range $line [lindex $bs 0] [expr {[lindex $bs 1] - 1}]] eq "bold"}]
set line "Done ~~struck out~~ and **bold**, `~~not~~ struck`"
set st [lsearch -inline -exact -index 2 -all [notes::md::spans $line] strike]
ok "the strike span covers the text between the tildes" [expr {[llength $st] == 1 && [string range $line [lindex $st 0 0] [expr {[lindex $st 0 1] - 1}]] eq "struck out"}]
set tl 0
foreach s [notes::md::spans $line] { if {[lindex $s 2] eq "elide" && [string range $line [lindex $s 0] [expr {[lindex $s 1] - 1}]] eq "~~"} { incr tl } }
ok "both ~~ markers of a strike are elided, and a ~~ inside code is not a strike" [expr {$tl == 2}]
ok "tags are lower case, unique and skip code and headings" [expr {[notes::md::tags [dict get $p body]] eq {design}}]
ok "tags inside a code fence are not tags" [expr {[notes::md::tags "```\n#notatag\n```\n#real #Real"] eq {real}}]
ok "the title is the first level-1 heading" [expr {[notes::md::title [dict get $p body]] eq "Notes app, first cut"}]

# ---- versions: a changed save keeps the earlier text ------------------------------------------------
notes::store::write_note "Ribbon" "Notes app, first cut" "---\npinned: true\n---\nsecond\n"
set vdir [file join $root Ribbon .versions]
ok "an earlier text is kept in .versions" [expr {[llength [glob -directory $vdir *]] == 1}]
ok "the kept text is the one before the save" [expr {[encoding convertfrom utf-8 [read [set fh [open [lindex [glob -directory $vdir *] 0] rb]]]] eq $tricky}]
close $fh
notes::store::write_note "Ribbon" "Notes app, first cut" "---\npinned: true\n---\nsecond\n"
ok "an unchanged save keeps no extra version" [expr {[llength [glob -directory $vdir *]] == 1}]

# ---- the index: refresh by mtime, order, counts -----------------------------------------------------
notes::store::write_note "Ribbon" "Release checklist 0.9" "# Release checklist 0.9\n\n- \[ \] tag the build #release\n"
notes::store::write_note "Ribbon/Shell" "Tiling in labwc" "# Tiling\n\nSnap to halves; tile rules in rc.xml\n"
notes::store::write_note "Inbox" "Quick thought" "remember the tile sizes\n"
ok "folders include the nested ones" [expr {[notes::store::folders] eq {Inbox Ribbon Ribbon/Shell}}]
ok "a first refresh reads every note" [expr {[notes::index::refresh] == 4}]
ok "an unchanged refresh reads nothing" [expr {[notes::index::refresh] == 0}]
set e0 [lindex [notes::index::entries] 0]
ok "the pinned note comes first" [expr {[dict get $e0 name] eq "Notes app, first cut" && [dict get $e0 pinned]}]
ok "a folder counts its notes and the notes below it" [expr {[notes::index::count "Ribbon"] == 3 && [notes::index::count ""] == 4}]
ok "tag counts" [expr {[dict get [notes::index::tag_counts] release] == 1}]
# an edit made outside the app, with a new mtime
set f [notes::store::note_path "Inbox" "Quick thought"]
set fh [open $f w]; puts -nonewline $fh "remember the tile sizes, now longer\n"; close $fh
file mtime $f [expr {[file mtime $f] + 60}]
ok "a note whose mtime changed is read again" [expr {[notes::index::refresh] == 1}]
ok "and its new text is in the index" [expr {[string match "*now longer*" [dict get [lindex [notes::index::in_folder Inbox] 0] body]]}]
file delete $f
ok "a deleted note leaves the index" [expr {[notes::index::refresh] == 0 && [llength [notes::index::in_folder Inbox]] == 0}]
notes::store::write_note "Inbox" "Quick thought" "remember the tile sizes\n"

# ---- search: every word, case-blind, snippets and counts -------------------------------------------
notes::index::refresh
set hits [notes::index::search "TILE"]
ok "search finds the word in the body and the name, case-blind" [expr {[llength $hits] == 2}]
set h0 [lindex $hits 0]
set snip [dict get $h0 snippet]
ok "the snippet holds the match where it says" [expr {[string range [dict get $snip text] [dict get $snip at] [expr {[dict get $snip at] + [dict get $snip len] - 1}]] eq "tile" || [string range [dict get $snip text] [dict get $snip at] [expr {[dict get $snip at] + [dict get $snip len] - 1}]] eq "TILE"}]
ok "the count is the matches of the first word" [expr {[dict get $h0 count] >= 1}]
ok "every word must match" [expr {[llength [notes::index::search "tile rc.xml"]] == 1 && [llength [notes::index::search "tile zzz"]] == 0}]
ok "an empty query finds nothing" [expr {[llength [notes::index::search "   "]] == 0}]

# ---- rename, move, create, trash ---------------------------------------------------------------------
notes::store::rename_note "Ribbon" "Release checklist 0.9" "Release checklist 1.0"
ok "rename moves the file" [expr {[file exists [notes::store::note_path Ribbon "Release checklist 1.0"]] && ![file exists [notes::store::note_path Ribbon "Release checklist 0.9"]]}]
ok "rename carries the versions when there are any" [expr {[llength [glob -nocomplain -directory $vdir "Release checklist 0.9*"]] == 0}]
set refused [catch {notes::store::rename_note "Ribbon" "Release checklist 1.0" "Notes app, first cut"} msg]
ok "rename refuses a name already in the folder" [expr {$refused && [string match "*already*" $msg]}]
set refused [catch {notes::store::rename_note "Ribbon" "Release checklist 1.0" "a/b"} msg]
ok "rename refuses a slash" $refused
notes::store::move_note "Ribbon" "Release checklist 1.0" "Home"
ok "move puts the note in the other folder" [file exists [notes::store::note_path Home "Release checklist 1.0"]]
set n [notes::store::create_note "Home"]
set n2 [notes::store::create_note "Home"]
ok "new notes are Untitled, then Untitled 2" [expr {$n eq "Untitled" && $n2 eq "Untitled 2"}]
set tn [notes::store::trash_note "Home" "Untitled"]
ok "trash moves the note under .trash" [expr {[file exists [file join $root .trash Home "Untitled.md"]] && ![file exists [notes::store::note_path Home Untitled]]}]
notes::store::trash_note "Home" "Untitled 2"
set trashed [notes::store::trashed]
ok "trashed lists the trashed notes with their folders" [expr {[llength $trashed] == 2 && [lindex $trashed 0] eq {Home Untitled}}]
ok "the folder list ignores hidden folders" [expr {[lsearch [notes::store::folders] .trash] < 0 && [lsearch [notes::store::folders] .versions] < 0}]

file delete -force $root
puts [expr {$fails == 0 ? "notes store: all checks passed" : "notes store: $fails check(s) failed"}]
exit [expr {$fails == 0 ? 0 : 1}]
