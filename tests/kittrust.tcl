# The kit signing infrastructure (kit/kittrust, docs/KIT-TRUST.md) end to end, with the test-only
# keys in tests/fixtures/kittrust/ and copies of kitfmt's golden kits: the key list and its
# updates, kit seals, the signed index, and the kitfmt verifier hook.  Needs minisign.  With
# Mk4tcl (KITFMT_MK4TCL=<dir>) it also builds a repository from kits and checks their chunks.
#   tclsh8.6 tests/kittrust.tcl
set repo [file normalize [file join [file dirname [info script]] ..]]
set K $repo/kit/kittrust
set F $repo/tests/fixtures/kittrust
set G $repo/kit/kitfmt/tests/golden
set T [file join [expr {[info exists env(TMPDIR)] && [file isdirectory $env(TMPDIR)] ? $env(TMPDIR) : "/tmp"}] kittrust-test-[pid]]
file delete -force $T
file mkdir $T/kits $T/anchor $T/state
set tclsh [info nameofexecutable]
set MK [expr {[info exists env(KITFMT_MK4TCL)] ? $env(KITFMT_MK4TCL) : ""}]

set fail 0 ; set count 0
proc check {desc cond} {
    incr ::count
    if {[uplevel 1 [list expr $cond]]} { puts "  ok   $desc" } else { puts "  FAIL $desc"; set ::fail 1 }
}
# run a tool: -> {exit-code output}
proc tool {name args} {
    set rc [catch {exec $::tclsh $::K/$name {*}$args 2>@1} out opts]
    set code 0
    if {$rc} {
        set ec [dict get $opts -errorcode]
        set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : 99}]
    }
    return [list $code $out]
}
# the tool must succeed / must fail with code (and output matching pattern)
proc pass {desc name args} {
    lassign [tool $name {*}$args] code out
    check $desc {$code == 0}
    if {$code != 0} { puts "       $out" }
    return $out
}
proc refuse {desc pattern name args} {
    lassign [tool $name {*}$args] code out
    check $desc {$code == 4 && [regexp -- $pattern $out]}
    if {$code != 4 || ![regexp -- $pattern $out]} { puts "       (exit $code) $out" }
    return $out
}
proc slurp {p} { set f [open $p rb] ; set d [read $f] ; close $f ; return $d }
proc spit {p d} { set f [open $p wb] ; puts -nonewline $f $d ; close $f }
proc keyid {pub} { return [::kitfmt::PubKeyId [lindex [split [string trim [slurp $pub]] \n] end]] }
proc cpkit {from to} { file copy -force $from $to ; file attributes $to -permissions 0644 }
proc cplist {from to} { file copy -force $from $to ; file copy -force $from.minisig $to.minisig }

if {[auto_execok minisign] eq ""} { puts "  skip kit signing (no minisign)" ; exit 0 }
source $K/kittrust.tcl
source $K/publish.tcl

set APP [keyid $F/test-app.pub] ; set APP2 [keyid $F/test-app2.pub] ; set SYS [keyid $F/test-system.pub]
set IDX [keyid $F/test-index.pub] ; set IDX2 [keyid $F/test-index2.pub] ; set ROOT [keyid $F/test-root.pub]
set L $T/trusted-keys

# ---- 1. a valid chain: root -> key list -> app/system/index keys -> kits and the index ----------
puts "  -- a valid chain"
pass "kitkey init: a new list with the test root" kitkey init -repository org.ribbon.test -root $F/test-root.pub $L
pass "kitkey add: app, system and index keys" kitkey add -role app $L $F/test-app.pub
tool kitkey add -role system $L $F/test-system.pub
tool kitkey add -role index -for 60d $L $F/test-index.pub
pass "kitkey sign: the root signs serial 1" kitkey sign -key $F/test-root.key $L
pass "kitkey check: the list is signed by its root" kitkey check $L
cplist $L $T/anchor/trusted-keys
set A $T/anchor/trusted-keys
# the kit CLI's own reader (core.tcl trustedKeys): the first word of lines that look like keys
proc naive {path} {
    set out {}
    foreach line [split [slurp $path] \n] {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} continue
        set k [lindex [split $line] 0]
        if {[regexp {^[A-Za-z0-9+/]{54}[A-Za-z0-9+/=]{2}$} $k]} { lappend out [::kitfmt::PubKeyId $k] }
    }
    return [lsort $out]
}
check "a plain reader of the list sees exactly the online keys (never the root)" {[naive $L] eq [lsort [list $APP $SYS $IDX]]}

cpkit $G/app.kit $T/kits/app.kit
cpkit $G/system.kit $T/kits/system.kit
pass "kitseal: re-sign an app kit in place with the app key" kitseal -key $F/test-app.key -keys $L $T/kits/app.kit
pass "kitseal: re-sign a system kit with the system key" kitseal -key $F/test-system.key -keys $L $T/kits/system.kit
cpkit $G/app-header.kit $T/kits/app-header.kit
pass "kitseal: sign an unsigned kit (kitpack without -sign, with a starkit header)" kitseal -key $F/test-app.key -keys $L $T/kits/app-header.kit
pass "  ... and it checks" kitseal -check -keys $L $T/kits/app-header.kit
file delete $T/kits/app-header.kit
check "re-signing keeps the size (the store never moves)" {[file size $T/kits/app.kit] == [file size $G/app.kit]}
set out [pass "kitseal -check: both kits are signed by keys of their role" kitseal -check -keys $L $T/kits/app.kit $T/kits/system.kit]
check "  it names the signer and the role" {[string match "*good signature by $APP (test-app), a trusted app key*" $out]}

# the index: built from the kits with Mk4tcl, else published from their seals (records only)
::kittrust load -anchor $L
proc records {kits} {
    set out {}
    foreach k $kits {
        set fr [::kitfmt::Frame $k] ; set st [dict get $fr st]
        lappend out [list [dict get $st name] [dict get $st version] [dict get $st kind] [dict get $st root] \
            [::kitfmt hash [dict get $fr statement]] 1000 1000 [lindex [split [dict get $st name] .] end] - - "test kit" ""]
    }
    return $out
}
set R $T/repo
if {$MK ne ""} {
    pass "kitindex build: the index of a directory of kits (Mk4tcl)" kitindex build -key $F/test-index.key -keys $L -mk4tcl $MK \
        -mirror https://mirror.example.org/test -flag app=security $T/kits $R
    set I [::kittrust parseindex [slurp $R/index]]
    set ok 1
    foreach r [dict get $I kits] {
        set b [slurp $R/kits/[lindex $r 3]]
        if {[::kitfmt hash $b] ne [lindex $r 4]} { set ok 0 }
        foreach {- h n} [regexp -all -inline {(?n)^([0-9a-f]{64}) ([0-9]+)$} $b] {
            set c $R/chunks/[string range $h 0 1]/$h
            if {![file isfile $c] || [file size $c] != $n || [::kitfmt hash [slurp $c]] ne $h} { set ok 0 }
        }
    }
    check "  every manifest matches its index line and every chunk its hash" {$ok}
    check "  -flag sets the index flags" {[lindex [lsearch -inline -index 0 [dict get $I kits] org.ribbon.golden.app] 8] eq "security"}
} else {
    puts "  skip kitindex build from kits (no Mk4tcl: set KITFMT_MK4TCL); publishing the seals' records instead"
    ::kittrust::repo::Publish $R "" [records [list $T/kits/app.kit $T/kits/system.kit]] -key $F/test-index.key \
        -mirrors https://mirror.example.org/test
}
set out [pass "kitindex check: the index is signed by an index key" kitindex check -keys $L $R/index]
check "  serial 1, key list 1" {[string match "*serial 1, 2 kits, key list 1,*" $out]}
check "the repository carries the key list clients update from" {[slurp $R/keys] eq [slurp $L]}
cplist $R/index $T/index-1

# kitfmt's pluggable verifier, as the kit CLI configures it
::kitfmt configure -keys [::kittrust keys] -verifier ::kittrust::Verify
set fr [::kitfmt::Frame $T/kits/system.kit]
set s [::kitfmt::SigCheck [dict get $fr statement] [dict get $fr signature]]
check "kitfmt -verifier ::kittrust::Verify: a system kit by the system key is valid" {[dict get $s state] eq "valid"}

# ---- 2. wrong role -----------------------------------------------------------------------------------
puts "  -- wrong role"
cpkit $G/system.kit $T/kits/system-by-app.kit
refuse "kitseal refuses to sign a system kit with an app key (nothing written)" {signs app, not system} \
    kitseal -key $F/test-app.key -keys $L $T/kits/system-by-app.kit
check "  the kit is unchanged" {[slurp $T/kits/system-by-app.kit] eq [slurp $G/system.kit]}
tool kitseal -key $F/test-app.key $T/kits/system-by-app.kit
refuse "a system kit signed by the app key is invalid" {signs app, not system kits} kitseal -check -keys $L $T/kits/system-by-app.kit
set fr [::kitfmt::Frame $T/kits/system-by-app.kit]
set s [::kitfmt::SigCheck [dict get $fr statement] [dict get $fr signature]]
check "  kitfmt says invalid, with the reason (never untrusted, which allow-unsigned would take)" \
    {[dict get $s state] eq "invalid" && [string match "*signs app, not system*" [dict get $s detail]]}
set text [slurp $R/index]
spit $T/index-by-app $text
spit $T/index-by-app.minisig [::kittrust sign $text $F/test-app.key "wrong role"]
refuse "an index signed by an app key is refused" {signs app, not index} kitindex check -keys $L $T/index-by-app
cplist $L $T/list-by-app
spit $T/list-by-app.minisig [::kittrust sign [slurp $L] $F/test-app.key "wrong role"]
refuse "a key list signed by an online key is refused" {signed by 0 of its root keys} kitkey check $T/list-by-app
check "kitkey sign will not sign the list with an online key" {[lindex [tool kitkey sign -key $F/test-app.key $T/list-by-app] 0] == 1}

# ---- 3. an expired key -------------------------------------------------------------------------------
puts "  -- an expired key"
tool kitkey gen -nopass -dir $T test-expired
set EXP [keyid $T/test-expired.pub]
pass "kitkey add: an app key valid from 30 days ago until yesterday" kitkey add -role app -from -30d -until -1d $L $T/test-expired.pub
pass "the root signs serial 2" kitkey sign -key $F/test-root.key $L
cpkit $G/app.kit $T/kits/app-expired.kit
refuse "kitseal -keys refuses an expired key" {expired on} kitseal -key $T/test-expired.key -keys $L $T/kits/app-expired.kit
tool kitseal -key $T/test-expired.key $T/kits/app-expired.kit
refuse "a kit signed by an expired key is invalid for installing" "key $EXP \\(test-expired\\) expired on" kitseal -check -keys $L $T/kits/app-expired.kit
pass "  ... but stays valid for an installed kit (-mode installed: expiry is not re-judged)" kitseal -check -mode installed -keys $L $T/kits/app-expired.kit
refuse "a key not valid yet is refused (-now 40 days back)" {is not valid before} kitseal -check -now -40d -keys $L $T/kits/app.kit
refuse "the whole list expired (-now 400 days on): every key is refused" {trusted key list expired} kitseal -check -now 400d -keys $L $T/kits/app.kit

# ---- 4. rotation -------------------------------------------------------------------------------------
puts "  -- rotation"
set out [pass "kitkey rotate: test-app2 takes over the app role, test-app overlaps 7 days" kitkey rotate -overlap 7d $L $APP $F/test-app2.pub]
pass "the root signs serial 3" kitkey sign -key $F/test-root.key $L
pass "during the overlap the old key's kits still verify" kitseal -check -keys $L $T/kits/app.kit
refuse "after the overlap they do not (-now 8d)" "key $APP \\(test-app\\) expired" kitseal -check -now 8d -keys $L $T/kits/app.kit
pass "kitseal moves the kit to the new key, in place" kitseal -key $F/test-app2.key -keys $L $T/kits/app.kit
pass "  ... and it verifies after the overlap" kitseal -check -now 8d -keys $L $T/kits/app.kit
check "  the statement (and so the root) did not change" \
    {[dict get [::kitfmt::Frame $T/kits/app.kit] statement] eq [dict get [::kitfmt::Frame $G/app.kit] statement]}

# ---- 5. revocation -----------------------------------------------------------------------------------
puts "  -- a revoked key"
cpkit $T/kits/app.kit $T/kits/app-by-old.kit
tool kitseal -key $F/test-app.key $T/kits/app-by-old.kit
pass "kitkey revoke: test-app is revoked (leaked), signed as serial 4" kitkey revoke -reason "test: the key leaked" $L $APP
tool kitkey sign -key $F/test-root.key $L
refuse "a kit signed by a revoked key is invalid" {was revoked on .*: test: the key leaked} kitseal -check -keys $L $T/kits/app-by-old.kit
refuse "  ... also for installed kits (-mode installed)" {was revoked} kitseal -check -mode installed -keys $L $T/kits/app-by-old.kit
refuse "  ... and kitseal will not sign with it" {was revoked} kitseal -key $F/test-app.key -keys $L $T/kits/app-by-old.kit
check "a plain reader no longer sees the revoked key" {$APP ni [naive $L]}
# revocation announced by the index, before the root signs a new list
::kittrust load -anchor $L
set out [::kittrust::repo::Publish $T/repo-rev "" [records [list $T/kits/app.kit]] -key $F/test-index.key \
    -revoke [dict create $APP2 "test: CI was broken into"]]
::kittrust load -anchor $L
set c [::kittrust check [dict get [::kitfmt::Frame $T/kits/app.kit] statement] [dict get [::kitfmt::Frame $T/kits/app.kit] signature]]
check "before the index is read, test-app2's kit is valid" {[dict get $c state] eq "valid"}
::kittrust index [slurp $T/repo-rev/index] [slurp $T/repo-rev/index.minisig]
set c [::kittrust check [dict get [::kitfmt::Frame $T/kits/app.kit] statement] [dict get [::kitfmt::Frame $T/kits/app.kit] signature]]
check "an index's revoked line revokes test-app2 at once" {[dict get $c state] eq "invalid" && [string match "*announced by the repository index*" [dict get $c detail]]}
::kittrust load -anchor $L
# T3 A as narrowed: an index revokes app and system keys only, never an index key nor an id the list does not hold
set out [::kittrust::repo::Publish $T/repo-rev2 "" [records [list $T/kits/app.kit]] -key $F/test-index.key \
    -revoke [dict create $IDX "test: an index revoking itself" 0123456789ABCDEF "test: no such key"]]
::kittrust load -anchor $L
::kittrust index [slurp $T/repo-rev2/index] [slurp $T/repo-rev2/index.minisig]
set c [::kittrust check [slurp $T/repo-rev2/index] [slurp $T/repo-rev2/index.minisig]]
check "an index cannot revoke an index key (T3 A narrowed): the index key still signs" {[dict get $c state] eq "valid"}
check "  and an id the key list does not hold is not taken as revoked" {![info exists ::kittrust::extra(0123456789ABCDEF)] && ![info exists ::kittrust::extra($IDX)]}
::kittrust load -anchor $L

# ---- 6. root-signed key-list updates (rollback and freeze protection) ------------------------------
puts "  -- key-list updates"
set out [pass "kitkey update: serial 4 chains from the anchor (serial 1)" kitkey update -anchor $A -state $T/state $L]
check "  it is kept in the state directory" {[file isfile $T/state/4.keys] && [file isfile $T/state/4.keys.minisig]}
check "  it says so" {[string match "*serial 1 -> 4*" $out]}
set out [pass "the same list again is no change" kitkey update -anchor $A -state $T/state $L]
check "  'the one in use'" {[string match "*is the one in use*" $out]}
refuse "an older list (serial 1) is refused: rollback" {already has serial 4} kitkey update -anchor $A -state $T/state $A
# two different lists that both claim serial 5
cplist $L $T/l5a ; cplist $L $T/l5b
tool kitkey add -role index $T/l5a $F/test-index2.pub ; tool kitkey sign -key $F/test-root.key $T/l5a
tool kitkey add -role app $T/l5b $F/test-index2.pub ; tool kitkey sign -key $F/test-root.key $T/l5b
pass "serial 5 is accepted" kitkey update -anchor $A -state $T/state $T/l5a
refuse "a different list with the same serial 5 is refused" {same serial 5} kitkey update -anchor $A -state $T/state $T/l5b
cplist $T/l5a $T/l6
tool kitkey sign -expires 1h -key $F/test-root.key $T/l6
refuse "a list past its expiry is refused (a frozen copy, -now 2h)" {expired on} kitkey update -now 2h -anchor $A -state $T/state $T/l6
cplist $T/l6 $T/l6t
spit $T/l6t [string map [list "\ttest-index2\n" "\ttest-indeX2\n"] [slurp $T/l6]]
refuse "a tampered list is refused" {signed by 0 of the current root keys} kitkey update -anchor $A -state $T/state $T/l6t
cplist $T/l6 $T/l6o
spit $T/l6o.minisig [::kittrust sign [slurp $T/l6] $F/test-app2.key "not a root"]
refuse "a list signed by an online key is refused" {signed by 0 of the current root keys} kitkey update -anchor $A -state $T/state $T/l6o
tool kitkey init -repository org.example.other -root $F/test-root.pub $T/other
tool kitkey add -role app $T/other $F/test-other.pub
tool kitkey sign -key $F/test-root.key $T/other
refuse "a list for another repository is refused (same root)" {for repository org.example.other} kitkey update -anchor $A -state $T/state $T/other
set s [::kittrust load -anchor $A -state $T/state]
check "loading picks the newest list that chains from the anchor (serial 5)" {[dict get $s serial] == 5}
spit $T/state/7.keys [slurp $T/l6t] ; spit $T/state/7.keys.minisig [slurp $T/l6t.minisig]
set s [::kittrust load -anchor $A -state $T/state]
check "a planted list in the state directory that does not chain is skipped" {[dict get $s serial] == 5 && [llength [dict get $s skipped]] == 1}
file delete $T/state/7.keys $T/state/7.keys.minisig

# ---- 7. root rotation and a 2-of-3 threshold ---------------------------------------------------------
puts "  -- root rotation"
cplist $T/l5a $T/r1
pass "kitkey root: add test-root2 and test-root3, drop test-root, threshold 2" kitkey root -add $F/test-root2.pub -add $F/test-root3.pub -drop $ROOT -threshold 2 $T/r1
set out [pass "kitkey sign -prev: the new roots sign" kitkey sign -prev $T/l5a -key $F/test-root2.key -key $F/test-root3.key $T/r1]
check "  ... and kitkey warns it is not yet a valid update (the old root has not signed)" {[string match "*not yet a valid update*" $out]}
refuse "without the old root it is refused (signed by 0 of the current roots)" {signed by 0 of the current root keys} kitkey update -anchor $A -state $T/state $T/r1
pass "kitkey cosign -prev: the old root signs too" kitkey cosign -prev $T/l5a -key $F/test-root.key $T/r1
pass "kitkey check -prev: now it is a valid update" kitkey check -prev $T/l5a $T/r1
pass "the rotated list is accepted" kitkey update -anchor $A -state $T/state $T/r1
cplist $T/r1 $T/r2
tool kitkey add -role index $T/r2 $F/test-other.pub
tool kitkey sign -key $F/test-root.key -prev $T/r1 $T/r2
check "the old root alone can sign no longer (kitkey sign refuses it)" {[lindex [tool kitkey sign -key $F/test-root.key $T/r2] 0] == 1}
tool kitkey sign -key $F/test-root2.key $T/r2
set good [slurp $T/r2.minisig]
spit $T/r2.minisig [::kittrust sign [slurp $T/r2] $F/test-root.key "old root"]
refuse "  ... and a list it signed is refused" {signed by 0 of the current root keys} kitkey update -anchor $A -state $T/state $T/r2
spit $T/r2.minisig $good
refuse "one of the two needed roots is not enough" {signed by 1 of the current root keys; 2 needed} kitkey update -anchor $A -state $T/state $T/r2
pass "kitkey cosign: the second root signs" kitkey cosign -key $F/test-root3.key $T/r2
pass "2 of 3 roots: accepted" kitkey update -anchor $A -state $T/state $T/r2
set s [::kittrust load -anchor $A -state $T/state]
check "the chain anchor -> 4 -> 5 -> 6 (new roots) -> 7 loads" {[dict get $s serial] == 7}

# the anchor in the base system changes (an update, a rollback, an attack)
file mkdir $T/b $T/bstate
cplist $A $T/b/trusted-keys
::kittrust load -anchor $T/b/trusted-keys -state $T/bstate
check "the first anchor a client sees is recorded in its state" {[slurp $T/bstate/anchor] eq [slurp $A]}
cplist $L $T/b/trusted-keys
set s [::kittrust load -anchor $T/b/trusted-keys -state $T/bstate]
check "a base update shipping a newer list that chains is taken (serial 4)" {[dict get $s serial] == 4 && [file isfile $T/bstate/4.keys]}
cplist $A $T/b/trusted-keys
set s [::kittrust load -anchor $T/b/trusted-keys -state $T/bstate]
check "a base rollback shipping the older list changes nothing (still 4)" {[dict get $s serial] == 4}
tool kitkey init -repository org.ribbon.test -root $F/test-other.pub $T/b/evil
tool kitkey add -role app,system,index $T/b/evil $F/test-other.pub
spit $T/b/evil [string map [list "serial\t0" "serial\t98"] [slurp $T/b/evil]]
tool kitkey sign -key $F/test-other.key $T/b/evil
cplist $T/b/evil $T/b/trusted-keys
set s [::kittrust load -anchor $T/b/trusted-keys -state $T/bstate]
check "a replaced anchor with other roots (serial 99) is ignored: the roots stay" \
    {[dict get $s serial] == 4 && [string match "*does not follow the trusted key list*" [dict get $s skipped]]}

# ---- 8. the index: replay, expiry, snapshots, tampering ------------------------------------------
puts "  -- the signed index"
pass "kitindex refresh: serial 2, same kits" kitindex refresh -key $F/test-index.key -keys $L $R
cplist $R/index $T/index-2
refuse "the older index (serial 1) after serial 2 is a replay" {already used serial 2} kitindex check -keys $L -prev $T/index-2 $T/index-1
pass "  serial 2 after serial 1 is fine" kitindex check -keys $L -prev $T/index-1 $T/index-2
::kittrust load -anchor $L
::kittrust::repo::Publish $T/repo-fork [::kittrust parseindex [slurp $T/index-1]] [records [list $T/kits/app.kit]] -key $F/test-index.key
refuse "a different index with the same serial is refused" {different index with the same serial 2} kitindex check -keys $L -prev $T/index-2 $T/repo-fork/index
refuse "a snapshot served as the live index is refused" {snapshot .* served as the live index} kitindex check -keys $L $R/snapshots/2
pass "  ... but is fine pinned (KIT_INDEX)" kitindex check -pinned -keys $L $R/snapshots/2
refuse "an index past its expiry is refused (-now 8d)" {expired on} kitindex check -now 8d -keys $L $R/index
pass "  ... its snapshot still pins for 90 days" kitindex check -pinned -now 8d -keys $L $R/snapshots/2
spit $T/index-t [string map {"\tGolden test kit (app)" "\tGolden test kit (evil)" "\ttest kit" "\tevil kit"} [slurp $R/index]]
file copy -force $R/index.minisig $T/index-t.minisig
refuse "a tampered index is refused" {BAD signature} kitindex check -keys $L $T/index-t
refuse "an index made with a newer key list than this computer's is refused until it updates" {update the key list first} \
    kitindex check -keys $A $R/index
# index key compromise: test-index signs a huge serial; the root revokes it and lists test-index2
::kittrust load -anchor $L
::kittrust::repo::Publish $T/repo-evil "" [records [list $T/kits/app.kit]] -key $F/test-index.key -serial 1000000
cplist $L $T/rec
tool kitkey revoke -reason "test: index key stolen" $T/rec $IDX
tool kitkey add -role index $T/rec $F/test-index2.pub
tool kitkey sign -key $F/test-root.key $T/rec
::kittrust load -anchor $T/rec
::kittrust::repo::Publish $T/repo-rec [::kittrust parseindex [slurp $R/index]] [records [list $T/kits/app.kit]] -key $F/test-index2.key
refuse "the stolen index key's index is refused once revoked" {was revoked} kitindex check -keys $T/rec $T/repo-evil/index
pass "after it, the new index key's serial 3 is accepted despite the stolen key's serial 1000000" \
    kitindex check -keys $T/rec -prev $T/repo-evil/index $T/repo-rec/index

# ---- 9. tampered kits ----------------------------------------------------------------------------
puts "  -- tampered kits"
proc reseal-raw {path stmt sig} {
    set fr [::kitfmt::Frame $path]
    set B [dict get $fr sealSize] ; set body $stmt$sig
    set seal $body[string repeat \x00 [expr {$B - 32 - [string length $body]}]]
    append seal KITSEAL\x1a [binary format IIIIII 1 $B [string length $stmt] [string length $sig] [zlib crc32 $body] 0]
    set f [open $path {RDWR BINARY}] ; seek $f [dict get $fr sealStart] ; puts -nonewline $f $seal ; close $f
}
cpkit $T/kits/app.kit $T/kits/app-t1.kit
set fr [::kitfmt::Frame $T/kits/app-t1.kit]
reseal-raw $T/kits/app-t1.kit [string map {"version 1.2.0" "version 9.2.0"} [dict get $fr statement]] [dict get $fr signature]
refuse "a kit whose statement was changed (CRC fixed) is refused" {BAD signature} kitseal -check -keys $L $T/kits/app-t1.kit
cpkit $T/kits/app.kit $T/kits/app-t2.kit
set sig [split [dict get $fr signature] \n]
set b64 [lindex $sig 1]
lset sig 1 [string range $b64 0 39][expr {[string index $b64 40] eq "A" ? "B" : "A"}][string range $b64 41 end]
reseal-raw $T/kits/app-t2.kit [dict get $fr statement] [join $sig \n]
refuse "a kit whose signature was changed is refused" {BAD signature} kitseal -check -keys $L $T/kits/app-t2.kit
cpkit $T/kits/app.kit $T/kits/app-t3.kit
reseal-raw $T/kits/app-t3.kit [dict get $fr statement] [::kittrust sign [dict get $fr statement] $F/test-other.key "not listed"]
refuse "a kit signed by a key not in the list is refused" {untrusted: signed by key .* not in the trusted key list} kitseal -check -keys $L $T/kits/app-t3.kit
if {$MK ne ""} {
    cpkit $G/bad-chunk.kit $T/kits/bad-chunk.kit
    tool kitseal -key $F/test-app2.key -keys $L $T/kits/bad-chunk.kit
    refuse "a kit with a changed chunk fails even with a good seal (Mk4tcl)" {content: lib/big.txt} \
        kitseal -check -mk4tcl $MK -keys $L $T/kits/bad-chunk.kit
    file mkdir $T/badkits ; file copy $T/kits/bad-chunk.kit $T/badkits/
    refuse "kitindex build refuses to publish it" {failed verification} kitindex build -key $F/test-index.key -keys $L -mk4tcl $MK $T/badkits $T/badrepo
    check "  ... and wrote no index" {![file exists $T/badrepo/index]}
} else {
    puts "  skip changed-chunk checks (no Mk4tcl: set KITFMT_MK4TCL)"
}

file delete -force $T
puts [expr {$fail ? "  FAIL kit signing: some of $count checks failed" : "  ok   kit signing: $count checks"}]
exit $fail
