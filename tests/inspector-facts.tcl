# inspector-facts.tcl - the facts the Inspector shows (properties/facts.tcl): sizes,
# a text file's lines, characters, encoding and line endings, its language, the GPS
# coordinates of a photo's EXIF, the exposure strip, and a folder's count tagged with its
# path. Run by tests/steps.d/30-inspector.sh:
#   tclsh8.6 -encoding utf-8 tests/inspector-facts.tcl WORKDIR [EXIFDIR]
# EXIFDIR holds the fixtures tests/make-exif.py writes (mm.jpg, ii.jpg, bare.jpg); without it
# the EXIF checks are skipped.
encoding system utf-8
set repo [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $repo srcpkgs ribbon-desktop files properties facts.tcl]
lassign $argv work exifdir
file mkdir $work
set fails 0
proc check {what cond} {
	global fails
	if {$cond} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
# a tag of an EXIF dict, or "" when the file had none (a missing tag is a FAIL of its check, not a crash)
proc tag {x k} { expr {[dict exists $x $k] ? [dict get $x $k] : ""} }

# sizes, as the Inspector writes them
check "human: 21,604,113 bytes is 21.6 MB" [expr {[facts::human 21604113] eq "21.6 MB"}]
check "human: 3,104,226,817 bytes is 3.1 GB" [expr {[facts::human 3104226817] eq "3.1 GB"}]
check "human: 6,912 bytes is 6.9 KB (KB, as the boards write it)" [expr {[facts::human 6912] eq "6.9 KB"}]
# the boards: one decimal under 100, a whole number from 100 (FileProps-Inspector-Multi's 812 MB)
check "human: 811,904,377 bytes is 812 MB (a whole number from 100)" [expr {[facts::human 811904377] eq "812 MB"}]
check "human: 38,000,000 bytes is 38 MB (the .0 dropped)" [expr {[facts::human 38000000] eq "38 MB"}]
check "human: 1.1 KB keeps its decimal" [expr {[facts::human 1100] eq "1.1 KB"}]
check "human: 999,960 bytes is 1 MB, not 1000 KB" [expr {[facts::human 999960] eq "1 MB"}]
check "human: under 1000 bytes is bytes" [expr {[facts::human 999] eq "999 bytes"}]
check "human: 412 GB" [expr {[facts::human 412000000000] eq "412 GB"}]

# the language, from the name
check "language: main.rs is Rust" [expr {[facts::language /x/main.rs] eq "Rust"}]
check "language: an unknown name has none" [expr {[facts::language /x/data.bin] eq ""}]

# a text file: CRLF endings, no final newline, UTF-8 characters
set f [file join $work notes.txt]
set fh [open $f wb]; puts -nonewline $fh "first \xc3\xa9\r\nsecond\r\nthird"; close $fh
set t [facts::text_info $f 2]
check "text: three lines with no final newline" [expr {[dict get $t lines] == 3}]
check "text: characters counted (the CRs too), not bytes" [expr {[dict get $t chars] == 22}]
check "text: UTF-8" [expr {[dict get $t enc] eq "UTF-8"}]
check "text: CRLF line endings" [expr {[dict get $t eol] eq "CRLF"}]
check "text: the first two lines, without their CR" [expr {[dict get $t head] eq [list "first \u00e9" "second"]}]

# bytes that aren't UTF-8 are Unknown; a file with a NUL is not text
set f [file join $work latin.txt]
set fh [open $f wb]; puts -nonewline $fh "caf\xe9\n"; close $fh
check "text: Latin-1 bytes are Unknown" [expr {[dict get [facts::text_info $f] enc] eq "Unknown"}]
set f [file join $work blob.bin]
set fh [open $f wb]; puts -nonewline $fh "a\0b"; close $fh
check "text: a file with a NUL has no text facts" [expr {[dict get [facts::text_info $f] lines] eq ""}]

# coordinates from the GPS tags, in the boards' form
set x [dict create GPSLatitude {64.0 4.0 41.08} GPSLatitudeRef N GPSLongitude {16.0 13.0 51.6} GPSLongitudeRef W]
check "coords: 64.078° N, 16.231° W" [expr {[facts::coords $x] eq "64.078° N, 16.231° W"}]
check "coords: the south and east hemispheres" [expr {[facts::coords [dict merge $x {GPSLatitudeRef S GPSLongitudeRef E}]] eq "64.078° S, 16.231° E"}]
check "coords: none without the tags" [expr {[facts::coords {Make FUJIFILM}] eq ""}]

# a folder's count is tagged with its path, and counts what is in it
set d [file join $work tree]
file mkdir [file join $d sub]
foreach n {a.jpg b.txt sub/c.png} { set fh [open [file join $d $n] wb]; puts -nonewline $fh "x"; close $fh }
facts::count $d {}
vwait facts::W(busy)
check "count: the path it counted" [expr {$facts::W(path) eq $d}]
check "count: files and folders" [expr {$facts::W(files) == 3 && $facts::W(dirs) == 1}]

# the exposure strip's figures, as the board writes them
check "shutter: 1/250 from 0.004" [expr {[facts::shutter 0.004] eq "1/250"}]
check "shutter: 0.4 s is not a whole part" [expr {[facts::shutter 0.4] eq "0.4 s"}]
check "shutter: 1/3 from its decimal" [expr {[facts::shutter [expr {1.0 / 3}]] eq "1/3"}]
check "shutter: 2 s and up in seconds" [expr {[facts::shutter 2.0] eq "2 s" && [facts::shutter 1.3] eq "1.3 s"}]
set e [facts::exposure {FNumber 8.0 ExposureTime 0.004 ISO 125.0 FocalLength 23.0}]
check "exposure: f/8, 1/250, 125, 23 mm" [expr {$e eq {{f/8 Aperture} {1/250 Shutter} {125 ISO} {{23 mm} Focal}}}]
set e [facts::exposure {FNumber 5.6 FocalLength 16.5}]
check "exposure: a missing figure is blank, 16.5 mm keeps its half" [expr {$e eq {{f/5.6 Aperture} {{} Shutter} {{} ISO} {{16.5 mm} Focal}}}]
check "exposure: a figure that is not a number is blank" [expr {[lindex [facts::exposure {FNumber abc}] 0 0] eq ""}]
check "exposure: zero is no figure" [expr {[lindex [facts::exposure {ExposureTime 0}] 1 0] eq ""}]

# a photo's EXIF (tests/make-exif.py): big-endian from PIL, little-endian built by hand, bare
if {$exifdir ne "" && [file exists [file join $exifdir mm.jpg]]} {
	set x [facts::exif [file join $exifdir mm.jpg]]
	check "exif: the camera" [expr {[facts::camera $x] eq "Fujifilm X-T5"}]
	check "exif: DateTimeOriginal" [expr {[tag $x DateTimeOriginal] eq "2026:08:14 21:43:00"}]
	check "exif: the GPS coordinates" [expr {[facts::coords $x] eq "64.078° N, 16.231° W"}]
	check "exif: the lens" [expr {[tag $x LensModel] eq "XF16-55mm F2.8"}]
	check "exif: the exposure strip (RATIONAL tags)" [expr {[facts::exposure $x] eq {{f/5.6 Aperture} {1/250 Shutter} {125 ISO} {{23 mm} Focal}}}]
	set x [facts::exif [file join $exifdir ii.jpg]]
	check "exif: little-endian: the camera" [expr {[facts::camera $x] eq "Fujifilm X-T20"}]
	check "exif: little-endian: the exposure strip" [expr {[facts::exposure $x] eq {{f/4 Aperture} {{0.4 s} Shutter} {800 ISO} {{16.5 mm} Focal}}}]
	check "exif: little-endian: the GPS coordinates, south and east" [expr {[facts::coords $x] eq "51.500° S, 0.128° E"}]
	check "exif: little-endian: the date" [expr {[tag $x DateTimeOriginal] eq "2026:08:14 21:43:00"}]
	check "exif: no lens tag, no lens" [expr {![dict exists $x LensModel]}]
	set x [facts::exif [file join $exifdir bare.jpg]]
	check "exif: a JPEG without EXIF has none" [expr {$x eq ""}]
	check "exif: and no coordinates or exposure" [expr {[facts::coords $x] eq "" && [lindex [facts::exposure $x] 0 0] eq ""}]
	set f [file join $work notes.txt]
	set fh [open $f w]; puts $fh "not a picture"; close $fh
	check "exif: a text file has none" [expr {[facts::exif $f] eq ""}]
} else {
	puts "  skip exif: no fixtures (tests/make-exif.py needs PIL)"
}

puts [expr {$fails ? "inspector facts: $fails checks failed" : "inspector facts: all checks passed"}]
exit [expr {$fails > 0}]
