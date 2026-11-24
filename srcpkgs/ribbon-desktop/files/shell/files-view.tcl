# files-view.tcl - what Ribbon Files' list and grid say about each item (Files-List,
# Files-Grid-Thumbs): the kind ("Markdown", "Folder"), a folder's item count, the
# relative date ("Today, 13:52", "2 Nov"), the status bar's line, and pictures'
# thumbnails from the freedesktop.org thumbnail cache.
#
# Thumbnails (the Thumbnail Managing Standard): ~/.cache/thumbnails/normal/MD5(URI).png,
# at most 128 px, with the Thumb::URI and Thumb::MTime text chunks; one that does not
# match the file's URI and mtime is made again. A picture ffmpeg cannot read is noted
# in fail/ribbon-files/ and not tried again until it changes. Made in the background,
# one at a time (ffmpeg), and drawn when ready; the tile's picture is the cached one
# cut to the tile (ffmpeg again, raw RGBA) with its corners rounded here.

namespace eval files {
	variable kinds        ;# extension -> kind
	array set kinds {}
	variable counts       ;# folder -> {mtime count}
	array set counts {}
	variable thumbq {}     ;# paths waiting for a thumbnail
	variable thumbbusy 0
	variable thumbimg      ;# "path w h" -> photo
	array set thumbimg {}
	variable thumbfail     ;# path -> mtime that failed
	array set thumbfail {}
}

# ---- kinds, counts, dates ------------------------------------------------------------

proc files::mimeof {name} {
	set byext {
		jpg image/jpeg jpeg image/jpeg png image/png webp image/webp gif image/gif svg image/svg+xml avif image/avif
		heic image/heic bmp image/bmp tif image/tiff tiff image/tiff
		mp3 audio/mpeg flac audio/flac ogg audio/ogg opus audio/ogg wav audio/x-wav m4a audio/mp4 aac audio/aac
		mp4 video/mp4 mkv video/x-matroska webm video/webm mov video/quicktime avi video/x-msvideo
		pdf application/pdf txt text/plain md text/markdown html text/html htm text/html css text/css csv text/csv
		zip application/zip tar application/x-tar gz application/gzip tgz application/x-compressed-tar
		xz application/x-xz zst application/zstd bz2 application/x-bzip2 7z application/x-7z-compressed rar application/vnd.rar
		iso application/x-cd-image img application/x-raw-disk-image kit application/x-ribbon-kit
		tcl text/x-tcl py text/x-python sh application/x-shellscript c text/x-csrc h text/x-chdr rs text/rust
		js text/javascript ts text/x-typescript go text/x-go lua text/x-lua json application/json toml application/toml
		yaml application/yaml yml application/yaml xml application/xml sql application/sql
		odt application/vnd.oasis.opendocument.text ods application/vnd.oasis.opendocument.spreadsheet
		docx application/vnd.openxmlformats-officedocument.wordprocessingml.document
		xlsx application/vnd.openxmlformats-officedocument.spreadsheetml.sheet epub application/epub+zip
		ttf font/ttf otf font/otf woff2 font/woff2 desktop application/x-desktop
	}
	set e [string tolower [string trimleft [file extension $name] .]]
	if {[dict exists $byext $e]} { return [dict get $byext $e] }
	return ""
}

# "Markdown", "JPEG image", "Folder", by the name only (the list never reads files to draw):
# the words the boards and Ribbon's file chooser use (chooser-main.tcl page::kind), else
# shared-mime-info's comment when the Properties modules are there, else "XYZ file".
proc files::kindname {name isdir} {
	variable kinds
	if {$isdir} { return Folder }
	set e [string tolower [string trimleft [file extension $name] .]]
	if {[info exists kinds($e)]} { return $kinds($e) }
	set k [dict create jpg "JPEG image" jpeg "JPEG image" png "PNG image" gif "GIF image" webp "WebP image" avif "AVIF image" \
		bmp "BMP image" svg "SVG image" heic "HEIC image" tif "TIFF image" tiff "TIFF image" \
		md "Markdown" markdown "Markdown" txt "Plain text" pdf "PDF document" html "HTML page" json "JSON" \
		mp3 "MP3 audio" flac "FLAC audio" ogg "Ogg audio" opus "Opus audio" wav "WAV audio" m4a "MPEG-4 audio" \
		mp4 "MPEG-4 video" mkv "Matroska video" webm "WebM video" mov "QuickTime video" \
		zip "Zip archive" tar "Tar archive" gz "Gzip archive" tgz "Tar archive" xz "XZ archive" zst "Zstd archive" \
		bz2 "Bzip2 archive" 7z "7-Zip archive" rar "RAR archive" \
		iso "Disc image" tcl "Tcl source" py "Python source" sh "Shell script" c "C source" h "C header" rs "Rust source" \
		ribbon-theme "Ribbon theme" conf "Settings" desktop "App launcher"]
	if {[dict exists $k $e]} {
		set out [dict get $k $e]
	} elseif {[set m [mimeof $name]] ne "" && [info commands ::facts::mime_comment] ne "" && ![catch {facts::mime_comment $m} c] && $c ne ""} {
		set out [string toupper [string index $c 0]][string range $c 1 end]
	} elseif {$e eq ""} {
		set out File
	} else { set out "[string toupper $e] file" }
	set kinds($e) $out
	return $out
}

# A folder's item count (its names that do not start with a dot), kept until it changes.
proc files::count {dir} {
	variable counts
	if {[catch {file mtime $dir} m]} { return "" }
	if {[info exists counts($dir)] && [lindex $counts($dir) 0] == $m} { return [lindex $counts($dir) 1] }
	if {[catch {llength [glob -nocomplain -directory $dir *]} n]} { return "" }
	set counts($dir) [list $m $n]
	return $n
}

proc files::items {n} { return "$n item[expr {$n == 1 ? "" : "s"}]" }

# "Today, 13:52", "Yesterday, 18:40", "2 Nov", "4 Apr 2024".
proc files::when {t {now ""}} {
	if {$now eq ""} { set now [clock seconds] }
	set day [clock format $t -format %Y-%m-%d]
	if {$day eq [clock format $now -format %Y-%m-%d]} { return "Today, [clock format $t -format %H:%M]" }
	if {$day eq [clock format [clock add $now -1 day] -format %Y-%m-%d]} { return "Yesterday, [clock format $t -format %H:%M]" }
	set d [string trimleft [clock format $t -format %d] 0]
	if {[clock format $t -format %Y] eq [clock format $now -format %Y]} { return "$d [clock format $t -format %b]" }
	return "$d [clock format $t -format {%b %Y}]"
}

# The status bar's left: "30 items · Jökulsárlón.jpg selected, 21.6 MB", "8 items · 5 selected, 813 MB".
proc files::selline {items sel} {
	set left [items [llength $items]]
	if {![llength $sel]} { return $left }
	set bytes 0; set files 0
	foreach it $items {
		lassign $it name isdir size
		if {$name in $sel && !$isdir} { incr bytes $size; incr files }
	}
	set what [expr {[llength $sel] == 1 ? "[lindex $sel 0] selected" : "[llength $sel] selected"}]
	if {$files} { append what ", [human $bytes]" }
	return "$left · $what"
}

# ---- thumbnails ----------------------------------------------------------------------------

proc files::thumbable {name} { string match image/* [mimeof $name] }

proc files::thumbdir {{kind normal}} {
	set c [expr {[info exists ::env(XDG_CACHE_HOME)] && $::env(XDG_CACHE_HOME) ne "" ? $::env(XDG_CACHE_HOME) : [file join [home] .cache]}]
	file join $c thumbnails $kind
}

# MD5 of the bytes S, as hex (md5sum: coreutils; tcllib's md5 is not a dependency)
proc files::md5 {s} {
	set fh [::open |[list md5sum] r+]
	fconfigure $fh -translation binary
	puts -nonewline $fh $s
	chan close $fh write
	set out [read $fh]
	::close $fh
	lindex $out 0
}

proc files::thumbfile {p {kind normal}} {
	set uri file://[uri [file normalize $p]]
	return [list $uri [file join [thumbdir $kind] [md5 [encoding convertto utf-8 $uri]].png]]
}

# The tEXt chunks of a PNG file as a dict ("" when it is not one).
proc files::pngtext {f} {
	if {[catch {::open $f rb} fh]} { return "" }
	set d [read $fh]; ::close $fh
	if {[string range $d 0 7] ne "\x89PNG\r\n\x1a\n"} { return "" }
	set out {}
	set i 8
	while {$i + 8 <= [string length $d]} {
		binary scan $d @${i}Ia4 len type
		if {$type eq "tEXt"} {
			set body [string range $d [expr {$i + 8}] [expr {$i + 7 + $len}]]
			set z [string first \0 $body]
			if {$z > 0} { dict set out [string range $body 0 [expr {$z - 1}]] [encoding convertfrom iso8859-1 [string range $body [expr {$z + 1}] end]] }
		}
		if {$type eq "IEND"} break
		set i [expr {$i + 12 + $len}]
	}
	return $out
}

# Put the spec's chunks in after IHDR.
proc files::pngtag {data pairs} {
	set chunks ""
	foreach {k v} $pairs {
		set body [encoding convertto iso8859-1 $k]\0[encoding convertto utf-8 $v]
		append chunks [binary format I [string length $body]] tEXt $body [binary format I [zlib crc32 tEXt$body]]
	}
	binary scan $data @8I ihdr
	set at [expr {8 + 12 + $ihdr}]
	string cat [string range $data 0 [expr {$at - 1}]] $chunks [string range $data $at end]
}

# The cached thumbnail of P if it is current, else "".
proc files::thumb_cached {p} {
	lassign [thumbfile $p] uri f
	if {![file exists $f] || [catch {file mtime $p} m]} { return "" }
	set t [pngtext $f]
	if {[dict exists $t Thumb::URI] && [dict get $t Thumb::URI] eq $uri && [dict exists $t Thumb::MTime] && [dict get $t Thumb::MTime] == $m} { return $f }
	return ""
}

# The tile's picture for P, W x H, or "" (asked for: drawn when it is ready).
proc files::thumb {p w h} {
	variable thumbimg
	variable thumbq
	variable thumbfail
	set k [list $p $w $h]
	if {[info exists thumbimg($k)]} {
		lassign $thumbimg($k) m img
		if {![catch {file mtime $p} now] && $now == $m} { return $img }
		catch {image delete $img}; unset thumbimg($k)
	}
	if {[catch {file mtime $p} m] || ([info exists thumbfail($p)] && $thumbfail($p) == $m)} { return "" }
	if {[auto_execok ffmpeg] eq ""} { return "" }
	# never the cache's own pictures (the spec: each would make another one there)
	if {[string first [file normalize [file dirname [thumbdir]]]/ [file normalize $p]] == 0} { return "" }
	if {$k ni $thumbq} { lappend thumbq $k }
	after idle files::thumb_next
	return ""
}

proc files::thumb_next {} {
	variable thumbq
	variable thumbbusy
	if {$thumbbusy || ![llength $thumbq]} return
	set thumbq [lassign $thumbq k]
	set thumbbusy 1
	if {[catch {thumb_make {*}$k} err]} { set thumbbusy 0; after idle files::thumb_next }
}

# Step 1: the cache's 128 px PNG (unless it is current); step 2: the tile from it.
proc files::thumb_make {p w h} {
	variable thumbfail
	set f [thumb_cached $p]
	if {$f ne ""} { return [thumb_tile $p $w $h $f] }
	lassign [thumbfile $p] uri f
	set m [file mtime $p]
	# noted in fail/ribbon-files (by this run or an earlier one) and unchanged since: not tried again
	lassign [thumbfile $p fail/ribbon-files] - ff
	set t [pngtext $ff]
	if {[dict exists $t Thumb::URI] && [dict get $t Thumb::URI] eq $uri && [dict exists $t Thumb::MTime] && [dict get $t Thumb::MTime] == $m} {
		set thumbfail($p) $m
		set ::files::thumbbusy 0
		after idle files::thumb_next
		return
	}
	set dir [file dirname $f]
	file mkdir $dir
	catch {file attributes [file dirname $dir] -permissions 0700}
	set tmp $f.ribbon-[pid]
	set fh [::open |[list ffmpeg -nostdin -v error -y -i $p -frames:v 1 -vf scale=128:128:force_original_aspect_ratio=decrease:flags=area -f image2 -c:v png $tmp 2>@1] r]
	fconfigure $fh -blocking 0
	fileevent $fh readable [list files::thumb_made $fh $p $w $h $uri $f $tmp $m]
}

proc files::thumb_made {fh p w h uri f tmp m} {
	variable thumbbusy
	variable thumbfail
	read $fh
	if {![eof $fh]} return
	fconfigure $fh -blocking 1
	set bad [catch {::close $fh}]
	if {!$bad && ![catch {::open $tmp rb} in]} {
		set d [read $in]; ::close $in
		set bad [catch {
			set out [::open $tmp wb]; puts -nonewline $out [pngtag $d [list Thumb::URI $uri Thumb::MTime $m Software {Ribbon Files}]]; ::close $out
			file attributes $tmp -permissions 0600
			file rename -force -- $tmp $f
		}]
	} else { set bad 1 }
	catch {file delete -- $tmp}
	if {$bad} {
		# the spec's fail folder: an empty PNG with the same chunks, so it is not tried again
		set thumbfail($p) $m
		lassign [thumbfile $p fail/ribbon-files] - ff
		catch {file mkdir [file dirname $ff]; set o [::open $ff wb]; puts -nonewline $o [pngtag [raster::png 1 1 {{0 0 0 0}}] [list Thumb::URI $uri Thumb::MTime $m]]; ::close $o}
		set thumbbusy 0
		after idle files::thumb_next
		return
	}
	if {[catch {thumb_tile $p $w $h $f}]} { set thumbbusy 0; after idle files::thumb_next }
}

proc files::thumb_tile {p w h f} {
	set fh [::open |[list ffmpeg -nostdin -v error -i $f -frames:v 1 -vf scale=$w:$h:force_original_aspect_ratio=increase:flags=area,crop=$w:$h -f rawvideo -pix_fmt rgba - 2>/dev/null] rb]
	fconfigure $fh -blocking 0 -translation binary
	set ::files::thumbraw($fh) ""
	fileevent $fh readable [list files::thumb_tiled $fh $p $w $h]
}

proc files::thumb_tiled {fh p w h} {
	variable thumbbusy
	variable thumbimg
	variable thumbraw
	append thumbraw($fh) [read $fh]
	if {![eof $fh]} return
	set raw $thumbraw($fh); unset thumbraw($fh)
	catch {::close $fh}
	set thumbbusy 0
	after idle files::thumb_next
	if {[string length $raw] != $w * $h * 4 || [catch {file mtime $p} m]} return
	set img [image create photo -data [thumb_png $raw $w $h 6]]
	set thumbimg([list $p $w $h]) [list $m $img]
	# the windows that show P's folder draw it
	foreach win [windows] {
		if {[file dirname $p] eq $::files::st($win,path) && $::files::st($win,view) eq "grid"} { layout $win }
	}
}

# Raw RGBA rows with the corners rounded (radius R, anti-aliased) as PNG bytes.
proc files::thumb_png {raw w h r} {
	binary scan $raw cu* px
	set rows {}
	set i 0
	for {set y 0} {$y < $h} {incr y} {
		set row [lrange $px $i [expr {$i + $w * 4 - 1}]]
		incr i [expr {$w * 4}]
		if {$y < $r || $y >= $h - $r} {
			for {set x 0} {$x < $r} {incr x} {
				foreach xx [list $x [expr {$w - 1 - $x}]] {
					set cx [expr {$xx < $r ? $r : $w - $r}]; set cy [expr {$y < $r ? $r : $h - $r}]
					set d [expr {hypot($xx + 0.5 - $cx, $y + 0.5 - $cy)}]
					set a [expr {max(0.0, min(1.0, $r - $d + 0.5))}]
					set k [expr {$xx * 4 + 3}]
					lset row $k [expr {round([lindex $row $k] * $a)}]
				}
			}
		}
		lappend rows $row
	}
	raster::png $w $h $rows
}
