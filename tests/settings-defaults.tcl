# settings-defaults.tcl - Settings → Default apps' backend (apps/settings/defaults.tcl) with no display, against a
# scratch tree of .desktop files, mimeapps.list files and xdg-terminals.list files that this test makes:
#   tclsh8.6 tests/settings-defaults.tcl FILES SCRATCH
# FILES is the srcpkgs/ribbon-desktop/files folder, SCRATCH an empty folder. It checks the apps read (and the ones
# left out), each row's candidates and default through the lookup order, the writes (every type, every other line
# kept, atomic, a link kept, a failure changing nothing), the terminal list, that Properties' own code
# (properties/facts.tcl) reads what is written and the other way round, that apps/term/bin/ribbon-terminal starts the
# terminal the backend wrote (stub programs), the watch for changes made elsewhere, and, when gio is installed, that
# GLib reads the same default and that the backend reads what gio writes. Prints one line per check.
set D [lindex $argv 0]
set T [file normalize [lindex $argv 1]]
set fails 0
proc check {what ok} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
proc put {f text} { file mkdir [file dirname $f]; set fh [open $f w]; fconfigure $fh -translation binary; puts -nonewline $fh [encoding convertto utf-8 $text]; close $fh }
proc get {f} { set fh [open $f r]; fconfigure $fh -translation binary; set d [read $fh]; close $fh; return $d }
proc desktop {dir id args} {
	set t "\[Desktop Entry\]\nType=Application\n"
	foreach {k v} $args { append t "$k=$v\n" }
	put [file join $dir applications $id.desktop] $t
}
proc row {id} { foreach r [dict get [defapps::model] rows] { if {[dict get $r id] eq $id} { return $r } } }
proc cur {id} { dict get [row $id] current }
proc ids {id} { lmap it [dict get [row $id] items] { lindex $it 0 } }
proc names {id} { lmap it [dict get [row $id] items] { lindex $it 1 } }

# ---- the scratch system ---------------------------------------------------------------------------------------
set H $T/home; set C $T/config; set DH $T/data-home; set U $T/usr-share; set L $T/usr-local-share; set E $T/etc-xdg
file mkdir $H $C $DH $U $L $E $T/bin
foreach {k v} [list HOME $H XDG_CONFIG_HOME $C XDG_DATA_HOME $DH XDG_DATA_DIRS $L:$U XDG_CONFIG_DIRS $E XDG_CURRENT_DESKTOP Ribbon RIBBON_DEFAULTS_ROOT $T/root] { set ::env($k) $v }
set ::env(PATH) $T/bin:$::env(PATH)

desktop $U firefox Name Firefox Exec {firefox %u} Categories {Network;WebBrowser;} MimeType {text/html;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;application/pdf;}
desktop $U chromium Name Chromium Exec {chromium %U} Categories {Network;WebBrowser;} MimeType {text/html;x-scheme-handler/http;x-scheme-handler/https;}
desktop $U surf Name Surf Exec surf Categories {WebBrowser;}
desktop $U writer Name {LibreOffice Writer} Exec {soffice --writer %U} Categories {Office;} MimeType {text/html;text/plain;}
desktop $U mailer Name Mail Exec {mailer %u} MimeType {x-scheme-handler/mailto;message/rfc822;}
desktop $U ribbon-files Name Files Exec {ribbon-files %U} Categories {System;FileManager;} MimeType {inode/directory;}
desktop $U ribbon-editor Name {Text editor} Exec {ribbon-editor %F} Categories {Utility;TextEditor;} MimeType {text/plain;}
desktop $U org.ribbon.imageviewer Name {Image viewer} Exec {ribbon-viewer %F} MimeType {image/png;image/jpeg;image/gif;image/webp;image/bmp;image/avif;}
desktop $U paint Name Paint Exec paint MimeType {image/png;image/jpeg;image/x-xcf;text/plain2;}
desktop $U ribbon-terminal Name Terminal Exec ribbon-terminal Categories {System;TerminalEmulator;}
desktop $U alacritty Name Alacritty Exec alacritty TryExec alacritty Categories {System;TerminalEmulator;}
desktop $U org.codeberg.dnkl.foot Name Foot Exec foot Categories {System;TerminalEmulator;}
desktop $U org.codeberg.dnkl.footclient Name {Foot Client} Exec footclient Categories {System;TerminalEmulator;}
desktop $U org.codeberg.dnkl.foot-server Name {Foot Server} Exec {foot --server} Categories {System;TerminalEmulator;}
desktop $U mpv Name {mpv Media Player} Exec {mpv -- %U} MimeType {audio/mpeg;audio/flac;audio/x-opus+ogg;video/mp4;video/x-matroska;video/x-flv;}
# the ones that are not offered
desktop $U gone Name Gone Exec gone Hidden true MimeType {text/plain;x-scheme-handler/http;} Categories {WebBrowser;TerminalEmulator;}
desktop $U kit-run Name {Run kit} Exec {kit run %f} NoDisplay true MimeType {text/plain;application/x-ribbon-kit;}
desktop $U kde-only Name Konqueror Exec konqueror OnlyShowIn {KDE;} MimeType {x-scheme-handler/http;} Categories {WebBrowser;}
desktop $U not-here Name Epiphany Exec epiphany NotShowIn {GNOME;Ribbon;} MimeType {x-scheme-handler/http;}
desktop $U no-binary Name Kitty Exec kitty TryExec $T/bin/kitty-is-not-there Categories {TerminalEmulator;}
desktop $U no-exec Name Nothing MimeType {text/plain;}
put $U/applications/a-link.desktop "\[Desktop Entry\]\nType=Link\nName=A link\nURL=http://example.org\nMimeType=text/plain;\n"
put $U/applications/garbage.desktop "\x00\x01\xff\xfe not a desktop file\n=\n\[\n"
put $U/applications/action-only.desktop "\[Desktop Action new\]\nName=Sneaky\nExec=sneaky\nMimeType=text/plain;\n"
file mkdir $U/applications/folder.desktop
# the data home's file of an id wins; /usr/local/share comes before /usr/share
desktop $L chromium Name {Chromium (local)} Exec {chromium %U} Categories {WebBrowser;} MimeType {x-scheme-handler/http;x-scheme-handler/https;}
desktop $DH mailer Name {My Mail} Exec {mailer %u} MimeType {x-scheme-handler/mailto;}
put $T/bin/alacritty "#!/bin/sh\n"; file attributes $T/bin/alacritty -permissions 0755
# Ribbon's shipped defaults, in the config dirs here
put $E/mimeapps.list "# Ribbon defaults; yours in ~/.config/mimeapps.list win.\n\[Default Applications\]\ninode/directory=ribbon-files.desktop\nimage/png=org.ribbon.imageviewer.desktop\nimage/jpeg=org.ribbon.imageviewer.desktop\ntext/plain=ribbon-editor.desktop\n"
# a data folder's list: lower than the config dirs
put $U/applications/mimeapps.list "\[Default Applications\]\ntext/plain=writer.desktop\nx-scheme-handler/http=uninstalled.desktop;chromium.desktop;\n\[Added Associations\]\napplication/zip=ribbon-files.desktop;\n"

source [file join $D apps settings defaults.tcl]

# ---- reading --------------------------------------------------------------------------------------------------
set m [defapps::model]
check "the model has the ten rows of the board, in its order" \
	[expr {[lmap r [dict get $m rows] { dict get $r id }] eq {web mail files terminal text pictures music video pdf archives}}]
check "  six open with, four are media" \
	[expr {[lmap r [dict get $m rows] { dict get $r group }] eq {opens opens opens opens opens opens media media media media}}]
check "the row labels are the board's" \
	[expr {[lmap r [dict get $m rows] { dict get $r label }] eq {Web Mail Files Terminal Text Pictures Music Video {Documents (PDF)} Archives}}]
check "Web offers the browsers by name: by their http handler or the WebBrowser category, not by text/html alone ([names web])" \
	[expr {[ids web] eq {chromium.desktop firefox.desktop surf.desktop}}]
check "  an id's first file wins (/usr/local/share before /usr/share): [lindex [names web] 0]" [expr {[lindex [names web] 0] eq "Chromium (local)"}]
check "  hidden, OnlyShowIn another desktop, NotShowIn this one are not offered" \
	[expr {"gone.desktop" ni [ids web] && "kde-only.desktop" ni [ids web] && "not-here.desktop" ni [ids web]}]
check "Web's default skips an id that is not installed and takes the next of the list (chromium)" [expr {[cur web] eq "chromium.desktop"}]
check "the subtitle names the browser" [expr {[dict get $m subtitle] eq "Chromium (local) for the web"}]
check "Mail: the data home's entry (My Mail), the first associated app with no default anywhere" \
	[expr {[cur mail] eq "mailer.desktop" && [names mail] eq {{My Mail}}}]
check "Files: Ribbon's shipped default from \$XDG_CONFIG_DIRS" [expr {[cur files] eq "ribbon-files.desktop"}]
check "Text: the config dirs' list beats a data folder's (Text editor, not Writer)" [expr {[cur text] eq "ribbon-editor.desktop"}]
check "  Text offers the editor and Writer; not a NoDisplay handler, a Link, an entry with no Exec, a folder, garbage ([names text])" \
	[expr {[ids text] eq {writer.desktop ribbon-editor.desktop}}]
check "Pictures: the viewer, and Paint is offered" [expr {[cur pictures] eq "org.ribbon.imageviewer.desktop" && [ids pictures] eq {org.ribbon.imageviewer.desktop paint.desktop}}]
check "Music and Video: mpv, the first associated app" [expr {[cur music] eq "mpv.desktop" && [cur video] eq "mpv.desktop"}]
check "Documents (PDF): Firefox declares application/pdf" [expr {[cur pdf] eq "firefox.desktop"}]
check "Archives: an Added Association makes Files the app" [expr {[cur archives] eq "ribbon-files.desktop" && [ids archives] eq {ribbon-files.desktop}}]
check "Terminal: Ribbon Terminal with no list; Alacritty and Foot are offered, not foot's server or client, not one whose TryExec is missing ([names terminal])" \
	[expr {[cur terminal] eq "ribbon-terminal.desktop" && [ids terminal] eq {alacritty.desktop org.codeberg.dnkl.foot.desktop ribbon-terminal.desktop}}]
check "no row with an app has a Not set item" [expr {[lsearch -exact [concat {*}[lmap r [dict get $m rows] { lmap it [dict get $r items] { lindex $it 0 } }]] ""] < 0}]

# Ribbon's own list (/usr/share/ribbon/xdg/mimeapps.list, under the test's root) comes after the config dirs and
# before the data folders
put $T/root/usr/share/ribbon/xdg/mimeapps.list "\[Default Applications\]\nx-scheme-handler/http=firefox.desktop\ntext/plain=writer.desktop\n"
defapps::refresh
check "Ribbon's shipped list beats a data folder's (Firefox) and gives way to the config dirs' (Text editor)" \
	[expr {[cur web] eq "firefox.desktop" && [cur text] eq "ribbon-editor.desktop"}]
file delete $T/root/usr/share/ribbon/xdg/mimeapps.list
defapps::refresh

# the user's list wins; Removed Associations take an app out; a default that is not offered is still shown
put $C/mimeapps.list "\[Default Applications\]\ntext/plain=kit-run.desktop\nx-scheme-handler/http=firefox.desktop\n\[Removed Associations\]\nimage/png=paint.desktop;\nimage/jpeg=paint.desktop;\nimage/webp=paint.desktop;\nimage/gif=paint.desktop;\n"
check "refresh sees the user's new mimeapps.list" [defapps::refresh]
check "  nothing changed since: refresh does nothing" [expr {![defapps::refresh]}]
check "the user's list wins: Firefox for the web" [expr {[cur web] eq "firefox.desktop" && [dict get [defapps::model] subtitle] eq "Firefox for the web"}]
check "a default that is not offered (NoDisplay) is in its row's list all the same" [expr {[cur text] eq "kit-run.desktop" && "kit-run.desktop" in [ids text]}]
check "Removed Associations for every type take Paint out of Pictures" [expr {[ids pictures] eq {org.ribbon.imageviewer.desktop}}]

# nothing installed for a row: Not set
file delete $U/applications/mpv.desktop
defapps::refresh
check "with no player installed Music and Video are Not set, with that one item" \
	[expr {[cur music] eq "" && [cur video] eq "" && [dict get [row music] items] eq {{{} {Not set}}} && [defapps::name ""] eq "Not set"}]
desktop $U mpv Name {mpv Media Player} Exec {mpv -- %U} MimeType {audio/mpeg;audio/flac;audio/x-opus+ogg;video/mp4;video/x-matroska;video/x-flv;}
desktop $U tunes Name Tunes Exec tunes MimeType {audio/mpeg;audio/x-mod;}
defapps::refresh
check "an app installed since is offered (mpv, Tunes)" [expr {[ids music] eq {mpv.desktop tunes.desktop}}]
file delete $U/applications/firefox.desktop $U/applications/chromium.desktop $L/applications/chromium.desktop $U/applications/surf.desktop
defapps::refresh
check "with the browsers gone, the one that would still open a link is shown though it is not offered elsewhere (as Files finds it)" \
	[expr {[cur web] eq "kde-only.desktop" && [ids web] eq {kde-only.desktop} && [dict get [defapps::model] subtitle] eq "Konqueror for the web"}]
file delete $U/applications/kde-only.desktop $U/applications/not-here.desktop
defapps::refresh
check "with no browser the subtitle is No web browser" [expr {[dict get [defapps::model] subtitle] eq "No web browser" && [cur web] eq ""}]
desktop $U firefox Name Firefox Exec {firefox %u} Categories {Network;WebBrowser;} MimeType {text/html;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;application/pdf;}
desktop $U chromium Name Chromium Exec {chromium %U} Categories {Network;WebBrowser;} MimeType {text/html;x-scheme-handler/http;x-scheme-handler/https;}
defapps::refresh

# ---- writing --------------------------------------------------------------------------------------------------
set before "# my own notes\n\[Added Associations\]\ntext/plain=writer.desktop;\nimage/png=paint.desktop;\n\n\[Default Applications\]\ntext/plain=kit-run.desktop\nx-scheme-handler/http=firefox.desktop;surf.desktop;\napplication/x-thing=thing.desktop\nx-scheme-handler/http=old-duplicate.desktop\n\n\[Removed Associations\]\ntext/html=chromium.desktop;writer.desktop;\nx-scheme-handler/https=chromium.desktop;\nimage/gif=paint.desktop;\n\[X-Other Section\]\nkey with spaces = kept ; as is\nx-scheme-handler/http=not-touched-here.desktop\n"
put $C/mimeapps.list $before
file attributes $C/mimeapps.list -permissions 0600
defapps::refresh
check "choose web chromium is written" [defapps::choose web chromium.desktop]
set after [get $C/mimeapps.list]
set want "# my own notes\n\[Added Associations\]\ntext/plain=writer.desktop;\nimage/png=paint.desktop;\n\n\[Default Applications\]\ntext/plain=kit-run.desktop\nx-scheme-handler/http=chromium.desktop\napplication/x-thing=thing.desktop\nx-scheme-handler/https=chromium.desktop\ntext/html=chromium.desktop\n\n\[Removed Associations\]\ntext/html=writer.desktop;\nimage/gif=paint.desktop;\n\[X-Other Section\]\nkey with spaces = kept ; as is\nx-scheme-handler/http=not-touched-here.desktop\n"
check "  http, https and text/html are Chromium's in \[Default Applications\]; every other line and section is as it was; Chromium is out of the Removed lines that would undo it" [expr {$after eq $want}]
if {$after ne $want} { puts "---- got\n$after---- want\n$want" }
check "  the file's mode is kept (0600) and no temp file is left" \
	[expr {[file attributes $C/mimeapps.list -permissions] eq "00600" && [glob -nocomplain -directory $C *.tmp*] eq {}}]
check "  the model follows: Chromium for the web" [expr {[cur web] eq "chromium.desktop" && [dict get [defapps::model] subtitle] eq "Chromium for the web"}]
set saved $defapps::apps
dict set defapps::apps zz-coder.desktop mimes {text/plain text/markdown text/x-python application/json application/x-shellscript text/html application/pdf image/png}
check "an editor chosen for Text takes every kind of text it names, not Web's text/html nor other rows' types" \
	[expr {[defapps::types_for text zz-coder.desktop] eq {text/plain text/markdown text/x-python application/json application/x-shellscript}}]
set defapps::apps $saved
check "choose web firefox also takes Firefox's own xhtml type (the row's pattern), not its PDF type" \
	[expr {[defapps::choose web firefox.desktop] && [string match "*\napplication/xhtml+xml=firefox.desktop\n*" [get $C/mimeapps.list]] && ![string match *application/pdf=* [get $C/mimeapps.list]]}]
check "choose music tunes: the row's five types and Tunes' own audio/x-mod" \
	[expr {[defapps::choose music tunes.desktop] && [defapps::types_for music tunes.desktop] eq {audio/mpeg audio/flac audio/ogg audio/mp4 audio/x-wav audio/x-mod} && [cur music] eq "tunes.desktop"}]
set g [defapps::mimeapps_read $C/mimeapps.list]
check "  all six are in the file" [expr {[lmap t [defapps::types_for music tunes.desktop] { dict get $g "Default Applications\t$t" }] eq [lrepeat 6 tunes.desktop]}]
check "choose pictures paint brings Paint back from the user's Removed lines" \
	[expr {[defapps::choose pictures paint.desktop] && [cur pictures] eq "paint.desktop" && ![string match "*image/gif=paint.desktop;*" [get $C/mimeapps.list]]}]
check "  a type that is not a plain MIME type (text/plain2 is fine, a pattern is not) is never written" [expr {![string match {*\*=*} [get $C/mimeapps.list]]}]
foreach {r app} {mail mailer.desktop files ribbon-files.desktop text ribbon-editor.desktop video mpv.desktop pdf firefox.desktop archives ribbon-files.desktop} {
	check "choose $r $app holds" [expr {[defapps::choose $r $app] && [cur $r] eq $app}]
}
set now [get $C/mimeapps.list]
check "the notes, the other sections and the stranger's key are still there after ten writes" \
	[expr {[string first "# my own notes\n\[Added Associations\]\ntext/plain=writer.desktop;\n" $now] == 0 && [string first "\napplication/x-thing=thing.desktop\n" $now] > 0
		&& [string range $now end-96 end] eq "\n\[X-Other Section\]\nkey with spaces = kept ; as is\nx-scheme-handler/http=not-touched-here.desktop\n"}]

# a file with CRLF ends and no final newline, bytes that are not UTF-8
put $C/mimeapps.list ""
set fh [open $C/mimeapps.list w]; fconfigure $fh -translation binary
puts -nonewline $fh "\[Default Applications\]\r\nx-odd/\xff\xfe=odd.desktop\r\ntext/plain=writer.desktop"; close $fh
check "a CRLF file with a byte that is not UTF-8: the line is replaced, the odd bytes stay" \
	[expr {[defapps::choose text ribbon-editor.desktop] && [get $C/mimeapps.list] eq "\[Default Applications\]\r\nx-odd/\xff\xfe=odd.desktop\r\ntext/plain=ribbon-editor.desktop\r\n"}]
# no file, no folder
file delete -force $C
check "with no config folder at all the file is made" \
	[expr {[defapps::choose pdf firefox.desktop] && [get $C/mimeapps.list] eq "\[Default Applications\]\napplication/pdf=firefox.desktop\n"}]
# a file with other sections only
put $C/mimeapps.list "\[Added Associations\]\ntext/plain=writer.desktop;"
check "a file with no \[Default Applications\] gets one at its end" \
	[expr {[defapps::choose pdf firefox.desktop] && [get $C/mimeapps.list] eq "\[Added Associations\]\ntext/plain=writer.desktop;\n\n\[Default Applications\]\napplication/pdf=firefox.desktop\n"}]
# a symlinked mimeapps.list stays a link
file mkdir $T/dotfiles
put $T/dotfiles/mimeapps "\[Default Applications\]\n"
file delete $C/mimeapps.list
file link -symbolic $C/mimeapps.list ../dotfiles/mimeapps
check "a symlinked mimeapps.list stays a link; its target is written" \
	[expr {[defapps::choose text writer.desktop] && [file type $C/mimeapps.list] eq "link" && [get $T/dotfiles/mimeapps] eq "\[Default Applications\]\ntext/plain=writer.desktop\n" && [cur text] eq "writer.desktop"}]
file delete $C/mimeapps.list
put $C/mimeapps.list "\[Default Applications\]\ntext/plain=writer.desktop\n"
defapps::refresh

# refusals
set keep [get $C/mimeapps.list]
check "an unknown row is refused" [expr {![defapps::choose nonsense firefox.desktop] && $defapps::error ne ""}]
check "an app that is not installed is refused" [expr {![defapps::choose web uninstalled.desktop]}]
check "an id that would write a second line is refused" [expr {![defapps::choose web "firefox.desktop\ntext/plain=evil.desktop"] && ![defapps::choose web ""] && ![defapps::choose text ../x.desktop]}]
check "  and the file is as it was" [expr {[get $C/mimeapps.list] eq $keep}]
# a config home that cannot be written (it is under a plain file): nothing changes, the model is as it was
put $T/plain-file "x"
set m0 [defapps::model]
set ::env(XDG_CONFIG_HOME) $T/plain-file/config
defapps::refresh 1
set m1 [defapps::model]
check "a config home that cannot be made: choose says no, with the reason, and the model is as it was" \
	[expr {![defapps::choose text ribbon-editor.desktop] && $defapps::error ne "" && [defapps::model] eq $m1 && ![defapps::choose terminal alacritty.desktop]}]
set ::env(XDG_CONFIG_HOME) $C
defapps::refresh 1
check "  back in the real one the model is as before" [expr {[defapps::model] eq $m0}]

# ---- the terminal ---------------------------------------------------------------------------------------------
put $U/xdg-terminal-exec/xdg-terminals.list "org.codeberg.dnkl.foot.desktop\n"
defapps::refresh
check "a data folder's xdg-terminal-exec/xdg-terminals.list names the terminal (Foot)" [expr {[cur terminal] eq "org.codeberg.dnkl.foot.desktop"}]
put $E/xdg-terminals.list "# the system's\n-foo.desktop\n/execarg_default:x\n../../evil.desktop\nnot-installed.desktop\nalacritty.desktop:new-window\n"
defapps::refresh
check "the config dirs' list wins; comments, options, paths and entries that are not installed are passed over (Alacritty)" [expr {[cur terminal] eq "alacritty.desktop"}]
put $C/xdg-terminals.list "# mine\n\n-alacritty.desktop\nnot-installed.desktop\norg.codeberg.dnkl.foot.desktop\nalacritty.desktop\n"
defapps::refresh
check "the user's list wins (Foot)" [expr {[cur terminal] eq "org.codeberg.dnkl.foot.desktop"}]
check "choose terminal alacritty" [defapps::choose terminal alacritty.desktop]
check "  it is the first entry; the comment, the other entries are kept; its old line and the line that left it out are gone" \
	[expr {[get $C/xdg-terminals.list] eq "# mine\n\nalacritty.desktop\nnot-installed.desktop\norg.codeberg.dnkl.foot.desktop\n" && [cur terminal] eq "alacritty.desktop"}]
check "choose terminal ribbon-terminal puts Ribbon Terminal first" \
	[expr {[defapps::choose terminal ribbon-terminal.desktop] && [cur terminal] eq "ribbon-terminal.desktop" && [lindex [split [get $C/xdg-terminals.list] \n] 2] eq "ribbon-terminal.desktop"}]
check "mimeapps.list was not touched by the terminal" [expr {[get $C/mimeapps.list] eq $keep}]

# apps/term/bin/ribbon-terminal follows the list the backend wrote. Stub programs log their arguments.
set LOG $T/term.log
foreach c {ribbon-term-ctl foot alacritty xfce4-terminal directterm} {
	put $T/bin/$c "#!/bin/sh\n{ printf '%s' \"\${0##*/}\"; for a in \"\$@\"; do printf ' \[%s\]' \"\$a\"; done; echo; } >>\"\$LOG\"\n\[ \"\${0##*/}\" = ribbon-term-ctl \] && \[ -n \"\$CTL_FAIL\" \] && exit 1\nexit 0\n"
	file attributes $T/bin/$c -permissions 0755
}
set script [file join $D apps term bin ribbon-terminal]
proc term {args} {
	global LOG script
	file delete $LOG
	set env [list LOG=$LOG]
	if {[lindex $args 0] eq "-ctl-fails"} { lappend env CTL_FAIL=1; set args [lrange $args 1 end] }
	# from the home folder: run anywhere else, a bare ribbon-terminal opens a tab in that folder (newin)
	set here [pwd]; cd $::H
	catch {exec env {*}$env sh $script {*}$args 2>@1} out
	cd $here
	if {![file exists $LOG]} { return "nothing ran: $out" }
	string trim [get $LOG]
}
check "ribbon-terminal with Ribbon Terminal chosen: a new tab, as before ([term])" [expr {[term] eq {ribbon-term-ctl [new]}}]
check "  -e CMD ARGS: a tab that runs it" [expr {[term -e top -d 1] eq {ribbon-term-ctl [new] [top] [-d] [1]}}]
check "  without the shell: foot, and foot CMD" [expr {[term -ctl-fails] eq "ribbon-term-ctl \[new\]\nfoot" && [term -ctl-fails -e top] eq "ribbon-term-ctl \[new\] \[top\]\nfoot \[top\]"}]
check "  other arguments are foot's" [expr {[term --title x] eq {foot [--title] [x]}}]
defapps::choose terminal alacritty.desktop
check "after choose terminal alacritty, ribbon-terminal starts Alacritty ([term])" [expr {[term] eq {alacritty}}]
check "  -e CMD ARGS becomes alacritty -e CMD ARGS, the arguments whole" [expr {[term -e sh -c {echo "a  b"} {}] eq {alacritty [-e] [sh] [-c] [echo "a  b"] []}}]
check "  a bare -e opens it" [expr {[term -e] eq {alacritty}}]
check "  other arguments still go to foot" [expr {[term --title x] eq {foot [--title] [x]}}]
desktop $U xfce4-terminal Name {Xfce Terminal} Exec {xfce4-terminal --disable-server "--title=My  Terminal" %U} Categories {TerminalEmulator;}
desktop $U direct Name Direct Exec directterm X-TerminalArgExec {} Categories {TerminalEmulator;}
desktop $U dashes Name Dashes Exec {directterm start} X-TerminalArgExec -- Categories {TerminalEmulator;}
desktop $U loops Name Loops Exec {/usr/bin/ribbon-terminal} Categories {TerminalEmulator;}
desktop $U broken Name Broken Exec {this-terminal-is-not-installed} Categories {TerminalEmulator;}
defapps::refresh
defapps::choose terminal xfce4-terminal.desktop
check "a terminal known to take -x gets it; its Exec's quotes are undone and its field codes dropped ([term -e top])" \
	[expr {[term -e top] eq {xfce4-terminal [--disable-server] [--title=My  Terminal] [-x] [top]}}]
defapps::choose terminal direct.desktop
check "an empty X-TerminalArgExec: the command follows directly" [expr {[term -e top -d 1] eq {directterm [top] [-d] [1]}}]
defapps::choose terminal dashes.desktop
check "X-TerminalArgExec=-- is used" [expr {[term -e top] eq {directterm [start] [--] [top]}}]
defapps::choose terminal loops.desktop
check "an entry that runs ribbon-terminal is Ribbon Terminal, not a loop" [expr {[term -e top] eq {ribbon-term-ctl [new] [top]}}]
defapps::choose terminal broken.desktop
check "an entry whose program is not installed is passed over: the next entry runs ([term]), and the row says the same ([defapps::name [cur terminal]])" \
	[expr {[term] eq {ribbon-term-ctl [new]} && [cur terminal] eq "loops.desktop" && "broken.desktop" ni [ids terminal]}]
file delete $C/xdg-terminals.list $E/xdg-terminals.list $U/xdg-terminal-exec/xdg-terminals.list
check "with no list anywhere ribbon-terminal is Ribbon Terminal" [expr {[term -e top] eq {ribbon-term-ctl [new] [top]}}]
defapps::refresh

# ---- Files and Properties read what Settings writes (their own code), and Settings what they write ------------------
# (facts.tcl names Ribbon's shipped list by its real path, so the test's root is dropped here)
unset ::env(RIBBON_DEFAULTS_ROOT)
# (and facts::apps stops at a folder named like an entry; Settings' reader passed over it above)
file delete -force $U/applications/folder.desktop
source [file join $D properties facts.tcl]
put $C/mimeapps.list "\[Default Applications\]\n"
defapps::refresh
set bad {}
foreach {r app} {web chromium.desktop mail mailer.desktop files ribbon-files.desktop text writer.desktop pictures paint.desktop music tunes.desktop video mpv.desktop pdf firefox.desktop archives ribbon-files.desktop} {
	if {![defapps::choose $r $app]} { lappend bad "$r: $defapps::error" }
	foreach t [defapps::types_for $r $app] {
		if {[lindex [facts::handlers $t] 0] ne $app} { lappend bad "$t reads [lindex [facts::handlers $t] 0], not $app" }
	}
}
check "facts::handlers (Properties, Files' Inspector) reads every type of every row as Settings wrote it $bad" [expr {$bad eq {}}]
set bad {}
foreach r {web mail files text pictures music video pdf archives} {
	set t [lindex [dict get $defapps::ROWS $r types] 0]
	if {[lindex [facts::handlers $t] 0] ne [cur $r]} { lappend bad $r }
}
file delete $C/mimeapps.list
defapps::refresh
foreach r {web mail files text pictures music video pdf archives} {
	set t [lindex [dict get $defapps::ROWS $r types] 0]
	if {[lindex [facts::handlers $t] 0] ne [cur $r]} { lappend bad "$r (no user file)" }
}
check "with and without a user file both find the same default for every row $bad" [expr {$bad eq {}}]
facts::set_default text/plain writer.desktop
facts::set_default image/png paint.desktop
check "what Properties writes (facts::set_default) is what Settings then shows" \
	[expr {[defapps::refresh] && [cur text] eq "writer.desktop" && [cur pictures] eq "paint.desktop"}]

# ---- a change made elsewhere reaches the page ---------------------------------------------------------------------
set ::seen 0
defapps::start {incr ::seen} {set ::watching}
set ::watching 1
after 300 { facts::set_default text/plain ribbon-editor.desktop }
set t0 [clock milliseconds]
after 8000 { set ::seen -1 }
vwait ::seen
check "the watch calls back after Properties changes a default ([expr {[clock milliseconds] - $t0}] ms), and the model has it" \
	[expr {$::seen == 1 && [cur text] eq "ribbon-editor.desktop"}]
set ::watching 0
set t0 [clock milliseconds]
while {$defapps::timer ne "" && [clock milliseconds] - $t0 < 6000} { after 50; update }
check "the watch ends when nobody is looking" [expr {$defapps::timer eq ""}]
defapps::start {incr ::seen} {set ::watching}
defapps::stop
check "stop ends it too" [expr {$defapps::timer eq ""}]

# ---- GLib agrees (gio, when it is installed) --------------------------------------------------------------------------
if {[auto_execok gio] ne ""} {
	# GLib loads an entry only when its program is installed
	foreach c {firefox chromium} { put $T/bin/$c "#!/bin/sh\n"; file attributes $T/bin/$c -permissions 0755 }
	defapps::choose web firefox.desktop
	defapps::choose pdf firefox.desktop
	set bad {}
	foreach t {x-scheme-handler/http x-scheme-handler/https text/html application/pdf} {
		if {[catch {exec gio mime $t 2>@1} out] || ![regexp {firefox\.desktop} [lindex [split $out \n] 0]]} { lappend bad "$t: $out" }
	}
	check "gio mime reads Firefox as the default of the types Settings wrote $bad" [expr {$bad eq {}}]
	if {![catch {exec gio mime x-scheme-handler/https chromium.desktop 2>@1} out]} {
		# the row shows its first type (http); gio set https only
		catch {exec gio mime x-scheme-handler/http chromium.desktop 2>@1}
		defapps::refresh
		check "what gio writes is what Settings then shows (Chromium)" [expr {[cur web] eq "chromium.desktop"}]
		check "  and Settings can take it back" [expr {[defapps::choose web firefox.desktop] && [regexp {firefox\.desktop} [lindex [split [exec gio mime x-scheme-handler/https 2>@1] \n] 0]]}]
	} else { puts "  skip gio writing a default here ($out)" }
} else { puts "  skip the check against GLib (no gio)" }

# ---- the spec's corners: Removed Associations by level, desktop ids of subfolders ------------------------------------
# (mime-apps-spec: a list's Removed Associations hold for that list and the lists after it, not for a more important
# one; desktop-entry-spec: applications/kde/kwrite.desktop is the id kde-kwrite.desktop)
set keepu [get $U/applications/mimeapps.list]
put $C/mimeapps.list "\[Added Associations\]\ntext/plain=paint.desktop;\n"
put $U/applications/mimeapps.list "$keepu\[Removed Associations\]\ntext/plain=paint.desktop;\nx-scheme-handler/mailto=mailer.desktop;\n"
defapps::refresh
check "an app the user's list adds stays though a data folder's list removes it (Paint for Text: [names text])" [expr {"paint.desktop" in [ids text]}]
check "  a data folder's Removed Associations do not take out an app of a more important folder (My Mail: [names mail])" \
	[expr {[cur mail] eq "mailer.desktop" && "mailer.desktop" in [ids mail]}]
if {[auto_execok gio] ne ""} {
	put $T/bin/paint "#!/bin/sh\n"; file attributes $T/bin/paint -permissions 0755
	check "  gio lists Paint for text/plain too" [expr {![catch {exec gio mime text/plain 2>@1} out] && [string match *paint.desktop* $out]}]
}
put $U/applications/mimeapps.list $keepu
file delete $C/mimeapps.list
defapps::refresh
desktop $U kde/kwrite Name KWrite Exec kwrite MimeType {text/plain;}
put $T/bin/kwrite "#!/bin/sh\n"; file attributes $T/bin/kwrite -permissions 0755
check "an entry new in a subfolder of applications is seen by refresh" [defapps::refresh]
check "  it is offered by its desktop id, kde-kwrite.desktop ([names text])" [expr {"kde-kwrite.desktop" in [ids text] && "KWrite" in [names text]}]
check "  choosing it writes that id, and the row reads it back" \
	[expr {[defapps::choose text kde-kwrite.desktop] && [cur text] eq "kde-kwrite.desktop" && [string match "*text/plain=kde-kwrite.desktop\n*" [get $C/mimeapps.list]]}]
if {[auto_execok gio] ne ""} {
	check "  gio reads kde-kwrite.desktop as the default of text/plain" [expr {![catch {exec gio mime text/plain 2>@1} out] && [string match *kde-kwrite.desktop* [lindex [split $out \n] 0]]}]
}
desktop $U xfce/sub-term Name {Sub Terminal} Exec {directterm --sub} Categories {TerminalEmulator;}
defapps::refresh
check "a terminal in a subfolder is offered as xfce-sub-term.desktop" [expr {"xfce-sub-term.desktop" in [ids terminal]}]
defapps::choose terminal xfce-sub-term.desktop
check "  and ribbon-terminal starts it ([term -e top])" [expr {[term -e top] eq {directterm [--sub] [-e] [top]}}]
file delete -force $U/applications/kde $U/applications/xfce $C/mimeapps.list

# ---- Ribbon Terminal's control pipe is one line of words: a command it cannot carry whole goes to foot --------------------
defapps::choose terminal ribbon-terminal.desktop
check "a file name with a space is not split into two by the shell's pipe: foot runs it whole ([term -e vim {/h/a b.txt}])" \
	[expr {[term -e vim {/h/a b.txt}] eq {foot [vim] [/h/a b.txt]}}]
check "  a file name with a newline cannot make a second control line: foot runs it whole" \
	[expr {[term -e vim "/h/x\nquit"] eq "foot \[vim\] \[/h/x\nquit\]"}]
check "  a name the pipe carries still opens a tab ([term -e vim /h/a.txt])" [expr {[term -e vim /h/a.txt] eq {ribbon-term-ctl [new] [vim] [/h/a.txt]}}]

if {$fails} { puts "  $fails default-apps check(s) failed"; exit 1 }
puts "  all default-apps checks passed"
