# kitdc.tcl -- kit's way to kitd (bin/kitd, org.ribbon.Kit1): a verb on system kits runs in kitd's system scope, as root, and
# this is the client side.  A person never names kitd or a scope: scope.tcl decides from the kits' own (signed) kind that a verb
# concerns system kits, and hands it here.
#
#   ::kit::kitdc::run WORDS      WORDS is a verb and its arguments.  kitd's worker plans it and waits (Start); the plan is
#                                shown as kit shows any plan (rows, then the question) and answered as kit's prompt is (or
#                                by --yes); a yes is authorized by polkit at that moment, for this person (Answer); then the
#                                transaction is followed, its output printed as it grows.  Returns the verb's exit code
#                                (docs/KIT-CLI.md): 1 when the answer was no, 2 usage, 3 no kitd or no network, 4 verification.
#   ::kit::kitdc::reachable      is there a system bus to ask kitd on (a quick look at its socket, not a call)
#
# What kitd does with it is kitd's own business: it fetches and verifies its own index, plans in system scope, and refuses
# what is not a system kit; nothing of what this process thinks (the kind it routed by, the plan it was shown) is trusted by
# it: the plan that is carried out is the one its worker holds.
# Environment (the tests'): KITD_BUS a bus address (default: the system bus); KITD_POLL milliseconds between polls.

namespace eval ::kit::kitdc {
    variable verbs {grab check toss rewind mend list info}
    variable here [file dirname [file normalize [info script]]]   ;# only known while this file is read
    variable bus ""
}

# ribbon::dbus: installed with the desktop (/usr/lib/ribbon), or beside it in the source tree
proc ::kit::kitdc::Dbus {} {
    if {![catch {package present ribbon::dbus}]} return
    variable here
    set tree [file dirname [file dirname [file dirname $here]]]   ;# srcpkgs, from srcpkgs/ribbon-kit/files/lib
    foreach d [list /usr/lib/ribbon [file join $tree ribbon-desktop files]] {
        if {[file isdirectory $d] && $d ni $::auto_path} { lappend ::auto_path $d }
    }
    if {[catch {package require ribbon::dbus} why]} {
        ::kit::fail 2 "talking to kitd needs ribbon::dbus (the desktop's D-Bus client): $why"
    }
}

# Is there a system bus to ask?  (The address, or its socket on disk; a bus that is there and a kitd that does not answer
# are found out by the call itself.)
proc ::kit::kitdc::reachable {} {
    set addr [::kit::env KITD_BUS [::kit::env DBUS_SYSTEM_BUS_ADDRESS unix:path=/run/dbus/system_bus_socket]]
    if {$addr eq "system"} { set addr unix:path=/run/dbus/system_bus_socket }
    if {[regexp {unix:path=([^,]+)} $addr -> sock]} { return [file exists $sock] }
    return 1
}

proc ::kit::kitdc::Connect {} {
    variable bus
    if {$bus ne ""} { return $bus }
    Dbus
    if {[catch {ribbon::dbus::connect [::kit::env KITD_BUS system]} b]} { ::kit::fail 3 "no system bus to ask kitd on: $b" }
    return [set bus $b]
}

proc ::kit::kitdc::Call {member sig args} {
    variable bus
    set K {org.ribbon.Kit1 /org/ribbon/Kit1 org.ribbon.Kit1}
    # interactive: polkit may ask for the password; -timeout 0: for as long as the person takes
    if {[catch {$bus call -interactive 1 -timeout 0 {*}$K $member $sig {*}$args} r opts]} {
        set name [lindex [dict get $opts -errorcode] 1]
        switch -- $name {
            org.freedesktop.DBus.Error.AccessDenied { ::kit::fail 1 "not allowed: $r" }
            org.freedesktop.DBus.Error.InvalidArgs { ::kit::fail 2 $r }
            org.ribbon.Kit1.Error.NotAsking { ::kit::fail 1 $r }
            default { ::kit::fail 3 "kitd could not be asked: $r" }
        }
    }
    return $r
}

proc ::kit::kitdc::run {words} {
    variable verbs ; variable bus
    if {![llength $words] || [lindex $words 0] ni $verbs} {
        ::kit::fail 2 "kitd runs [join $verbs {, }], not \"[lindex $words 0]\""
    }
    Connect
    set rc [catch {Run $words} res opts]
    catch {$bus close} ; set bus ""
    if {$rc} { return -options $opts $res }
    return $res
}

proc ::kit::kitdc::Run {words} {
    set id [lindex [Call Start as $words] 0]
    set seen 0 ; set code 2 ; set answered 0
    set poll [::kit::env KITD_POLL 300]
    while 1 {
        if {[catch {$::kit::kitdc::bus call org.ribbon.Kit1 /org/ribbon/Kit1 org.ribbon.Kit1 Job s $id} j]} {
            ::kit::fail 3 "kitd stopped answering for transaction $id: $j"
        }
        lassign [lindex $j 0] state code lines
        foreach l [lrange $lines $seen end] { puts $l }
        set seen [llength $lines]
        if {$state eq "done"} break
        if {!$answered} {
            set text [lindex [Call Plan s $id] 0]
            if {$text ne ""} {
                set answered 1
                # the plan, as any plan: its rows, its question, the answer typed or --yes; kitd's polkit asks when it is yes
                set go [::kit::ui::ask [dict get $text rows] [dict get $text question] [dict get $text default]]
                if {[catch {Call Answer sb $id [expr {$go ? 1 : 0}]} err opts]} {
                    catch {Call Answer sb $id 0}   ;# a refused authorization is a no: the worker is not left waiting (caught: it may fail too)
                    return -options $opts $err
                }
            }
        }
        after $poll
    }
    return $code
}
