# plan.tcl -- working out what grab, check and toss would do, before anything is fetched.
#
# A plan is a dict, the same for every front end (CLI, GUI, the automatic updater):
#   rows    what the prompt shows: {name old new action bytes tags kind} per kit, action
#           install | update | remove
#   notes   things to say that need no question ("firefox is up to date", "... stays: ... uses it")
#   A       the active set after the plan (store.tcl)
#   cands   the kit versions to stage: root -> candidate (bundle, origin, ...)
#   fetch   blobs to download first; sizes: blob -> stored bytes
#
# Rules (KIT-CLI.md, "Transactions: what grab may change"): grab never removes or downgrades a kit
# the user installed; shared libraries are replaced only within the ranges every installed kit
# accepts, and several versions live side by side when kits need different ones; a plan with an
# unmet need fails here, before anything is fetched.  The kit being replaced is kept (as "prev")
# until the new version has started once.

namespace eval ::kit::plan {
    variable hints {}   ;# "name version" -> root, from the history (::kit::txn::hints): see Version
}

proc ::kit::plan::new {A} {
    return [dict create rows {} notes {} A $A base $A cands {} fetch {} sizes {} order {} changed 0]
}

# ---- data versions (KIT-FORMAT.md 4.1: the manifest field data N) -----------------------------------
# A version whose data is lower than the installed one's may not open the data the installed one wrote.
# One note for its row; nothing is copied (kit never copies user data).  "" when either side says nothing.
proc ::kit::plan::DataNote {short target tfields installed ifields} {
    if {![dict exists $tfields data] || ![dict exists $ifields data]} { return "" }
    if {[dict get $tfields data] >= [dict get $ifields data]} { return "" }
    return "$short $target may not open data written by $installed"
}
# the manifest fields: of a candidate (its ki) or of an installed version (store::kinfo)
proc ::kit::plan::FieldsOf {c} { return [dict get [expr {[dict exists $c ki] ? [dict get $c ki] : $c}] fields] }

# ---- row names (U03n) -----------------------------------------------------------------------------------
# The name a kit's row shows: the Name= of its launcher entry, from a copy of the kit already in the store
# (any version of it, in the set A), else its short name.  A kit not installed yet has no copy to read, so
# it shows its short name until it is installed; its updates show the launcher's name.  Libraries have no
# launcher and keep their name.  `short` stays in the row for the shell's icon lookup.
proc ::kit::plan::RowName {A name short} {
    foreach l [::kit::store::lines $A $name] {
        set n [::kit::store::launcherName [dict get $l root] $name]
        if {$n ne ""} { return $n }
    }
    return $short
}

# ---- candidates: one kit version that could be installed --------------------------------------
proc ::kit::plan::fromRecord {rec} {
    ::kit::system::refuse [dict get $rec kind] [dict get $rec name]
    set b [::kit::repo::bundle $rec]
    lassign [::kit::repo::bundleCheck $b [dict get $rec root]] st sig
    foreach k {name version kind} {
        if {[dict get $st $k] ne [dict get $rec $k]} { ::kit::fail 4 "[dict get $rec name] [dict get $rec version]: the index and the kit's signed statement disagree about its $k" }
    }
    Trust [dict get $rec name] [dict get $rec version] $sig
    set ki [::kit::store::kitIndex [dict get $b index]]
    return [dict create name [dict get $rec name] version [dict get $rec version] kind [dict get $rec kind] \
        root [dict get $rec root] short [dict get $rec short] origin repo bundle $b st $st ki $ki sig $sig \
        flags [dict get $rec flags] needs [dict get $ki needs] provides [dict get $ki provides] size [dict get $rec size]]
}

proc ::kit::plan::fromFile {path} {
    ::kit::kitfmt
    if {![file isfile $path]} { ::kit::fail 2 "$path: no such file" }
    set h [::kitfmt open $path]
    set rc [catch {
        set inf [::kitfmt info $h]
        set m [::kitfmt manifest $h]
        set f [dict get $m fields]
        ::kit::system::refuse [dict get $f kind] [dict get $f name]
        Trust [dict get $f name] [dict get $f version] [dict get $inf signature]
        set b [::kit::store::bundleOf $h]
        set st [dict get $::kitfmt::H($h,frame) st]
    } err opts]
    ::kitfmt close $h
    if {$rc} { return -options $opts $err }
    return [dict create name [dict get $f name] version [dict get $f version] kind [dict get $f kind] \
        root [dict get $inf root] short [::kit::shortOf [dict get $f name] [expr {[dict exists $f x-short] ? [dict get $f x-short] : ""}]] \
        origin [file normalize $path] bundle $b st $st ki [::kit::store::kitIndex [dict get $b index]] \
        sig [dict get $inf signature] flags {} needs [dict get $m needs] provides [dict get $m provides] \
        bytes [file size $path]]
}

# Unsigned or untrusted kits are refused unless the developer setting allows them (loudly).
proc ::kit::plan::Trust {name version sig} {
    set state [dict get $sig state]
    if {![::kit::sigAcceptable $state]} {
        ::kit::fail 4 "$name $version: its signature is $state ([dict get $sig detail]); refusing to install it"
    }
    if {$state ne "valid"} { ::kit::warn "$name $version is $state, installed only because allow-unsigned = yes" }
}

proc ::kit::plan::isFile {word} {
    return [expr {[string match *.kit $word] || [string first / $word] >= 0}]
}

# ---- choosing versions -----------------------------------------------------------------------------
# What a user of a line needs it to be: the range its lock was made for (its kit's needs).
proc ::kit::plan::rangeFor {A user need} {
    set k [dict get $A kits $user]
    foreach n [dict get [::kit::store::kinfo [dict get $k root]] needs] {
        if {[lindex $n 0] eq $need} { return [lindex $n 1] }
    }
    return ""
}

# Does a kit version (record or candidate) satisfy need {name range}?
proc ::kit::plan::satisfies {kname kversion provides need range} {
    if {$kname eq $need} { return [::kit::inrange $kversion $range] }
    foreach p $provides { if {[lindex $p 0] eq $need && [::kit::inrange [lindex $p 1] $range]} { return 1 } }
    return 0
}

# The newest index version of a line's kit that every user of the line accepts ("" if none newer).
proc ::kit::plan::best {A I line} {
    set key [::kit::store::key $line]
    set ranges {}
    foreach u [dict get $A uses] {
        lassign $u user need lib
        if {$lib eq $key} { lappend ranges $need [rangeFor $A $user $need] }
    }
    set best ""
    foreach r [::kit::repo::records $I [dict get $line name]] {
        if {[dict get $r name] ne [dict get $line name]} continue
        if {[::kit::vcmp [dict get $r version] [dict get $line version]] <= 0} continue
        if {[dict exists [dict get $A kits] "[dict get $r name] [dict get $r version]"]} continue
        set ok 1
        foreach {need range} $ranges {
            if {![satisfies [dict get $r name] [dict get $r version] [dict get $r provides] $need $range]} { set ok 0 ; break }
        }
        if {$ok && ($best eq "" || [::kit::vcmp [dict get $r version] [dict get $best version]] > 0)} { set best $r }
    }
    return $best
}

proc ::kit::plan::newest {recs} {
    set best ""
    foreach r $recs { if {$best eq "" || [::kit::vcmp [dict get $r version] [dict get $best version]] > 0} { set best $r } }
    return $best
}

# Updates waiting, without fetching anything: {line record} per installed line with a newer
# version every one of its users accepts.  names: only these (installed) kits.
proc ::kit::plan::updates {A I {names {}}} {
    set lines {}
    if {[llength $names]} {
        foreach n $names {
            set l [::kit::store::findLive $A $n]
            if {$l eq ""} { ::kit::fail 2 "$n is not installed" }
            lappend lines $l
        }
    } else {
        dict for {key k} [dict get $A kits] { if {[dict get $k reason] ne "prev"} { lappend lines $k } }
    }
    set out {}
    foreach l [lsort -unique $lines] {
        # held at an older version (NAME@VERSION): not offered until grabbed by name again
        if {[dict get $l name] in [dict get $A holds]} continue
        set r [best $A $I $l]
        if {$r eq "" || [::kit::system::waiting $l $r]} continue
        # app kits per user (kit), system kits system-wide (kitd's system scope)
        if {[dict get $r kind] eq [::kit::system::kind]} { lappend out [list $l $r] }
    }
    return $out
}

# ---- building a plan --------------------------------------------------------------------------------
# Add a candidate: install it, or replace the line `old` with it.
proc ::kit::plan::Add {pName c reason old} {
    upvar 1 $pName P
    set A [dict get $P A]
    set A0 $A   ;# the set before this change: the row names come from its copies (RowName)
    set key "[dict get $c name] [dict get $c version]"
    dict set P cands [dict get $c root] $c
    dict lappend P order [dict get $c root]
    set started 0
    if {$old ne ""} {
        set okey [::kit::store::key $old]
        if {[dict get $old reason] eq "user"} { set reason user }
        # users of the old version move to the new one (best/choose made sure they accept it)
        set uses {}
        foreach u [dict get $A uses] {
            lassign $u user need lib
            if {$lib eq $okey && [satisfies [dict get $c name] [dict get $c version] [dict get $c provides] $need [rangeFor $A $user $need]]} {
                set lib $key
            }
            lappend uses [list $user $need $lib]
        }
        dict set A uses $uses
        if {[dict get $old started]} {
            # kept until the new one has started once (a failed first start rolls back to it)
            dict set A kits $okey reason prev
        } elseif {[llength [::kit::store::users $A $okey]]} {
            dict set A kits $okey reason dep
        } else {
            dict unset A kits $okey
            dict set A uses [lmap u [dict get $A uses] { if {[lindex $u 0] eq $okey} continue ; set u }]
        }
        lappend row old [dict get $old version] action update
        set note [DataNote [dict get $c short] [dict get $c version] [FieldsOf $c] [dict get $old version] [FieldsOf [::kit::store::kinfo [dict get $old root]]]]
        if {$note ne ""} { lappend row note $note }
    } else {
        lappend row old "" action install
    }
    dict set A kits $key [dict create name [dict get $c name] version [dict get $c version] root [dict get $c root] reason $reason started $started]
    dict set P A $A
    set tags {}
    if {"security" in [dict get $c flags]} { lappend tags security }
    if {[::kit::system::restart $c]} { lappend tags restart }
    if {[dict get [dict get $c sig] state] ne "valid"} { lappend tags [dict get [dict get $c sig] state] }
    dict lappend P rows [dict create name [RowName $A0 [dict get $c name] [dict get $c short]] short [dict get $c short] {*}$row new [dict get $c version] kind [dict get $c kind] tags $tags root [dict get $c root] fullname [dict get $c name]]
    return $key
}

# Resolve the needs of every candidate added so far (and of what they pull in), locking each need
# to one exact kit version: an installed one if it fits, else the newest in the index that fits.
proc ::kit::plan::Resolve {pName I} {
    upvar 1 $pName P
    set done [dict create]
    while {1} {
        set todo {}
        foreach root [dict get $P order] { if {![dict exists $done $root]} { lappend todo $root } }
        if {![llength $todo]} break
        foreach root $todo {
            dict set done $root 1
            set c [dict get $P cands $root]
            set key "[dict get $c name] [dict get $c version]"
            set A [dict get $P A]
            dict set A uses [lmap u [dict get $A uses] { if {[lindex $u 0] eq $key} continue ; set u }]
            dict set P A $A
            foreach n [dict get $c needs] {
                lassign $n need range
                set lib [Provider P $I $need $range [dict get $c name]]
                set A [dict get $P A]
                dict lappend A uses [list $key $need $lib]
                dict set P A $A
            }
        }
    }
}

proc ::kit::plan::Provider {pName I need range who} {
    upvar 1 $pName P
    set A [dict get $P A]
    # installed (or already planned) versions first: nothing to fetch
    set best ""
    dict for {key k} [dict get $A kits] {
        if {[dict get $k reason] eq "prev"} continue
        set inf [expr {[dict exists $P cands [dict get $k root]] ? [dict get $P cands [dict get $k root]] : [::kit::store::kinfo [dict get $k root]]}]
        if {[satisfies [dict get $k name] [dict get $k version] [dict get $inf provides] $need $range]} {
            if {$best eq "" || [::kit::vcmp [dict get $k version] [dict get $best version]] > 0} { set best $k }
        }
    }
    if {$best ne ""} { return [::kit::store::key $best] }
    if {$I eq ""} { ::kit::fail 3 "$who needs $need [join $range], which is not installed, and there is no index to find it in" }
    set cands {}
    foreach r [dict get $I kits] {
        if {[satisfies [dict get $r name] [dict get $r version] [dict get $r provides] $need $range]} { lappend cands $r }
    }
    set r [newest $cands]
    if {$r eq ""} { ::kit::fail 2 "nothing provides $need [join $range] (needed by $who)" }
    return [Add P [fromRecord $r] dep ""]
}

# grab: install or update each target: an index name, NAME@VERSION (go back to that version and
# hold it there), or a .kit file.  Grabbing a held kit by name takes it forward again.
proc ::kit::plan::grab {A I targets} {
    set P [new $A]
    foreach t $targets {
        set want ""
        if {[isFile $t]} {
            set c [fromFile $t]
        } else {
            if {[regexp {^([^@]+)@(.+)$} $t -> t want]} {}
            set old [::kit::store::findLive [dict get $P A] $t]
            set recs [expr {$I eq "" ? {} : [::kit::repo::records $I $t]}]
            set names [lsort -unique [lmap r $recs { dict get $r name }]]
            if {[llength $names] > 1} { ::kit::fail 2 "$t is ambiguous: [join $names {, }]" }
            if {$old ne ""} { set held [Hold P [dict get $old name] [expr {$want ne ""}]] }
            if {$want ne ""} {
                set c [Version P $I $t $old $recs $want]
                if {$c eq ""} continue
            } else {
                if {$I eq "" && ![llength $recs]} { ::kit::fail 3 "no index to look $t up in" }
                if {![llength $recs]} {
                    if {$old ne ""} { dict lappend P notes "$t is up to date" ; continue }
                    ::kit::fail 2 "there is no kit called $t (kit find $t)"
                }
                set r [expr {$old ne "" && [dict get $old name] eq [lindex $names 0] ? [best [dict get $P A] $I $old] : [newest $recs]}]
                if {$r eq ""} { dict lappend P notes "$t is up to date" ; Promote P $old ; continue }
                set c [fromRecord $r]
            }
        }
        set old [::kit::store::live [dict get $P A] [dict get $c name]]
        if {$old ne ""} {
            set cmp [::kit::vcmp [dict get $c version] [dict get $old version]]
            if {$cmp == 0} { dict lappend P notes "[dict get $c short] is up to date" ; Promote P $old ; continue }
            if {$cmp < 0 && $want eq ""} {
                ::kit::fail 2 "[dict get $c short] [dict get $c version] is older than the installed [dict get $old version]: kit never downgrades a kit you installed (name the version to go back: [dict get $c short]@[dict get $c version])"
            }
            if {[set u [Outside [dict get $P A] $old $c]] ne ""} {
                ::kit::fail 2 "[dict get $c short] [dict get $c version] is outside the range [lindex $u 0] accepts ([join [lindex $u 1]]): [lindex $u 0] is in the way"
            }
        }
        Add P $c user $old
        # NAME@VERSION holds the kit there (Kit-Sheet-4's "held"): its row says so
        if {$want ne ""} { Tag P [dict get $c root] held }
    }
    Resolve P $I
    return [Finish $P]
}

# Add a tag to the row of the kit version ROOT
proc ::kit::plan::Tag {pName root tag} {
    upvar 1 $pName P
    dict set P rows [lmap r [dict get $P rows] {
        if {[dict get $r root] eq $root && $tag ni [dict get $r tags]} { dict lappend r tags $tag }
        set r
    }]
}

# Hold a name (NAME@VERSION) or let it go (a plain grab); says so when that changes anything.
proc ::kit::plan::Hold {pName name on} {
    upvar 1 $pName P
    set A [dict get $P A]
    set hs [dict get $A holds]
    set was [expr {$name in $hs}]
    if {$on && !$was} { dict lappend A holds $name ; dict set P changed 1 }
    if {!$on && $was} {
        dict set A holds [lmap h $hs { if {$h eq $name} continue ; set h }]
        dict set P changed 1
    }
    dict set P A $A
    return $was
}

# NAME@VERSION: that version from the store when it is still there (the kept old version: no
# download, works offline), else from the index.  "" when it is the installed version.
proc ::kit::plan::Version {pName I t old recs want} {
    upvar 1 $pName P
    if {$old ne "" && [::kit::vcmp [dict get $old version] $want] == 0} {
        dict lappend P notes "[dict get [::kit::store::kinfo [dict get $old root]] short] $want is installed, and held there"
        return ""
    }
    if {$old ne ""} {
        foreach l [::kit::store::lines [dict get $P A] [dict get $old name]] {
            if {[dict get $l version] eq $want && [file isfile [::kit::path store [dict get $l root] manifest]]} {
                return [fromStore [dict get $l root]]
            }
        }
    }
    foreach r $recs { if {[dict get $r version] eq $want} { return [fromRecord $r] } }
    # a version the history knows the root of (kit rewind, grab KIT@VERSION): a mirror still has it by root
    variable hints
    if {$old ne "" && [dict exists $hints "[dict get $old name] $want"]} {
        return [fromRoot [dict get $hints "[dict get $old name] $want"]]
    }
    if {$I eq ""} { ::kit::fail 3 "no index to find $t $want in" }
    ::kit::fail 2 "there is no version $want of $t (kit info $t)"
}

# A version by its root alone: from the store, the manifest cache, or a mirror (kits/<root>,
# checked against the root it must have), for kit rewind.
proc ::kit::plan::fromRoot {root} {
    if {[file isfile [::kit::path store $root manifest]] && [file isfile [::kit::path store $root kit]]} { return [fromStore $root] }
    set b ""
    set f [::kit::path cache manifests $root]
    if {[file isfile $f] && ![catch {::kit::repo::bundleParse [::kit::slurp $f]} bb] && ![catch {::kit::repo::bundleCheck $bb $root}]} { set b $bb }
    if {$b eq ""} {
        foreach mirror [::kit::repo::mirrorOrder] {
            if {[catch {::kit::net::get $mirror/kits/$root -max 67108864} r]} continue
            if {[catch {set bb [::kit::repo::bundleParse [dict get $r data]] ; ::kit::repo::bundleCheck $bb $root}]} continue
            set b $bb ; break
        }
    }
    if {$b eq ""} { ::kit::fail 3 "the kit with root [string range $root 0 15]… is not stored here, and no mirror has it" }
    lassign [::kit::repo::bundleCheck $b $root] st sig
    Trust [dict get $st name] [dict get $st version] $sig
    set ki [::kit::store::kitIndex [dict get $b index]]
    set f [dict get $ki fields]
    return [dict create name [dict get $st name] version [dict get $st version] kind [dict get $st kind] \
        root $root short [::kit::shortOf [dict get $st name] [expr {[dict exists $f x-short] ? [dict get $f x-short] : ""}]] \
        origin repo bundle $b st $st ki $ki sig $sig flags {} needs [dict get $ki needs] provides [dict get $ki provides]]
}

# A version already in the store (its signed manifest is kept beside it).
proc ::kit::plan::fromStore {root} {
    set b [::kit::repo::bundleParse [::kit::slurp [::kit::path store $root manifest]]]
    # a version that is installed already (kept as the old one, or brought back by a rewind) is judged in mode installed:
    # revoked keys refuse it, a key that has expired since does not (KIT-TRUST.md section 2)
    ::kit::kitfmt
    set was [dict get [::kittrust configure] -mode]
    ::kittrust configure -mode installed
    set rc [catch {::kit::repo::bundleCheck $b $root} chk opts]
    ::kittrust configure -mode $was
    if {$rc} { return -options $opts $chk }
    lassign $chk st sig
    set inf [::kit::store::kinfo $root]
    Trust [dict get $st name] [dict get $st version] $sig
    set ki [::kit::store::kitIndex [dict get $b index]]
    return [dict create name [dict get $st name] version [dict get $st version] kind [dict get $st kind] \
        root $root short [dict get $inf short] origin repo bundle $b st $st ki $ki sig $sig \
        flags {} needs [dict get $ki needs] provides [dict get $ki provides]]
}

# check's yes: update these {line record} pairs (from updates).
proc ::kit::plan::update {A I pairs} {
    set P [new $A]
    foreach pr $pairs {
        lassign $pr line rec
        set old [dict get [dict get $P A] kits [::kit::store::key $line]]
        Add P [fromRecord $rec] [dict get $line reason] $old
    }
    Resolve P $I
    return [Finish $P]
}

# A user of `old` whose range the candidate is outside of: {user range} or "".
proc ::kit::plan::Outside {A old c} {
    set okey [::kit::store::key $old]
    foreach u [dict get $A uses] {
        lassign $u user need lib
        if {$lib ne $okey} continue
        set range [rangeFor $A $user $need]
        if {![satisfies [dict get $c name] [dict get $c version] [dict get $c provides] $need $range]} {
            return [list [dict get [::kit::store::kinfo [dict get [dict get $A kits $user] root]] short] $range]
        }
    }
    return ""
}

# Asked for by name, so it is the user's now (a library grabbed on purpose stays when its users go).
proc ::kit::plan::Promote {pName line} {
    upvar 1 $pName P
    if {$line eq "" || [dict get $line reason] eq "user"} return
    dict set P A kits [::kit::store::key $line] reason user
}

proc ::kit::plan::Finish {P} {
    set A [::kit::plan::Tidy [dict get $P A]]
    dict set P A $A
    # what to fetch: every blob of every repository candidate that is not stored here
    set fetch {} ; set sizes [dict create]
    set rows {}
    foreach row [dict get $P rows] {
        set c [dict get $P cands [dict get $row root]]
        if {[::kit::system::whole $c]} {
            dict set row bytes [::kit::system::bytes $c]
        } elseif {[dict get $c origin] eq "repo"} {
            set b [dict get $c bundle]
            set miss [::kit::store::missing [::kit::store::blobs [dict get $c ki] [dict get $c st]]]
            set n 0
            foreach h $miss { incr n [dict get $b sizes $h] ; dict set sizes $h [dict get $b sizes $h] }
            lappend fetch {*}$miss
            dict set row bytes $n
        } else {
            dict set row bytes [dict get $c bytes]
        }
        lappend rows $row
    }
    dict set P rows $rows
    dict set P fetch [lsort -unique $fetch]
    dict set P sizes $sizes
    return $P
}

# After any change: dep lines nobody uses go, and prev lines go once what replaced them has
# started (nothing else of their name is waiting for its first start).
proc ::kit::plan::Tidy {A} {
    set A [::kit::store::prune $A]
    dict for {key k} [dict get $A kits] {
        if {[dict get $k reason] ne "prev"} continue
        set waiting 0
        foreach l [::kit::store::lines $A [dict get $k name]] {
            # (newer, or older after NAME@VERSION: whatever replaced it and hasn't started yet)
            if {[dict get $l reason] ne "prev" && ![dict get $l started]} { set waiting 1 }
        }
        if {!$waiting} {
            dict unset A kits $key
            dict set A uses [lmap u [dict get $A uses] { if {[lindex $u 0] eq $key} continue ; set u }]
        }
    }
    return [::kit::store::prune $A]
}

# toss: remove these kits; libraries go with their last user.  Essential kits stop the plan.
proc ::kit::plan::toss {A targets} {
    set A0 $A
    set P [new $A]
    set lines {}
    foreach t $targets {
        set l [::kit::store::findLive $A $t]
        if {$l eq ""} { dict lappend P notes "$t is not installed" ; continue }
        lappend lines $l
    }
    set stop {}
    foreach l $lines {
        if {[::kit::store::essential [::kit::store::kinfo [dict get $l root]]]} { lappend stop [dict get [::kit::store::kinfo [dict get $l root]] short] }
    }
    if {[llength $stop]} {
        ::kit::fail 2 "[join $stop {, }] [expr {[llength $stop] == 1 ? "is" : "are"}] needed for the system to run and can't be tossed"
    }
    set gone [lmap l $lines { ::kit::store::key $l }]
    foreach l $lines {
        set key [::kit::store::key $l]
        set users [lmap u [::kit::store::users $A $key] { if {$u in $gone} continue ; set u }]
        if {[llength $users]} {
            dict set A kits $key reason dep
            dict lappend P notes "[dict get [::kit::store::kinfo [dict get $l root]] short] stays: [join [lmap u $users { dict get [::kit::store::kinfo [dict get [dict get $A kits $u] root]] short }] {, }] [expr {[llength $users] == 1 ? "uses" : "use"}] it"
            continue
        }
        foreach k [::kit::store::lines $A [dict get $l name]] {
            if {[dict get $k reason] eq "prev" || [::kit::store::key $k] eq $key} {
                dict unset A kits [::kit::store::key $k]
                dict set A uses [lmap u [dict get $A uses] { if {[lindex $u 0] eq [::kit::store::key $k]} continue ; set u }]
            }
        }
    }
    set A [Tidy $A]
    # a kit that is gone is held no more
    dict set A holds [lmap h [dict get $A holds] { if {[::kit::store::live $A $h] eq ""} continue ; set h }]
    # every line that went (the kits asked for first, then the libraries that went with them)
    set rows {}
    set order [concat $gone [lsort [dict keys [dict get $P A kits]]]]
    foreach key [lsort -unique $order] {
        if {![dict exists [dict get $P A] kits $key] || [dict exists [dict get $A kits] $key]} continue
        set k [dict get $P A kits $key]
        if {[dict get $k reason] eq "prev"} continue
        set inf [::kit::store::kinfo [dict get $k root]]
        lappend rows [dict create name [RowName $A0 [dict get $k name] [dict get $inf short]] short [dict get $inf short] old [dict get $k version] new removed action remove bytes "" tags {} \
            kind [dict get $inf kind] root [dict get $k root] fullname [dict get $k name]]
    }
    dict set P rows [lsort -command [list ::kit::plan::Order $gone] $rows]
    dict set P A $A
    return $P
}
proc ::kit::plan::Order {gone a b} {
    set ia [lsearch -exact $gone "[dict get $a fullname] [dict get $a old]"]
    set ib [lsearch -exact $gone "[dict get $b fullname] [dict get $b old]"]
    if {$ia < 0} { set ia 1000000 } ; if {$ib < 0} { set ib 1000000 }
    if {$ia != $ib} { return [expr {$ia - $ib}] }
    return [string compare [dict get $a name] [dict get $b name]]
}

# A stored version judged by the key lists as they are now, in mode installed (revocation, not expiry): raises
# exit 4 when its signature no longer holds.
proc ::kit::plan::Rejudge {root} {
    ::kit::kitfmt
    set was [dict get [::kittrust configure] -mode]
    ::kittrust configure -mode installed
    set rc [catch {fromRoot $root} err opts]
    ::kittrust configure -mode $was
    if {$rc} { return -options $opts $err }
}

# kit rewind: the active set T as it was before a history entry's change (UNDOES is that entry's id: the
# rewind is logged as "undoes UNDOES", and the cursor moves to the next change it can take back).  Rows say
# what changes, kit by kit; a kit of T whose version is no longer stored is fetched again by its root
# (fromRoot).  What is running now stays started, so a rewind does not undo a first start.
proc ::kit::plan::restore {A T undoes} {
    dict for {key k} [dict get $T kits] {
        if {[dict exists [dict get $A kits] $key] && [dict get [dict get $A kits] $key started]} { dict set T kits $key started 1 }
    }
    set T [Tidy $T]
    set P [new $A]
    set cands [dict create]
    set live {}
    dict for {key k} [dict get $A kits] { lappend live [dict get $k root] }
    dict for {key k} [dict get $T kits] {
        set root [dict get $k root]
        if {[file isfile [::kit::path store $root info]]} {
            # a version still in the store comes back without being fetched, but not without being judged again: a key
            # revoked since it was installed refuses it (KIT-TRUST.md section 2: "refused for everything, installed kits
            # included"); expiry does not, an installed kit is not judged for that again.  What is live now is not
            # brought back, it stays.
            if {$root ni $live} { Rejudge $root }
            continue
        }
        dict set cands $root [fromRoot $root]
    }
    set names {}
    foreach set [list $A $T] { dict for {key k} [dict get $set kits] { lappend names [dict get $k name] } }
    set rows {}
    foreach n [lsort -unique $names] {
        set cl [::kit::store::live $A $n]
        set tl [::kit::store::live $T $n]
        if {$cl ne "" && $tl ne "" && [dict get $cl root] eq [dict get $tl root]} continue
        if {$tl eq ""} {
            set inf [::kit::store::kinfo [dict get $cl root]]
            lappend rows [dict create name [RowName $A $n [dict get $inf short]] short [dict get $inf short] old [dict get $cl version] new removed action remove \
                bytes "" tags {} kind [dict get $inf kind] root [dict get $cl root] fullname $n]
            continue
        }
        set c [expr {[dict exists $cands [dict get $tl root]] ? [dict get $cands [dict get $tl root]] : [::kit::store::kinfo [dict get $tl root]]}]
        set row [dict create name [RowName $A $n [dict get $c short]] short [dict get $c short] old [expr {$cl eq "" ? "" : [dict get $cl version]}] \
            new [dict get $tl version] action [expr {$cl eq "" ? "install" : "update"}] bytes "" \
            tags [expr {$n in [dict get $T holds] ? "held" : ""}] kind [dict get $c kind] root [dict get $tl root] fullname $n]
        if {$cl ne ""} {
            set note [DataNote [dict get $c short] [dict get $tl version] [FieldsOf $c] [dict get $cl version] [FieldsOf [::kit::store::kinfo [dict get $cl root]]]]
            if {$note ne ""} { dict set row note $note }
        }
        lappend rows $row
    }
    # what to fetch: the blobs of each kit fetched again that the store lacks
    set fetch {} ; set sizes [dict create] ; set bytes [dict create]
    dict for {root c} $cands {
        if {[::kit::system::whole $c]} { dict set bytes $root [::kit::system::bytes $c] ; continue }
        set b [dict get $c bundle]
        set miss [::kit::store::missing [::kit::store::blobs [dict get $c ki] [dict get $c st]]]
        set n 0
        foreach h $miss { incr n [dict get $b sizes $h] ; dict set sizes $h [dict get $b sizes $h] }
        lappend fetch {*}$miss
        dict set bytes $root $n
    }
    set out {}
    foreach r $rows {
        ::kit::system::refuseRewind [dict get $r kind] [dict get $r fullname]
        if {[dict get $r action] ne "remove" && [dict exists $bytes [dict get $r root]]} { dict set r bytes [dict get $bytes [dict get $r root]] }
        lappend out $r
    }
    dict set P rows $out
    dict set P A $T
    dict set P cands $cands
    dict set P fetch [lsort -unique $fetch]
    dict set P sizes $sizes
    dict set P undoes $undoes
    dict set P cursor [::kit::txn::Next $undoes]
    dict set P changed 1
    return $P
}

# ---- carrying a plan out: fetch, verify, stage, switch ------------------------------------------------
proc ::kit::plan::execute {P op} {
    set repo 0
    dict for {root c} [dict get $P cands] { if {[dict get $c origin] eq "repo"} { set repo 1 } }
    if {$repo} { ::kit::repo::needFresh }
    ::kit::repo::fetchChunks [dict get $P fetch] [dict get $P sizes]
    # system scope (kitd): the view agrees with the set before anything changes; system kits are fetched
    # whole, then the snapshot is taken, and the view follows the switch (system.tcl)
    if {[::kit::system::kind] eq "system"} {
        ::kit::system::reconcile
        ::kit::system::fetch [dict get $P cands]
        ::kit::system::snapshot $op [dict get $P rows]
        if {"::kit::system::afterSwitch" ni $::kit::txn::afterSwitch} { lappend ::kit::txn::afterSwitch ::kit::system::afterSwitch }
        if {"::kit::system::beforeSwitch" ni $::kit::txn::beforeSwitch} { lappend ::kit::txn::beforeSwitch ::kit::system::beforeSwitch }
    }
    set stages {}
    dict for {root c} [dict get $P cands] { lappend stages $root [list ::kit::plan::Build $c] }
    set extra [dict create history [::kit::store::text [dict get $P base]]]
    if {[dict exists $P undoes]} { dict set extra undoes [dict get $P undoes] ; dict set extra cursor [dict get $P cursor] }
    ::kit::txn::apply $op [dict get $P A] $stages $extra
}

proc ::kit::plan::Build {c dir} {
    if {[::kit::system::whole $c]} { ::kit::system::build $c $dir ; return }
    if {[dict get $c origin] ne "repo"} {
        file copy [dict get $c origin] $dir/kit
        ::kit::store::stage $dir "" [dict get $c origin]
        return
    }
    ::kit::store::assemble [dict get $c bundle] $dir/kit
    if {[catch {::kit::store::stage $dir [dict get $c bundle] repo} err opts]} {
        # a damaged chunk in the cache: fetch this kit's chunks again, once
        if {[lindex [dict get $opts -errorcode] 1] ne "4"} { return -options $opts $err }
        set hs [::kit::store::blobs [dict get $c ki] [dict get $c st]]
        foreach h $hs { catch {file delete [::kit::repo::chunkPath $h]} }
        set miss [::kit::store::missing $hs]
        ::kit::repo::fetchChunks $miss [dict get $c bundle sizes]
        foreach f [glob -nocomplain -directory $dir *] { file delete -force $f }
        ::kit::store::assemble [dict get $c bundle] $dir/kit
        ::kit::store::stage $dir [dict get $c bundle] repo
    }
}
