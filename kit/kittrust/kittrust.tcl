# kittrust.tcl -- who may sign what: the root-signed key list, its updates, the policy verifier
# kitfmt calls, and the checks on a signed repository index (docs/KIT-TRUST.md).
#
#   package require kittrust          (sources kitfmt; needs the minisign program to verify and sign)
#
#   kittrust configure ?-now secs? ?-mode install|installed? ?-inner cmdprefix?
#   kittrust load ?-anchor FILE? ?-state DIR?     the trusted key list: the anchor, then any newer
#                                                 lists in DIR that chain from it -> summary dict
#   kittrust keys                                 public keys to give `kitfmt configure -keys`
#   kittrust verify stmt sig pubkey               ::kittrust::Verify is the `kitfmt configure -verifier`
#   kittrust check data sig                       -> dict state detail keyid role name comment
#   kittrust update text sig                      accept a newer key list (into the -state DIR)
#   kittrust index text sig ?-prev text? ?-prevsig sig? ?-pinned 0|1?   check a repository index
#   kittrust role data                            which role signs this data: app system index keys ""
#   kittrust parsekeys text | formatkeys dict | parseindex text
#   kittrust sign data seckey comment             a minisign signature (for the tools)
#   kittrust reseal kit seckey                    re-sign a kit's seal in place (statement unchanged)
#
# Errors carry -errorcode {KITTRUST <CODE>}: SYNTAX SIGNATURE THRESHOLD ROLLBACK EXPIRED
# REPOSITORY REPLAY SNAPSHOT KEYS CONFIG IO.
#
# The key list (UTF-8, LF after every line, fields separated by one TAB and escaped like the kit
# index: \\ \t \n \r):
#
#   ribbon-kit-keys 1
#   repository <id>                         the repository these keys are for (reverse-DNS)
#   serial     <n>                          raised by every signed version; never goes back
#   issued     <seconds>                    when the root signed it
#   expires    <seconds>                    after this no key in it is valid for installing
#   threshold  <n>                          how many root keys must sign the next version
#   root       <pubkey> <keyid> <name>      a root key (offline; signs only this list)
#   <pubkey>   <keyid> <roles> <from> <until> <name>     an online key: roles app,system,index
#   revoked    <pubkey> <keyid> <time> <reason>          a key that must never be trusted again
#
# A key line starts with the public key itself, so a reader that takes the first word of every
# line that looks like a minisign key (the kit CLI's trustedKeys) reads exactly the online keys.
# The signature is LIST.minisig: one or more minisign signatures (4 lines each), by root keys.
#
# Tcl 8.5 to 9 compatible, ASCII only.

package require Tcl 8.5-10

namespace eval ::kittrust {
    variable version 1.0.0
    variable dir [file dirname [file normalize [info script]]]
    variable cfg
    array set cfg {-now "" -mode install -inner ::kitfmt::MinisignVerify}
    variable T ""          ;# the trusted key list (dict), set by load
    variable Ttext ""      ;# its text
    variable Tsig ""       ;# its signature
    variable stateDir ""   ;# where accepted updates are kept ("" = none)
    variable extra         ;# keyid -> {time reason}: revocations announced by an accepted index
    array set extra {}
    variable roles {app system index}
}

if {![namespace exists ::kitfmt] || ![info exists ::kitfmt::version]} {
    set ::kittrust::kf [file join $::kittrust::dir .. kitfmt kitfmt.tcl]
    if {[file exists $::kittrust::kf]} { source $::kittrust::kf } else { package require kitfmt }
    unset ::kittrust::kf
}

namespace eval ::kittrust {
    namespace ensemble create -command ::kittrust -map {
        configure ::kittrust::Configure  load ::kittrust::Load  keys ::kittrust::Keys
        verify ::kittrust::Verify  check ::kittrust::Check  update ::kittrust::Update
        index ::kittrust::Index  role ::kittrust::Role  list ::kittrust::Current
        parsekeys ::kittrust::ParseKeys  formatkeys ::kittrust::FormatKeys  parseindex ::kittrust::ParseIndex
        sign ::kittrust::Sign  reseal ::kittrust::Reseal
    }
}

proc ::kittrust::Fail {code msg} { return -code error -errorcode [list KITTRUST $code] $msg }

proc ::kittrust::Configure {args} {
    variable cfg
    if {![llength $args]} { return [array get cfg] }
    if {[llength $args] % 2} { Fail CONFIG "configure takes option value pairs" }
    foreach {k v} $args {
        if {![info exists cfg($k)]} { Fail CONFIG "unknown option $k: [join [lsort [array names cfg]] {, }]" }
        if {$k eq "-mode" && $v ni {install installed}} { Fail CONFIG "-mode is install or installed" }
        if {$k eq "-now" && $v ne "" && ![string is wideinteger -strict $v]} { Fail CONFIG "-now takes seconds since the epoch" }
        set cfg($k) $v
    }
    return ""
}

proc ::kittrust::Now {} {
    variable cfg
    if {$cfg(-now) ne ""} { return $cfg(-now) }
    return [clock seconds]
}

proc ::kittrust::Date {t} { return [clock format $t -format "%Y-%m-%d %H:%M UTC" -gmt 1] }

# "7d", "12h", "2w", "1y", "30m" from base; "YYYY-MM-DD" (UTC midnight); "@seconds".
proc ::kittrust::When {s {base ""}} {
    if {$base eq ""} { set base [Now] }
    if {[regexp {^@(-?[0-9]+)$} $s -> t]} { return $t }
    if {[regexp {^([0-9]{4})-([0-9]{2})-([0-9]{2})$} $s]} {
        if {[catch {clock scan $s -format %Y-%m-%d -gmt 1} t]} { Fail SYNTAX "not a date: $s" }
        return $t
    }
    if {[regexp {^([+-]?)([0-9]+)([mhdwy])$} $s -> sign n u]} {
        set mul [dict get {m 60 h 3600 d 86400 w 604800 y 31536000} $u]
        set d [expr {wide($n) * $mul}]
        return [expr {$sign eq "-" ? $base - $d : $base + $d}]
    }
    Fail SYNTAX "not a time: '$s' (7d, 12h, 2w, 1y, YYYY-MM-DD or @seconds)"
}

# ---- text helpers (the kit index's escapes, KIT-FORMAT.md section 6.2) ---------------------------
proc ::kittrust::Esc {s} { return [string map [list \\ \\\\ \t \\t \n \\n \r \\r] $s] }
proc ::kittrust::Unesc {s} { return [string map [list \\\\ \\ \\t \t \\n \n \\r \r] $s] }
proc ::kittrust::Line {args} { return [join [lmap a $args { Esc $a }] \t] }
proc ::kittrust::Tsplit {line} { return [lmap f [split $line \t] { Unesc $f }] }

proc ::kittrust::IsPub {s} { return [regexp {^[A-Za-z0-9+/]{54}[A-Za-z0-9+/=]{2}$} $s] }
proc ::kittrust::IsNum {s} { return [regexp {^(0|[1-9][0-9]{0,17})$} $s] }
proc ::kittrust::IsRepo {s} { return [regexp {^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$} $s] }

proc ::kittrust::Slurp {path {enc binary}} {
    if {[catch {open $path rb} ch]} { Fail IO "can't read $path: $ch" }
    if {$enc ne "binary"} { fconfigure $ch -encoding $enc }
    set d [read $ch]
    close $ch
    return $d
}

# atomically: a temporary name in the same directory, then rename
proc ::kittrust::Spit {path data {enc binary}} {
    file mkdir [file dirname $path]
    set tmp $path.tmp[pid]
    set ch [open $tmp {WRONLY CREAT TRUNC}]
    fconfigure $ch -translation binary
    if {$enc ne "binary"} { fconfigure $ch -encoding $enc }
    puts -nonewline $ch $data
    close $ch
    file rename -force $tmp $path
}

# ---- minisign signatures --------------------------------------------------------------------------
# A signature file holds one or more minisign signatures, 4 lines each.
proc ::kittrust::SplitSigs {sig} {
    set lines [split [string trimright $sig \n] \n]
    if {![llength $lines] || [llength $lines] % 4} { return -code error "not a minisign signature file" }
    set out {}
    for {set i 0} {$i < [llength $lines]} {incr i 4} { lappend out "[join [lrange $lines $i [expr {$i + 3}]] \n]\n" }
    return $out
}

proc ::kittrust::SigKeyId {sig} {
    if {[catch {::kitfmt::ParseSig $sig} s]} { return "" }
    return [dict get $s keyid]
}

# Which of the keys in pks (keyid -> pubkey) made a valid signature of data in the signature file.
proc ::kittrust::Signers {data sigfile pks} {
    variable cfg
    set out {}
    if {[catch {SplitSigs $sigfile} sigs]} { return {} }
    foreach s $sigs {
        set id [SigKeyId $s]
        if {$id eq "" || ![dict exists $pks $id] || $id in $out} continue
        if {![catch {{*}$cfg(-inner) $data $s [dict get $pks $id]} ok] && $ok} { lappend out $id }
    }
    return $out
}

# Sign data with a minisign secret key; returns the signature text.  An encrypted key asks for its
# password on the terminal (the root ceremony); CI keys are unencrypted (minisign -G -W).
proc ::kittrust::Sign {data seckey comment} {
    if {[auto_execok minisign] eq ""} { Fail CONFIG "signing needs minisign" }
    if {![file isfile $seckey]} { Fail IO "no secret key $seckey" }
    if {[regexp {[\n\r]} $comment]} { Fail SYNTAX "a trusted comment is one line" }
    set tmp [::kitfmt::TempDir]
    set rc [catch {
        set ch [open $tmp/m {WRONLY CREAT EXCL}] ; fconfigure $ch -translation binary ; puts -nonewline $ch $data ; close $ch
        exec minisign -S -s $seckey -m $tmp/m -x $tmp/m.minisig -c "ribbon kit signature" -t $comment <@stdin >@stderr 2>@stderr
        Slurp $tmp/m.minisig
    } res opts]
    file delete -force $tmp
    if {$rc} { Fail SIGNATURE "minisign could not sign with $seckey: $res" }
    return $res
}

# ---- the key list ---------------------------------------------------------------------------------
proc ::kittrust::ParseKeys {text} {
    variable roles
    set text [encoding convertfrom utf-8 $text]
    if {[string index $text end] ne "\n"} { Fail SYNTAX "the key list does not end with a newline" }
    set lines [split [string range $text 0 end-1] \n]
    if {[lindex $lines 0] ne "ribbon-kit-keys 1"} { Fail SYNTAX "not a kit key list (or a version this reader doesn't know)" }
    set d [dict create repository "" serial "" issued "" expires "" threshold "" roots {} keys {} revoked {}]
    set ids {}
    set n 1
    foreach line [lrange $lines 1 end] {
        incr n
        if {$line eq "" || [string index $line 0] eq "#"} continue
        set f [Tsplit $line]
        set tag [lindex $f 0]
        set where "key list line $n"
        switch -- $tag {
            repository - serial - issued - expires - threshold {
                if {[llength $f] != 2} { Fail SYNTAX "$where: '$tag' takes one value" }
                if {[dict get $d $tag] ne ""} { Fail SYNTAX "$where: '$tag' given twice" }
                set v [lindex $f 1]
                if {$tag eq "repository" ? ![IsRepo $v] : ![IsNum $v]} { Fail SYNTAX "$where: bad $tag '$v'" }
                dict set d $tag $v
            }
            root {
                if {[llength $f] != 4} { Fail SYNTAX "$where: root <pubkey> <keyid> <name>" }
                lassign $f - pk id name
                CheckPub $pk $id $where
                if {$id in $ids} { Fail SYNTAX "$where: key $id is listed twice" }
                lappend ids $id
                dict set d roots $id [dict create pk $pk name $name]
            }
            revoked {
                if {[llength $f] != 5} { Fail SYNTAX "$where: revoked <pubkey> <keyid> <time> <reason>" }
                lassign $f - pk id t why
                CheckPub $pk $id $where
                if {![IsNum $t]} { Fail SYNTAX "$where: bad time '$t'" }
                if {$id in $ids} { Fail SYNTAX "$where: key $id is listed twice" }
                lappend ids $id
                dict set d revoked $id [dict create pk $pk time $t reason $why]
            }
            default {
                if {![IsPub $tag]} { Fail SYNTAX "$where: unknown line '$tag'" }
                if {[llength $f] != 6} { Fail SYNTAX "$where: <pubkey> <keyid> <roles> <from> <until> <name>" }
                lassign $f pk id rl from until name
                CheckPub $pk $id $where
                if {$id in $ids} { Fail SYNTAX "$where: key $id is listed twice" }
                lappend ids $id
                set rs [split $rl ,]
                if {![llength $rs]} { Fail SYNTAX "$where: key $id has no role" }
                foreach r $rs { if {$r ni $roles} { Fail SYNTAX "$where: unknown role '$r' (roles: [join $roles {, }])" } }
                if {![IsNum $from] || ![IsNum $until] || $until <= $from} { Fail SYNTAX "$where: key $id needs from < until" }
                dict set d keys $id [dict create pk $pk roles [lsort -unique $rs] from $from until $until name $name]
            }
        }
    }
    foreach k {repository serial issued expires threshold} {
        if {[dict get $d $k] eq ""} { Fail SYNTAX "the key list has no '$k' line" }
    }
    set nr [dict size [dict get $d roots]]
    if {$nr == 0} { Fail SYNTAX "the key list names no root key" }
    if {[dict get $d threshold] < 1 || [dict get $d threshold] > $nr} { Fail SYNTAX "threshold [dict get $d threshold] with $nr root keys" }
    if {[dict get $d issued] > 0 && [dict get $d expires] <= [dict get $d issued]} { Fail SYNTAX "the key list expires before it was issued" }
    return $d
}

proc ::kittrust::CheckPub {pk id where} {
    if {![IsPub $pk]} { Fail SYNTAX "$where: not a minisign public key" }
    set real [::kitfmt::PubKeyId $pk]
    if {$real eq ""} { Fail SYNTAX "$where: not an Ed25519 minisign public key" }
    if {$real ne $id} { Fail SYNTAX "$where: key id $id does not match the key (its id is $real)" }
}

proc ::kittrust::FormatKeys {d} {
    set out [list "ribbon-kit-keys 1" "# Ribbon kit trusted keys, signed by the root keys below (docs/KIT-TRUST.md)"]
    foreach k {repository serial issued expires threshold} { lappend out [Line $k [dict get $d $k]] }
    set g {}
    dict for {id r} [dict get $d roots] { lappend g [Line root [dict get $r pk] $id [dict get $r name]] }
    lappend out {*}[lsort $g]
    set g {}
    dict for {id k} [dict get $d keys] {
        lappend g [Line [dict get $k pk] $id [join [dict get $k roles] ,] [dict get $k from] [dict get $k until] [dict get $k name]]
    }
    lappend out {*}[lsort $g]
    set g {}
    dict for {id r} [dict get $d revoked] { lappend g [Line revoked [dict get $r pk] $id [dict get $r time] [dict get $r reason]] }
    lappend out {*}[lsort $g]
    return [encoding convertto utf-8 "[join $out \n]\n"]
}

proc ::kittrust::RootPks {d} {
    set out [dict create]
    dict for {id r} [dict get $d roots] { dict set out $id [dict get $r pk] }
    return $out
}

# Is the list signed by at least its own threshold of its own roots?  -> the signer key ids
proc ::kittrust::SelfSigned {d text sig} {
    set who [Signers $text $sig [RootPks $d]]
    if {[llength $who] < [dict get $d threshold]} {
        Fail THRESHOLD "the key list (serial [dict get $d serial]) is signed by [llength $who] of its root keys; it needs [dict get $d threshold]"
    }
    return $who
}

# May list N (text, sig) follow list C?  The rules of docs/KIT-TRUST.md section 3:
# the same repository, a higher serial, signed by C's threshold of C's roots and by N's threshold of
# N's roots, and (when checkExpiry) not expired.
proc ::kittrust::Step {C N text sig checkExpiry} {
    if {[dict get $N repository] ne [dict get $C repository]} {
        Fail REPOSITORY "the new key list is for repository [dict get $N repository], not [dict get $C repository]"
    }
    if {[dict get $N serial] <= [dict get $C serial]} {
        Fail ROLLBACK "the new key list has serial [dict get $N serial]; this computer already has serial [dict get $C serial] (an old list is never taken back)"
    }
    set all [dict merge [RootPks $C] [RootPks $N]]
    set who [Signers $text $sig $all]
    set byOld [llength [lmap id $who { if {![dict exists $C roots $id]} continue ; set id }]]
    set byNew [llength [lmap id $who { if {![dict exists $N roots $id]} continue ; set id }]]
    if {$byOld < [dict get $C threshold]} {
        Fail THRESHOLD "the new key list is signed by $byOld of the current root keys; [dict get $C threshold] needed"
    }
    if {$byNew < [dict get $N threshold]} {
        Fail THRESHOLD "the new key list is signed by $byNew of its own root keys; [dict get $N threshold] needed"
    }
    if {$checkExpiry && [Now] >= [dict get $N expires]} {
        Fail EXPIRED "the new key list expired on [Date [dict get $N expires]]: a frozen or stale copy is never accepted"
    }
    return $who
}

# The trusted list.  Without -state: the anchor itself.  With -state DIR (where a client keeps
# what it has accepted): the anchor seen first is recorded there (DIR/anchor, at install), then
# the newer lists in DIR, each only if it chains from the one before (section 3 of KIT-TRUST.md).
# A different anchor later (a base-system update or rollback) is only another candidate: taken if
# it is newer and chains, ignored otherwise, so replacing the file can't replace the roots.
# Re-anchoring is deliberate: remove DIR.
proc ::kittrust::Load {args} {
    variable T ; variable Ttext ; variable Tsig ; variable stateDir ; variable extra
    array set o {-anchor /etc/kit/trusted-keys -state ""}
    if {[llength $args] % 2} { Fail CONFIG "load: options come in pairs" }
    foreach {k v} $args { if {![info exists o($k)]} { Fail CONFIG "load: unknown option $k (-anchor, -state)" } ; set o($k) $v }
    set atext [Slurp $o(-anchor)]
    set asig "" ; catch {set asig [Slurp $o(-anchor).minisig]}
    set A [ParseKeys $atext]
    SelfSigned $A $atext $asig
    set skipped {}
    if {$o(-state) eq ""} {
        set C $A ; set text $atext ; set sig $asig ; set src $o(-anchor)
    } else {
        set pin [file join $o(-state) anchor]
        if {![file isfile $pin]} {
            Spit $pin.minisig $asig
            Spit $pin $atext
        }
        set text [Slurp $pin]
        set sig "" ; catch {set sig [Slurp $pin.minisig]}
        if {[catch {set C [ParseKeys $text] ; SelfSigned $C $text $sig} err]} {
            Fail SIGNATURE "the recorded anchor $pin is damaged ($err); remove $o(-state) to re-anchor"
        }
        set src $pin
        set texts [list $text]
        set serials {}
        foreach f [glob -nocomplain -directory $o(-state) -tails *.keys] {
            if {[regexp {^([0-9]+)\.keys$} $f -> s]} { lappend serials $s }
        }
        foreach s [lsort -integer $serials] {
            if {$s <= [dict get $C serial]} continue
            set f [file join $o(-state) $s.keys]
            if {[catch {
                set nt [Slurp $f] ; set ns [Slurp $f.minisig]
                set N [ParseKeys $nt]
                if {[dict get $N serial] != $s} { Fail SYNTAX "$f holds serial [dict get $N serial]" }
                Step $C $N $nt $ns 0
            } err]} { lappend skipped "$f: $err" ; continue }
            set C $N ; set text $nt ; set sig $ns ; set src $f
            lappend texts $nt
        }
        if {$atext ni $texts && [dict get $A serial] > [dict get $C serial]} {
            if {[catch {Step $C $A $atext $asig 0} err]} {
                lappend skipped "$o(-anchor): ignored, it does not follow the trusted key list: $err"
            } else {
                set f [file join $o(-state) [dict get $A serial].keys]
                Spit $f.minisig $asig
                Spit $f $atext
                set C $A ; set text $atext ; set sig $asig ; set src $o(-anchor)
            }
        }
    }
    set T $C ; set Ttext $text ; set Tsig $sig ; set stateDir $o(-state)
    array unset extra ; array set extra {}
    return [Summary $src $skipped]
}

proc ::kittrust::Summary {{src ""} {skipped {}}} {
    variable T
    return [dict create repository [dict get $T repository] serial [dict get $T serial] \
        issued [dict get $T issued] expires [dict get $T expires] expired [expr {[Now] >= [dict get $T expires]}] \
        keys [dict size [dict get $T keys]] revoked [dict size [dict get $T revoked]] roots [dict size [dict get $T roots]] \
        source $src skipped $skipped]
}

proc ::kittrust::Current {} { variable T ; variable Ttext ; variable Tsig ; return [dict create list $T text $Ttext sig $Tsig] }

proc ::kittrust::Need {} {
    variable T
    if {$T eq ""} { Fail CONFIG "no trusted key list is loaded (kittrust load)" }
}

# Accept a newer key list (fetched from a mirror, or shipped by a base-system update).
# -> "current" (we have exactly this one) or "updated" (kept in the state directory).
proc ::kittrust::Update {text sig} {
    variable T ; variable Ttext ; variable Tsig ; variable stateDir
    Need
    if {$stateDir eq ""} { Fail CONFIG "kittrust load was given no -state directory to keep updates in" }
    set N [ParseKeys $text]
    if {[dict get $N serial] == [dict get $T serial]} {
        if {$text eq $Ttext} { return current }
        Fail ROLLBACK "a different key list with the same serial [dict get $N serial]: refused (only one list may have each serial)"
    }
    Step $T $N $text $sig 1
    set f [file join $stateDir [dict get $N serial].keys]
    Spit $f.minisig $sig
    Spit $f $text
    set T $N ; set Ttext $text ; set Tsig $sig
    return updated
}

# Public keys for `kitfmt configure -keys`: every online key, revoked ones included, so that a
# signature by a revoked key reaches the verifier (and is refused as invalid, never "untrusted").
proc ::kittrust::Keys {} {
    variable T
    Need
    set out {}
    dict for {id k} [dict get $T keys] { lappend out [dict get $k pk] }
    dict for {id k} [dict get $T revoked] { lappend out [dict get $k pk] }
    return $out
}

# ---- the policy --------------------------------------------------------------------------------
# Which role must have signed this data: a kit's seal statement names its kind (app or system,
# D42), a repository index is signed by an index key, a key list by the root only.
proc ::kittrust::Role {data} {
    set nl [string first \n $data]
    set first [string range $data 0 [expr {$nl - 1}]]
    switch -- $first {
        "ribbon-kit-seal 1" {
            if {[regexp {\nkind (app|system)\n} $data -> k]} { return $k }
            return ""
        }
        "ribbon-kit-repo 1" { return index }
        "ribbon-kit-keys 1" { return keys }
    }
    return ""
}

# Why a key may not sign data of this role now ("" = it may).
proc ::kittrust::Refusal {id role} {
    variable T ; variable extra ; variable cfg
    if {$role eq ""} { return "kit keys sign kit seals and repository indexes only" }
    if {$role eq "keys"} { return "key lists are signed by the root keys only" }
    if {[dict exists $T revoked $id]} {
        set r [dict get $T revoked $id]
        return "key $id was revoked on [Date [dict get $r time]]: [dict get $r reason]"
    }
    if {[info exists extra($id)]} {
        lassign $extra($id) t why
        return "key $id was revoked on [Date $t] (announced by the repository index): $why"
    }
    if {![dict exists $T keys $id]} { return "key $id is not in the trusted key list" }
    set k [dict get $T keys $id]
    if {$role ni [dict get $k roles]} {
        return "key $id ([dict get $k name]) signs [join [dict get $k roles] {, }], not $role[expr {$role in {app system} ? " kits" : "es"}]"
    }
    if {$cfg(-mode) eq "install"} {
        set now [Now]
        if {$now >= [dict get $T expires]} { return "the trusted key list expired on [Date [dict get $T expires]]; it must be updated first" }
        if {$now < [dict get $k from]} { return "key $id ([dict get $k name]) is not valid before [Date [dict get $k from]]" }
        if {$now >= [dict get $k until]} { return "key $id ([dict get $k name]) expired on [Date [dict get $k until]]" }
    }
    return ""
}

# The verifier kitfmt calls (kitfmt configure -verifier ::kittrust::Verify) for a signature by
# a key in -keys: the signature first (a bad one says so), then the policy.
proc ::kittrust::Verify {stmt sig pk} {
    variable cfg
    Need
    set id [::kitfmt::PubKeyId $pk]
    if {![{*}$cfg(-inner) $stmt $sig $pk]} { return [list 0 "BAD signature (key $id)"] }
    set why [Refusal $id [Role $stmt]]
    if {$why ne ""} { return [list 0 $why] }
    return 1
}

proc ::kittrust::KeyName {id} {
    variable T
    foreach part {keys revoked roots} {
        if {[dict exists $T $part $id name]} { return [dict get $T $part $id name] }
    }
    return ""
}

# The signature state of data, as kitfmt's (unsigned untrusted invalid valid), with the policy.
proc ::kittrust::Check {data sig} {
    variable T
    Need
    set role [Role $data]
    set out [dict create state "" detail "" keyid "" role $role name "" comment ""]
    if {$sig eq ""} { return [dict replace $out state unsigned detail "not signed"] }
    if {[catch {::kitfmt::ParseSig $sig} s]} { return [dict replace $out state invalid detail "malformed signature: $s"] }
    set id [dict get $s keyid]
    dict set out keyid $id ; dict set out comment [dict get $s comment] ; dict set out name [KeyName $id]
    if {[dict exists $T keys $id]} {
        set pk [dict get $T keys $id pk]
    } elseif {[dict exists $T revoked $id]} {
        set pk [dict get $T revoked $id pk]
    } else {
        return [dict replace $out state untrusted detail "signed by key $id, which is not in the trusted key list"]
    }
    if {[catch {Verify $data $sig $pk} r]} { return [dict replace $out state unchecked detail "the signature could not be checked: $r"] }
    if {[lindex $r 0] ne "1"} { return [dict replace $out state invalid detail [lindex $r 1]] }
    return [dict replace $out state valid detail "good signature by $id ([KeyName $id]), a trusted $role key"]
}

# ---- the repository index ------------------------------------------------------------------------
# The kit CLI's index (srcpkgs/ribbon-kit lib/repo.tcl) with the lines of docs/KIT-TRUST.md section 4:
#   ribbon-kit-repo 1
#   generated <seconds>        expires <seconds>       serial <n>
#   repository <id>            keys <serial> <sha256>  snapshot <serial>  (snapshots only)
#   mirror <url> ...           revoked <keyid> <time> <reason> ...
#   kit <name> <version> <kind> <root> <manifest sha256> <size> <download> <short> <flags> <provides> <summary> <tags>
# Lines this reader doesn't know are ignored (as the CLI does).  Every text this package takes or
# returns (key lists, indexes) is the file's bytes, UTF-8 encoded, exactly as signed.
proc ::kittrust::ParseIndex {text} {
    set text [encoding convertfrom utf-8 $text]
    if {[string index $text end] ne "\n"} { Fail SYNTAX "the index does not end with a newline" }
    set lines [split [string range $text 0 end-1] \n]
    if {[lindex $lines 0] ne "ribbon-kit-repo 1"} { Fail SYNTAX "not a kit repository index (ribbon-kit-repo 1)" }
    set d [dict create generated "" expires "" serial "" repository "" keys "" keysHash "" snapshot "" mirrors {} revoked {} kits {}]
    set n 1
    foreach line [lrange $lines 1 end] {
        incr n
        if {$line eq ""} continue
        set f [Tsplit $line]
        set tag [lindex $f 0]
        switch -- $tag {
            generated - expires - serial - snapshot {
                if {[llength $f] != 2 || ![IsNum [lindex $f 1]]} { Fail SYNTAX "index line $n: bad $tag line" }
                if {[dict get $d $tag] ne ""} { Fail SYNTAX "index line $n: '$tag' given twice" }
                dict set d $tag [lindex $f 1]
            }
            repository {
                if {[llength $f] != 2 || ![IsRepo [lindex $f 1]] || [dict get $d repository] ne ""} { Fail SYNTAX "index line $n: bad repository line" }
                dict set d repository [lindex $f 1]
            }
            keys {
                if {[llength $f] != 3 || ![IsNum [lindex $f 1]] || ![regexp {^[0-9a-f]{64}$} [lindex $f 2]] || [dict get $d keys] ne ""} {
                    Fail SYNTAX "index line $n: keys <serial> <sha256>"
                }
                dict set d keys [lindex $f 1] ; dict set d keysHash [lindex $f 2]
            }
            mirror { dict lappend d mirrors [lindex $f 1] }
            revoked {
                if {[llength $f] != 4 || ![regexp {^[0-9A-F]{16}$} [lindex $f 1]] || ![IsNum [lindex $f 2]]} { Fail SYNTAX "index line $n: revoked <keyid> <time> <reason>" }
                dict set d revoked [lindex $f 1] [lrange $f 2 3]
            }
            kit {
                if {[llength $f] != 13} { Fail SYNTAX "index line $n: a kit line has 13 fields, not [llength $f]" }
                dict lappend d kits [lrange $f 1 end]
            }
        }
    }
    foreach k {generated expires serial repository keys} {
        if {[dict get $d $k] eq ""} { Fail SYNTAX "the index has no '$k' line" }
    }
    return $d
}

# Check an index and its signature against the trusted keys; with -prev (the index this computer
# used last, and -prevsig its signature) refuse a replay.  -pinned 1: the user pinned this file
# (KIT_INDEX), so a snapshot is allowed.  Revocations it announces are applied from then on.
# -> dict serial generated expires expired snapshot repository keys mirrors revoked kits signer
proc ::kittrust::Index {text sig args} {
    variable T ; variable Ttext ; variable extra
    Need
    array set o {-prev "" -prevsig "" -pinned 0}
    if {[llength $args] % 2} { Fail CONFIG "index: options come in pairs" }
    foreach {k v} $args { if {![info exists o($k)]} { Fail CONFIG "index: unknown option $k (-prev, -prevsig, -pinned)" } ; set o($k) $v }
    set I [ParseIndex $text]
    set c [Check $text $sig]
    if {[dict get $c state] ne "valid"} { Fail SIGNATURE "the index signature is [dict get $c state]: [dict get $c detail]" }
    if {[dict get $I repository] ne [dict get $T repository]} {
        Fail REPOSITORY "the index is for repository [dict get $I repository], not [dict get $T repository]"
    }
    # revocations are genuine once the signature is: apply them even if a later check fails. T3 A: an
    # index revokes app and system keys of the list only; an index key or an id the list does not hold
    # is left alone (only the root revokes an index key)
    dict for {id r} [dict get $I revoked] {
        if {[dict exists $T revoked $id] || ![dict exists $T keys $id]} continue
        if {"index" in [dict get $T keys $id roles]} continue
        set extra($id) $r
    }
    if {[dict get $I snapshot] ne "" && !$o(-pinned)} {
        Fail SNAPSHOT "a pinned snapshot (of index [dict get $I snapshot]) was served as the live index: refused"
    }
    set ks [dict get $I keys]
    if {$ks > [dict get $T serial]} {
        Fail KEYS "the index was made with key list $ks; this computer has key list [dict get $T serial]: update the key list first"
    }
    if {$ks == [dict get $T serial] && [::kitfmt::Hash $Ttext] ne [dict get $I keysHash]} {
        Fail KEYS "the index names a different key list with the same serial $ks"
    }
    if {$o(-prev) ne ""} {
        set P "" ; catch {set P [ParseIndex $o(-prev)]}
        set pid [SigKeyId $o(-prevsig)]
        set void [expr {$pid ne "" && ([dict exists $T revoked $pid] || [info exists extra($pid)])}]
        if {$P ne "" && !$void && [dict get $P repository] eq [dict get $I repository]} {
            if {[dict get $I serial] < [dict get $P serial]} {
                Fail REPLAY "the index has serial [dict get $I serial]; this computer already used serial [dict get $P serial] (an old index replayed?)"
            }
            if {[dict get $I serial] == [dict get $P serial] && $text ne $o(-prev)} {
                Fail REPLAY "a different index with the same serial [dict get $I serial]: refused"
            }
        }
    }
    return [dict create serial [dict get $I serial] generated [dict get $I generated] expires [dict get $I expires] \
        expired [expr {[Now] >= [dict get $I expires]}] snapshot [dict get $I snapshot] repository [dict get $I repository] \
        keys $ks mirrors [dict get $I mirrors] revoked [dict get $I revoked] kits [llength [dict get $I kits]] \
        signer [dict get $c keyid] name [dict get $c name]]
}

# ---- kits: re-signing the seal in place (KIT-FORMAT.md section 7.1) -----------------------------
# The statement stays as it is; only the signature changes, inside the same block, so the store
# never moves.  Returns the new signature.
# accept: an optional command prefix called with the statement and the new signature before
# anything is written; it returns "" to go on, or the reason to refuse.
proc ::kittrust::Reseal {path seckey {comment ""} {accept ""}} {
    set fr [::kitfmt::Frame $path]
    set stmt [dict get $fr statement]
    set st [dict get $fr st]
    if {$comment eq ""} { set comment "[dict get $st name] [dict get $st version]" }
    set sig [Sign $stmt $seckey $comment]
    if {$accept ne ""} {
        set why [{*}$accept $stmt $sig]
        if {$why ne ""} { Fail SIGNATURE "$path: not re-signed: $why" }
    }
    set B [dict get $fr sealSize]
    set body $stmt$sig
    if {[string length $body] + 32 > $B} { Fail SYNTAX "$path: the statement and signature do not fit its $B-byte seal" }
    set seal $body[string repeat \x00 [expr {$B - 32 - [string length $body]}]]
    append seal KITSEAL\x1a [binary format IIIIII 1 $B [string length $stmt] [string length $sig] [zlib crc32 $body] 0]
    set ch [open $path {RDWR BINARY}]
    fconfigure $ch -translation binary
    seek $ch [dict get $fr sealStart]
    puts -nonewline $ch $seal
    close $ch
    set again [::kitfmt::Frame $path]
    if {[dict get $again signature] ne $sig} { Fail IO "$path: the new seal did not read back" }
    return $sig
}

package provide kittrust $::kittrust::version
