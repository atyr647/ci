# updater.tcl -- the background refresh and update check (KIT-CLI.md, "Automatic, so nobody has
# to remember"; K1, K3).  Runs as a per-user dinit service (kit-updater).
#
# Settings, in ~/.config/kit/updates.conf (what Settings writes; kit-updater --set checks the values):
#   notify = yes          show waiting updates in the bar (cache/updates: notify 1)
#   download = no         fetch and verify updates in the background, so Update is instant
#   install = off         or HH:MM: install waiting updates then, when the machine is awake and idle
#   interval = 6h         how often to refresh: 1h to 7d (s, m, h, d)
#
# Every cycle: nothing while the index is pinned; skip on a metered connection or on battery below
# 20 % (where that can be detected: NetworkManager over D-Bus, /sys/class/power_supply); refresh the
# index with a conditional request; compare it with what is installed (cache/updates, which the bar
# and `kit list` read); then download and install as the settings say, through grab's machinery.

namespace eval ::kit::updater {
    variable defaults {notify yes download no install off interval 6h}
}

proc ::kit::updater::log {msg} { puts stderr "kit-updater: $msg" }

proc ::kit::updater::settingsFile {} { return [::kit::path config updates.conf] }

proc ::kit::updater::settings {} {
    variable defaults
    set s $defaults
    if {![catch {::kit::slurp [settingsFile] utf-8} text]} {
        foreach line [split $text \n] {
            if {[regexp {^\s*([a-z]+)\s*=\s*(.*?)\s*$} $line -> k v] && [dict exists $defaults $k] && [valid $k $v] eq ""} { dict set s $k $v }
        }
    }
    return $s
}

# "" if the value is fine, else why not
proc ::kit::updater::valid {k v} {
    switch -- $k {
        notify - download { if {[string tolower $v] ni {yes no on off true false 1 0}} { return "$k is yes or no" } }
        install { if {$v ne "off" && ![regexp {^([01][0-9]|2[0-3]):[0-5][0-9]$} $v]} { return "install is off or a time HH:MM" } }
        interval {
            if {[catch {seconds $v} n]} { return $n }
            if {$n < 3600 || $n > 7 * 86400} { return "interval is 1 hour to 7 days" }
        }
        default { return "unknown setting $k (notify, download, install, interval)" }
    }
    return ""
}
proc ::kit::updater::seconds {v} {
    if {![regexp {^([0-9]+)\s*([smhd]?)$} $v -> n u]} { error "an interval looks like 6h, 90m or 2d" }
    return [expr {$n * [dict get {"" 1 s 1 m 60 h 3600 d 86400} $u]}]
}

proc ::kit::updater::change {pairs} {
    set s [settings]
    foreach p $pairs {
        if {![regexp {^([a-z]+)=(.*)$} $p -> k v]} { ::kit::fail 2 "expected KEY=VALUE, not $p" }
        set why [valid $k $v]
        if {$why ne ""} { ::kit::fail 2 $why }
        dict set s $k $v
    }
    set out "# kit's automatic updates (docs/KIT-CLI.md); written by Settings and kit-updater --set\n"
    dict for {k v} $s { append out "$k = $v\n" }
    ::kit::spit [settingsFile] $out
}

# ---- conditions ---------------------------------------------------------------------------------------
# Metered: NetworkManager's Metered property (1 yes, 3 guess-yes).  Unknown counts as not metered.
proc ::kit::updater::metered {} {
    if {[auto_execok dbus-send] eq ""} { return 0 }
    if {[catch {exec dbus-send --system --print-reply=literal --reply-timeout=2000 --dest=org.freedesktop.NetworkManager \
            /org/freedesktop/NetworkManager org.freedesktop.DBus.Properties.Get \
            string:org.freedesktop.NetworkManager string:Metered 2>/dev/null} out]} { return 0 }
    return [expr {[lindex $out end] in {1 3}}]
}

# On battery below 20 %: no supply online and every battery that reports a capacity under 20 and
# not charging.  Machines without batteries are never "low".
proc ::kit::updater::lowBattery {} {
    set base [file join [::kit::env KIT_SYSFS /sys] class power_supply]
    set low 0 ; set battery 0
    foreach d [glob -nocomplain -directory $base *] {
        set type "" ; catch {set type [string trim [::kit::slurp $d/type utf-8]]}
        if {$type in {Mains USB}} {
            if {![catch {string trim [::kit::slurp $d/online utf-8]} on] && $on eq "1"} { return 0 }
        } elseif {$type eq "Battery"} {
            set battery 1
            if {[catch {string trim [::kit::slurp $d/capacity utf-8]} cap]} continue
            set status "" ; catch {set status [string trim [::kit::slurp $d/status utf-8]]}
            if {$cap < 20 && $status ni {Charging Full}} { set low 1 } else { return 0 }
        }
    }
    return [expr {$battery && $low}]
}

# Awake and idle: the one-minute load average under 1.
proc ::kit::updater::idle {} {
    if {[catch {::kit::slurp [file join [::kit::env KIT_PROC /proc] loadavg] utf-8} l]} { return 1 }
    return [expr {[lindex $l 0] < 1.0}]
}

proc ::kit::updater::skipWhy {} {
    if {[metered]} { return "the connection is metered" }
    if {[lowBattery]} { return "the battery is below 20 %" }
    return ""
}

# ---- one cycle -------------------------------------------------------------------------------------
# Returns the seconds until the next refresh.
proc ::kit::updater::cycle {} {
    ::kit::readConf
    set s [settings]
    set interval [seconds [dict get $s interval]]
    if {[::kit::pinned] ne ""} { log "the index is pinned to [::kit::pinned]: background refresh is off" ; return $interval }
    set why [skipWhy]
    if {$why ne ""} { log "skipped: $why" ; return 900 }
    ::kit::txn::recover
    set ::kit::repo::I ""
    if {[catch {::kit::repo::ensure 0} I]} { log "no index: $I" ; return 300 }
    if {[dict exists $I offline]} { log "offline: will try again" ; return 300 }
    set A [::kit::store::load]
    Save $A $I $s
    set pairs [::kit::plan::updates $A $I]
    log "[llength $pairs] update[expr {[llength $pairs] == 1 ? "" : "s"}] waiting"
    if {[llength $pairs] && [::kit::truthy [dict get $s download]]} {
        if {[catch {
            set P [::kit::plan::update $A $I $pairs]
            ::kit::repo::fetchChunks [dict get $P fetch] [dict get $P sizes]
        } err]} { log "download failed: $err" } else { log "downloaded and verified: [llength [dict get $P fetch]] chunks" }
    }
    systemCheck
    return $interval
}

# The base's own packages, checked on the same schedule and under the same conditions (not metered, not on a low
# battery, index not pinned), so the bar's chip and Settings' rail count them without anyone opening a panel first.
# `ribbon-update --tcl` plans without root and leaves what waits in ~/.cache/ribbon/system-updates (the form kit's
# own cache has); the bar sums both files.  A failure (no network yet, the package manager busy) only costs this
# cycle: the next one asks again.  KIT_RIBBON_UPDATE names another command (tests).
proc ::kit::updater::systemCheck {} {
    set exe [::kit::env KIT_RIBBON_UPDATE ""]
    if {$exe eq ""} { set exe [auto_execok ribbon-update] }
    if {$exe eq ""} { return }
    if {[auto_execok timeout] ne ""} { set cmd [list timeout 300 {*}$exe --tcl] } else { set cmd [list {*}$exe --tcl] }
    if {[catch {exec sh -c {exec "$@" 2>&1} sh {*}$cmd </dev/null} out]} {
        # exec adds its own "child process exited abnormally" after the command's words: the words are the reason
        set out [string trim [regsub {(^|\n)child process exited abnormally$} [string trim $out] {}]]
        log "system packages: not checked ([expr {$out eq "" ? "ribbon-update failed" : [lindex [split $out \n] end]}])"
        return
    }
    set out [string trim $out]
    if {[string match "plan *" $out] && ![catch {dict get [lindex $out 1] rows} rows]} {
        log "system packages: [llength $rows] waiting"
    } else {
        log "system packages: [expr {$out eq "" ? "nothing waiting" : [lindex [split $out \n] end]}]"
    }
}

proc ::kit::updater::Save {A I s} {
    ::kit::verbs::saveUpdates $A $I
    set U [::kit::verbs::loadUpdates]
    dict set U notify [::kit::truthy [dict get $s notify]]
    ::kit::spit [::kit::path cache updates] $U
}

# The install time today (or tomorrow, once today's has been done), in seconds.
proc ::kit::updater::installAt {s} {
    set t [dict get $s install]
    if {$t eq "off"} { return "" }
    set today [clock format [::kit::now] -format %Y-%m-%d]
    set at [clock scan "$today $t" -format "%Y-%m-%d %H:%M"]
    if {[State last-install] eq $today} { set at [clock add $at 1 day] }
    return $at
}

proc ::kit::updater::State {key {value ""}} {
    set f [::kit::path cache updater.state]
    set d {} ; catch {set d [::kit::slurp $f utf-8]} ; if {[catch {dict size $d}]} { set d {} }
    if {$value ne ""} { dict set d $key $value ; ::kit::spit $f $d ; return $value }
    return [expr {[dict exists $d $key] ? [dict get $d $key] : ""}]
}

# At the install time: if the machine is idle, install what waits (downloading what isn't yet).
# Returns 1 when done for today, 0 to try again shortly.
proc ::kit::updater::install {} {
    set s [settings]
    set why [skipWhy]
    if {$why ne ""} { log "install postponed: $why" ; return 0 }
    if {![idle]} { log "install postponed: the machine is busy" ; return 0 }
    ::kit::txn::recover
    set ::kit::repo::I ""
    if {[catch {::kit::repo::ensure 3600} I]} { log "install postponed: $I" ; return 0 }
    set A [::kit::store::load]
    set pairs [::kit::plan::updates $A $I]
    set rc 0
    if {[llength $pairs]} {
        set ::kit::ui::renderer ::kit::ui::log
        set ::kit::ui::yes 1
        set rc [catch {
            set P [::kit::plan::update $A $I $pairs]
            ::kit::ui::ask [dict get $P rows] [::kit::ui::question [dict get $P rows]] 1
            ::kit::plan::execute $P grab
            ::kit::verbs::Summary $P
        } err]
        if {$rc} { log "install failed: $err" } else { log "installed [llength $pairs] update[expr {[llength $pairs] == 1 ? "" : "s"}]; running apps switch at their next start" }
    }
    Save [::kit::store::load] $I $s
    if {$rc} { return 0 }
    State last-install [clock format [::kit::now] -format %Y-%m-%d]
    return 1
}

# Is the install time due now?  (within six hours of it: a machine that slept through the whole
# window waits for the next day rather than installing in the middle of the afternoon)
proc ::kit::updater::due {s} {
    set at [installAt $s]
    if {$at eq "" || [::kit::now] < $at} { return 0 }
    if {[::kit::now] - $at > 6 * 3600} { State last-install [clock format [::kit::now] -format %Y-%m-%d] ; return 0 }
    return 1
}

# The service: shortly after login (once the network is up), then every interval; installs at
# the set time.  Settings are read again every cycle, so a change applies without a restart.
proc ::kit::updater::loop {delay} {
    set next [expr {[::kit::now] + $delay}]
    set retry 0
    while {1} {
        set s [settings]
        set at [installAt $s]
        if {$at ne "" && $at < $retry} { set at $retry }
        set wake [expr {$at ne "" && $at < $next ? $at : $next}]
        after [expr {max(1, min($wake - [::kit::now], 600)) * 1000}]
        if {[::kit::now] >= $retry && [due $s]} {
            set retry [expr {[install] ? 0 : [::kit::now] + 600}]
        }
        if {[::kit::now] >= $next} {
            set next [expr {[::kit::now] + [cycle]}]
        }
    }
}
