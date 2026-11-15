# tests/kit-catalogue-index.tcl -- what the Catalogue's kit side (srcpkgs/ribbon-desktop/files/apps/catalogue/kitq.tcl)
# reads from the repository index beyond the kit lines: the title line (srcpkgs/ribbon-kit/files/lib/repo.tcl; the name
# people know an app by, so an app not installed is "OBS Studio", not "Obs"), and why there is no index when it can't
# be had.  A signed test repository is built with kit pack and kittrust's kitindex, its index given title lines and
# signed again with the test index key (kittrust's reader ignores a line it doesn't know; the signature covers it).
#   KITFMT_MK4TCL=<dir with Mk4tcl> tclsh8.6 -encoding utf-8 tests/kit-catalogue-index.tcl
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
    if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name" ; if {$detail ne ""} { puts "       [string range $detail 0 1500]" } ; incr ::fails }
}
proc spit {p d {mode ""}} { file mkdir [file dirname $p] ; set f [open $p w] ; fconfigure $f -translation binary ; puts -nonewline $f [encoding convertto utf-8 $d] ; close $f ; if {$mode ne ""} { file attributes $p -permissions $mode } }
proc slurp {p} { set f [open $p rb] ; set d [read $f] ; close $f ; return $d }
proc tool {args} { if {[catch {exec {*}$args 2>@1} out]} { error "$args: $out" } ; return $out }
if {[auto_execok minisign] eq ""} { puts "  skip the Catalogue's index lines (no minisign)" ; exit 0 }

# ---- the repository ----------------------------------------------------------------------------------
set W [file normalize [exec mktemp -d]]
set env(HOME) $W/home
file mkdir $W/home
set env(KIT_CONF) $W/kit.conf
set env(KIT_NOSYNC) 1
foreach v {KIT_INDEX XDG_DATA_HOME XDG_CACHE_HOME XDG_CONFIG_HOME} { unset -nocomplain env($v) }
set L $W/keys/trusted-keys
file mkdir $W/keys
tool $tclsh $KT/kitkey init -repository org.ribbon.test -root $F/test-root.pub $L
tool $tclsh $KT/kitkey add -role app -from -30d $L $F/test-app.pub
tool $tclsh $KT/kitkey add -role index -from -30d $L $F/test-index.pub
tool $tclsh $KT/kitkey sign -key $F/test-root.key $L
proc kitsrc {name manifest files} {
    set dir $::W/src/$name
    foreach {p data mode} $files { spit $dir/$p $data $mode }
    spit $dir.manifest $manifest
    file mkdir $::W/repo.kits
    tool $::tclsh $::KIT pack -q -sign $::F/test-app.key $dir $::W/repo.kits/$name.kit
}
kitsrc obs-31.0.1 "name com.obsproject.obs version 31.0.1 kind app summary {Screen recording and streaming} x-short obs\nentries {{obs bin/app {} app}}" \
    [list bin/app "#!/bin/sh\necho obs\n" 493]
kitsrc hello-1 "name org.example.hello version 1 kind app summary {Hello from the index}\nentries {{hello bin/app {} cli}}" [list bin/app "#!/bin/sh\n" 493]
tool $tclsh $KT/kitindex build -key $F/test-index.key -keys $L $W/repo.kits $W/repo
# the publisher's title lines: one for OBS, none for hello (whose name the window makes from its short name)
set text [encoding convertfrom utf-8 [slurp $W/repo/index]]
append text "title\tcom.obsproject.obs\tOBS Studio\n"
regexp -line {^serial\t([0-9]+)$} $text -> serial
set sign [list lappend auto_path $KT $top/kit/kitfmt \; package require kittrust \; \
    puts -nonewline \[::kittrust sign \[encoding convertto utf-8 [list $text]\] [list $F/test-index.key] [list "ribbon-kit-repo org.ribbon.test serial $serial"]\]]
set sig [exec $tclsh << [join $sign " "]]
spit $W/repo/index $text
spit $W/repo/index.minisig $sig
spit $env(KIT_CONF) "keys = $L\nmirror = file://$W/repo\ntimeout = 5\n"

proc said {out} {
    set r {}
    foreach line [split $out \n] { if {[string match "catalogue: *" $line]} { lappend r [lrange $line 1 end] } }
    return $r
}
proc kitq {args} {
    set code 0
    if {[catch {exec timeout -k 5 120 $::tclsh -encoding utf-8 $::KITQ {*}$args 2>@1} out opts]} {
        set ec [dict get $opts -errorcode]
        set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : "error"}]
    }
    list $code $out
}

# ---- the title line --------------------------------------------------------------------------------------
lassign [kitq apps] code out
set A [lindex [lsearch -inline -index 0 [said $out] apps] 1]
set T [dict create]
foreach r $A { dict set T [dict get $r name] [list [dict get $r installed] [dict get $r title]] }
ok "the index is taken, title line and all (its signature covers it)" [expr {$code == 0 && [dict size $T] == 2}] "$code $out"
ok "an app not installed is named by the index's title: OBS Studio" [expr {[dict exists $T com.obsproject.obs] && [dict get $T com.obsproject.obs] eq {{} {OBS Studio}}}] $T
ok "... and one the index gives no title has none (the window makes it from its short name)" [expr {[dict exists $T org.example.hello] && [dict get $T org.example.hello] eq {{} {}}}] $T
# repo.tcl alone: the title is on every version of its kit, a malformed title line is ignored
source -encoding utf-8 $top/srcpkgs/ribbon-kit/files/lib/core.tcl
::kit::init
::kit::need repo
set I [::kit::repo::parse [encoding convertto utf-8 "ribbon-kit-repo 1\ngenerated\t1\nexpires\t2\nkit\ta.b.c\t1\tapp\tr1\th\t1\t1\tc\t-\t-\ts\t\nkit\ta.b.c\t2\tapp\tr2\th\t1\t1\tc\t-\t-\ts\t\ntitle\ta.b.c\tSee\\tSaw\ntitle\tx.y\nkit\td.e\t1\tapp\tr3\th\t1\t1\te\t-\t-\ts\t\n"]]
ok "repo.tcl: a title line names every version of its kit, tabs flattened; a short line is ignored" \
    [expr {[lmap k [dict get $I kits] { dict get $k title }] eq {{See Saw} {See Saw} {}}}] [dict get $I kits]

# ---- no index: the reason comes through --------------------------------------------------------------------
file delete -force $W/home/.cache
spit $env(KIT_CONF) "keys = $L\nmirror = file://$W/nowhere\ntimeout = 2\n"
lassign [kitq apps] code out
set N [lsearch -inline -index 0 [said $out] noindex]
ok "offline with no index fetched before: noindex, with why" [expr {$N ne "" && [string trim [lindex $N 1]] ne ""}] "$code $out"

file delete -force $W
if {$fails} { puts "kit catalogue index: $fails checks failed" ; exit 1 }
puts "kit catalogue index: all checks passed"
