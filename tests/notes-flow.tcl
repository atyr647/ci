# notes-flow.tcl - a Tk flow test of the note page (U34b), run as a scene by apps/notes/main.tcl:
#   RIBBON_NOTES_SCENE=this file, RIBBON_NOTES_FIXTURES = a folder made here.
# Checks: the text widget's round trip (body_text equals the note's body), the checkbox toggle by a click on its box,
# the format bar's Bold on a selection, find stepping through the matches, and undo. Prints "flow: ok" and exits 0,
# or prints the failing check and exits 1.
set dir $::env(RIBBON_NOTES_FIXTURES)
file delete -force $dir
file mkdir [file join $dir Ribbon]
set fh [open [file join $dir Ribbon flow.md] w]
fconfigure $fh -encoding utf-8 -translation lf
puts -nonewline $fh "# Flow\n\nFormatting goes here, and tile sizes too.\n\n- \[ \] Buy tile\n- \[x\] Buy grout\n- \[ \] Third row\n"
close $fh
notes::store::set_root $dir
notes::index::refresh
set ::notesapp::open {Ribbon}
notesapp::open_note Ribbon flow
set fails 0
proc check {name ok} {
	global fails
	if {$ok} { puts "  ok   $name" } else { puts "  FAIL $name"; incr fails }
}
set page $notesapp::page
set body0 "# Flow\n\nFormatting goes here, and tile sizes too.\n\n- \[ \] Buy tile\n- \[x\] Buy grout\n- \[ \] Third row\n"
check "the text round trip gives the body back" [expr {[notesapp::body_text] eq $body0}]

# the checkbox: click on the box of the open line
set at [$page search -- "Buy tile" 1.0]
set ln [lindex [split $at .] 0]
update
set bb [$page bbox "$ln.0"]
lassign $bb bx by bw bh
notesapp::clicked [expr {$bx + 4}] [expr {$by + $bh / 2}]
check "a click on the box checks it" [string match {*- \[x\] Buy tile*} [notesapp::body_text]]
# the first click re-lays the page, so the box is measured again before the second click
update
lassign [$page bbox "$ln.0"] bx by bw bh
notesapp::clicked [expr {$bx + 4}] [expr {$by + $bh / 2}]
check "a second click unchecks it" [string match {*- \[ \] Buy tile*} [notesapp::body_text]]

# the rows of a checklist are 32 px apart (the board's min-height 32), and a click anywhere on a box, at the row's own
# geometry, toggles it; a click beside the 30 px of the box and its gap does not
set l1 [lindex [split [$page search -- "Buy tile" 1.0] .] 0]
set l2 [lindex [split [$page search -- "Buy grout" 1.0] .] 0]
set l3 [lindex [split [$page search -- "Third row" 1.0] .] 0]
update
set y1 [lindex [$page dlineinfo $l1.0] 1]
set y2 [lindex [$page dlineinfo $l2.0] 1]
set y3 [lindex [$page dlineinfo $l3.0] 1]
check "checkbox rows are 32 px apart" [expr {$y2 - $y1 == 32 && $y3 - $y2 == 32}]
lassign [$page dlineinfo $l3.0] lx ly lw lh lb
notesapp::clicked 40 [expr {$ly + 2}]
check "a click beside the box does not toggle it" [expr {[notesapp::body_text] eq $body0}]
update
lassign [$page dlineinfo $l3.0] lx ly lw lh lb
notesapp::clicked 9 [expr {$ly + $lh - 3}]
check "a click on the third row's box (at its lower edge) toggles that row" [string match "*- \\\[x\\\] Third row*" [notesapp::body_text]]
check "and only that row" [string match "*- \\\[ \\\] Buy tile*" [notesapp::body_text]]
notesapp::undo
check "undo takes the toggle back" [expr {[notesapp::body_text] eq $body0}]
update
# a click on the first box when the lines have other spacing (the real geometry is read, not assumed)
$page tag configure box -spacing1 10 -spacing3 10
update
lassign [$page dlineinfo $l1.0] lx ly lw lh lb
notesapp::clicked 9 [expr {$ly + $lh / 2}]
check "with 10 px spacing round the rows a click on the box still toggles it" [string match "*- \\\[x\\\] Buy tile*" [notesapp::body_text]]
$page tag configure box -spacing1 0 -spacing3 0
notesapp::undo
update

# the format bar shows over a selection, and goes when the selection does
check "the format bar is hidden with no selection" [expr {![winfo ismapped $notesapp::page_bar]}]
$page tag remove sel 1.0 end
set w [$page search -- "Formatting" 1.0]
$page tag add sel $w "$w + 10 chars"
notesapp::format_update
update
check "the format bar shows on a selection" [winfo ismapped $notesapp::page_bar]
check "the bar has width and is 40 px high" [expr {[winfo width $notesapp::page_bar] > 150 && [winfo height $notesapp::page_bar] == 40}]
lassign [$page bbox sel.first] bx by bw bh
check "the bar sits above the selection's line, 2 px in from its start" [expr {[winfo x $notesapp::page_bar] - [winfo x $page] == $bx + 2 && [winfo y $notesapp::page_bar] - [winfo y $page] + 40 <= $by}]
check "the selection colour is the neutral wash, not the accent" [expr {[$page cget -selectbackground] eq $notesapp::c(sel) && $notesapp::c(sel) ne $notesapp::c(soft2)}]
$page tag remove sel 1.0 end
notesapp::format_update
check "the bar goes with the selection" [expr {![winfo ismapped $notesapp::page_bar]}]

# strike: the button wraps the selection in ~~, and the page draws it struck with the markers hidden
$page tag add sel $w "$w + 10 chars"
notesapp::format_strike
check "Strike wraps the selection in ~~" [string match "*~~Formatting~~ goes*" [notesapp::body_text]]
set sr [$page tag ranges strike]
check "the struck text is tagged strike and overstruck" [expr {[llength $sr] == 2 && [$page get {*}$sr] eq "Formatting" && [$page tag cget strike -overstrike] == 1}]
check "the ~~ markers are hidden" [expr {[llength [$page tag ranges elide]] > 0 && "elide" in [$page tag names [$page search -elide -- "~~" 1.0]]}]
notesapp::undo
check "undo takes the Strike back" [expr {[notesapp::body_text] eq $body0}]

# the format bar: select a word, Bold wraps it
$page tag remove sel 1.0 end
set w [$page search -- "Formatting" 1.0]
$page tag add sel $w "$w + 10 chars"
notesapp::format_bold
check "Bold wraps the selection in **" [string match "*\*\*Formatting**\ goes*" [notesapp::body_text]]
notesapp::undo
check "undo takes the Bold back" [expr {[notesapp::body_text] eq $body0}]

# find: two matches of "tile", stepping goes to the next and wraps
set notesapp::state(query) tile
notesapp::find_marks
check "find counts the matches" [expr {$notesapp::state(hits) == 2}]
notesapp::find_step 1
check "find steps to the second match" [expr {$notesapp::state(current) == 1}]
notesapp::find_step 1
check "find wraps to the first" [expr {$notesapp::state(current) == 0}]

# typing is one undo step, and the body after undo is the body before typing
$page mark set insert end-1c
$page insert insert " more"
notesapp::restyle
check "typing changes the body" [string match "*more*" [notesapp::body_text]]
notesapp::undo
check "undo takes the typing back" [expr {[notesapp::body_text] eq $body0}]

# the text paste (Edit, A2): the clipboard's text goes in at the insert point and the body keeps it
clipboard clear
clipboard append "pasted words"
$page mark set insert end-1c
event generate $page <<Paste>>
update
check "a text paste puts the clipboard text in the body" [string match "*pasted words*" [notesapp::body_text]]
notesapp::undo
check "undo takes the text paste back" [expr {[notesapp::body_text] eq $body0}]

# the picture paste: a PNG on the clipboard (image/png) is saved beside the note and its picture line goes in
# the picture source lives outside the note's folder; the note's folder is Ribbon
set nd [notes::store::dir_of Ribbon]
file mkdir [file join $dir src]
set png [image create photo -width 6 -height 4]
$png put red -to 0 0 6 4
$png write [file join $dir src paste-src.png] -format png
set fh [open [file join $dir src paste-src.png] rb]
fconfigure $fh -translation binary
set pngbytes [read $fh]
close $fh
selection handle -selection CLIPBOARD -type image/png . [list apply {{off max} {
	global pngbytes
	return [string range $pngbytes $off [expr {$off + $max - 1}]]
}}]
selection own -selection CLIPBOARD .
$page mark set insert end-1c
event generate $page <<Paste>>
update
set body [notesapp::body_text]
set pasted [regexp -inline {!\[(pasted-[^]]+)\]\((pasted-[^)]+\.png)\)} $body]
check "a picture on the clipboard becomes a picture line" [expr {[llength $pasted] == 3}]
if {[llength $pasted] == 3} {
	set got [file join $nd [lindex $pasted 2]]
	check "the pasted picture is the clipboard's bytes" [expr {[file exists $got] && [file size $got] == [string length $pngbytes]}]
}
notesapp::undo
selection clear -selection CLIPBOARD .
check "undo takes the picture paste back" [expr {[notesapp::body_text] eq $body0}]

# the image insert from a file (the Image button's dialog goes through insert_image_file)
notesapp::insert_image_file [file join $dir src paste-src.png]
check "an image from a file gets its picture line" [string match {*!\[paste-src\](paste-src.png)*} [notesapp::body_text]]
check "the file is copied beside the note" [file exists [file join $nd paste-src.png]]
notesapp::undo

# a JPEG in a note: Tk cannot read it, so the page goes through ffmpeg (as the Image Viewer does)
if {[auto_execok ffmpeg] ne ""} {
	exec ffmpeg -nostdin -v error -y -i [file join $dir src paste-src.png] [file join $nd tiny.jpg]
	check "Tk cannot read the JPEG itself" [catch {image create photo -file [file join $nd tiny.jpg]}]
	set ph [notesapp::picture tiny.jpg Ribbon]
	check "a JPEG in a note loads through ffmpeg" [expr {$ph ne "" && [image width $ph] == 6 && [image height $ph] == 4}]
	set big [file join $dir src big.jpg]
	exec ffmpeg -nostdin -v error -y -f lavfi -i color=c=0x3060a0:s=1000x400 -frames:v 1 $big
	file copy -force $big [file join $nd big.jpg]
	set ph [notesapp::picture big.jpg Ribbon]
	check "a wide JPEG is scaled to the 620 px measure by ffmpeg" [expr {[image width $ph] == 620 && [image height $ph] == 248}]
	check "its corners are rounded (the corner pixel is the page colour, the middle the picture)" \
		[expr {[$ph get 0 0] eq [raster::rgb $notesapp::c(bar)] && [lindex [$ph get 300 100] 2] > [lindex [$ph get 300 100] 0] + 60}]
} else {
	puts "  skip JPEG in a note (no ffmpeg)"
}

if {$fails} { puts "flow: $fails check(s) failed"; exit 1 }
puts "flow: ok"
exit 0
