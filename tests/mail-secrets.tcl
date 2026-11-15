# mail-secrets.tcl - Mail's Secret Service client (apps/mail/secrets.tcl) against tests/mail-secret-service.tcl on a
# private dbus-daemon: a password saved and read back (UTF-8, quotes), replaced, cleared; a locked collection opened
# through the provider's prompt; a dismissed prompt; a store with no default collection; no provider at all.
# With RIBBON_TEST_GNOME_KEYRING=1 and gnome-keyring-daemon present, the round trip also runs against a real
# gnome-keyring on its own bus. Prints "ok ..." lines and "secrets: ok" at the end; any failure exits 1.
#   tclsh8.6 tests/mail-secrets.tcl   (unix_extra on TCLLIBPATH)

set here [file dirname [file normalize [info script]]]
set repo [file dirname $here]
set files [file join $repo srcpkgs ribbon-desktop files]
lappend auto_path $files
package require ribbon::dbus
source -encoding utf-8 [file join $files apps mail secrets.tcl]

set fails 0
set pids {}
proc ok {cond what} {
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr ::fails }
}
proc code_of {script} {
	if {[catch {uplevel 1 $script} r o]} { return [lindex [dict get $o -errorcode] 1] }
	return ""
}

# a private bus; its address in the environment for the stand-in
proc newbus {} {
	set fh [open |[list dbus-daemon --config-file=[file join $::here mail-fixtures session-bus.conf] --nofork --print-address=1] r]
	lappend ::pids {*}[pid $fh]
	gets $fh addr
	set ::busfh $fh
	return $addr
}
proc standin {addr args} {
	set ::env(DBUS_SESSION_BUS_ADDRESS) $addr
	set fh [open |[list [info nameofexecutable] [file join $::here mail-secret-service.tcl] {*}$args 2>@stderr] r]
	lappend ::pids {*}[pid $fh]
	fconfigure $fh -blocking 1
	if {[gets $fh line] < 0 || $line ne "ready"} { puts "  FAIL the stand-in did not start"; exit 1 }
	return $fh
}
proc stop {fh} {
	foreach p [pid $fh] { catch {exec kill $p} }
	catch {close $fh}
}
proc dump {} {
	set b [ribbon::dbus::connect $::env(DBUS_SESSION_BUS_ADDRESS)]
	set r [lindex [$b call org.freedesktop.secrets /org/ribbon/test org.ribbon.Test Dump] 0]
	$b close
	return $r
}
proc calls {} {
	set b [ribbon::dbus::connect $::env(DBUS_SESSION_BUS_ADDRESS)]
	set r [lindex [$b call org.freedesktop.secrets /org/ribbon/test org.ribbon.Test Calls] 0]
	$b close
	return $r
}
proc cleanup {} { foreach p $::pids { catch {exec kill $p} } }

after 60000 {puts "  FAIL timed out"; cleanup; exit 1}

set A [dict create xdg:schema org.ribbon.Mail account maya@lind.page]
set pw "pa ss\"wörd ☃"

# ---- an unlocked login collection ----
set addr [newbus]
mail::secrets::address $addr
ok {![mail::secrets::available]} "no provider on the bus: not available"
ok {[code_of {mail::secrets::lookup $A}] eq "service"} "no provider: a service error, not a hang"
set s [standin $addr]
mail::secrets::address $addr
ok {[mail::secrets::available]} "a provider on the bus: available"
mail::secrets::store $A "Mail: maya@lind.page" $pw
ok {[mail::secrets::lookup $A] eq $pw} "a password saved is read back the same (UTF-8, quote, space)"
set d [dump]
ok {[llength $d] == 1 && [dict get [lindex $d 0 0] account] eq "maya@lind.page" && [lindex $d 0 1] eq "Mail: maya@lind.page"} \
	"the item has the account's attributes and label"
mail::secrets::store $A "Mail: maya@lind.page" second
ok {[llength [dump]] == 1 && [mail::secrets::lookup $A] eq "second"} "saving again replaces the item (one item)"
set B [dict create xdg:schema org.ribbon.Mail account maya@hearth.studio]
ok {[code_of {mail::secrets::lookup $B}] eq "none"} "another account has no password: a none error"
mail::secrets::store $B "Mail: maya@hearth.studio" third
ok {[mail::secrets::lookup $A] eq "second" && [mail::secrets::lookup $B] eq "third"} "two accounts keep their own passwords"
mail::secrets::clear $A
ok {[code_of {mail::secrets::lookup $A}] eq "none" && [mail::secrets::lookup $B] eq "third"} "clear removes only that account's item"
ok {"GetSecrets" in [calls] && "Prompt" ni [calls]} "an unlocked store answers without a prompt"
stop $s

# ---- a locked collection: the provider's prompt unlocks it ----
set s [standin $addr -locked 1]
mail::secrets::address $addr
mail::secrets::store $A "Mail: maya@lind.page" $pw
ok {"Unlock" in [calls] && "Prompt" in [calls]} "saving into a locked collection asks the provider to unlock it (Prompt)"
ok {[mail::secrets::lookup $A] eq $pw} "and the password is read back"
stop $s
set s [standin $addr -locked 1 -dismiss 1]
mail::secrets::address $addr
ok {[code_of {mail::secrets::store $A x y}] eq "dismissed"} "a dismissed unlock prompt is a dismissed error"
ok {[llength [dump]] == 0} "and nothing is saved"
stop $s

# ---- no default collection: one is made ----
set s [standin $addr -nodefault 1]
mail::secrets::address $addr
mail::secrets::store $A "Mail: maya@lind.page" $pw
ok {"CreateCollection" in [calls] && [mail::secrets::lookup $A] eq $pw} "a store with no default collection gets one, then keeps the password"
stop $s

# ---- a real gnome-keyring, when asked for and present ----
if {[info exists ::env(RIBBON_TEST_GNOME_KEYRING)] && [auto_execok gnome-keyring-daemon] ne ""} {
	set addr2 [newbus]
	set ::env(DBUS_SESSION_BUS_ADDRESS) $addr2
	set kdir [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] mailsecrets[pid]]
	file mkdir $kdir
	set ::env(XDG_DATA_HOME) $kdir
	set ::env(XDG_RUNTIME_DIR) $kdir
	set fh [open |[list gnome-keyring-daemon --unlock --foreground --components=secrets 2>@stderr] r+]
	lappend pids {*}[pid $fh]
	puts -nonewline $fh "test"; close $fh write
	mail::secrets::address $addr2
	for {set i 0} {$i < 50 && ![mail::secrets::available]} {incr i} { after 100 }
	mail::secrets::store $A "Mail: maya@lind.page" $pw
	ok {[mail::secrets::lookup $A] eq $pw} "gnome-keyring: a password saved is read back"
	mail::secrets::clear $A
	ok {[code_of {mail::secrets::lookup $A}] eq "none"} "gnome-keyring: and cleared"
	file delete -force $kdir
}

cleanup
if {$fails} { puts "secrets: $fails failed"; exit 1 }
puts "secrets: ok"
exit 0
