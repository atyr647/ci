# txn.tcl -- transactions: a journal, staging beside the live set, one atomic switch, recovery.
#
# Every grab, toss and rewind (and the small change `kit run` makes after a first start, which is not
# logged) is one transaction (KIT-CLI.md, "Transactions"; round 2 section 8 item 2):
#
#   1. begin     data/journal is written: "begin <id> <op>"            (under data/lock)
#   2. stage     each new kit version is written and verified in data/staging/<id>/<root>/,
#                then renamed into data/store/<root>/ (content-addressed: a re-run reuses it)
#   3. staged    the new set is written to data/staging/<id>/active, naming the transaction; the
#                log entry and the cursor (history, history.cursor) are staged beside it
#   4. switch    rename(staging/<id>/active, data/active): THE atomic step
#   5. after     launcher exports updated, unreferenced versions removed, journal deleted
#
# A crash before 4 leaves the old set (data/active never changed); a crash after it leaves the
# new one.  The next kit command looks at the journal before doing anything else: if data/active
# names the journal's transaction the switch happened, and it finishes step 5; otherwise it undoes
# the staging.  Nothing else is needed, because data/active is only ever replaced by a rename.

namespace eval ::kit::txn {
    variable afterSwitch {}   ;# commands run (with the new set) after every switch and recovery
    variable beforeSwitch {}  ;# commands run (with the new set) once it is staged, before it becomes the set
    variable last ""          ;# the id of the transaction this process applied last
}

proc ::kit::txn::journal {line} {
    set ch [open [::kit::path journal] {WRONLY CREAT APPEND}]
    fconfigure $ch -translation lf -encoding utf-8
    puts $ch $line
    close $ch
}

proc ::kit::txn::readJournal {} {
    if {[catch {::kit::slurp [::kit::path journal] utf-8} text]} { return "" }
    foreach line [split $text \n] {
        if {[regexp {^begin (\S+) (.+)$} $line -> id op]} { return [list $id $op] }
    }
    return [list "" ""]
}

# Run first by every command.  Cheap when there is nothing to do (one stat).
proc ::kit::txn::recover {} {
    set staging [glob -nocomplain -directory [::kit::path staging] *]
    if {![file exists [::kit::path journal]] && ![llength $staging]} return
    # a transaction another live kit is running right now is not half-done
    if {[::kit::lockOwner] ne ""} return
    ::kit::lock
    set rc [catch {
        if {[file exists [::kit::path journal]]} {
            lassign [readJournal] id op
            set A [::kit::store::load]
            if {$id ne "" && [dict get $A txn] eq $id} {
                After $id $A
                ::kit::note "kit: finished an interrupted $op"
            } else {
                if {$id ne ""} { ::kit::store::Rmtree [::kit::path staging $id] }
                foreach cmd $::kit::txn::afterSwitch { {*}$cmd $A }
                ::kit::store::gc $A
                file delete [::kit::path journal]
                ::kit::note "kit: undid an interrupted [expr {$op eq "" ? "change" : $op}]; nothing was changed"
            }
        }
        foreach d [glob -nocomplain -directory [::kit::path staging] *] { ::kit::store::Rmtree $d }
    } err opts]
    ::kit::unlock
    if {$rc} { return -options $opts $err }
}

# Apply a new set.  stages: {root builder ...}: each builder is called with a fresh directory to
# write that version's kit file into (see store::stage); roots already in the store are reused.
# extra: history BEFORE-TEXT records this change in the log (a grab, toss or rewind-kit: the cursor moves
# to it), and when it is a plain rewind also "undoes ID" and "cursor NEXT" (the cursor's new value).
# Without history (a first start, a rollback) nothing is logged and the cursor does not move.
proc ::kit::txn::apply {op A stages {extra {}}} {
    ::kit::lock
    set rc [catch {
        set id [clock milliseconds]-[pid]
        set ::kit::txn::last $id
        file mkdir [::kit::path staging $id] [::kit::path store]
        journal "begin $id $op"
        ::kit::crashpoint begin
        set sync {}
        foreach {root builder} $stages {
            set final [::kit::path store $root]
            if {[file isdirectory $final] && [file exists $final/info]} continue
            set dir [::kit::path staging $id $root]
            file mkdir $dir
            {*}$builder $dir
            lappend sync $dir/kit $dir/manifest $dir/info $dir
            ::kit::crashpoint stage
            ::kit::store::Rmtree $final
            file rename $dir $final
            journal "stage $root"
        }
        ::kit::crashpoint staged
        # what must hold of the new set before it becomes the set (the system scope: no path in two kits); an error
        # here is an error before the switch: nothing changed, the staged kits are removed again
        foreach cmd $::kit::txn::beforeSwitch { {*}$cmd $A }
        dict set A txn $id
        set logged {}
        if {[dict exists $extra history]} {
            set entry [dict create op $op time [::kit::now] before [dict get $extra history] after [::kit::store::text $A]]
            if {[dict exists $extra undoes]} { dict set entry undoes [dict get $extra undoes] }
            set cursor [expr {[dict exists $extra cursor] ? [dict get $extra cursor] : $id}]
            ::kit::spit [::kit::path staging $id history] $entry
            ::kit::spit [::kit::path staging $id cursor] "$cursor\n"
            set logged [list [::kit::path staging $id history] [::kit::path staging $id cursor]]
        }
        set new [::kit::path staging $id active]
        ::kit::spit $new [::kit::store::text $A]
        ::kit::durable {*}[lmap p $sync { string map [list [::kit::path staging $id] [::kit::path store]] $p }] $new {*}$logged [::kit::path store]
        ::kit::crashpoint synced
        journal "switch"
        ::kit::crashpoint switch
        file rename -force $new [::kit::path active]
        ::kit::crashpoint switched
        ::kit::durable [::kit::path data]
        After $id $A
    } err opts]
    ::kit::unlock
    if {$rc} {
        # an error (not a crash) before the switch: undo now, as recovery would
        if {[info exists id] && [dict get [::kit::store::load] txn] ne $id} {
            catch {::kit::store::Rmtree [::kit::path staging $id]}
            catch {file delete [::kit::path journal]}
            catch {::kit::store::gc [::kit::store::load]}
        }
        return -options $opts $err
    }
}

proc ::kit::txn::After {id A} {
    History $id
    ::kit::store::syncExports $A
    ::kit::crashpoint exports
    # what the switch needs from the store (the system scope builds and mounts the new /usr view from the kits' files,
    # and the old view still shows the old ones until then) is still there when it runs: gc comes after it, never before
    foreach cmd $::kit::txn::afterSwitch { {*}$cmd $A }
    ::kit::store::gc $A
    ::kit::crashpoint gc
    ::kit::store::Rmtree [::kit::path staging $id]
    file delete [::kit::path journal]
    ::kit::crashpoint done
}

# ---- history: the log, and the cursor a plain kit rewind takes back --------------------------------
# data/history/<id>: one entry per grab, toss, rewind-kit and plain rewind (a dict: op time before after,
# and "undoes ID" for a plain rewind; before and after are the active sets on either side of the switch;
# "data" for a toss, added by amend once its question is answered).
# Entries are never deleted by a rewind.  The newest HISTORY (200) are kept; the cursor's entry is kept
# too, even when it is older than that.
#
# data/history.cursor: the id of the change the next plain kit rewind takes back ("" or missing: none).
#   - a grab, toss or rewind-kit moves the cursor to its own entry;
#   - a plain rewind applies the cursor entry's before, logs "undoes CURSOR", and moves the cursor to the
#     next older change that is not a rewind and not already undone (Walk).  There is no redo.
# The entry and the cursor are staged in staging/<id>/ before the switch and moved into place in After,
# so recovery finishes or undoes them with the switch, the same as the active set.
namespace eval ::kit::txn { variable HISTORY 200 ; variable HISTORY_LOCAL 3 }

# Moves a switched transaction's log entry and cursor into place (idempotent: recovery runs it again),
# then keeps the newest HISTORY entries.
proc ::kit::txn::History {id} {
    file mkdir [::kit::path data history]
    set h [::kit::path staging $id history]
    if {[file exists $h]} { file rename -force $h [::kit::path data history $id] }
    set c [::kit::path staging $id cursor]
    if {[file exists $c]} { file rename -force $c [::kit::path data history.cursor] }
    Trim
}

# Drops the entries older than the newest HISTORY, except the cursor's entry.
proc ::kit::txn::Trim {} {
    variable HISTORY
    set cur [cursor]
    foreach old [lrange [history] $HISTORY end] {
        if {$old ne $cur} { file delete [::kit::path data history $old] }
    }
}

# History entry ids, newest first.  (Not `apply` in a lambda here: this namespace has its own apply.)
proc ::kit::txn::history {} {
    set ids [lmap f [glob -nocomplain -tails -directory [::kit::path data history] *] { if {![regexp {^[0-9]+-[0-9]+$} $f]} continue ; set f }]
    return [lsort -decreasing -command ::kit::txn::IdOrder $ids]
}
proc ::kit::txn::IdOrder {a b} {
    lassign [split $a -] ta pa ; lassign [split $b -] tb pb
    return [expr {$ta != $tb ? ($ta < $tb ? -1 : 1) : ($pa < $pb ? -1 : ($pa > $pb))}]
}
proc ::kit::txn::entry {id} { return [::kit::slurp [::kit::path data history $id] utf-8] }

# What a change's log entry says beyond its sets, recorded after its switch: toss's answer to "Also remove
# its data?" is "data {NAME kept|removed ...}" (the Kit-Bar-4 history's "· data kept").  The entry is
# replaced by a rename, so it is the old or the new one, never half; a change that logged nothing (a first
# start, a rollback) or whose entry is gone is left alone.  -> 1 when the entry was changed.
proc ::kit::txn::amend {id key value} {
    if {$id eq "" || [catch {entry $id} e]} { return 0 }
    dict set e $key $value
    ::kit::spit [::kit::path data history $id] $e
    ::kit::durable [::kit::path data history $id]
    return 1
}

# The id a plain kit rewind takes back next: "" when there is none (or its entry has been trimmed).
proc ::kit::txn::cursor {} {
    if {[catch {::kit::slurp [::kit::path data history.cursor] utf-8} c]} { return "" }
    set c [string trim $c]
    if {![regexp {^[0-9]+-[0-9]+$} $c] || ![file exists [::kit::path data history $c]]} { return "" }
    return $c
}

# The undo walk: the change entries older than FROM (newest first) that a plain rewind can still take back.
# Rewind entries are skipped (they are the undoing, not something to undo), and so is any change that a
# rewind already undid.  FROM "" walks the whole log.
proc ::kit::txn::Walk {from} {
    set undone [dict create]
    set ids [history]
    foreach id $ids {
        if {[catch {entry $id} e]} continue
        if {[dict exists $e undoes]} { dict set undone [dict get $e undoes] 1 }
    }
    set out {}
    foreach id $ids {
        if {$from ne "" && [IdOrder $id $from] >= 0} continue
        if {[catch {entry $id} e]} continue
        if {[dict exists $e undoes] || [dict exists $undone $id]} continue
        lappend out $id
    }
    return $out
}

# The cursor a plain rewind of ID leaves: the next older change it can take back, or "".
proc ::kit::txn::Next {id} {
    set w [Walk $id]
    return [expr {[llength $w] ? [lindex $w 0] : ""}]
}

# The active set a history entry starts from (before its change), as store::parse reads it.
proc ::kit::txn::before {id} { return [::kit::store::parse [dict get [entry $id] before]] }

# "name version" -> root, for every kit that any history entry's set had: what kit rewind KIT and
# grab KIT@VERSION need to find an older version by its root when no index has it.
proc ::kit::txn::hints {} {
    set h [dict create]
    foreach id [history] {
        if {[catch {before $id} B]} continue
        dict for {key k} [dict get $B kits] { dict set h $key [dict get $k root] }
    }
    return $h
}

# Roots of the 3 changes nearest the cursor (the cursor's entry and the ones a rewind walks to next):
# kept by the store's GC, so the next rewinds need no download.
proc ::kit::txn::historyRoots {} {
    variable HISTORY_LOCAL
    set cur [cursor]
    if {$cur eq ""} { return {} }
    set out {}
    foreach id [lrange [linsert [Walk $cur] 0 $cur] 0 [expr {$HISTORY_LOCAL - 1}]] {
        if {[catch {entry $id} e]} continue
        lappend out {*}[regexp -all -inline {[0-9a-f]{64}} [dict get $e before]]
    }
    return $out
}
