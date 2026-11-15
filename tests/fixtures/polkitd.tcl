# polkitd.tcl - a stand-in for polkitd (tests/steps.d/70-polkit.sh): the Authority side the agent talks to,
# and the caller of BeginAuthentication / CancelAuthentication. It owns org.freedesktop.PolicyKit1 on
# DBUS_SYSTEM_BUS_ADDRESS (a private bus here). Commands on stdin, one per line; events on stdout.
#   begin TAG COOKIE IDENTITIES   BeginAuthentication on the registered agent. IDENTITIES: user:UID,group:GID
#   cancel COOKIE                 CancelAuthentication
#   quit                          leave (the name goes with the process)
# Events: "registered SENDER SESSION LOCALE PATH", "unregistered", "response2 UID COOKIE",
#         "begun TAG ok" or "begun TAG error NAME", "cancelled COOKIE ok|error NAME".
lappend auto_path [file join [file dirname [file normalize [info script]]] .. .. srcpkgs ribbon-desktop files]
package require ribbon::dbus
fconfigure stdout -buffering line
proc ev {args} { puts $args }
set bus [ribbon::dbus::connect system]
set agent {}
set A /org/freedesktop/PolicyKit1/Authority
set I org.freedesktop.PolicyKit1.Authority

proc Register {msg subject locale path} {
	global agent
	set s [ribbon::dbus::strip (sa{sv}) $subject]
	set agent [list [dict get $msg sender] $path]
	ev registered [dict get $msg sender] [dict get [lindex $s 1] session-id] $locale $path
	return
}
proc Unregister {msg subject path} { ev unregistered; return }
proc Response2 {msg uid cookie identity} { ev response2 $uid $cookie; return }

$bus export $A $I {
	method RegisterAuthenticationAgent (sa{sv})so "" Register
	method UnregisterAuthenticationAgent (sa{sv})o "" Unregister
	method AuthenticationAgentResponse2 us(sa{sv}) "" Response2
}
if {[$bus request org.freedesktop.PolicyKit1] ne "primary"} { ev error cannot own the name; exit 1 }
ev ready

proc Done {tag status values} {
	if {$status eq "ok"} { ev begun $tag ok } else { ev begun $tag error [lindex $values 0] }
}
proc DoneCancel {cookie status values} {
	if {$status eq "ok"} { ev cancelled $cookie ok } else { ev cancelled $cookie error [lindex $values 0] }
}

proc command {line} {
	global bus agent
	set words [split $line " "]
	switch -- [lindex $words 0] {
		begin {
			lassign $words - tag cookie idl
			set ids {}
			foreach i [split $idl ,] {
				lassign [split $i :] kind n
				if {$kind eq "user"} { lappend ids [list unix-user [list uid [list u $n]]] } else { lappend ids [list unix-group [list gid [list u $n]]] }
			}
			lassign $agent name path
			$bus call -command [list Done $tag] -timeout 0 $name $path org.freedesktop.PolicyKit1.AuthenticationAgent BeginAuthentication \
				sssa{ss}sa(sa{sv}) org.ribbon.test.action "Authentication is needed to test" "dialog-password" {polkit.caller-pid 4242} $cookie $ids
		}
		cancel {
			lassign $agent name path
			set cookie [lindex $words 1]
			$bus call -command [list DoneCancel $cookie] $name $path org.freedesktop.PolicyKit1.AuthenticationAgent CancelAuthentication s $cookie
		}
		quit { exit 0 }
	}
}
fileevent stdin readable {
	if {[gets stdin line] < 0} { exit 0 }
	if {[catch {command $line} err]} { ev error [lindex [split $err \n] 0] }
}
vwait forever
