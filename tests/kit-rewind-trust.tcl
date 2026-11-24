# tests/kit-rewind-trust.tcl -- kit rewind and the signer of what it brings back (docs/KIT-TRUST.md section 2: a revoked key is
# refused for everything, installed kits included; an expired one only stops new installs). A plain rewind re-activates
# versions that are still in the store; it used to do that without asking kittrust again, so a kit signed by a key that was
# revoked since came back. Now every version a rewind brings back is judged again, in mode installed.
# Needs Mk4tcl (KITFMT_MK4TCL) and minisign; skips without them.
#   KITFMT_MK4TCL=DIR tclsh8.6 -encoding utf-8 tests/kit-rewind-trust.tcl
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
    puts "  skip kit rewind's trust check (no Mk4tcl: KITFMT_MK4TCL, or no minisign)" ; exit 0
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
tool $tclsh $KT/kitkey add -role app -from -30d $L $F/test-app2.pub
tool $tclsh $KT/kitkey sign -key $F/test-root.key $L
spit $env(KIT_CONF) "keys = $L\nrepos = $W/none\n"
proc keyid {pub} {
    string trim [exec $::tclsh << "lappend auto_path $::top/kit/kitfmt; package require kitfmt; puts \[::kitfmt::PubKeyId \[lindex \[split \[string trim \[read \[open $pub\]\]\] \\n\] end\]\]"]
}
proc resign {} { tool $::tclsh $::KT/kitkey sign -key $::F/test-root.key $::L }

proc pack {name version key} {
    set dir $::W/src/$name-$version
    spit $dir/bin/app "#!/bin/sh\necho $name-$version\n" 493
    spit $dir.manifest "name org.example.$name version $version kind app summary {A probe}\nentries {{$name bin/app {} app}}\n"
    tool $::tclsh $::KIT pack -q -sign $key $dir $::W/$name-$version.kit
    return $::W/$name-$version.kit
}
proc kit {args} {
    set code 0
    if {[catch {exec timeout -k 5 60 $::tclsh $::KIT {*}$args 2>@1} out opts]} {
        set ec [dict get $opts -errorcode]
        set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : "error"}]
    }
    list $code $out
}
proc version {name} {
    lassign [kit list] code out
    if {[regexp -line "^  $name +(\\S+)" $out -> v]} { return $v }
    return ""
}

# A: alpha 1 by the first key, alpha 2 by the second; the first key is revoked afterwards; a rewind would bring 1 back
set a1 [pack alpha 1 $F/test-app.key]
set a2 [pack alpha 2 $F/test-app2.key]
foreach f [list $a1 $a2] { lassign [kit grab --yes $f] code out ; ok "grab [file tail $f]" [expr {$code == 0}] "$code $out" }
ok "alpha 2 is installed" [expr {[version alpha] eq "2"}]
tool $tclsh $KT/kitkey revoke -reason test $L [keyid $F/test-app.pub]
resign
lassign [kit rewind --yes] code out
ok "rewind to a version whose signing key has been revoked since: refused as a verification failure (exit 4)" [expr {$code == 4}] "$code $out"
ok "  and says why (revoked)" [string match -nocase *revoked* $out] $out
ok "  and nothing changed: alpha 2 is still installed" [expr {[version alpha] eq "2"}] [version alpha]

# B: beta 1 by the second key, beta 2 by the first; the second key's validity has ended since; a rewind may still bring 1 back
set b1 [pack beta 1 $F/test-app2.key]
# (the first key is revoked by now, so both are signed by the second)
set b2 [pack beta 2 $F/test-app2.key]
foreach f [list $b1 $b2] { lassign [kit grab --yes $f] code out ; ok "grab [file tail $f]" [expr {$code == 0}] "$code $out" }
tool $tclsh $KT/kitkey remove $L [keyid $F/test-app2.pub]
tool $tclsh $KT/kitkey add -role app -from -60d -until -1d $L $F/test-app2.pub
resign
lassign [kit rewind --yes] code out
ok "rewind to a version whose key has expired since: allowed (installed kits are not judged for expiry again)" [expr {$code == 0}] "$code $out"
ok "  beta 1 is back" [expr {[version beta] eq "1"}] [version beta]

# C: kit rewind KIT (one kit, by name) is judged the same way: gamma 1 and 2 by keys that are valid when grabbed ...
tool $tclsh $KT/kitkey remove $L [keyid $F/test-app2.pub]
tool $tclsh $KT/kitkey add -role app -from -30d $L $F/test-app2.pub
resign
set g1 [pack gamma 1 $F/test-app2.key]
set g2 [pack gamma 2 $F/test-app2.key]
foreach f [list $g1 $g2] { lassign [kit grab --yes $f] code out ; ok "grab [file tail $f]" [expr {$code == 0}] "$code $out" }
# ... the key's validity ends: the named rewind still works (expiry only stops new installs)
tool $tclsh $KT/kitkey remove $L [keyid $F/test-app2.pub]
tool $tclsh $KT/kitkey add -role app -from -60d -until -1d $L $F/test-app2.pub
resign
lassign [kit rewind org.example.gamma --yes] code out
ok "rewind KIT to a version whose key has expired since: allowed" [expr {$code == 0 && [version gamma] eq "1"}] "$code $out [version gamma]"
# ... and when the key is revoked, it is refused
lassign [kit grab --yes gamma] code out
tool $tclsh $KT/kitkey remove $L [keyid $F/test-app2.pub]
tool $tclsh $KT/kitkey add -role app -from -30d $L $F/test-app2.pub
resign
set g3 [pack gamma 3 $F/test-app2.key]
lassign [kit grab --yes $g3] code out
ok "grab gamma 3" [expr {$code == 0 && [version gamma] eq "3"}] "$code $out"
tool $tclsh $KT/kitkey revoke -reason test $L [keyid $F/test-app2.pub]
resign
lassign [kit rewind org.example.gamma --yes] code out
ok "rewind KIT when the signing key has been revoked: refused (exit 4), nothing changed" [expr {$code == 4 && [version gamma] eq "3"}] "$code $out [version gamma]"

file delete -force $W
if {$fails} { puts "kit rewind trust: $fails checks failed" ; exit 1 }
puts "kit rewind trust: all checks passed"
