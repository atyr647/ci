# mime-defaults.tcl - what opens each kind of file on a fresh install: the shipped xdg/mimeapps.list and the
# desktop entries of the Text editor and Notes, read by Properties' and Files' own lookup (properties/facts.tcl,
# facts::handlers, with its walk up shared-mime-info's type tree), and, when they are installed, by GLib (gio mime)
# and xdg-utils (xdg-mime query default / filetype, what Files' double-click runs through xdg-open):
#   tclsh8.6 tests/mime-defaults.tcl FILES SCRATCH
# FILES is srcpkgs/ribbon-desktop/files, SCRATCH an empty folder. The system is a scratch tree: the shipped entries
# copied into a data folder, stand-ins for Firefox and VLC (the entries their packages ship, programs that do
# nothing), the shipped list as the XDG_CONFIG_DIRS list (it is installed at /usr/share/ribbon/xdg, which
# ribbon-session puts there), a fixture type tree, and the host's own shared-mime-info tree when it has one.
# Prints one line per check.
set D [file normalize [lindex $argv 0]]
set T [file normalize [lindex $argv 1]]
set fails 0
proc check {what ok} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
proc skip {what} { puts "  skip $what" }
proc put {f text} { file mkdir [file dirname $f]; set fh [open $f w]; fconfigure $fh -translation lf -encoding utf-8; puts -nonewline $fh $text; close $fh }
proc desktop {dir id args} {
	set t "\[Desktop Entry\]\nType=Application\n"
	foreach {k v} $args { append t "$k=$v\n" }
	put [file join $dir applications $id.desktop] $t
}
proc stub {name} { put $::T/bin/$name "#!/bin/sh\nexit 0\n"; file attributes $::T/bin/$name -permissions 0755 }
proc def {m} { lindex [facts::handlers $m] 0 }
proc others {m} { lindex [facts::handlers $m] 1 }
# after a change to the entries: facts' own caches dropped, and applications/mimeinfo.cache written again as
# update-desktop-database (the package trigger) writes it; GLib and xdg-mime read associations from it
proc reload {} {
	catch {unset ::facts::apps}; catch {unset ::facts::tree}
	set by {}
	foreach f [lsort [glob -directory $::S/applications *.desktop]] { foreach m [mimes $f] { dict lappend by $m [file tail $f] } }
	set t "\[MIME Cache\]\n"
	dict for {m ids} $by { append t "$m=[join $ids \;]\;\n" }
	put $::S/applications/mimeinfo.cache $t
}
# a desktop entry's MimeType list
proc mimes {f} {
	set fh [open $f]; set t [read $fh]; close $fh
	set l ""
	regexp -line {^MimeType=(.*)$} $t -> l
	lmap x [split $l \;] { if {$x eq ""} continue; set x }
}

# ---- the scratch system -----------------------------------------------------------------------------------------
set H $T/home; set C $T/config; set DH $T/data-home; set S $T/share
file mkdir $H $C $DH $S/applications $T/bin
foreach {k v} [list HOME $H XDG_CONFIG_HOME $C XDG_DATA_HOME $DH XDG_DATA_DIRS $S XDG_CONFIG_DIRS $D/xdg XDG_CURRENT_DESKTOP Ribbon:wlroots] {
	set ::env($k) $v
}
set ::env(PATH) $T/bin:$::env(PATH)
foreach f [list apps/editor/applications/ribbon-editor.desktop apps/notes/applications/ribbon-notes.desktop \
		apps/viewer/org.ribbon.imageviewer.desktop applications/ribbon-files.desktop applications/ribbon-kit-run.desktop] {
	file copy [file join $D $f] $S/applications/
}
# Firefox as its package ships it (no PDF or audio types: Ribbon's list names it for those)
desktop $S firefox Name Firefox Exec {firefox %u} Categories {Network;WebBrowser;} \
	MimeType {text/html;text/xml;application/xhtml+xml;application/vnd.mozilla.xul+xml;text/mml;x-scheme-handler/http;x-scheme-handler/https;}
# an app for "any file" must never become what opens a type that has no app
desktop $S hexer Name Hexer Exec {hexer %f} MimeType {application/octet-stream;}
foreach p {ribbon-editor ribbon-notes ribbon-viewer ribbon-files kit firefox hexer vlc writer} { stub $p }
# a fixture type tree, the most important data folder: an alias, a text kind two levels down, an XML kind
put $DH/mime/aliases "text/x-fixture-alias text/x-fixture-lang\n"
put $DH/mime/subclasses "text/x-fixture-lang text/x-csrc\ntext/x-csrc text/plain\napplication/x-fixture-doc application/xml\napplication/xml text/plain\n"
set host [expr {[file readable /usr/share/mime/subclasses] && [file readable /usr/share/mime/aliases]}]
if {$host} { file mkdir $S/mime; foreach f {aliases subclasses} { file copy /usr/share/mime/$f $S/mime/ } }

source -encoding utf-8 [file join $D properties facts.tcl]
reload

# ---- text: every type the Text editor names, and every kind of text it does not ------------------------------------
set edtypes [mimes $S/applications/ribbon-editor.desktop]
set need {text/plain text/markdown text/x-python application/x-shellscript text/x-tcl text/x-c application/json
	application/xml application/toml text/x-script.python text/x-shellscript text/xml}
set miss [lmap t $need { if {$t in $edtypes} continue; set t }]
check "the Text editor's entry names text/plain, Markdown, Python, shell, Tcl, C, JSON, XML and TOML, under shared-mime-info's and file(1)'s names (missing: $miss)" [expr {$miss eq {}}]
set bad [lmap t $edtypes { if {[def $t] eq "ribbon-editor.desktop"} continue; set t }]
check "each of its [llength $edtypes] types opens in the Text editor (wrong: $bad)" [expr {$bad eq {}}]
set bad {}
foreach t {text/x-rust text/x-fixture-lang text/x-fixture-alias application/x-fixture-doc TEXT/X-Rust} {
	if {[def $t] ne "ribbon-editor.desktop"} { lappend bad "$t [def $t]" }
}
check "a kind of text that no app names follows text/plain up the type tree (an alias, two levels, an XML kind, any text/*) (wrong: $bad)" [expr {$bad eq {}}]
check "the chain is nearest first, aliases resolved, octet-stream left out ([facts::mime_chain text/x-fixture-alias])" \
	[expr {[facts::mime_chain text/x-fixture-alias] eq {text/x-fixture-alias text/x-fixture-lang text/x-csrc text/plain}}]
if {$host} {
	set bad {}
	foreach t {text/x-java text/x-go text/x-ruby application/x-perl application/javascript text/x-cmake application/x-yaml application/x-ruby} {
		if {[lsearch [facts::mime_chain $t] text/plain] < 0} continue
		if {[def $t] ne "ribbon-editor.desktop"} { lappend bad "$t [def $t]" }
	}
	check "with the host's shared-mime-info tree, source files no app names open in the Text editor (wrong: $bad)" [expr {$bad eq {}}]
} else { skip "the host's shared-mime-info tree (no /usr/share/mime/subclasses)" }
check "Markdown opens in the Text editor, and Notes is offered for it ([facts::handlers text/markdown])" \
	[expr {[def text/markdown] eq "ribbon-editor.desktop" && "ribbon-notes.desktop" in [others text/markdown]}]
check "Notes' entry names Markdown and nothing else" [expr {[mimes $S/applications/ribbon-notes.desktop] eq {text/markdown text/x-markdown}}]
check "web pages stay with the browser, not the Text editor they would fall back to ([def text/html], [def application/xhtml+xml])" \
	[expr {[def text/html] eq "firefox.desktop" && [def application/xhtml+xml] eq "firefox.desktop"}]
set bad {}
foreach t [mimes $S/applications/org.ribbon.imageviewer.desktop] { if {[def $t] ne "org.ribbon.imageviewer.desktop"} { lappend bad $t } }
check "pictures still open in the image viewer, every kind its entry names, TIFF too (wrong: $bad)" [expr {$bad eq {} && [def image/tiff] eq "org.ribbon.imageviewer.desktop"}]
check "folders in Files, kits in kit ([def inode/directory], [def application/x-ribbon-kit])" \
	[expr {[def inode/directory] eq "ribbon-files.desktop" && [def application/x-ribbon-kit] eq "ribbon-kit-run.desktop"}]

# ---- the user's text choice reaches the kinds nobody names, and what they take out stays out --------------------------
desktop $S writer Name Writer Exec {writer %f} MimeType {text/plain;}
reload
put $C/mimeapps.list "\[Default Applications\]\ntext/plain=writer.desktop\n"
check "text/plain set to another app in ~/.config: a kind of text nobody names follows it ([def text/x-rust])" [expr {[def text/x-rust] eq "writer.desktop"}]
check "  and the kinds the Text editor names stay with it ([def text/x-python])" [expr {[def text/x-python] eq "ribbon-editor.desktop"}]
check "a kind of text offers its parents' apps after its own (text/x-python: [others text/x-python])" \
	[expr {[others text/x-python] eq {writer.desktop}}]
put $C/mimeapps.list "\[Removed Associations\]\ntext/x-fixture-lang=ribbon-editor.desktop;\n"
check "an app taken out of a type (\[Removed Associations\]) is not its default through a parent either ([facts::handlers text/x-fixture-lang])" \
	[expr {[def text/x-fixture-lang] eq "writer.desktop" && "ribbon-editor.desktop" ni [others text/x-fixture-lang]}]
file delete $C/mimeapps.list $S/applications/writer.desktop
reload

# ---- an app that names the type itself comes before a default set only for a parent (GLib's order: for each type
# nearest first, its defaults and then its associations; a parent is tried only when the nearer type has neither)
desktop $S coder Name Coder Exec {coder %f} MimeType {text/rust;text/x-fixture-lang;}
foreach p {coder} { stub $p }
reload
check "an app that names a kind of text opens it ahead of text/plain's default ([facts::handlers text/x-fixture-lang])" \
	[expr {[def text/x-fixture-lang] eq "coder.desktop" && "ribbon-editor.desktop" in [others text/x-fixture-lang]}]
if {$host && [auto_execok gio] ne ""} {
	if {[catch {exec gio mime text/rust 2>/dev/null} out]} { set out "" }
	set g ""
	regexp {Default application for [^:]*:\s*(\S+)} $out -> g
	check "  and gio mime agrees for text/rust (gio $g, facts [def text/rust])" [expr {$g eq [def text/rust] && $g eq "coder.desktop"}]
} else { skip "gio mime for an app that names a kind of text" }
file delete $S/applications/coder.desktop
reload

# ---- PDF, music, video, archives ---------------------------------------------------------------------------------
check "PDFs open in Firefox ([def application/pdf])" [expr {[def application/pdf] eq "firefox.desktop"}]
set audio {audio/mpeg audio/flac audio/ogg audio/x-vorbis+ogg audio/mp4 audio/x-wav audio/webm}
set bad [lmap t $audio { if {[def $t] eq "firefox.desktop"} continue; set t }]
check "music opens in Firefox with no player installed (wrong: $bad)" [expr {$bad eq {}}]
set vids {video/mp4 video/x-m4v video/x-matroska video/webm video/quicktime video/x-msvideo}
set bad [lmap t $vids { if {[def $t] eq "org.ribbon.imageviewer.desktop"} continue; set t }]
check "video opens in the image viewer (mpv) with no player installed (wrong: $bad)" [expr {$bad eq {}}]
desktop $S vlc Name {VLC media player} Exec {vlc --started-from-file %U} \
	MimeType {audio/mpeg;audio/flac;audio/ogg;audio/x-vorbis+ogg;audio/mp4;audio/x-wav;audio/webm;video/mp4;video/x-matroska;video/webm;}
reload
set bad [lmap t $audio { if {[def $t] eq "vlc.desktop"} continue; set t }]
check "with VLC installed music opens there (wrong: $bad)" [expr {$bad eq {}}]
check "  and so does video ([def video/mp4], [def video/x-matroska])" [expr {[def video/mp4] eq "vlc.desktop" && [def video/x-matroska] eq "vlc.desktop"}]
set bad {}
foreach t {application/zip application/x-tar application/x-7z-compressed application/gzip application/x-compressed-tar application/vnd.rar} {
	if {[facts::handlers $t] ne {{} {}}} { lappend bad "$t [facts::handlers $t]" }
}
check "archives open in nothing (no archive app), not in an app for any file (wrong: $bad)" [expr {$bad eq {}}]

# ---- GLib agrees ---------------------------------------------------------------------------------------------------
# (text/x-rust is in no tree: shared-mime-info makes it a kind of text/plain, GLib does not know it)
set types [concat $need text/x-fixture-lang text/markdown text/html application/pdf $audio video/mp4 image/png inode/directory]
if {[auto_execok gio] ne ""} {
	set bad {}
	foreach t $types {
		if {[catch {exec gio mime $t 2>/dev/null} out]} { set out "" }
		set g ""
		regexp {Default application for [^:]*:\s*(\S+)} $out -> g
		if {$g ne [def $t]} { lappend bad "$t (gio $g, facts [def $t])" }
	}
	check "gio mime reads the same default for [llength $types] types (differ: $bad)" [expr {$bad eq {}}]
} else { skip "gio mime (no gio)" }

# ---- xdg-utils agrees (Files' double-click: xdg-open asks xdg-mime) -----------------------------------------------------
if {[auto_execok xdg-mime] ne ""} {
	catch {exec xdg-mime --version} v
	regexp {(\d+)\.(\d+)} $v -> maj min
	set lists [expr {[info exists maj] && ($maj > 1 || $min >= 2)}]
	set bad {}
	foreach t $types {
		# xdg-utils before 1.2 reads only the first app of a list (VLC; the fallback is not seen)
		if {!$lists && [string match audio/* $t]} continue
		if {[catch {exec xdg-mime query default $t 2>/dev/null} g]} { set g "" }
		if {$g ne [def $t] && !($g eq "" && $t in {text/x-rust text/x-fixture-lang})} { lappend bad "$t (xdg-mime $g, facts [def $t])" }
	}
	check "xdg-mime query default names the same app (xdg-utils $v[expr {$lists ? "" : ", lists skipped"}]; differ: $bad)" [expr {$bad eq {}}]
	file mkdir $T/files
	put $T/files/notes.md "# Today\n\nSome *words*.\n"
	put $T/files/tool.py "#!/usr/bin/env python3\nprint('hi')\n"
	put $T/files/run.sh "#!/bin/sh\necho hi\n"
	put $T/files/data.json "{\"a\": 1}\n"
	put $T/files/feed.xml "<?xml version=\"1.0\"?>\n<feed/>\n"
	put $T/files/main.c "#include <stdio.h>\nint main(void) { return 0; }\n"
	put $T/files/table.csv "a,b\n1,2\n"
	put $T/files/plain.txt "hello\n"
	set bad {}
	foreach f [lsort [glob $T/files/*]] {
		if {[catch {exec xdg-mime query filetype $f 2>/dev/null} m]} { set m "?" }
		set m [lindex [split $m \;] 0]
		if {[catch {exec xdg-mime query default $m 2>/dev/null} g]} { set g "" }
		if {$g ne "ribbon-editor.desktop"} { lappend bad "[file tail $f] ($m: $g)" }
	}
	check "xdg-open's lookup sends Markdown, Python, shell, JSON, XML, C, CSV and plain text files to the Text editor (wrong: $bad)" [expr {$bad eq {}}]
} else { skip "xdg-mime (no xdg-utils)" }

puts [expr {$fails ? "  $fails failed" : "  all mime checks passed"}]
exit [expr {$fails ? 1 : 0}]
