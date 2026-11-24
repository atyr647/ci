# catalogue-kit.tcl - the Catalogue's kit side against a real, signed test repository: kits packed
# with `kit pack` and kittrust's test-only keys, an index built with kitindex and served by
# tests/kit-httpd.tcl (as tests/kit-cli.tcl does). It checks apps/catalogue/kitq.tcl (the index's
# apps without its libraries, what is installed, kit info's requests, uses and signer, and grab
# with kit's prompt answered no and yes, its download's progress and the switch), then the window:
# RIBBON_CATALOGUE_PROBE drives the real Catalogue (tests/catalogue-flow.tcl) through the list, the
# kit's page, kit's prompt as a sheet, the download in the footer and Open.
#   KITFMT_MK4TCL=<dir with Mk4tcl> tclsh8.6 -encoding utf-8 tests/catalogue-kit.tcl
set top [file dirname [file dirname [file normalize [info script]]]]
set KIT $top/srcpkgs/ribbon-kit/files/bin/kit
set KITQ $top/srcpkgs/ribbon-desktop/files/apps/catalogue/kitq.tcl
set KT $top/kit/kittrust
set F $top/tests/fixtures/kittrust
set tclsh [info nameofexecutable]
encoding system utf-8
fconfigure stdout -encoding utf-8
set fails 0
proc ok {name cond {detail ""}} {
	if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name"; if {$detail ne ""} { puts "       [string range $detail 0 2000]" }; incr ::fails }
}
proc spit {p d {mode ""}} { file mkdir [file dirname $p]; set f [open $p w]; fconfigure $f -translation binary; puts -nonewline $f [encoding convertto utf-8 $d]; close $f; if {$mode ne ""} { file attributes $p -permissions $mode } }
set W [file normalize [exec mktemp -d]]
set HOME $W/home
file mkdir $HOME
set ::env(HOME) $HOME
set ::env(KIT_CONF) $W/kit.conf
set ::env(KIT_NOSYNC) 1
foreach v {KIT_INDEX XDG_DATA_HOME XDG_CACHE_HOME XDG_CONFIG_HOME} { unset -nocomplain ::env($v) }
proc tool {args} { if {[catch {exec {*}$args 2>@1} out]} { error "$args: $out" }; return $out }

# ---- the repository ----------------------------------------------------------------------------------
set L $W/keys/trusted-keys
file mkdir $W/keys
tool $tclsh $KT/kitkey init -repository org.ribbon.test -root $F/test-root.pub $L
tool $tclsh $KT/kitkey add -role app -from -30d $L $F/test-app.pub
tool $tclsh $KT/kitkey add -role index -from -30d $L $F/test-index.pub
tool $tclsh $KT/kitkey sign -key $F/test-root.key $L
set APP "#!/bin/sh\necho hello\n"
proc kitsrc {name manifest files} {
	set dir $::W/src/$name
	foreach {p data mode} $files { spit $dir/$p $data $mode }
	spit $dir.manifest $manifest
	tool $::tclsh $::KIT pack -q -sign $::F/test-app.key $dir $dir.kit
}
# a library (it provides, so the Catalogue does not list it) and an app that uses it, with
# requests; the app is big enough to take several groups of chunks
set big ""
for {set i 0} {$i < 60000} {incr i} { append big "line $i [expr {($i * 7919) % 104729}]\n" }
kitsrc libgreet-1.0 "name org.ribbon.test.libgreet version 1.0 kind app summary {Greetings, shared}\nprovides {{greet-api 1.0}}" [list lib/greeting.txt "greet 1.0\n" 420]
kitsrc obs-31.0.1 "name com.obsproject.obs version 31.0.1 kind app summary {Screen recording and streaming} x-short obs x-tags {video record}
needs {{org.ribbon.test.libgreet >=1}}
perms {network yes display wayland audio mic gpu 1 camera 1}
entries {{obs bin/app {} app}}
effects {{desktop share/applications/obs.desktop}}" [list bin/app $APP 493 share/big.txt $big 420 \
	share/applications/obs.desktop "\[Desktop Entry\]\nType=Application\nName=OBS Studio\nExec=obs\n" 420]
kitsrc hello-1 "name org.example.hello version 1 kind app summary {Hello from the index}\nentries {{hello bin/app {} cli}}" [list bin/app $APP 493]
file mkdir $W/repo.kits
foreach k [glob $W/src/*.kit] { file copy $k $W/repo.kits/ }
tool $tclsh $KT/kitindex build -key $F/test-index.key -keys $L $W/repo.kits $W/repo
set srv [open |[list $tclsh $top/tests/kit-httpd.tcl $W/repo $W/httpd.log] r]
set port [gets $srv]
spit $::env(KIT_CONF) "keys = $L\nmirror = http://127.0.0.1:$port\ntimeout = 5\n"

# ---- kitq.tcl -------------------------------------------------------------------------------------------
proc said {out} {
	set r {}
	foreach line [split $out \n] { if {[string match "catalogue: *" $line]} { lappend r [lrange $line 1 end] } }
	return $r
}
proc kitq {args} {
	set in ""
	if {[lindex $args 0] eq "-in"} { set in [lindex $args 1]; set args [lrange $args 2 end] }
	set code 0
	if {[catch {exec timeout -k 5 120 $::tclsh -encoding utf-8 $::KITQ {*}$args << $in 2>@1} out opts]} {
		set ec [dict get $opts -errorcode]
		set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : "error"}]
	}
	list $code $out
}
lassign [kitq apps] code out
set A [lindex [lsearch -inline -index 0 [said $out] apps] 1]
set names [lsort [lmap r $A { dict get $r name }]]
ok "apps: the index's apps, not its libraries" [expr {$code == 0 && $names eq "com.obsproject.obs org.example.hello"}] "$code $out"
set obs [lsearch -inline -index 1 [lmap r $A { list $r [dict get $r name] }] com.obsproject.obs]
set obs [lindex $obs 0]
ok "... each with its short name, version, summary, tags, sizes and nothing installed" \
	[expr {[dict get $obs short] eq "obs" && [dict get $obs version] eq "31.0.1" && [dict get $obs summary] eq "Screen recording and streaming" \
		&& [dict get $obs tags] eq "video record" && [dict get $obs size] > 0 && [dict get $obs installed] eq ""}] $obs
lassign [kitq info obs] code out
set D [lindex [lsearch -inline -index 0 [said $out] info] 1]
ok "info: kit's requests and what it uses" [expr {$code == 0 && [lsearch -index 0 [dict get $D perms] camera] >= 0 && [lindex [dict get $D needs] 0 0] eq "org.ribbon.test.libgreet"}] "$code $out"
ok "... the signature checked, and who signed it" [expr {[dict get $D sigstate] eq "valid" && [dict get $D keyid] ne "" && [dict get $D checked] > 0}] $D
lassign [kitq -in "0\n" grab obs] code out
set S [said $out]
set plan [lindex [lsearch -inline -index 0 $S plan] 1]
ok "grab asks with kit's prompt: its rows and its question" [expr {[lindex $plan 1] eq "Install?" && [llength [lindex $plan 0]] == 2}] $out
ok "... and No installs nothing (kit's exit 1)" [expr {$code == 1 && [lsearch -inline -index 0 $S end] eq "end 1" && ![file exists $HOME/.local/share/kit/active] || $code == 1 && ![string match "*com.obsproject.obs*" [exec cat $HOME/.local/share/kit/active]]}] $out
lassign [kitq -in "1\n" grab obs] code out
set S [said $out]
set prog [lmap s $S { if {[lindex $s 0] ne "progress"} continue; lrange $s 1 2 }]
ok "Yes: the download's progress, from nothing to the whole" [expr {[llength $prog] >= 2 && [lindex $prog 0 0] == 0 && [lindex $prog end 0] == [lindex $prog end 1] && [lindex $prog end 1] > 0}] $prog
ok "... then the switch, and kit's exit 0" [expr {$code == 0 && [lsearch -exact $S {phase install}] >= 0 && [lindex $S end] eq "end 0"}] $out
ok "... and it is installed, with its library" [expr {[string match "*com.obsproject.obs*31.0.1*" [exec cat $HOME/.local/share/kit/active]] && [string match "*org.ribbon.test.libgreet*" [exec cat $HOME/.local/share/kit/active]]}]
lassign [kitq apps] code out
set A [lindex [lsearch -inline -index 0 [said $out] apps] 1]
ok "apps now says it is installed, by its launcher entry's name" [expr {[lsearch -inline [lmap r $A { expr {[dict get $r name] eq "com.obsproject.obs" ? "[dict get $r installed] [dict get $r title]" : ""} }] "31.0.1 OBS Studio"] eq "31.0.1 OBS Studio"}] $A
lassign [kitq info obs] code out
set D [lindex [lsearch -inline -index 0 [said $out] info] 1]
ok "info of an installed kit: when, and the library versions it uses" [expr {[dict get $D installed] eq "31.0.1" && [dict get $D when] > 0 && [dict get $D uses] eq "org.ribbon.test.libgreet 1.0"}] $D
lassign [kitq info nothing-here] code out
ok "info of a kit nobody lists: kit's usage error" [expr {$code == 2}] "$code $out"

# the window installs it again
catch {exec $tclsh $KIT toss --yes obs 2>@1} tossed
ok "(kit toss obs, for the window)" [expr {![string match "*com.obsproject.obs*" [exec cat $HOME/.local/share/kit/active]]}] $tossed

# ---- the window ----------------------------------------------------------------------------------------------
if {[auto_execok xvfb-run] ne "" && [auto_execok wish8.6] ne ""} {
	set ::env(CATALOGUE_FLOW_OUT) $W/flow.out
	set ::env(XDG_CACHE_HOME) $W/cache
	# no Flathub here: the kit side alone
	set ::env(PATH) $W/nobin:$::env(PATH)
	set ::env(RIBBON_CATALOGUE_PROBE) $top/tests/catalogue-flow.tcl
	catch {exec timeout -k 5 240 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 $top/srcpkgs/ribbon-desktop/files/apps/catalogue/main.tcl 2>@1} wout
	set fl [expr {[file exists $W/flow.out] ? [split [string trim [exec cat $W/flow.out]] \n] : {}}]
	foreach line $fl { ok [lindex $line 1] [expr {[lindex $line 0] eq "ok"}] [lrange $line 2 end] }
	ok "the window's flow ran to its end" [expr {[lindex $fl end 1] eq "the window's flow ended"}] $wout
} else { puts "  skip the window (no xvfb-run / wish8.6)" }

catch {exec kill [pid $srv]}
catch {close $srv}
file delete -force $W
if {$fails} { puts "catalogue kit: $fails checks failed"; exit 1 }
puts "catalogue kit: all checks passed"
