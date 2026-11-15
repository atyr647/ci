# shell-updates.tcl -- the bar's updates panel end to end (tests/run.sh), on Xvfb and a fixture kit store:
#
#   KITFMT_MK4TCL=<dir with Mk4tcl> tclsh8.6 -encoding utf-8 tests/shell-updates.tcl
#
# Builds a few kits with `kit pack` (signed with kittrust's test-only keys, as tests/kit-cli.tcl does),
# publishes them to a mirror served by tests/kit-httpd.tcl on 127.0.0.1 (never the network), installs the old
# versions, publishes the new ones, then starts the real shell under Xvfb (RIBBON_SHELL_TEST=
# tests/shell-updates-flow.tcl, RIBBON_KIT = this tree's kit) which drives the panel: it opens from the chip,
# shows kit's plan and question, Cancel closes it, the button runs kit's grab, then Done, History and Rewind; and the
# system's packages beside the kits, through the real ribbon-update on a stand-in package seam and pkexec.
# RIBBON_UPDATES_SHOTS=DIR keeps a screenshot of each state there. Every step has a time limit.

set top [file dirname [file dirname [file normalize [info script]]]]
set tclsh [info nameofexecutable]
set KIT $top/srcpkgs/ribbon-kit/files/bin/kit
set F $top/tests/fixtures/kittrust
set KT $top/kit/kittrust
encoding system utf-8
set W [file normalize [exec mktemp -d]]
set HOME $W/home
set CONF $W/kit.conf
set ::env(KIT_NOSYNC) 1
unset -nocomplain ::env(KIT_INDEX) ::env(KIT_CRASH_AT) ::env(XDG_DATA_HOME) ::env(XDG_CACHE_HOME) ::env(XDG_CONFIG_HOME)

proc spit {path data {mode ""}} {
	file mkdir [file dirname $path]
	set ch [open $path {WRONLY CREAT TRUNC}]; fconfigure $ch -translation binary; puts -nonewline $ch $data; close $ch
	if {$mode ne ""} { file attributes $path -permissions $mode }
}
proc kit {args} {
	set saved [array get ::env]
	set ::env(HOME) $::HOME; set ::env(KIT_CONF) $::CONF
	set rc [catch {exec timeout -k 5 120 $::tclsh $::KIT {*}$args < /dev/null 2>@1} out]
	foreach k [array names ::env] { if {![dict exists $saved $k]} { unset ::env($k) } }
	dict for {k v} $saved { if {![info exists ::env($k)] || $::env($k) ne $v} { set ::env($k) $v } }
	if {$rc} { error "kit $args: $out" }
	return $out
}
proc tool {t args} { if {[catch {exec $::tclsh $::KT/$t {*}$args 2>@1} out]} { error "$t $args: $out" }; return $out }

# keys: a root-signed key list made from kittrust's test keys
set L $W/keys/trusted-keys
file mkdir $W/keys
tool kitkey init -repository org.ribbon.test -root $F/test-root.pub $L
tool kitkey add -role app -from -30d $L $F/test-app.pub
tool kitkey add -role index -from -30d $L $F/test-index.pub
tool kitkey sign -key $F/test-root.key $L

# kits: an app each, two versions; the new ones of firefox and openssl are security updates
set APP "#!/usr/bin/env tclsh8.6\nputs \$env(KIT_NAME)\n"
proc mk {name short v {pad 1}} {
	set dir $::W/src/$short-$v
	file delete -force $dir
	spit $dir/bin/app $::APP 493
	spit $dir/share/data.txt [string repeat "$short $v [string repeat x 60]\n" [expr {800 * $pad}]] 420
	# firefox has a launcher: its row in the panel shows the Name= of that entry (U03n), as in the real kit
	set effects ""
	if {$short eq "firefox"} {
		spit $dir/share/applications/firefox.desktop "\[Desktop Entry\]\nName=Firefox\nExec=firefox %u\nTryExec=firefox\nIcon=firefox\nType=Application\n" 420
		set effects "\neffects {{desktop share/applications/firefox.desktop}}"
	}
	spit $dir.manifest "name $name version $v kind app summary {$short} x-short $short\nentries {{$short bin/app {} app}}$effects"
	if {[catch {exec $::tclsh $::KIT pack -q -sign $::F/test-app.key $dir 2>@1} out]} { error "kit pack $dir: $out" }
}
file mkdir $W/src
cd $W/src      ;# kit pack leaves NAME-VERSION.kit in the working directory
foreach {n s old new} {org.mozilla.firefox firefox 134.0.1 134.0.2 org.ribbon.test.ffmpeg ffmpeg 7.1 7.1.1 org.ribbon.test.mesa mesa 25.2.7 25.2.8 org.ribbon.test.openssl openssl 3.0.13 3.0.14} {
	mk $n $s $old 12 ; mk $n $s $new 12
}
proc publish {repo args} {
	set opts {}
	while {[string index [lindex $args 0] 0] eq "-"} { lappend opts {*}[lrange $args 0 1]; set args [lrange $args 2 end] }
	file mkdir $repo.kits
	foreach k $args { file copy -force $k $repo.kits/ }
	tool kitindex build -key $::F/test-index.key -keys $::L {*}$opts $repo.kits $repo
}
proc kf {n v} { lindex [glob $::W/src/$n-$v.kit] 0 }
set A $W/mirror
publish $A {*}[lmap {n v} {org.mozilla.firefox 134.0.1 org.ribbon.test.ffmpeg 7.1 org.ribbon.test.mesa 25.2.7 org.ribbon.test.openssl 3.0.13} { kf $n $v }]

# the mirror: 127.0.0.1, a free port
set log $W/httpd.log
spit $log ""
set httpd [open |[list $tclsh $top/tests/kit-httpd.tcl $A $log] r]
set port [gets $httpd]
spit $CONF "keys = $L\ntimeout = 5\nmirror = http://127.0.0.1:$port\n"
puts "updates panel fixture in $W (mirror 127.0.0.1:$port)"

# installed: the old versions; then the new ones are published, and one check (answered no: nobody to ask)
# writes ~/.cache/kit/updates, which is what shows the chip
kit grab --yes firefox ffmpeg mesa openssl
publish $A -flag org.mozilla.firefox=security -flag org.ribbon.test.openssl=security \
	{*}[lmap {n v} {org.mozilla.firefox 134.0.2 org.ribbon.test.ffmpeg 7.1.1 org.ribbon.test.mesa 25.2.8 org.ribbon.test.openssl 3.0.14} { kf $n $v }]
catch {kit check}

# the shell on Xvfb, driven by tests/shell-updates-flow.tcl; kit is this tree's, the mirror and HOME the fixture's
set ::env(HOME) $HOME
set ::env(KIT_CONF) $CONF
set ::env(RIBBON_KIT) [list $tclsh $KIT]
set ::env(RIBBON_SHELL_TEST) $top/tests/shell-updates-flow.tcl
set ::env(RIBBON_UPDATES_FIXTURE) $W
# the system's packages: the real ribbon-update on a stand-in for the package seam (tests/fixtures/updates-seam),
# run as root by a stand-in pkexec; the seam's state (plan, installed, log) is in $W/seam, the reboot flag in $W/run
set SF $top/tests/fixtures/updates-seam
file mkdir $W/seam $W/run $W/modules
spit $W/seam/plan ""
spit $W/seam/installed "linux6.18 6.18.58_1\nglibc 2.41_1\n"
spit $W/seam/log ""
set ::env(RIBBON_UPDATE) [list bash $top/srcpkgs/ribbon-tools/files/bin/ribbon-update]
set ::env(RIBBON_UPDATE_PKEXEC) $SF/bin/pkexec
set ::env(RIBBON_LIB) $SF
set ::env(RIBBON_REAL_LIB) $top/srcpkgs/ribbon-tools/files/lib
set ::env(RIBBON_SEAM_STUB) $W/seam
set ::env(RIBBON_RUN) $W/run
set ::env(RIBBON_MODULES) $W/modules
file mkdir $HOME/.cache $HOME/.config
set rc [catch {exec timeout -k 5 150 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 \
	$top/srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell 2>@1} out]
puts $out
catch {exec kill [pid $httpd]}
if {!$rc && [info exists ::env(KEEP)] == 0} { file delete -force $W }
exit $rc
