# tests/open-folder-choice.tcl - apps::folder_choice and apps::open_path from shell/apps.tcl, alone, with stand-ins:
# a folder goes to Ribbon Files unless another app is the inode/directory default in the person's mimeapps.list.
#   tclsh8.6 tests/open-folder-choice.tcl FILES-DIR TMPDIR
namespace eval apps {}; namespace eval launcher {}; namespace eval files {}
set D [lindex $argv 0]; set T [lindex $argv 1]
# only the two procs under test
set src [read [set fh [open $D/shell/apps.tcl]]]; close $fh
foreach name {folder_choice open_path} {
	regexp -line -indices "^proc apps::$name " $src at
	set from [lindex $at 0]; set to [string first "\n\x7d\n" $src $from]
	eval [string range $src $from [expr {$to + 1}]]
}
proc apps::expand p { return $p }; proc apps::shellquote p { return '$p' }
proc apps::run c { lappend ::log "run $c" }; proc files::show p { lappend ::log "files $p" }
proc launcher::files_focused {} { return 0 }
set env(XDG_CONFIG_HOME) $T/cfg; file mkdir $T/cfg $T/dir
proc w {t} { set fh [open $::T/cfg/mimeapps.list w]; puts -nonewline $fh $t; close $fh }
proc t {what text want} { if {$text eq "-"} { file delete $::T/cfg/mimeapps.list } else { w $text }; set ::log {}; apps::open_path $::T/dir
	puts "[expr {[string match $want [lindex $::log 0]] ? "  ok  " : "  FAIL"}] $what"; if {![string match $want [lindex $::log 0]]} { puts "       $::log"; set ::bad 1 } }
set bad 0
t "no mimeapps.list: Ribbon Files" - "files *"
t "Ribbon Files chosen: Ribbon Files" "\[Default Applications\]\ninode/directory=ribbon-files.desktop\n" "files *"
t "another app chosen: xdg-open" "\[Added Associations\]\ninode/directory=x.desktop\n\[Default Applications\]\ntext/plain=e.desktop\ninode/directory=thunar.desktop;ribbon-files.desktop\n" "run xdg-open *"
t "only an added association: Ribbon Files" "\[Added Associations\]\ninode/directory=thunar.desktop\n" "files *"
exit $bad
