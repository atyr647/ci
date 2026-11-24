# tests/kit-txn-order.tcl -- a change's after-switch commands (the system scope's /usr view switch is one) run BEFORE the
# store's garbage collection, not after: a root that the previous set used, and that the history no longer keeps, is
# still in the store while the new view is made and mounted (a crash or a failure in between used to leave a view that
# names kit files gc had removed). The probe is registered as an afterSwitch command and says whether a root that gc is
# about to collect is still there when it runs. Needs Mk4tcl (KITFMT_MK4TCL) and minisign; skips without them.
#   KITFMT_MK4TCL=DIR tclsh8.6 -encoding utf-8 tests/kit-txn-order.tcl
set top [file dirname [file dirname [file normalize [info script]]]]
set KIT $top/srcpkgs/ribbon-kit/files/bin/kit
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
proc tool {args} { if {[catch {exec {*}$args 2>@1} out]} { error "$args: $out" } ; return $out }
set mk4 [expr {[info exists env(KITFMT_MK4TCL)] ? $env(KITFMT_MK4TCL) : ""}]
if {[auto_execok minisign] eq "" || [catch {exec $tclsh << "lappend auto_path {$mk4}; package require Mk4tcl"}]} {
    puts "  skip kit's change order (no Mk4tcl: KITFMT_MK4TCL, or no minisign)" ; exit 0
}
set W [file normalize [exec mktemp -d]]
file mkdir $W/home
set env(HOME) $W/home
foreach v {XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME KIT_INDEX} { unset -nocomplain env($v) }
set env(KIT_CONF) $W/kit.conf
set env(TCLLIBPATH) [concat [list $mk4] [expr {[info exists env(TCLLIBPATH)] ? $env(TCLLIBPATH) : ""}]]
set L $W/keys/trusted-keys
file mkdir $W/keys
tool $tclsh $KT/kitkey init -repository org.ribbon.main -root $F/test-root.pub $L
tool $tclsh $KT/kitkey add -role app -from -30d $L $F/test-app.pub
tool $tclsh $KT/kitkey sign -key $F/test-root.key $L
spit $env(KIT_CONF) "keys = $L\nrepos = $W/none\n"
proc pack {name} {
    set dir $::W/src/$name
    spit $dir/bin/app "#!/bin/sh\necho $name\n" 493
    spit $dir.manifest "name org.example.$name version 1 kind app summary {A probe}\nentries {{$name bin/app {} app}}\n"
    tool $::tclsh $::KIT pack -q -sign $::F/test-app.key $dir $::W/$name.kit
    return $::W/$name.kit
}
proc kit {args} { tool $::tclsh $::KIT {*}$args }

# alpha comes and goes; three more changes push its removal out of the history window (the 3 latest changes' sets are kept)
kit grab --yes [pack alpha]
set root [lindex [glob -directory $W/home/.local/share/kit/store *] 0]
ok "alpha is in the store" [file isdirectory $root]
kit toss --yes org.example.alpha
kit grab --yes [pack beta]
kit grab --yes [pack gamma]
ok "alpha's files are still kept by the history (a rewind could bring it back)" [file isdirectory $root]

# the last change, run in this process with a probe after the switch
set driver $W/driver.tcl
spit $driver {
    lassign $argv kitlib root kitfile out
    source -encoding utf-8 $kitlib/core.tcl
    ::kit::init
    ::kit::need ui repo net store plan system verbs txn launch
    set ::kit::ui::yes 1
    proc probe {A} { set f [open $::out a] ; puts $f "probe: store [expr {[file isdirectory [::kit::path store $::root]] ? "has" : "lacks"}] the root gc will collect" ; close $f }
    lappend ::kit::txn::afterSwitch probe
    ::kit::prologue
    ::kit::txn::recover
    ::kit::verbs::Grab $kitfile
    set f [open $::out a] ; puts $f "after: store [expr {[file isdirectory [::kit::path store $::root]] ? "has" : "lacks"}] the root" ; close $f
}
set outf $W/probe.log
set rc [catch {exec $tclsh $driver $top/srcpkgs/ribbon-kit/files/lib $root [pack delta] $outf 2>@1} out]
set log [expr {[file exists $outf] ? [string trim [exec cat $outf]] : ""}]
ok "the fourth change ran" [expr {!$rc}] "$out"
ok "the after-switch command ran while the store still had the root gc was about to collect" [string match "*probe: store has the root*" $log] $log
ok "and gc collected it afterwards (it is not kept for ever)" [string match "*after: store lacks the root*" $log] $log

file delete -force $W
if {$fails} { puts "kit change order: $fails checks failed" ; exit 1 }
puts "kit change order: all checks passed"
