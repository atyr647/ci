# ui.tcl -- the one function that draws every plan and asks every question (KIT-CLI.md, "The
# prompt").  grab, check and toss's data question all go through ::kit::ui::ask; the GUI and the
# automatic updater pass their own renderer and get the same rows and the same question.
#
#   ::kit::ui::ask rows question default    -> 1 (yes) or 0 (no)
#   ::kit::ui::question rows                -> "Install?", "Update?", "Install N and update M?"
#   ::kit::ui::tell rows lines              what happened (grab's summary): rows, then lines
#
# A row is a dict: name old new action (install|update|remove|done) bytes tags; a done row says
# what happened to version `old` in `new` ("switched").  A renderer is a command prefix, called as
#   {*}$renderer show rows question default answer   answer "" (ask) or the --yes answer: returns 1 or 0
#   {*}$renderer tell rows lines extra ""    extra: a dict of what the lines say as data (stale, restart), for GUIs
# ::kit::ui::lines turns rows into the terminal's text, which other renderers may reuse.
# A row may carry a note (a warning, e.g. a version whose data is older than the installed one's): the terminal
# prints it under the row, and --tcl carries it as the row's note.

namespace eval ::kit::ui {
    variable renderer ::kit::ui::term
    variable yes 0         ;# --yes: every question is answered yes
    variable planned 0     ;# --tcl asked and was not answered: the plan was printed, nothing done
    variable extra {}      ;# what --tcl adds to the plan (annotate)
}

proc ::kit::ui::question {rows} {
    set ni 0 ; set nu 0 ; set restart 0
    foreach r $rows {
        switch -- [dict get $r action] { install { incr ni } update { incr nu } }
        if {"restart" in [dict get $r tags]} { set restart 1 }
    }
    if {$nu == 0} { set q "Install?" } elseif {$ni == 0} { set q "Update?" } else { set q "Install $ni and update $nu?" }
    # system kits switch at the next boot (SYSTEM-UPDATES.md section 6)
    if {$restart} { append q " (takes effect at restart)" }
    return $q
}

# --yes answers a [Y/n] question yes; a [y/N] one (toss's data question) takes its default, no:
# removing someone's data is only ever an explicit, typed yes.
proc ::kit::ui::ask {rows question default} {
    variable renderer ; variable yes
    return [{*}$renderer show $rows $question $default [expr {$yes ? ($default ? 1 : 0) : ""}]]
}

proc ::kit::ui::tell {rows lines {extra {}}} {
    variable renderer
    {*}$renderer tell $rows $lines $extra ""
}

# The rows as the terminal shows them:
#   "  firefox      134.0.1 → 134.0.2     12 MB"
#   "  obs          new       31.0.1      88 MB"
#   "  obs          31.0.1    removed"         (remove; done rows: "  mesa  25.2.8  switched")
proc ::kit::ui::lines {rows} {
    set wn 12 ; set wo 7 ; set wv 7
    foreach r $rows {
        set wn [expr {max($wn, [string length [dict get $r name]])}]
        if {[dict get $r action] ne "install"} { set wo [expr {max($wo, [string length [dict get $r old]])}] }
        if {[dict get $r action] ni {remove done}} { set wv [expr {max($wv, [string length [dict get $r new]])}] }
    }
    set out {}
    foreach r $rows {
        set line [format "  %-*s " $wn [dict get $r name]]
        switch -- [dict get $r action] {
            install { append line [format "%-*s" [expr {$wo + 3}] new] }
            update  { append line [format "%-*s → " $wo [dict get $r old]] }
            remove - done { append line [format "%-*s" [expr {$wo + 3}] [dict get $r old]] }
        }
        if {[dict get $r action] in {remove done}} {
            append line [dict get $r new]
        } else {
            append line [format "%-*s%10s" $wv [dict get $r new] [expr {[dict get $r bytes] eq "" ? "" : [::kit::fmtsize [dict get $r bytes]]}]]
        }
        if {[llength [dict get $r tags]]} { append line "   [join [dict get $r tags] { }]" }
        lappend out [string trimright $line]
        # a warning under the row (plan.tcl DataNote), aligned with the versions
        if {[dict exists $r note] && [dict get $r note] ne ""} { lappend out [format "  %-*s %s" $wn "" [dict get $r note]] }
    }
    return $out
}

# The terminal renderer: rows on stdout, then the question; the answer read from stdin.
proc ::kit::ui::term {op rows question default answer} {
    foreach l [lines $rows] { puts $l }
    if {$op eq "tell"} { foreach l $question { puts $l } ; flush stdout ; return 1 }
    if {$question eq ""} { flush stdout ; return 1 }
    set hint [expr {$default ? {[Y/n]} : {[y/N]}}]
    if {$answer ne ""} { puts "$question $hint [expr {$answer ? "y" : "n"}]" ; flush stdout ; return $answer }
    while {1} {
        puts -nonewline "$question $hint "
        flush stdout
        if {[gets stdin a] < 0} { puts "" ; return 0 }
        # read from a pipe, not typed: show the answer, so the transcript reads like a terminal
        if {![dict exists [fconfigure stdin] -mode]} { puts $a }
        set a [string tolower [string trim $a]]
        if {$a eq ""} { return $default }
        if {$a in {y yes}} { return 1 }
        if {$a in {n no}} { return 0 }
    }
}

# The updater's renderer: nobody to ask; it logs the plan and takes the given answer.
proc ::kit::ui::log {op rows question default answer} {
    foreach l [lines $rows] { puts stderr "kit-updater: [string trim $l]" }
    if {$op eq "tell"} { foreach l $question { puts stderr "kit-updater: $l" } ; return 1 }
    return [expr {$answer eq "" ? 0 : $answer}]
}

# The GUI's renderer (--tcl, for check and rewind only; docs/KIT-CLI.md, "Exit codes and scripting"): the shell's
# updates panel is the prompt, so nothing is asked.  Each call prints one line, a Tcl list "KIND DICT":
#   plan {rows ROWS question Q ...}   asked without --yes: the plan, and nothing is done (exit 0)
#   done {rows ROWS lines LINES stale S restart R time T}     what happened (grab's summary)
# With --yes the plan is not printed and the question is answered yes.
proc ::kit::ui::tcl {op rows question default answer} {
    variable extra ; variable planned
    if {$op eq "tell"} {
        puts [list done [dict merge $default [dict create rows $rows lines $question time [::kit::now]]]]
        flush stdout
        return 1
    }
    if {$answer ne ""} { return $answer }
    puts [list plan [dict merge $extra [dict create rows $rows question $question]]]
    flush stdout
    set planned 1
    return 0
}
proc ::kit::ui::gui {} { variable renderer ; return [expr {$renderer eq "::kit::ui::tcl"}] }
# a fact the GUI's plan carries beside the rows (the index's age, the history); a no-op otherwise
proc ::kit::ui::annotate {key value} { variable extra ; if {[gui]} { dict set extra $key $value } }
