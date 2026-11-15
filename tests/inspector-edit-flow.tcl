# inspector-edit-flow.tcl - the Inspector's edit view and Apply (properties/inspector.tcl, edit
# mode), driven without clicks: the rows' values, undo and Revert, the mode the rows make, and
# Apply's jobs on real files: a permission (and Revert), a rename, a name that is taken, the
# type's app (mimeapps.list), and the pkexec path for a file that is not yours (a stub pkexec).
# Run by properties/main.tcl as a scene:
#   RIBBON_PROPERTIES_SCENE=tests/inspector-edit-flow.tcl RIBBON_INSPECTOR_WORK=DIR \
#     HOME=... XDG_CONFIG_HOME=... (the home from tests/properties-fixture.tcl)
# Prints "  ok" / "  FAIL" lines and exits 0 when every check passes.

# the Inspector (Properties does not source it yet: the Files panel and the viewer will)
set repo [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $repo srcpkgs ribbon-desktop files properties inspector.tcl]

set fails 0
proc check {what cond} {
	global fails
	if {$cond} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
proc write_file {path mode} {
	file mkdir [file dirname $path]
	set fh [open $path w]; puts $fh "hello"; close $fh
	file attributes $path -permissions $mode
}
proc perm {path} { file stat $path st; format %04o [expr {$st(mode) & 07777}] }
proc settle {} { update }
# Apply's callback: the new path and the errors
proc got {newpath errs} { set ::done [list $newpath $errs] }

set work $::env(RIBBON_INSPECTOR_WORK)
set src [file join $work src]
file mkdir $src
set a [file join $src a.txt]
write_file $a 0644

# the rows of a fresh edit view
set F [facts::of $a]
inspector::edit_begin $F
check "the rows start as the file is: You read & write, Group read only" \
	[expr {$inspector::E(u) eq "read & write" && $inspector::E(g) eq "read only"}]
check "no row differs at the start" [expr {![inspector::changed {owner u g o x opens}]}]

# a change, its mode, undo, Run as program, Revert
inspector::pick g "no access"
check "Group no access differs from disk" [inspector::changed {g}]
check "the mode the rows make is 0604" [expr {[inspector::newmode] == 0604}]
inspector::undo g
check "undo puts Group back" [expr {$inspector::E(g) eq "read only" && ![inspector::changed {g}]}]
check "the mode is 0644 again" [expr {[inspector::newmode] == 0644}]
inspector::toggle_run
check "Run as program makes 0755" [expr {[inspector::newmode] == 0755}]
inspector::pick o "no access"
inspector::pick u "read only"
inspector::revert
check "Revert puts every row back" [expr {![inspector::changed {owner u g o x opens}]}]
check "the values are the file's again" [expr {$inspector::E(o) eq "read only" && $inspector::E(u) eq "read & write"}]

# Apply: a permission, through the jobs (direct: we own the file)
inspector::pick g "no access"
set ::done {}
inspector::apply got
settle
check "Apply writes 0604 to the file" [expr {[perm $a] eq "0604"}]
check "Apply hands back the same path with no errors" [expr {[lindex $::done 0] eq $a && [lindex $::done 1] eq {}}]
check "the edit view closes after Apply" [expr {!$inspector::edit}]

# a rename, through Apply's rename job
set b [file join $src b.txt]
inspector::edit_begin [facts::of $a]
ui::fset insp.name b.txt
set ::done {}
inspector::apply got
settle
check "Apply renames the file" [expr {[file exists $b] && ![file exists $a]}]
check "the renamed file keeps its mode" [expr {[perm $b] eq "0604"}]

# a name that is taken: an error, and the view stays open
write_file [file join $src c.txt] 0644
inspector::edit_begin [facts::of $b]
ui::fset insp.name c.txt
set ::done {}
inspector::apply got
settle
check "a taken name is refused" [expr {[lindex $::done 1] ne {} && [file exists $b]}]
check "the view stays open on a refused name" [expr {$inspector::edit}]
ui::fset insp.name "x/y"
inspector::apply got
check "a name with a slash is refused" [expr {[string match "*can't be a name*" [lindex $::done 1]]}]
inspector::revert
inspector::edit_end

# the type's app: Apply writes the default for the type (mimeapps.list); one file's own
# choice has no store yet (see the report)
set photo [file join $src photo.jpg]
file copy -force [file join $::env(HOME) Pictures Iceland "Jökulsárlón.jpg"] $photo
inspector::edit_begin [facts::of $photo]
check "the photo opens with Image Viewer by default" [expr {$inspector::E(opens) eq "org.ribbon.imageviewer.desktop"}]
inspector::pick_app darkroom.desktop
set ::done {}
inspector::apply got
settle
set mf [file join $::env(XDG_CONFIG_HOME) mimeapps.list]
set fh [open $mf]; set text [read $fh]; close $fh
set lines [split $text \n]
# the fixture's "photo" is a PNG under a .jpg name: its type is what file(1) says
set type [dict get [facts::of $photo] mime]
check "Apply writes the type's default ($type) to mimeapps.list" [expr {"$type=darkroom.desktop" in $lines}]
check "the default of another type is kept" [expr {"image/jpeg=org.ribbon.imageviewer.desktop" in $lines}]
check "the photo itself is unchanged by the app change" [expr {[perm $photo] eq [perm [file join $::env(HOME) Pictures Iceland "Jökulsárlón.jpg"]]}]

# a file that is not yours: its access goes through pkexec (a stub that runs the command)
set bin [file join $work bin]
file mkdir $bin
set log [file join $work pkexec.log]
set fh [open [file join $bin pkexec] w]
puts $fh "#!/bin/sh\necho \"\$@\" >> $log\nexec \"\$@\""
close $fh
file attributes [file join $bin pkexec] -permissions 0755
set ::env(PATH) "$bin:$::env(PATH)"
rename fp::uid fp::uid_real
proc fp::uid {} { return 1000 }
write_file $b 0644
inspector::edit_begin [facts::of $b]
inspector::pick g "read only"
inspector::pick o "read only"
inspector::pick u "read only"
set ::done {}
inspector::apply got
after 4000 {set ::done timeout}
vwait ::done
rename fp::uid {}
rename fp::uid_real fp::uid
check "a file not yours is changed through pkexec" [file exists $log]
check "the pkexec run changed the mode (0444)" [expr {[perm $b] eq "0444"}]
check "the pkexec run reports no errors" [expr {[lindex $::done 1] eq {}}]

# two owners in a selection are Mixed
check "two owners are Mixed" [expr {[lindex [inspector::same {ada root}] 0] eq "Mixed"}]
check "one owner is that owner" [expr {[lindex [inspector::same {ada ada}] 0] eq "ada"}]

puts [expr {$fails ? "inspector edit: $fails checks failed" : "inspector edit: all checks passed"}]
exit [expr {$fails > 0}]
