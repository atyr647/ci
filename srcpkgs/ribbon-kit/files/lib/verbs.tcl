# verbs.tcl -- the ten verbs of docs/KIT-CLI.md: find grab check toss rewind list info mend pack run.

namespace eval ::kit::verbs {
    variable table {
        {find WORDS}     {Search the index by name, summary and tags. Installed kits are marked.}
        {grab KIT…}      {Install a kit, or update it if it is already installed. Also takes a .kit file, and KIT@VERSION to go back to an older version.}
        {check [KIT…]}   {Look for updates: all installed kits, or just the ones named. Offers to grab what it finds.}
        {toss KIT…}      {Uninstall safely.}
        {rewind [KIT]}   {Take back the last change (grab, toss or rewind). With KIT, take that kit back to its previous version and hold it there.}
        {list}           {Installed kits, with version, size and a mark on those with an update waiting or held at an older version.}
        {info KIT}       {One kit in detail: version, size, permissions, what it uses, signer, installed or not.}
        {mend [KIT…]}    {Verify installed kits against their signed manifests and repair what is broken.}
        {pack DIR}       {Build a .kit from a directory and its manifest (for packagers).}
        {run KIT}        {Start a kit, installed or a .kit file (also what double-click does).}
    }
    variable pages
    array set pages {
find {kit find WORDS

Search the index by name, summary and tags; every word must match. Installed
kits are marked. The index is refreshed first when it is older than an hour.}
grab {kit grab KIT…

Install a kit, or update it if it is already installed. KIT is a name from the
index (kit find) or a .kit file. Every install and update goes through grab:

  1. the signed index is refreshed if it is older than an hour;
  2. the plan: versions and shared libraries, and what to fetch (only chunks
     that are not stored here);
  3. the plan is shown and you are asked, always;
  4. every chunk is fetched and checked against the signed manifest before it
     is used (a bad chunk is fetched again from another mirror);
  5. the new version is staged beside the old one and switched to in one
     atomic step. The old version is kept until the new one has started once.

A running app keeps its current version; the new one is used from its next
start. Afterwards grab says what was switched, and which running programs
still use old versions.

kit grab KIT@VERSION goes back to an older version (from the store when the
old version is still kept, else from a mirror) and holds it there: kit check
doesn't offer it and kit list marks it held, until kit grab KIT takes it
forward again. Otherwise grab never removes or downgrades a kit you installed.}
check {kit check [KIT…]

Refresh the index and look for updates: to every installed kit, or to the ones
named. Shows them with the same prompt as grab; yes hands them to grab, which
does not ask again. Kits held at an older version are not offered. With
nothing to update it prints "Up to date".}
toss {kit toss KIT…

Uninstall, as one transaction (the same staging and switch as grab). Shared
libraries stay while another kit uses them and go with their last user. Kits
the system needs to run can't be tossed. Then it asks, each time, whether to
remove the kit's data too, and says where it is. The answer is no unless you
type yes: --yes keeps the data.}
rewind {kit rewind [KIT]

Take back the last change: the newest grab, toss or kit rewind that no rewind
has taken back yet, as one transaction (the same staging and switch as grab).
It asks Rewind? with the plan, and each kit goes back to how it was before that
change. Rewinding a toss installs the kit again; its data is still there unless
you removed it. Running kit rewind again takes back the change before that one,
and so on. Nothing is redone: a rewind is added to the history, and the next
grab, toss or kit rewind KIT starts again from its own change. The history
keeps the last 200 entries.

kit rewind KIT takes one kit back to the version it had before its newest
change, and holds it there (the same as kit grab KIT@VERSION): kit check doesn't
offer it and kit list marks it held, until kit grab KIT takes it forward again.
A kit that its newest change installed has no earlier version to go back to. A
system kit is rewound for the whole system by kitd (org.ribbon.Kit1), not by kit.

Exit codes: 0 done, or nothing to rewind; 1 you said no; 2 bad usage.}
list {kit list

Installed kits, with version, size and a mark on those with an update waiting
(from the last check; the network is not touched) or held at an older version
(kit grab KIT@VERSION).}
info {kit info KIT

One kit in detail: version, size, permissions, what it uses, signer, and
whether it is installed. KIT is a name or a .kit file.}
mend {kit mend [KIT…]

Re-check every chunk of the named kits (all of them with no name) against the
signed manifest, fetch again whatever is missing or damaged, and repair the
launcher entries and the local database. Works offline for chunks still stored
here.}
pack {kit pack [KITPACK-OPTIONS] DIR [OUT.kit]

Build a .kit from DIR and its manifest, DIR.manifest (see kitpack for the
manifest's keys and the options, such as -sign KEY). Writes NAME-VERSION.kit
here unless OUT.kit is given.}
run {kit run KIT [ARGS…]

Start a kit: an installed one by name, or a .kit file (also what double-click
on a .kit does; no executable bit needed). ARGS go to the kit, and kit run
exits with the kit's own exit status. The first start of a new version that
fails goes back to the version before it.

A kit always and only runs straight from its file: mkkitfs (the session's FUSE
server) serves it, and nothing is extracted. When mkkitfs can't serve it, kit
run says so in one line and exits 5 (4 when the kit file itself is refused).}
    }
}

proc ::kit::verbs::usage {} {
    variable table
    set out {}
    foreach {cmd what} $table { lappend out [format "  kit %-14s %s" $cmd $what] }
    lappend out "" "kit help VERB prints one verb's page. --yes answers the prompt for scripts (and keeps data: toss removes it only on a typed yes)."
    return [join $out \n]
}

proc ::kit::verbs::Help {args} {
    variable pages
    if {![llength $args]} { puts [usage] ; return 0 }
    set v [lindex $args 0]
    if {![info exists pages($v)]} { ::kit::fail 2 "there is no verb '$v'\n[usage]" }
    puts $pages($v)
    return 0
}

proc ::kit::verbs::need {args n what} {
    if {[llength $args] < $n} { ::kit::fail 2 "usage: kit $what" }
}

# ---- the last check: what kit list and the bar show (cache/updates) ------------------------------
proc ::kit::verbs::saveUpdates {A {I ""}} {
    ::kit::need repo net plan system
    if {$I eq ""} { set I $::kit::repo::I }
    if {$I eq ""} {
        if {[::kit::pinned] ne ""} {
            if {[catch {::kit::repo::loadPinned [::kit::pinned]} I]} return
        } else { set I [::kit::repo::loadCache] }
    }
    if {$I eq ""} return
    set old [loadUpdates]
    set ups {}
    foreach pr [::kit::plan::updates $A $I] {
        lassign $pr l r
        lappend ups [dict create name [dict get $l name] short [dict get $r short] version [dict get $l version] \
            new [dict get $r version] flags [dict get $r flags] download [dict get $r download]]
    }
    ::kit::spit [::kit::path cache updates] [dict create checked [dict get $I checked] \
        notify [expr {[dict exists $old notify] ? [dict get $old notify] : 1}] updates $ups]
}
proc ::kit::verbs::loadUpdates {} {
    if {[catch {::kit::slurp [::kit::path cache updates] utf-8} d] || [catch {dict size $d}]} { return {} }
    return $d
}

# The index, refreshed when older than maxage; a failure is fatal unless optional.
proc ::kit::verbs::index {maxage {optional 0}} {
    if {[catch {::kit::repo::ensure $maxage} I opts]} {
        if {!$optional} { return -options $opts $I }
        return ""
    }
    return $I
}
proc ::kit::verbs::done {} {
    if {$::kit::repo::refreshed} { saveUpdates [::kit::store::load] }
}

# ---- find -----------------------------------------------------------------------------------------
proc ::kit::verbs::Find {args} {
    need $args 1 "find WORDS"
    set I [index 3600]
    set A [::kit::store::load]
    set words [lmap w $args { string tolower $w }]
    set newest [dict create]
    foreach r [dict get $I kits] {
        set n [dict get $r name]
        if {![dict exists $newest $n] || [::kit::vcmp [dict get $r version] [dict get $newest $n version]] > 0} { dict set newest $n $r }
    }
    set hits {}
    dict for {n r} $newest {
        set hay [string tolower "[dict get $r name] [dict get $r short] [dict get $r summary] [dict get $r tags]"]
        set ok 1
        foreach w $words { if {[string first $w $hay] < 0} { set ok 0 ; break } }
        if {$ok} { lappend hits $r }
    }
    if {![llength $hits]} { puts "Nothing found for [join $args { }]" ; done ; return 0 }
    set wn 12 ; set wv 7
    foreach r $hits { set wn [expr {max($wn, [string length [dict get $r short]])}] ; set wv [expr {max($wv, [string length [dict get $r version]])}] }
    foreach r [lsort -command {apply {{a b} { string compare [dict get $a short] [dict get $b short] }}} $hits] {
        set l [::kit::store::live $A [dict get $r name]]
        set mark ""
        if {$l ne ""} { set mark [expr {[dict get $l version] eq [dict get $r version] ? "   (installed)" : "   (installed [dict get $l version])"}] }
        puts [string trimright [format "  %-*s %-*s  %s%s" $wn [dict get $r short] $wv [dict get $r version] [dict get $r summary] $mark]]
    }
    done
    return 0
}

# ---- grab -----------------------------------------------------------------------------------------
proc ::kit::verbs::Grab {args} {
    need $args 1 "grab KIT…"
    set files 1
    foreach t $args { if {![::kit::plan::isFile $t]} { set files 0 } }
    # a .kit file needs the index only for what it uses
    set I [index 3600 $files]
    set A [::kit::store::load]
    # an older version KIT@VERSION may be one the history knows the root of
    if {[lsearch -glob $args *@*] >= 0} { set ::kit::plan::hints [::kit::txn::hints] }
    set P [::kit::plan::grab $A $I $args]
    foreach n [dict get $P notes] { puts $n }
    Broken $A $args
    if {![llength [dict get $P rows]]} {
        # only a hold taken or let go (NAME@VERSION of what is installed, or a plain grab of it)
        if {[dict get $P changed]} { ::kit::plan::execute $P grab }
        done
        return 0
    }
    if {![::kit::ui::ask [dict get $P rows] [::kit::ui::question [dict get $P rows]] 1]} { return 1 }
    ::kit::plan::execute $P grab
    Summary $P
    done
    return 0
}

# After the switch, what happened and what is left to do (KIT-CLI.md, grab):
#   "  firefox      134.0.2   switched"
#   "Still running old versions: firefox (libgreet). Restart them to use the new ones."
#   "Restart to finish: linux 6.18.60."         (system kits that take effect at restart)
proc ::kit::verbs::Summary {P} {
    set A [::kit::store::load]
    set rows {} ; set changed {} ; set restart {}
    foreach r [dict get $P rows] {
        lappend changed [dict get $r fullname]
        if {[dict get $r action] eq "remove"} {
            lappend rows [dict create name [dict get $r name] old [dict get $r old] action done bytes "" tags {} new removed]
            continue
        }
        lappend rows [dict create name [dict get $r name] short [dict get $r short] old [dict get $r new] action done bytes "" tags {} \
            new [expr {[dict get $r action] eq "install" ? "installed" : "switched"}]]
        if {"restart" in [dict get $r tags]} { lappend restart "[dict get $r name] [dict get $r new]" }
    }
    set lines {}
    # Stale gives {short libs display}; the --tcl dict keeps stale as {short libs} and carries the display
    # names beside it (names: short -> display name), so the shell can show the name the rows show
    set full [Stale $A $changed]
    set stale [lmap s $full { lrange $s 0 1 }]
    set names [dict create]
    foreach s $full { dict set names [lindex $s 0] [lindex $s 2] }
    set texts [lmap s $stale { lassign $s short libs ; expr {[llength $libs] ? "$short ([join $libs {, }])" : $short} }]
    if {[llength $stale]} { lappend lines "Still running old versions: [join $texts {, }]. Restart them to use the new ones." }
    if {[llength $restart]} { lappend lines "Restart to finish: [join $restart {, }]." }
    ::kit::ui::tell $rows $lines [dict create stale $stale restart $restart names $names]
}

# Running launches (data/running/<root>.<pid>, each naming the kit it started) that use an old
# version of one of these kits: {firefox {}}, or {firefox libgreet} when only its libraries changed
# (shown "firefox" and "firefox (libgreet)").  Each entry is {short libs display}: display is the row name.
proc ::kit::verbs::Stale {A changed} {
    set groups [dict create]
    foreach f [glob -nocomplain -directory [::kit::path running] *] {
        if {![regexp {^([0-9a-f]{64})\.([0-9]+)$} [file tail $f] -> root p] || ![::kit::pidAlive $p]} continue
        set app "" ; catch {set app [lindex [::kit::slurp $f utf-8] 0]}
        dict lappend groups $p [list $root $app]
    }
    set out {}
    dict for {p items} $groups {
        set app [lindex $items 0 1]
        if {$app eq ""} continue
        set self 0 ; set libs {}
        foreach it $items {
            set n [dict get [::kit::store::kinfo [lindex $it 0]] name]
            set live [::kit::store::live $A $n]
            if {$n ni $changed || ($live ne "" && [dict get $live root] eq [lindex $it 0])} continue
            if {$n eq $app} { set self 1 } else { lappend libs [dict get [::kit::store::kinfo [lindex $it 0]] short] }
        }
        set l [::kit::store::live $A $app]
        set short [expr {$l ne "" ? [dict get [::kit::store::kinfo [dict get $l root]] short] : [lindex [split $app .] end]}]
        set shown [::kit::plan::RowName $A $app $short]
        if {$self} { lappend out [list $short {} $shown] } elseif {[llength $libs]} { lappend out [list $short [lsort -unique $libs] $shown] }
    }
    return [lsort -unique $out]
}

# grab falls back on mend when an installed kit it was asked for is broken
proc ::kit::verbs::Broken {A targets} {
    foreach t $targets {
        if {[::kit::plan::isFile $t]} continue
        set l [::kit::store::findLive [::kit::store::load] $t]
        if {$l eq ""} continue
        set d [::kit::path store [dict get $l root]]
        if {![file isfile $d/kit] || ![file isfile $d/info] || ![file isfile $d/manifest]} { Mend $t }
    }
}

# ---- check ----------------------------------------------------------------------------------------
proc ::kit::verbs::Check {args} {
    set I [index 0]
    set A [::kit::store::load]
    set pairs [::kit::plan::updates $A $I $args]
    if {![llength $pairs]} { puts "Up to date" ; done ; return 0 }
    set P [::kit::plan::update $A $I $pairs]
    ::kit::ui::annotate checked [dict get $I checked]
    if {![::kit::ui::ask [dict get $P rows] [::kit::ui::question [dict get $P rows]] 1]} { done ; return 1 }
    # yes hands them to grab's machinery, which does not ask again
    ::kit::plan::execute $P grab
    Summary $P
    done
    return 0
}

# ---- toss -----------------------------------------------------------------------------------------
proc ::kit::verbs::Toss {args} {
    need $args 1 "toss KIT…"
    set A [::kit::store::load]
    set P [::kit::plan::toss $A $args]
    foreach n [dict get $P notes] { puts $n }
    if {![llength [dict get $P rows]]} { return 0 }
    # where each kit's data is, found before its files go
    set data [dict create]
    foreach r [dict get $P rows] {
        set inf [::kit::store::kinfo [dict get $r root]]
        set ps [::kit::store::dataPaths $inf]
        set n 0 ; foreach p $ps { incr n [::kit::store::du $p] }
        dict set data [dict get $r root] [list $ps $n]
    }
    ::kit::plan::execute $P toss
    set answers {}
    foreach r [dict get $P rows] {
        # an empty private data directory goes with the kit, unasked
        catch {file delete [::kit::path appdata [dict get $r fullname]]}
        lassign [dict get $data [dict get $r root]] ps n
        if {![llength $ps]} { ::kit::ui::ask [list $r] "" 0 ; continue }
        set where [join [lmap p $ps { ::kit::tilde $p }] " and "]
        if {[::kit::ui::ask [list $r] "Also remove its data in $where ([::kit::fmtsize $n])?" 0]} {
            foreach p $ps { ::kit::store::Rmtree $p }
            lappend answers [dict get $r fullname] removed
        } else {
            lappend answers [dict get $r fullname] kept
        }
    }
    # the answers go into the toss's log entry: the history says "· data kept" (Kit-Bar-4)
    if {[llength $answers]} { ::kit::txn::amend $::kit::txn::last data $answers }
    return 0
}

# ---- rewind ---------------------------------------------------------------------------------------
# kit rewind: the change the history cursor names is taken back, as one transaction.  The rewind is
# appended to the log ("undoes ID"), never deleting anything, and the cursor moves to the next older
# change that is not undone yet (plan.tcl restore, txn.tcl Next).
proc ::kit::verbs::Rewind {args} {
    if {[llength $args] > 1} { ::kit::fail 2 "usage: kit rewind [KIT]" }
    if {[llength $args]} { return [RewindKit [lindex $args 0]] }
    set id [::kit::txn::cursor]
    if {$id eq ""} { puts "Nothing to rewind" ; return 0 }
    set P [::kit::plan::restore [::kit::store::load] [::kit::txn::before $id] $id]
    if {[::kit::ui::gui]} { ::kit::ui::annotate history [HistoryEntries] }
    if {![::kit::ui::ask [dict get $P rows] "Rewind?" 1]} { return 1 }
    ::kit::plan::execute $P rewind
    Summary $P
    done
    return 0
}

# The history as the GUI shows it (kit rewind --tcl): one dict per log entry, newest first: id, time, icon
# (up, plus, trash, or undo for a rewind), title and the line under it.  cursor is 1 on the change that a plain
# kit rewind takes back next (the one the Rewind button is for).  Titles and lines are made here, so every
# front end says the same: "Updated 5 kits" / "firefox, ffmpeg, mesa".
proc ::kit::verbs::HistoryEntries {} {
    set cur [::kit::txn::cursor]
    set out {}
    foreach id [::kit::txn::history] {
        if {[catch {::kit::txn::entry $id} e] || [catch {Describe $e} d]} continue
        if {$d eq ""} continue
        lappend out [dict merge [dict create id $id time [dict get $e time] cursor [expr {$id eq $cur}]] $d]
    }
    return $out
}
# {icon title sub} for one history entry, "" when it changed no kit.  A rewind (a plain one, or kit rewind KIT)
# reads "Rewound ..."; a held kit's change too, as before.
proc ::kit::verbs::Describe {e} {
    set B [::kit::store::parse [dict get $e before]] ; set A [::kit::store::parse [dict get $e after]]
    set was [Live $B] ; set now [Live $A]
    set names [lsort -unique [concat [dict keys $was] [dict keys $now]]]
    set added {} ; set gone {} ; set moved {}
    foreach n $names {
        if {![dict exists $was $n]} { lappend added $n } elseif {![dict exists $now $n]} { lappend gone $n
        } elseif {[lindex [dict get $was $n] 0] ne [lindex [dict get $now $n] 0]} { lappend moved $n }
    }
    set all [concat $added $gone $moved]
    if {![llength $all]} { return "" }
    set rewound [expr {[dict get $e op] in {rewind rewind-kit}}]
    if {[llength $all] == 1} {
        set n [lindex $all 0]
        if {$added ne ""} {
            lassign [dict get $now $n] v short
            return [dict create icon [expr {$rewound ? "undo" : "plus"}] title "[expr {$rewound ? "Rewound" : "Installed"}] $short" sub "$short $v"]
        }
        if {$gone ne ""} {
            lassign [dict get $was $n] v short
            set sub "$short $v"
            if {!$rewound && [dict exists $e data $n] && [dict get $e data $n] eq "kept"} { append sub " · data kept" }
            return [dict create icon [expr {$rewound ? "undo" : "trash"}] title "[expr {$rewound ? "Rewound" : "Uninstalled"}] $short" sub $sub]
        }
        lassign [dict get $was $n] a short ; lassign [dict get $now $n] b -
        if {$rewound || $n in [dict get $A holds]} {
            set sub "$a → $b"
            if {$n in [dict get $A holds]} { append sub " · held" }
            return [dict create icon undo title "Rewound $short" sub $sub]
        }
        return [dict create icon up title "Updated $short" sub "$a → $b"]
    }
    set shorts [lmap n $all { lindex [dict get [expr {[dict exists $now $n] ? $now : $was}] $n] 1 }]
    if {$rewound} { return [dict create icon undo title "Rewound [llength $all] kits" sub [join $shorts {, }]] }
    set verb [expr {[llength $moved] == [llength $all] ? "Updated" : ([llength $added] == [llength $all] ? "Installed" : ([llength $gone] == [llength $all] ? "Uninstalled" : "Changed"))}]
    set icon [dict get {Updated up Installed plus Uninstalled trash Changed up} $verb]
    return [dict create icon $icon title "$verb [llength $all] kits" sub [join $shorts {, }]]
}
# name -> {version short} for the kits of a set that are live (not the old versions kept as prev)
proc ::kit::verbs::Live {A} {
    set out [dict create]
    dict for {key k} [dict get $A kits] {
        if {[dict get $k reason] eq "prev"} continue
        set inf [::kit::store::kinfo [dict get $k root]]
        set short [dict get $inf short]
        if {$short eq "?"} { set short [::kit::shortOf [dict get $k name]] }
        dict set out [dict get $k name] [list [dict get $k version] $short]
    }
    return $out
}

# kit rewind KIT: that kit's previous version, grabbed by version: held there, and logged as a rewind-kit
# change like any grab (so a plain kit rewind takes this back too).
proc ::kit::verbs::RewindKit {word} {
    set A [::kit::store::load]
    set l [::kit::store::findLive $A $word]
    if {$l eq ""} { ::kit::fail 2 "$word is not installed" }
    set inf [::kit::store::kinfo [dict get $l root]]
    ::kit::system::refuseRewind [dict get $inf kind] [dict get $l name]
    set prev [PreviousOf $l]
    if {$prev eq ""} { puts "[dict get $inf short] has no earlier version to go back to" ; return 0 }
    set ::kit::plan::hints [::kit::txn::hints]
    set P [::kit::plan::grab $A [index 3600 1] [list "[dict get $l name]@[lindex $prev 0]"]]
    foreach n [dict get $P notes] { puts $n }
    if {![llength [dict get $P rows]]} {
        if {[dict get $P changed]} { ::kit::plan::execute $P rewind-kit }
        done
        return 0
    }
    if {![::kit::ui::ask [dict get $P rows] "Rewind?" 1]} { return 1 }
    ::kit::plan::execute $P rewind-kit
    Summary $P
    done
    return 0
}

# The version KIT had before its newest change: {version root} from the newest history entry whose
# set had another version of it.  "" when the change installed it, or history has no such entry.
proc ::kit::verbs::PreviousOf {l} {
    foreach id [::kit::txn::history] {
        if {[catch {::kit::txn::before $id} B]} break
        set bl [::kit::store::live $B [dict get $l name]]
        if {$bl eq ""} break
        if {[dict get $bl version] ne [dict get $l version]} { return [list [dict get $bl version] [dict get $bl root]] }
    }
    return ""
}

# ---- list -----------------------------------------------------------------------------------------
proc ::kit::verbs::List {args} {
    set A [::kit::store::load]
    set U [loadUpdates]
    set waiting [dict create]
    if {[dict exists $U updates]} {
        foreach u [dict get $U updates] { dict set waiting "[dict get $u name] [dict get $u version]" $u }
    }
    set rows {}
    dict for {key k} [dict get $A kits] {
        if {[dict get $k reason] eq "prev"} continue
        set inf [::kit::store::kinfo [dict get $k root]]
        set size 0 ; catch {set size [file size [::kit::path store [dict get $k root] kit]]}
        set mark ""
        if {[dict exists $waiting $key]} {
            set u [dict get $waiting $key]
            set mark "→ [dict get $u new]"
            if {"security" in [dict get $u flags]} { append mark "   security" }
        }
        if {[dict get $k reason] eq "dep"} { set mark [string trim "library   $mark"] }
        if {[dict get $k name] in [dict get $A holds]} { set mark [string trim "held   $mark"] }
        lappend rows [list [dict get $inf short] [dict get $k version] $size $mark]
    }
    # the machine's own kits, from the system's set (as a person may read it): the same list, marked system
    ::kit::need scope
    lappend rows {*}[::kit::scope::listRows]
    if {![llength $rows]} { puts "No kits installed" ; return 0 }
    set wn 12 ; set wv 7
    foreach r $rows { set wn [expr {max($wn, [string length [lindex $r 0]])}] ; set wv [expr {max($wv, [string length [lindex $r 1]])}] }
    foreach r [lsort -index 0 $rows] {
        lassign $r n v s m
        puts [string trimright [format "  %-*s %-*s %8s   %s" $wn $n $wv $v [::kit::fmtsize $s] $m]]
    }
    return 0
}

# ---- info -----------------------------------------------------------------------------------------
proc ::kit::verbs::Info {args} {
    need $args 1 "info KIT"
    set word [lindex $args 0]
    set A [::kit::store::load]
    set rec "" ; set inf "" ; set line "" ; set b ""
    if {[::kit::plan::isFile $word] && [file isfile $word]} {
        ::kit::kitfmt
        set h [::kitfmt open $word]
        set rc [catch {
            set fi [::kitfmt info $h] ; set m [::kitfmt manifest $h]
            set f [dict get $m fields]
            set inf [dict create name [dict get $f name] version [dict get $f version] kind [dict get $f kind] \
                short [::kit::shortOf [dict get $f name] [expr {[dict exists $f x-short] ? [dict get $f x-short] : ""}]] \
                summary [expr {[dict exists $f summary] ? [dict get $f summary] : ""}] size [dict get $fi bytes] fields $f \
                needs [dict get $m needs] perms [dict get $m perms] signer [dict get $fi signature]]
        } err opts]
        ::kitfmt close $h
        if {$rc} { return -options $opts $err }
        set line [::kit::store::live $A [dict get $inf name]]
        set I ""
    } else {
        set line [::kit::store::findLive $A $word]
        set I [index 3600 [expr {$line ne ""}]]
        if {$I ne ""} {
            set name [expr {$line ne "" ? [dict get $line name] : $word}]
            set recs [::kit::repo::records $I $name]
            if {$line ne ""} { set recs [lmap r $recs { if {[dict get $r name] ne [dict get $line name]} continue ; set r }] }
            set rec [::kit::plan::newest $recs]
        }
        if {$line eq "" && $rec eq ""} { ::kit::fail 2 "there is no kit called $word (kit find $word)" }
        if {$line ne ""} {
            set inf [::kit::store::kinfo [dict get $line root]]
        } else {
            set inf [dict create name [dict get $rec name] version [dict get $rec version] kind [dict get $rec kind] \
                short [dict get $rec short] summary [dict get $rec summary] size [dict get $rec size] fields {} needs {} perms {} signer {}]
            if {![catch {::kit::repo::bundle $rec} b]} {
                lassign [::kit::repo::bundleCheck $b [dict get $rec root]] st sig
                set ki [::kit::store::kitIndex [dict get $b index]]
                dict set inf fields [dict get $ki fields] ; dict set inf needs [dict get $ki needs]
                dict set inf perms [dict get $ki perms] ; dict set inf signer $sig
            }
        }
    }
    set out [list "[dict get $inf short] ([dict get $inf name])"]
    set row {apply {{k v} { if {$v ne ""} { return [format "  %-12s %s" $k $v] } ; return "" }}}
    lappend out [{*}$row Summary [dict get $inf summary]]
    set ver [dict get $inf version]
    if {$line ne ""} {
        set ver "[dict get $line version] installed"
        if {$rec ne "" && [::kit::vcmp [dict get $rec version] [dict get $line version]] > 0} { append ver ", [dict get $rec version] available" }
    } elseif {$rec ne ""} { set ver "[dict get $rec version] available" }
    lappend out [{*}$row Version $ver]
    set size [::kit::fmtsize [dict get $inf size]]
    if {$line ne "" && [file exists [::kit::path store [dict get $line root] kit]]} {
        append size " ([::kit::fmtsize [file size [::kit::path store [dict get $line root] kit]]] stored)"
    } elseif {$rec ne ""} { append size " ([::kit::fmtsize [dict get $rec download]] to fetch)" }
    lappend out [{*}$row Size $size]
    lappend out [{*}$row Kind [dict get $inf kind]]
    set perms [join [lmap p [dict get $inf perms] { join $p " " }] ", "]
    lappend out [{*}$row Permissions [expr {$perms eq "" ? "none requested" : $perms}]]
    set uses {}
    foreach n [dict get $inf needs] {
        lassign $n need range
        set got ""
        if {$line ne ""} {
            foreach u [dict get $A uses] { if {[lindex $u 0] eq [::kit::store::key $line] && [lindex $u 1] eq $need} { set got " → [lindex [split [lindex $u 2]] 1]" } }
        }
        lappend uses "$need [join $range]$got"
    }
    lappend out [{*}$row Uses [expr {[llength $uses] ? [join $uses ", "] : "nothing"}]]
    set sig [dict get $inf signer]
    if {$sig ne ""} {
        set s [dict get $sig state]
        if {[dict exists $sig keyid] && [dict get $sig keyid] ne ""} { append s ", key [dict get $sig keyid]" }
        if {[dict exists $sig comment] && [dict get $sig comment] ne ""} { append s " ([dict get $sig comment])" }
        lappend out [{*}$row Signer $s]
    }
    if {$line ne ""} {
        set when [clock format [dict get $inf installed] -format "%Y-%m-%d %H:%M"]
        set inst "yes, $when"
        foreach k [::kit::store::lines $A [dict get $line name]] {
            if {[dict get $k reason] eq "prev"} { append inst "; [dict get $k version] kept until [dict get $line version] has started once" }
        }
        if {[dict get $line reason] eq "dep"} { append inst "; a library [join [lmap u [::kit::store::users $A [::kit::store::key $line]] { lindex [split $u] 0 }] {, }] uses" }
        lappend out [{*}$row Installed $inst]
        set ps [::kit::store::dataPaths $inf]
        if {[llength $ps]} {
            set n 0 ; foreach p $ps { incr n [::kit::store::du $p] }
            lappend out [{*}$row Data "[join [lmap p $ps { ::kit::tilde $p }] {, }] ([::kit::fmtsize $n])"]
        }
    } else { lappend out [{*}$row Installed no] }
    puts [join [lmap l $out { if {$l eq ""} continue ; set l }] \n]
    done
    return 0
}

# ---- mend -----------------------------------------------------------------------------------------
proc ::kit::verbs::Mend {args} {
    ::kit::lock
    # what is installed is not judged for expiry again, only for revocation (KIT-TRUST.md section 6)
    ::kit::kitfmt
    ::kittrust configure -mode installed
    set A [MendSet]
    set lines {}
    if {[llength $args]} {
        foreach t $args {
            set l [::kit::store::findLive $A $t]
            if {$l eq ""} { ::kit::fail 2 "$t is not installed" }
            lappend lines $l
            foreach k [::kit::store::lines $A [dict get $l name]] { if {[dict get $k reason] eq "prev"} { lappend lines $k } }
        }
    } else { set lines [dict values [dict get $A kits]] }
    set worst 0 ; set rows {}
    foreach l [lsort -unique $lines] {
        set r [catch {MendOne $l} what opts]
        if {$r} {
            set code [lindex [dict get $opts -errorcode] 1]
            if {![string is integer -strict $code]} { set code 4 }
            set worst [expr {max($worst, $code)}]
            set what "damaged: $what"
        }
        if {[dict get $l reason] ne "prev"} {
            lappend rows [list [dict get [::kit::store::kinfo [dict get $l root]] short] [dict get $l version] $what]
        }
    }
    ::kit::store::syncExports $A
    # chunks now back inside kits are not needed in the cache
    ::kit::store::gc $A
    ::kit::unlock
    if {![llength $rows]} { puts "No kits installed" ; return 0 }
    set wn 12 ; set wv 7
    foreach r $rows { set wn [expr {max($wn, [string length [lindex $r 0]])}] ; set wv [expr {max($wv, [string length [lindex $r 1]])}] }
    foreach r [lsort -index 0 $rows] { puts [format "  %-*s %-*s   %s" $wn [lindex $r 0] $wv [lindex $r 1] [lindex $r 2]] }
    return $worst
}

# The active set, rebuilt from the store when it is unreadable (the local database).
proc ::kit::verbs::MendSet {} {
    if {![catch {::kit::store::load} A]} { return $A }
    set A [::kit::store::empty]
    foreach d [glob -nocomplain -directory [::kit::path store] -type d *] {
        set inf [::kit::store::kinfo [file tail $d]]
        if {[dict get $inf name] eq "?"} continue
        set old [::kit::store::live $A [dict get $inf name]]
        if {$old ne "" && [::kit::vcmp [dict get $old version] [dict get $inf version]] >= 0} continue
        if {$old ne ""} { dict unset A kits [::kit::store::key $old] }
        dict set A kits "[dict get $inf name] [dict get $inf version]" [dict create name [dict get $inf name] \
            version [dict get $inf version] root [file tail $d] reason user started 1]
    }
    ::kit::spit [::kit::path active] [::kit::store::text $A]
    ::kit::note "kit: the installed set was damaged and has been rebuilt from the store"
    return $A
}

proc ::kit::verbs::Origin {root} {
    set i [::kit::store::kinfo $root]
    return [expr {[dict exists $i origin] ? [dict get $i origin] : "repo"}]
}

proc ::kit::verbs::MendOne {l} {
    ::kit::kitfmt
    set root [dict get $l root]
    set d [::kit::path store $root]
    # the signed manifest: kept with the kit, else fetched again (checked against the root)
    set b ""
    if {[catch {::kit::repo::bundleParse [::kit::slurp $d/manifest]} b] || [catch {::kit::repo::bundleCheck $b $root}]} {
        set b ""
        foreach mirror [::kit::repo::mirrorOrder] {
            if {[catch {::kit::net::get $mirror/kits/$root -max 67108864} r]} continue
            if {[catch {set bb [::kit::repo::bundleParse [dict get $r data]] ; ::kit::repo::bundleCheck $bb $root}]} continue
            set b $bb ; break
        }
        if {$b eq ""} { ::kit::fail 3 "its signed manifest is damaged and no mirror has it" }
    }
    lassign [::kit::repo::bundleCheck $b $root] st sig
    if {![::kit::sigAcceptable [dict get $sig state]]} { ::kit::fail 4 "its signature is [dict get $sig state]" }
    set ki [::kit::store::kitIndex [dict get $b index]]
    set hashes [::kit::store::blobs $ki $st]
    # every chunk of the kit file, checked against the manifest
    set bad {}
    set whole 0
    if {[catch {::kitfmt open $d/kit} h]} {
        set whole 1
    } else {
        set v [::kitfmt verify $h]
        ::kitfmt close $h
        if {![dict get $v ok]} {
            foreach x [dict get $v bad] {
                lassign $x p i
                if {$p eq ""} { set whole 1 ; continue }
                foreach f [dict get $ki files] {
                    if {[lindex $f 0] ne $p} continue
                    set hs [split [lindex $f 6] ,]
                    lappend bad [expr {[lindex $f 4] eq "classic" ? [lindex $hs 0] : [lindex $hs $i]}]
                }
            }
        }
    }
    set fixed {}
    if {$whole || [llength $bad]} {
        ::kit::store::closeAll
        set m [::kit::store::chunkMap]
        if {$whole} {
            # nothing can be read from this kit file: its chunks come from the cache, other kits or a mirror
            dict for {hh r} $m { if {$r eq $root} { dict unset m $hh } }
            set ::kit::store::chunkMap $m
            set need [::kit::store::missing $hashes]
        } else {
            # the damaged chunks come from the cache (when a good copy is there) or a mirror; the
            # others are read back out of this kit's own file
            set need {}
            set cached {} ; set datas {}
            foreach hh [lsort -unique $bad] {
                set f [::kit::repo::chunkPath $hh]
                if {[file exists $f]} { lappend cached $hh ; lappend datas [::kit::slurp $f] } else { lappend need $hh }
            }
            foreach hh $cached hx [::kitfmt::HashMany $datas] {
                if {$hx ne $hh} { file delete [::kit::repo::chunkPath $hh] ; lappend need $hh }
            }
        }
        ::kit::repo::fetchChunks $need [dict get $b sizes]
        set new [::kit::path staging mend-[pid]-$root]
        ::kit::store::Rmtree $new
        file mkdir $new
        set rc [catch {
            ::kit::store::assemble $b $new/kit
            ::kit::store::stage $new $b [::kit::verbs::Origin $root]
        } err opts]
        ::kit::store::closeAll
        set ::kit::store::chunkMap ""
        if {$rc} { ::kit::store::Rmtree $new ; return -options $opts $err }
        foreach f {kit manifest info} { file rename -force $new/$f $d/$f }
        ::kit::store::Rmtree $d/export
        if {[file isdirectory $new/export]} { file rename $new/export $d/export }
        ::kit::store::Rmtree $new
        set n [llength $need]
        set how [expr {$n ? "$n chunk[expr {$n == 1 ? "" : "s"}] fetched" : "from chunks stored here"}]
        return "repaired ([expr {$whole ? "kit file rebuilt, " : ""}]$how)"
    }
    # the signed manifest and the info file are written again if they are missing
    if {![file isfile $d/manifest]} { ::kit::spit $d/manifest [::kit::repo::bundleText $b] binary ; lappend fixed manifest }
    if {![file isfile $d/info]} {
        set new [::kit::path staging mend-[pid]-$root]
        ::kit::store::Rmtree $new ; file mkdir $new
        file copy $d/kit $new/kit
        ::kit::store::stage $new $b [Origin $root]
        file rename -force $new/info $d/info
        ::kit::store::Rmtree $d/export ; file rename $new/export $d/export
        ::kit::store::Rmtree $new
        lappend fixed info
    }
    if {[llength $fixed]} { return "repaired ([join $fixed {, }] written again)" }
    return ok
}

# ---- pack -----------------------------------------------------------------------------------------
proc ::kit::verbs::Pack {args} {
    need $args 1 "pack DIR"
    # kitpack's options come first; then DIR and an optional OUT.kit
    set opts {} ; set pos {}
    for {set i 0} {$i < [llength $args]} {incr i} {
        set a [lindex $args $i]
        if {$a eq "-q"} { lappend opts $a ; continue }
        if {[string index $a 0] eq "-" && [llength $pos] == 0} { lappend opts $a [lindex $args [incr i]] ; continue }
        lappend pos $a
    }
    if {[llength $pos] < 1 || [llength $pos] > 2} { ::kit::fail 2 "usage: kit pack [KITPACK-OPTIONS] DIR [OUT.kit]" }
    set dir [string trimright [lindex $pos 0] /]
    if {![file isdirectory $dir]} { ::kit::fail 2 "$dir is not a directory" }
    if {"-manifest" ni $opts} {
        if {![file isfile $dir.manifest]} { ::kit::fail 2 "no manifest: write $dir.manifest (its keys are described at the top of kitpack)" }
        lappend opts -manifest $dir.manifest
    }
    set kp [file join [::kit::kitfmtDir] kitpack]
    # kitpack finds Mk4tcl through auto_path; KITFMT_MK4TCL is handed over as TCLLIBPATH so it
    # wins over any other copy, as it does in kit (kitpack would append it, and lose)
    set d [::kit::env KITFMT_MK4TCL]
    if {$d ne ""} { set ::env(TCLLIBPATH) [concat [list $d] [::kit::env TCLLIBPATH]] ; unset ::env(KITFMT_MK4TCL) }
    set rc [catch {exec [info nameofexecutable] $kp {*}$opts {*}$pos <@stdin >@stdout 2>@stderr}]
    return [expr {$rc ? 2 : 0}]
}

# ---- run --------------------------------------------------------------------------------------------
proc ::kit::verbs::Run {args} {
    need $args 1 "run KIT \[ARGS…\]"
    set word [lindex $args 0]
    set rest [lrange $args 1 end]
    set A [::kit::store::load]
    if {[::kit::plan::isFile $word] && [file isfile $word]} { return [RunFile $A $word $rest] }
    set line [::kit::store::findLive $A $word]
    if {$line eq ""} { ::kit::fail 2 "$word is not installed (kit grab $word)" }
    set root [dict get $line root]
    set inf [::kit::store::kinfo $root]
    ::kit::launch::checkPerms $inf
    # the kit and every library its lock names, transitively
    set set [list [::kit::store::key $line]]
    for {set i 0} {$i < [llength $set]} {incr i} {
        foreach u [dict get $A uses] { if {[lindex $u 0] eq [lindex $set $i] && [lindex $u 2] ni $set} { lappend set [lindex $u 2] } }
    }
    file mkdir [::kit::path running]
    set marks {} ; set cleanups {} ; set libs {}
    foreach key $set {
        set k [dict get $A kits $key]
        set m [::kit::path running [dict get $k root].[pid]]
        ::kit::spit $m [lindex [split [lindex $set 0]] 0]
        lappend marks $m
    }
    set rc [catch {
        foreach key $set {
            set k [dict get $A kits $key]
            lassign [::kit::launch::files [::kit::path store [dict get $k root] kit]] tree cleanup
            if {$cleanup ne ""} { lappend cleanups $cleanup }
            if {$key eq [lindex $set 0]} { set mytree $tree } else { lappend libs $tree }
        }
        set e [::kit::launch::entry $inf]
        set cmd [::kit::launch::command $inf $mytree $e {*}$rest]
        lassign [::kit::launch::start $cmd $inf $mytree $libs] status secs
    } err opts]
    foreach m $marks { catch {file delete $m} }
    foreach c $cleanups { catch {{*}$c} }
    if {$rc} { return -options $opts $err }
    FirstStart $set $e $status $secs
    return $status
}

# The old version is kept until the new one has started once: a good first start lets it go;
# a failed one goes back to it.  "Started" means it was still running after a grace period, or
# exited cleanly (for a command-line entry: that it could be started at all).
proc ::kit::verbs::FirstStart {set e status secs} {
    set A [::kit::store::load]
    set fresh {}
    foreach key $set { if {[dict exists [dict get $A kits] $key] && ![dict get $A kits $key started]} { lappend fresh $key } }
    if {![llength $fresh]} return
    set grace [::kit::env KIT_START_GRACE 3]
    set ok [expr {[lindex $e 3] eq "cli" ? $status != 127 : ($status == 0 || $secs >= $grace)}]
    set app [lindex $set 0]
    if {$ok} {
        foreach key $fresh { dict set A kits $key started 1 }
        ::kit::txn::apply "first start" [::kit::plan::Tidy $A] {}
        return
    }
    set back {}
    if {$app in $fresh} {
        set k [dict get $A kits $app]
        set prev ""
        foreach l [::kit::store::lines $A [dict get $k name]] { if {[dict get $l reason] eq "prev"} { set prev $l ; break } }
        if {$prev ne "" && ![llength [::kit::store::users $A $app]]} {
            dict unset A kits $app
            dict set A uses [lmap u [dict get $A uses] { if {[lindex $u 0] eq $app} continue ; set u }]
            dict set A kits [::kit::store::key $prev] reason [dict get $k reason]
            lappend back "[dict get [::kit::store::kinfo [dict get $k root]] short] [dict get $prev version]"
            set app [::kit::store::key $prev]
        }
    }
    # a library updated under this kit goes back to its previous version for this kit
    set uses {}
    foreach u [dict get $A uses] {
        lassign $u user need lib
        if {$user eq $app && $lib in $fresh} {
            set lk [dict get $A kits $lib]
            foreach l [::kit::store::lines $A [dict get $lk name]] {
                if {[dict get $l reason] eq "prev" && [::kit::plan::satisfies [dict get $l name] [dict get $l version] \
                        [dict get [::kit::store::kinfo [dict get $l root]] provides] $need [::kit::plan::rangeFor $A $user $need]]} {
                    set lib [::kit::store::key $l]
                    dict set A kits $lib reason dep
                    lappend back "[dict get [::kit::store::kinfo [dict get $l root]] short] [dict get $l version]"
                    break
                }
            }
        }
        lappend uses [list $user $need $lib]
    }
    dict set A uses $uses
    if {![llength $back]} return
    ::kit::txn::apply rollback [::kit::plan::Tidy $A] {}
    puts stderr "kit: [lindex [split [lindex $set 0]] 0] [lindex [split [lindex $set 0]] 1] did not start; back to [join $back {, }]"
}

proc ::kit::verbs::RunFile {A file rest} {
    set c [::kit::plan::fromFile $file]
    set inf [dict create name [dict get $c name] version [dict get $c version] short [dict get $c short] \
        entries [dict get $c ki entries] perms [dict get $c ki perms] provides [dict get $c provides]]
    ::kit::launch::checkPerms $inf
    set libs {} ; set cleanups {}
    set rc [catch {
        foreach n [dict get $c needs] {
            lassign $n need range
            set best ""
            dict for {key k} [dict get $A kits] {
                if {[dict get $k reason] eq "prev"} continue
                if {[::kit::plan::satisfies [dict get $k name] [dict get $k version] [dict get [::kit::store::kinfo [dict get $k root]] provides] $need $range]} { set best $k }
            }
            if {$best eq ""} { ::kit::fail 2 "[dict get $c short] needs $need [join $range], which is not installed (kit grab $file installs both)" }
            lassign [::kit::launch::files [::kit::path store [dict get $best root] kit]] t cl
            lappend libs $t ; if {$cl ne ""} { lappend cleanups $cl }
        }
        lassign [::kit::launch::files [file normalize $file]] tree cl
        if {$cl ne ""} { lappend cleanups $cl }
        set cmd [::kit::launch::command $inf $tree [::kit::launch::entry $inf] {*}$rest]
        lassign [::kit::launch::start $cmd $inf $tree $libs] status secs
    } err opts]
    foreach cl $cleanups { catch {{*}$cl} }
    if {$rc} { return -options $opts $err }
    return $status
}
