# kit-repos.tcl -- per-repository key lists (docs/KIT-TRUST.md section 6, decision T7 A), as the kit
# CLI loads them (srcpkgs/ribbon-kit/files/lib/core.tcl): /etc/kit/repos.d/<id>.conf, one root-signed
# key list per repository with its own roots, the system role honoured only in Ribbon's list, a
# list for another repository than its file names refused, Ribbon's mirrors from its repository
# file.  Uses the test-only keys in tests/fixtures/kittrust and kitfmt's golden kits; needs minisign.
#   tclsh8.6 tests/kit-repos.tcl
set top [file normalize [file join [file dirname [info script]] ..]]
set K $top/kit/kittrust
set F $top/tests/fixtures/kittrust
set G $top/kit/kitfmt/tests/golden
set CORE $top/srcpkgs/ribbon-kit/files/lib/core.tcl
set tclsh [info nameofexecutable]
set fail 0 ; set count 0
proc check {desc cond {detail ""}} {
    incr ::count
    if {[uplevel 1 [list expr $cond]]} { puts "  ok   $desc" ; return }
    puts "  FAIL $desc" ; set ::fail 1
    if {$detail ne ""} { foreach l [split [string trimright $detail] \n] { puts "       | $l" } }
}
proc tool {name args} {
    if {[catch {exec $::tclsh $::K/$name {*}$args 2>@1} out]} { puts "  FAIL $name $args: $out" ; set ::fail 1 }
    return $out
}
proc slurp {p} { set f [open $p rb] ; set d [read $f] ; close $f ; return $d }
proc spit {p d} { file mkdir [file dirname $p] ; set f [open $p wb] ; puts -nonewline $f $d ; close $f }
proc cpkit {from to} { file copy -force $from $to ; file attributes $to -permissions 0644 }

if {[auto_execok minisign] eq ""} { puts "  skip per-repository key lists (no minisign)" ; exit 0 }
set T [file normalize [exec mktemp -d]]
source $K/kittrust.tcl
proc keyid {pub} { return [::kitfmt::PubKeyId [lindex [split [string trim [slurp $pub]] \n] end]] }
set OTHER [keyid $F/test-other.pub]

# ---- the lists ---------------------------------------------------------------------------------------
# Ribbon's (org.ribbon.main): app, system and index keys under test-root
set RL $T/etc/kit/trusted-keys
tool kitkey init -repository org.ribbon.main -root $F/test-root.pub $RL
tool kitkey add -role app $RL $F/test-app.pub
tool kitkey add -role system $RL $F/test-system.pub
tool kitkey add -role index $RL $F/test-index.pub
tool kitkey sign -key $F/test-root.key $RL
# another publisher's (com.example.apps), under its own root, whose list gives its key every role
set XL $T/etc/kit/repos.d/com.example.apps.keys
tool kitkey init -repository com.example.apps -root $F/test-root2.pub $XL
tool kitkey add -role app,system,index -for 30d $XL $F/test-other.pub
tool kitkey sign -key $F/test-root2.key $XL
# a list for one repository (org.example.real) put in another one's file (net.example.wrong)
set WL $T/etc/kit/repos.d/net.example.wrong.keys
tool kitkey init -repository org.example.real -root $F/test-root3.pub $WL
tool kitkey add -role app $WL $F/test-app2.pub
tool kitkey sign -key $F/test-root3.key $WL

# ---- the kits: golden kits re-sealed in place -------------------------------------------------------
file mkdir $T/kits
foreach {name src key list} [list \
    ribbon-app app.kit test-app $RL   ribbon-system system.kit test-system $RL \
    other-app app.kit test-other $XL  other-system system.kit test-other $XL \
    wrong-app app.kit test-app2 $WL] {
    cpkit $G/$src $T/kits/$name.kit
    tool kitseal -key $F/$key.key -keys $list $T/kits/$name.kit
}

# ---- the configurations ---------------------------------------------------------------------------
proc conf {name text {repos {}}} {
    set d $::T/conf/$name
    file delete -force $d ; file mkdir $d/repos.d
    spit $d/kit.conf "repos = $d/repos.d\n$text"
    foreach {id body} $repos { spit $d/repos.d/$id.conf $body }
    return $d/kit.conf
}
set ribbonConf "url = https://kits.example.org/ribbon/\nmirror = https://mirror-a.example.org/ribbon\nmirror = https://mirror-b.example.org/ribbon\nkeys = $RL\n"
set otherConf "url = https://kits.example.com/apps\nkeys = $XL\n"
set wrongConf "keys = $WL\n"

# Load the CLI's core in a fresh interpreter with this kit.conf, then run script there; stderr
# (the CLI's warnings) is captured -> {result warnings}
proc withConf {conf script {home ""}} {
    if {$home eq ""} { set home [exec mktemp -d -p $::T] }
    set ::env(HOME) $home ; set ::env(KIT_CONF) $conf
    unset -nocomplain ::env(XDG_DATA_HOME) ::env(XDG_CACHE_HOME) ::env(XDG_CONFIG_HOME) ::env(KIT_INDEX)
    set i [interp create]
    $i eval [list set CORE $::CORE]
    $i eval {
        rename puts ::tcl_puts
        set ::warnings ""
        proc puts {args} {
            if {[llength $args] == 2 && [lindex $args 0] eq "stderr"} { append ::warnings [lindex $args 1] \n ; return }
            ::tcl_puts {*}$args
        }
        source $CORE
        ::kit::init
        ::kit::kitfmt
        proc sig {kit} {
            set fr [::kitfmt::Frame $kit]
            set s [::kitfmt::SigCheck [dict get $fr statement] [dict get $fr signature]]
            return [list [dict get $s state] [dict get $s detail]]
        }
    }
    set r [$i eval $script]
    set w [$i eval {set ::warnings}]
    interp delete $i
    return [list $r $w]
}
proc sigs {conf} {
    withConf $conf {
        set out {}
        foreach k {ribbon-app ribbon-system other-app other-system wrong-app} { lappend out $k [sig $::env(KITS)/$k.kit] }
        set out
    }
}
set env(KITS) $T/kits

# ---- 1. Ribbon's list from its repository file, another repository beside it ------------------------
puts "  -- two repositories, each with its own roots"
set c [conf both "" [list org.ribbon.main $ribbonConf com.example.apps $otherConf net.example.wrong $wrongConf]]
lassign [sigs $c] S W
check "Ribbon's app kit by Ribbon's app key is valid" {[lindex [dict get $S ribbon-app] 0] eq "valid"} $S
check "Ribbon's system kit by Ribbon's system key is valid" {[lindex [dict get $S ribbon-system] 0] eq "valid"} $S
check "another repository's app kit, by a key of its own list, is valid" {[lindex [dict get $S other-app] 0] eq "valid"} $S
check "its system kit is refused, although its own list gives the key the system role" \
    {[lindex [dict get $S other-system] 0] eq "invalid" &&
     [string match "*key $OTHER is a key of repository com.example.apps: only Ribbon's key list may sign system kits*" [lindex [dict get $S other-system] 1]]} $S
check "a list for another repository than its file names is refused: its key verifies nothing" \
    {[lindex [dict get $S wrong-app] 0] eq "untrusted"} $S
check "  and kit says why" {[string match "*repository net.example.wrong: its key list $WL is for repository org.example.real, not net.example.wrong: refused*" $W]} $W

lassign [withConf $c {
    list [::kit::mirrors] [::kit::keysFile] [file exists [::kit::path data repos com.example.apps keys anchor]] \
        [file exists [::kit::path data keys anchor]] [file exists [::kit::path data repos net.example.wrong keys]]
}] R
lassign $R mirrors keys anchorX anchorR wrongState
check "Ribbon's mirrors are its repository file's url, then its mirror lines" \
    {$mirrors eq {https://kits.example.org/ribbon https://mirror-a.example.org/ribbon https://mirror-b.example.org/ribbon}} $mirrors
check "Ribbon's key list is the keys line of its repository file" {$keys eq $RL} $keys
check "each list is anchored in its own state directory (Ribbon's in data/keys, another in data/repos/<id>/keys)" \
    {$anchorX && $anchorR}
check "a refused list leaves no state" {!$wrongState}

# ---- 2. without the other repository's file its kits are not trusted -----------------------------
set c2 [conf ribbon "" [list org.ribbon.main $ribbonConf]]
lassign [sigs $c2] S W
check "without com.example.apps.conf, its app kit is untrusted (the list is what admits it)" \
    {[lindex [dict get $S other-app] 0] eq "untrusted" && [lindex [dict get $S ribbon-app] 0] eq "valid"} $S

# ---- 3. Ribbon's file pointing at another repository's list --------------------------------------
set c3 [conf impostor "" [list org.ribbon.main "keys = $XL\n"]]
lassign [sigs $c3] S W
check "Ribbon's repository file with another repository's list: refused, nothing verifies" \
    {[lindex [dict get $S other-system] 0] ne "valid" && [lindex [dict get $S other-app] 0] ne "valid" &&
     [string match "*$XL is the key list of repository com.example.apps, not org.ribbon.main*" $W]} "$S\n$W"

# ---- 4. a key that Ribbon's list holds is judged by Ribbon's list alone --------------------------
# a copy of Ribbon's app key in another list (that grants it system) and Ribbon revoking it
set CL $T/etc/kit/repos.d/com.example.copy.keys
tool kitkey init -repository com.example.copy -root $F/test-root3.pub $CL
tool kitkey add -role app,system $CL $F/test-app.pub
tool kitkey sign -key $F/test-root3.key $CL
set RV $T/etc/kit/revoked-keys
file copy -force $RL $RV ; file copy -force $RL.minisig $RV.minisig
tool kitkey revoke -reason "test leak" $RV [keyid $F/test-app.pub]
tool kitkey sign -key $F/test-root.key $RV
set c4 [conf copy "" [list org.ribbon.main "keys = $RV\n" com.example.copy "keys = $CL\n"]]
lassign [sigs $c4] S W
check "another list can't bring back a key Ribbon revoked" \
    {[lindex [dict get $S ribbon-app] 0] eq "invalid" && [string match "*revoked*" [lindex [dict get $S ribbon-app] 1]]} $S

# ---- 5. expiry in another list follows kit's mode (install / installed, T2 A) ----------------------
lassign [withConf $c {
    set later [expr {[clock seconds] + 40 * 86400}]
    ::kittrust configure -now $later
    set a [sig $::env(KITS)/other-app.kit]
    ::kittrust configure -mode installed
    set b [sig $::env(KITS)/other-app.kit]
    list $a $b
}] R
lassign $R a b
check "another repository's expired key installs nothing" {[lindex $a 0] eq "invalid" && [string match "*expired*" [lindex $a 1]]} $a
check "  but what it signed stays valid once installed (kit mend: -mode installed)" {[lindex $b 0] eq "valid"} $b

# ---- 6. Ribbon's index: only Ribbon's index keys sign it ---------------------------------------------
# an index for org.ribbon.main signed by the other repository's index key (its own list says index)
::kittrust load -anchor $XL
source $K/publish.tcl
set fr [::kitfmt::Frame $T/kits/other-app.kit] ; set st [dict get $fr st]
set rec [list [dict get $st name] [dict get $st version] app [dict get $st root] [::kitfmt hash [dict get $fr statement]] 1000 1000 app - - "test kit" ""]
::kittrust::repo::Publish $T/repo-x "" [list $rec] -key $F/test-other.key
lassign [withConf $c {
    source [file join [file dirname $CORE] repo.tcl]
    set text [::kit::slurp $::env(KITS)/../repo-x/index] ; set sig [::kit::slurp $::env(KITS)/../repo-x/index.minisig]
    list [catch {::kit::repo::checkIndex $text $sig} e opts] $e [dict get $opts -errorcode]
}] R
lassign $R rc e ec
check "another repository's index is refused as Ribbon's index" {$rc == 1 && [lindex $ec 0] eq "KIT" && [lindex $ec 1] == 4} "$e $ec"

# a key list fetched from Ribbon's mirror (kit refresh) leaves the other repositories' keys with kitfmt
set ::env(KIT_RL) $RL
lassign [withConf $c {
    source [file join [file dirname $CORE] repo.tcl]
    namespace eval ::kit::net {}
    proc ::kit::net::get {url args} {
        set f $::env(KIT_RL)[expr {[string match *.minisig $url] ? ".minisig" : ""}]
        return [dict create data [::kit::slurp $f]]
    }
    list [::kit::repo::Keys file:///srv/kits] [sig $::env(KITS)/other-app.kit]
}] R
lassign $R r s
check "after Ribbon's key list is fetched, another repository's app kit is still valid" {$r eq "current" && [lindex $s 0] eq "valid"} $R

# ---- 7. kit.conf's keys = (a developer setting) still names Ribbon's list -------------------------
set c7 [conf dev "keys = $RL\nmirror = file:///srv/kits\n" [list org.ribbon.main "url = https://kits.example.org/ribbon\nkeys = /nonexistent\n"]]
lassign [withConf $c7 { list [::kit::keysFile] [::kit::mirrors] [sig $::env(KITS)/ribbon-system.kit] }] R
lassign $R keys mirrors s
check "kit.conf's keys = wins over Ribbon's repository file" {$keys eq $RL && [lindex $s 0] eq "valid"} "$keys $s"
check "kit.conf's mirror lines come before Ribbon's repository file's" {$mirrors eq {file:///srv/kits https://kits.example.org/ribbon}} $mirrors

# ---- 7b. a recorded anchor of another repository's list in data/keys ------------------------------
# kit.conf's keys = once named another repository's list (a developer setting), so data/keys pinned
# it; with the line gone, Ribbon's repository file names Ribbon's list, and the recorded anchor
# (which Load prefers) must not make that other list Ribbon's, with the system role
set home7 [exec mktemp -d -p $T]
withConf [conf devx "keys = $XL\n" {}] { ::kit::keysFile } $home7
set c7b [conf undev "" [list org.ribbon.main "keys = $RL\n"]]
lassign [withConf $c7b { list [sig $::env(KITS)/other-system.kit] [sig $::env(KITS)/ribbon-app.kit] } $home7] R W
lassign $R s r
check "a recorded anchor of another repository in data/keys doesn't become Ribbon's list" \
    {[lindex $s 0] ne "valid" && [string match "*com.example.apps*not org.ribbon.main*" $W]} "$R\n$W"

# ---- 8. what ribbon-kit ships -------------------------------------------------------------------
set shipped $top/srcpkgs/ribbon-kit/files/etc/kit/repos.d/org.ribbon.main.conf
set c8 [conf shipped "" {}]
file copy -force $shipped $T/conf/shipped/repos.d/
lassign [withConf $c8 { list [dict keys [::kit::repos]] [::kit::keysFile] }] R
check "ribbon-kit ships Ribbon's repository file, naming /etc/kit/trusted-keys" {$R eq {org.ribbon.main /etc/kit/trusted-keys}} $R
set tpl [slurp $top/srcpkgs/ribbon-kit/template]
check "  and its template installs it (a conf file, kept on upgrade)" \
    {[string match "*etc/kit/repos.d/org.ribbon.main.conf*" $tpl] && [regexp {conf_files="[^"]*/etc/kit/repos.d/org.ribbon.main.conf} $tpl]}

file delete -force $T
puts "  $count checks"
exit $fail
