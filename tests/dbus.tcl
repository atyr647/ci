# dbus.tcl - tests for ribbon::dbus (srcpkgs/ribbon-desktop/files/dbus)
# against a private bus: run by tests/test-dbus.sh, which starts the
# dbus-daemons and sets DBUS_SESSION_BUS_ADDRESS (and RIBBON_DBUS_ANON, a
# bus that only takes ANONYMOUS). Prints "  ok   ..." per check and a few
# "  info ..." measurements; exits 1 if any check failed.

set here [file dirname [file normalize [info script]]]
# the programs driven here (notify-send, gdbus) take UTF-8 arguments
encoding system utf-8
set env(LC_ALL) C.UTF-8
proc rss {} { exec awk {/VmRSS/ {print $2}} /proc/[pid]/status }
set rss0 [rss]
lappend auto_path [file join $here .. srcpkgs ribbon-desktop files]
package require ribbon::dbus
set rss1 [rss]
catch {wm withdraw .}
# a stuck check fails the run instead of hanging it
after 120000 {puts "  FAIL the tests took more than 2 minutes"; exit 1}

set failed 0
proc ok {what} { puts "  ok   $what" }
proc bad {what why} { global failed; incr failed; puts "  FAIL $what: $why" }
proc check {what cond} {
	if {[catch {uplevel 1 [list expr $cond]} r]} { bad $what $r } elseif {$r} { ok $what } else { bad $what "not true: [uplevel 1 [list subst $cond]]" }
}
# a background error (a callback's) fails the run, rather than a dialog in wish
interp bgerror {} {apply {{msg opts} { bad "background error" "$msg\n[dict get $opts -errorinfo]" }}}
proc same {what got want} { if {$got eq $want} { ok $what } else { bad $what "got {$got}, want {$want}" } }
# The errorCode of a script that must fail.
proc fails {script} {
	if {![catch {uplevel 1 $script} err opts]} { return "no error" }
	return [dict get $opts -errorcode]
}
proc info_line {text} { puts "  info $text" }
proc nfds {} { llength [glob -nocomplain /proc/[pid]/fd/*] }
proc ms {us n} { format %.3f [expr {$us / 1000.0 / $n}] }

# Inside the test coroutine: sleep, wait for a condition, run a program
# without blocking the event loop (the bus connections live in this process).
proc sleep {ms} { after $ms [list [info coroutine]]; yield }
proc waitfor {cond {ms 3000}} {
	for {set t 0} {$t < $ms} {incr t 10} {
		if {[uplevel 1 [list expr $cond]]} { return 1 }
		sleep 10
	}
	return 0
}
proc program {args} {
	# through sh, as exec would take an argument like <'v'> for a redirection
	set f [open |[list sh -c "[join [lmap a $args { string cat ' [string map {' '\\''} $a] ' }]] 2>&1"] r]
	fconfigure $f -blocking 0
	set out ""
	fileevent $f readable [list [info coroutine]]
	while {1} {
		yield
		append out [read $f]
		if {[eof $f]} break
	}
	fconfigure $f -blocking 1
	set code [catch {close $f}]
	return [list $code [string trim $out]]
}

# ---- 1. the wire format, without a bus ------------------------------------
puts "wire format"
set u "h\u00e9llo \u2603 \u0444"
set cases [list \
	y 0 y 255 b 1 b 0 n -32768 n 32767 q 0 q 65535 i -2147483648 i 2147483647 \
	u 0 u 4294967295 x -9223372036854775808 x 9223372036854775807 t 0 t 18446744073709551615 \
	d 0.0 d -2.5 d 1.5e+300 d [expr {acos(-1)}] s "" s $u o / o /org/ribbon/A_1 g "" g a{sv}(iiay)v \
	h fdA ay "" ay "a\0b\xff" as {} as [list a "b c" $u] ax {} ax {1 -2 3} ad {0.5 -1.0} \
	a{sv} [dict create k1 {s v} k2 {i -1} k3 {as {x y}}] a{yd} {1 0.5 2 1.5} \
	a{oa(ii)} [dict create /a {{1 2} {3 4}} /b {}] (ixs) {7 -8 x} ((y)(d)) {1 2.0} \
	v {s hi} v {v {ai {1 2}}} v {a{sv} {a {b 1}}} av {{y 1} {(ss) {a b}} {ay xyz}} \
	aav {{} {{u 3}} {}} aay [list "" "\x00\x01" abc] a(ybx) {{1 1 -1} {2 0 2}} ah {fdA fdB}]
set n 0
foreach {sig value} $cases {
	foreach e {little big} {
		if {[catch {ribbon::dbus::unmarshal $sig [ribbon::dbus::marshal $sig [list $value] $e] $e {fdA fdB}} back]} {
			bad "$sig ($e)" $back
		} elseif {$back ne [list $value]} { bad "$sig ($e)" "got {$back}, want {[list $value]}" } else { incr n }
	}
}
check "$n round trips of every type, both byte orders" {$n == [llength $cases]}
set all ybnqiuxtdsogvasaya{sv}a{oa(ii)}(yx(sd)b)aava{yd}axaqav
set allv [list 7 1 -3 4 -5 6 -7 8 0.25 $u /x/y a{sv} {s v} {a b} "\x00\x80" {k {i 1}} {/p {{1 2}}} {1 2 {s 3.5} 0} \
	{{} {{i 1} {s x}}} {1 0.5} {9 -9} {1 65535} {{g ab} {o /}}]
foreach e {little big} {
	same "a 23-value message body ($e)" [ribbon::dbus::unmarshal $all [ribbon::dbus::marshal $all $allv $e] $e] $allv
}
# the bytes the specification gives (alignment and padding included)
same "bytes: s, little endian" [binary encode hex [ribbon::dbus::marshal s hello]] 0500000068656c6c6f00
same "bytes: ys, big endian" [binary encode hex [ribbon::dbus::marshal ys {1 ab} big]] [join {01 000000 00000002 6162 00} ""]
same "bytes: an empty ax is padded to 8 after its length" [binary encode hex [ribbon::dbus::marshal ax {{}}]] [join {00000000 00000000} ""]
same "bytes: ax (big)" [binary encode hex [ribbon::dbus::marshal ax {5} big]] [join {00000008 00000000 0000000000000005} ""]
same "bytes: a{sv}" [binary encode hex [ribbon::dbus::marshal a{sv} {{a {y 1}}}]] [join {0a000000 00000000 01000000 6100 017900 01} ""]
same "bytes: (yv) aligns the struct, not the variant's value" [binary encode hex [ribbon::dbus::marshal y(yv) {1 {2 {u 3}}} big]] \
	[join {01 00000000000000 02 01 7500 00000003} ""]
same "booleans and integers in other spellings" [ribbon::dbus::unmarshal bbiy [ribbon::dbus::marshal bbiy {true no 0x10 0b11}]] {1 0 16 3}
same "strip takes the variant wrappers off" [ribbon::dbus::strip a{sv} {a {v {i 1}} b {as {x y}}}] {a 1 b {x y}}
same "types" [ribbon::dbus::types a{sv}i(ii)aay] {a{sv} i (ii) aay}
foreach {sig vals why} {
	y 256 "a byte out of range" n 32768 "an int16 out of range" u -1 "a negative uint32" t 18446744073709551616 "a uint64 out of range"
	i x "not an integer" b maybe "not a boolean" o a/b "a relative object path" o /a/ "a trailing /" o //a "an empty path element"
	s "a\0b" "NUL in a string" v x "a variant that isn't {SIG VALUE}" v {ii {1 2}} "a variant of two types" (ii) {1} "a short struct"
	a{sv} {a} "an odd dict"
} {
	set ec [fails {ribbon::dbus::marshal $sig [list $vals]}]
	if {$ec ne "no error"} { ok "refused: $why" } else { bad "refused: $why" "accepted" }
}
set nbad 0
foreach sig [list a ( ) (i "{ii}" "a{vs}" "a{iii}" "a{i}" "a{(i)s}" aa "(ii" z "()" "(i{ss})"] {
	if {[fails {ribbon::dbus::types $sig}] eq "DBUS org.freedesktop.DBus.Error.InvalidSignature"} { incr nbad } else { bad "bad signature $sig" accepted }
}
check "14 malformed signatures refused" {$nbad == 14}
same "a truncated body is an error" [fails {ribbon::dbus::unmarshal s [binary decode hex 0500000068]}] {DBUS org.freedesktop.DBus.Error.InvalidArgs}
same "bytes left over are an error" [fails {ribbon::dbus::unmarshal y [binary decode hex 0102]}] {DBUS org.freedesktop.DBus.Error.InvalidArgs}

# ---- 2. the bus: connect, the daemon's own methods -------------------------
puts "the bus"
set t0 [clock microseconds]
set a [ribbon::dbus::connect session]
set tconnect [expr {[clock microseconds] - $t0}]
set rss2 [rss]
check "connect (EXTERNAL) and Hello: [$a name]" {[string match :1.* [$a name]]}
check "fd passing negotiated" {[set ${a}(unixfd)] == 1}
set id [lindex [$a call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId] 0]
check "GetId: $id" {[regexp {^[0-9a-f]{32}$} $id]}
set names [lindex [$a call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ListNames] 0]
check "ListNames has the bus and us" {"org.freedesktop.DBus" in $names && [$a name] in $names}
same "a D-Bus error is a Tcl error with errorCode DBUS name" \
	[fails {$a call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus NoSuchMethod}] {DBUS org.freedesktop.DBus.Error.UnknownMethod}
foreach {why args} {"an interface name" {org.freedesktop.DBus / "no dots" GetId} "a member name" {org.freedesktop.DBus / org.freedesktop.DBus Get-Id}
	"a bus name" {org..x / org.x.Y Z}} {
	same "refused before it is sent: $why" [fails {$a call {*}$args}] {DBUS org.freedesktop.DBus.Error.InvalidArgs}
}
same "  and the connection is fine" [string length [lindex [$a call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId] 0]] 32
same "a name nobody owns" [fails {$a call -noautostart 1 org.ribbon.Nobody / org.ribbon.Nobody Hi}] \
	{DBUS org.freedesktop.DBus.Error.NameHasNoOwner}
set b [ribbon::dbus::connect $env(DBUS_SESSION_BUS_ADDRESS) -endian big]
check "a second connection, big endian: [$b name]" {[$b name] ne [$a name]}
same "the daemon answers big-endian calls" [lindex [$b call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId] 0] $id
set anon [ribbon::dbus::connect $env(RIBBON_DBUS_ANON)]
same "ANONYMOUS after EXTERNAL is rejected (abstract socket)" \
	[string length [lindex [$anon call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId] 0]] 32
$anon close
same "only ANONYMOUS offered to a bus that wants EXTERNAL" \
	[fails {ribbon::dbus::connect session -auth ANONYMOUS}] {DBUS org.freedesktop.DBus.Error.AuthFailed}
same "no socket" [fails {ribbon::dbus::connect unix:path=/nonexistent/bus}] {DBUS org.freedesktop.DBus.Error.NoServer}
same "an address with %-escapes and three entries" \
	[ribbon::dbus::addresses "unix:path=/run/a%20b%2c,guid=1;tcp:host=x,port=1;unix:abstract=z"] \
	[list {unix {path {/run/a b,} guid 1}} {tcp {host x port 1}} {unix {abstract z}}]

# ---- 3. an exported object ----------------------------------------------
namespace eval obj { variable later {} }
proc obj::echo {msg args} { return $args }
proc obj::add {msg x y} { expr {$x + $y} }
proc obj::nope {msg} { throw {DBUS org.ribbon.Test.Error.Nope} "nope, said [dict get $msg sender]" }
proc obj::crash {msg} { error "a plain Tcl error" }
proc obj::later {bus msg ms} { $bus defer $msg; after $ms [list $bus reply $msg [dict get $msg sender]] }
proc obj::never {bus msg} { $bus defer $msg }
proc obj::cat {msg f} { fconfigure $f -translation binary; set d [read $f]; close $f; return $d }
proc obj::open2 {msg text} {
	lassign [chan pipe] r w
	puts -nonewline $w $text; close $w
	set f [open /dev/null]
	after 0 [list apply {{r f} {close $r; close $f}} $r $f]
	return [list $r [list h $f]]
}
proc obj::count {msg fds} { foreach f $fds { close $f }; llength $fds }
proc obj::spec {bus} {
	list method Echo $::all $::all obj::echo \
		method Add ii i obj::add \
		method Nope "" "" obj::nope \
		method Crash "" "" obj::crash \
		method Later u s [list obj::later $bus] \
		method Never "" "" [list obj::never $bus] \
		method Cat h ay obj::cat \
		method Open s (hv) obj::open2 \
		method Count ah u obj::count \
		method Len ay u {apply {{m data} {string length $data}}} \
		signal Tick s
}
foreach bus [list $a $b] { $bus export /org/ribbon/Test org.ribbon.Test [obj::spec $bus] }
$a export /org/ribbon/Test/child/deeper org.ribbon.Other {method Hi "" s {apply {m {return hi}}}}

proc tests {} {
	global a b all allv id failed
	puts "calls to an exported object"
	same "Echo, 23 values: a big-endian call, a little-endian reply" [$b call [$a name] /org/ribbon/Test org.ribbon.Test Echo $all {*}$allv] $allv
	same "Echo, 23 values: a little-endian call, a big-endian reply" [$a call [$b name] /org/ribbon/Test org.ribbon.Test Echo $all {*}$allv] $allv
	same "a well-formed reply from the handler's value" [$b call [$a name] /org/ribbon/Test org.ribbon.Test Add ii 2 40] 42
	same "no interface given" [$b call [$a name] /org/ribbon/Test "" Add ii 1 1] 2
	same "thrown D-Bus error" [fails {$b call [$a name] /org/ribbon/Test org.ribbon.Test Nope}] {DBUS org.ribbon.Test.Error.Nope}
	catch {$b call [$a name] /org/ribbon/Test org.ribbon.Test Nope} err
	same "  its text" $err "nope, said [$b name]"
	same "a Tcl error is org.freedesktop.DBus.Error.Failed" [fails {$b call [$a name] /org/ribbon/Test org.ribbon.Test Crash}] {DBUS org.freedesktop.DBus.Error.Failed}
	same "wrong signature" [fails {$b call [$a name] /org/ribbon/Test org.ribbon.Test Add s 1}] {DBUS org.freedesktop.DBus.Error.InvalidArgs}
	same "unknown method" [fails {$b call [$a name] /org/ribbon/Test org.ribbon.Test Sub ii 1 1}] {DBUS org.freedesktop.DBus.Error.UnknownMethod}
	same "unknown interface" [fails {$b call [$a name] /org/ribbon/Test org.ribbon.Nope Add ii 1 1}] {DBUS org.freedesktop.DBus.Error.UnknownInterface}
	same "unknown object" [fails {$b call [$a name] /org/ribbon/None org.ribbon.Test Add ii 1 1}] {DBUS org.freedesktop.DBus.Error.UnknownObject}
	set t0 [clock milliseconds]
	same "a reply deferred by 150 ms" [$b call [$a name] /org/ribbon/Test org.ribbon.Test Later u 150] [$b name]
	check "  it took that long" {[clock milliseconds] - $t0 >= 140}
	set t0 [clock milliseconds]
	same "no reply: -timeout 200" [fails {$b call -timeout 200 [$a name] /org/ribbon/Test org.ribbon.Test Never}] {DBUS org.freedesktop.DBus.Error.NoReply}
	check "  after 200 ms" {[clock milliseconds] - $t0 >= 190 && [clock milliseconds] - $t0 < 1500}
	same "Peer.Ping" [$b call [$a name] /anything org.freedesktop.DBus.Peer Ping] {}
	same "Peer.GetMachineId" [string length [lindex [$b call [$a name] / org.freedesktop.DBus.Peer GetMachineId] 0]] 32

	# -command: no waiting; several calls in flight at once, in order
	set ::got {}
	foreach i {1 2 3} { $b call -command {apply {{s v} {lappend ::got $s $v}}} [$a name] /org/ribbon/Test org.ribbon.Test Add ii $i 10 }
	$b call -command {apply {{s v} {lappend ::got $s [lindex $v 0]}}} [$a name] /org/ribbon/Test org.ribbon.Test Nope
	check "-command: three replies and an error, in order" {[waitfor {[llength $::got] == 8}] && $::got eq {ok 11 ok 12 ok 13 error org.ribbon.Test.Error.Nope}}
	$b call -noreply 1 [$a name] /org/ribbon/Test org.ribbon.Test Add ii 1 1
	ok "-noreply: sent, nothing waited for"

	# the event loop keeps running while a call waits (Tk keeps drawing)
	set ::ticks 0
	proc ::tick {} { incr ::ticks; after 10 ::tick }
	after 10 ::tick
	$b call [$a name] /org/ribbon/Test org.ribbon.Test Later u 300
	set inco $::ticks
	after 0 ::waitcall
	waitfor {[info exists ::called]}
	after cancel ::tick
	check "the event loop runs while a call waits: in a coroutine ($inco ticks in 300 ms)" {$inco >= 10}
	check "  and in vwait outside one ($::vw ticks)" {$::vw >= 10}

	set big [string repeat "\x00\x01\x02\xff" 1048576]
	set t0 [clock microseconds]
	same "a 4 MiB message (ay), written without blocking" [$b call [$a name] /org/ribbon/Test org.ribbon.Test Len ay $big] 4194304
	set ::tbig [expr {[clock microseconds] - $t0}]

	puts "introspection"
	set x [lindex [$b call [$a name] /org/ribbon/Test org.freedesktop.DBus.Introspectable Introspect] 0]
	check "Introspect lists the methods and signals" {[string match {*<method name="Add"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="i" direction="out"/></method>*} $x] && [string match {*<signal name="Tick"><arg type="s"/></signal>*} $x]}
	check "  and the child node" {[string match {*<node name="child"/>*} $x]}
	set x [lindex [$b call [$a name] / org.freedesktop.DBus.Introspectable Introspect] 0]
	check "Introspect / lists org" {[string match {*<node name="org"/>*} $x]}
	if {[auto_execok gdbus] ne ""} {
		lassign [program gdbus introspect --session --dest [$a name] --object-path /org/ribbon/Test --recurse] code out
		check "gdbus introspect --recurse reads it" {$code == 0 && [string match {*Echo*} $out] && [string match {*org.ribbon.Other*} $out]}
		lassign [program gdbus call --session --dest [$a name] --object-path /org/ribbon/Test --method org.ribbon.Test.Add 20 22] code out
		same "gdbus call Add 20 22" $out "(42,)"
		lassign [program gdbus call --session --dest [$a name] --object-path /org/ribbon/Test --method org.ribbon.Test.Echo -- \
			7 true -3 4 -5 6 -7 8 0.25 "h\u00e9" /x/y "a{sv}" "<'v'>" "\['a'\]" "\[byte 0x00, 0x80\]" "{'k': <1>}" "{'/p': \[(1, 2)\]}" \
			"(1, 2, ('s', 3.5), false)" "\[@av \[\], \[<1>, <'x'>\]\]" "{1: 0.5}" "\[9, -9\]" "\[@q 1, 65535\]" "\[<@g 'ab'>, <@o '/'>\]"] code out
		same "gdbus call Echo: GDBus's marshalling of every type, read and written back" $out \
			"(byte 0x07, true, int16 -3, uint16 4, -5, uint32 6, int64 -7, uint64 8, 0.25, 'h\u00e9', objectpath '/x/y', signature 'a{sv}', <'v'>, \['a'\], \[byte 0x00, 0x80\], {'k': <1>}, {objectpath '/p': \[(1, 2)\]}, (byte 0x01, int64 2, ('s', 3.5), false), \[@av \[\], \[<1>, <'x'>\]\], {byte 0x01: 0.5}, \[int64 9, -9\], \[uint16 1, 65535\], \[<signature 'ab'>, <objectpath '/'>\])"
	}

	puts "names"
	same "RequestName: primary" [$a request org.ribbon.TestA] primary
	same "  again: owner" [$a request org.ribbon.TestA] owner
	same "  another connection, -noqueue 1: exists" [$b request org.ribbon.TestA -noqueue 1] exists
	set ::acquired ""
	$b listen -sender org.freedesktop.DBus -member NameAcquired {apply {{m name} {lappend ::acquired $name}}}
	same "  another connection: queued" [$b request org.ribbon.TestA] queued
	same "  call through the name" [$b call org.ribbon.TestA /org/ribbon/Test org.ribbon.Test Add ii 1 2] 3
	same "ReleaseName: released" [$a release org.ribbon.TestA] released
	check "  the queued one gets it (NameAcquired)" {[waitfor {"org.ribbon.TestA" in $::acquired}]}
	same "  call through the name, now B's" [$a call org.ribbon.TestA /org/ribbon/Test org.ribbon.Test Later u 0] [$a name]
	same "ReleaseName: notowner" [$a release org.ribbon.TestA] notowner
	same "RequestName -command (through await)" [ribbon::dbus::await [list $b request org.ribbon.TestB -command]] primary

	puts "signals"
	set c [ribbon::dbus::connect session]
	set ::sig {}
	set l1 [$a listen -interface org.ribbon.Test -member Tick {apply {{m s} {lappend ::sig 1 [dict get $m sender] $s}}}]
	set l2 [$a listen -interface org.ribbon.Test -member Tick -arg0 two {apply {{m s} {lappend ::sig 2 $s}}}]
	set l3 [$a listen -sender org.ribbon.TestB -member Tick {apply {{m s} {lappend ::sig 3 $s}}}]
	set l4 [$a listen -path_namespace /org/ribbon/Sub -member Tick {apply {{m s} {lappend ::sig 4 [dict get $m path]}}}]
	# (each GetId returns once the bus has passed the signals on, in order)
	$c emit /org/ribbon/Test org.ribbon.Test Tick s one
	$c emit /org/ribbon/Test org.ribbon.Test Tick s two
	$c call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId
	$b emit /org/ribbon/Test org.ribbon.Test Tick s three
	$b call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId
	$c emit /org/ribbon/Sub/x org.ribbon.Test Tick s four
	$c emit /org/ribbon/Subway org.ribbon.Test Tick s five
	waitfor {[llength $::sig] >= 21} 1000
	same "a signal from a third connection, filtered by rule" $::sig \
		[list 1 [$c name] one 1 [$c name] two 2 two 1 [$b name] three 3 three 1 [$c name] four 4 /org/ribbon/Sub/x 1 [$c name] five]
	set ::sig {}
	$a unlisten $l1; $a unlisten $l2; $a unlisten $l3; $a unlisten $l4
	$a call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId
	$c emit /org/ribbon/Test org.ribbon.Test Tick s six
	$c call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId
	sleep 50
	same "unlisten: no more" $::sig {}
	set ::sig {}
	$a listen -member Direct {apply {{m args} {lappend ::sig [dict get $m destination] $args}}}
	$c emit -destination [$a name] /x org.ribbon.Test Direct a{sv}(ii) {k {v {s deep}}} {1 2}
	waitfor {[llength $::sig]} 1000
	same "a unicast signal with a nested variant" $::sig [list [$a name] {{k {v {s deep}}} {1 2}}]

	puts "fd passing"
	set fds0 [nfds]
	set f [file tempfile path]
	fconfigure $f -translation binary
	puts -nonewline $f "bytes from a file\x00\xff"; close $f
	set f [open $path rb]
	same "an fd sent (h): the other side reads the file" [$b call [$a name] /org/ribbon/Test org.ribbon.Test Cat h $f] [list "bytes from a file\x00\xff"]
	close $f
	lassign [$b call [$a name] /org/ribbon/Test org.ribbon.Test Open s "through a pipe"] r
	lassign $r p inner
	lassign $inner vsig nul
	fconfigure $p -blocking 1
	same "fds received in a struct and a variant: a pipe's end" [read $p] "through a pipe"
	check "  and /dev/null, as a channel" {$vsig eq "h" && [read $nul] eq "" && [eof $nul]}
	close $p; close $nul
	set many {}
	for {set i 0} {$i < 16} {incr i} { lappend many [open /dev/null] }
	same "16 fds in one message (ah), the bus's limit" [$b call [$a name] /org/ribbon/Test org.ribbon.Test Count ah $many] 16
	lappend many [open /dev/null]
	same "  17 are refused before they are sent" [fails {$b call [$a name] /org/ribbon/Test org.ribbon.Test Count ah $many}] \
		{DBUS org.freedesktop.DBus.Error.LimitsExceeded}
	foreach f $many { close $f }
	for {set i 0} {$i < 50} {incr i} {
		set f [open $path rb]
		$a call [$b name] /org/ribbon/Test org.ribbon.Test Cat h $f
		close $f
	}
	file delete $path
	same "no fd leaked after 70 messages with fds" [nfds] $fds0

	notifications $c
	properties $c
	rarer $c
	measure $c

	puts "disconnects"
	set d [ribbon::dbus::connect session -onclose {apply {why {set ::closed $why}}}]
	set ::closed ""
	$d call -command {apply {{s v} {set ::pend [list $s [lindex $v 0]]}}} [$a name] /org/ribbon/Test org.ribbon.Test Never
	# break the protocol on purpose: the daemon hangs up
	puts -nonewline [set ${d}(chan)] [string repeat \xff 32]; flush [set ${d}(chan)]
	check "the bus hangs up: -onclose is called" {[waitfor {$::closed ne ""}]}
	check "  the call in flight fails with Disconnected" {[waitfor {[info exists ::pend]}] && $::pend eq {error org.freedesktop.DBus.Error.Disconnected}}
	same "  later calls fail at once" [fails {$d call org.freedesktop.DBus / org.freedesktop.DBus GetId}] {DBUS org.freedesktop.DBus.Error.Disconnected}
	$d close
	foreach bus [list $a $b $c] { $bus close }
	check "close removes the connection command" {[info commands $a] eq ""}
}

# vwait outside the coroutine, while it waits
proc waitcall {} {
	global a b
	set t $::ticks
	$b call [$a name] /org/ribbon/Test org.ribbon.Test Later u 300
	set ::vw [expr {$::ticks - $t}]
	set ::called 1
}

# ---- the notification server's D-Bus side (shell/notifyd.tcl),
# driven by notify-send and gdbus; "popups" are recorded, and a person
# picks the second action of any notification that has some
source [file join $here .. srcpkgs ribbon-desktop files shell notifyd.tcl]
set seen {}
proc popup {n} {
	lappend ::seen $n
	if {[llength [dict get $n actions]] >= 4} {
		after 50 [list notifyd::invoked [dict get $n id] [lindex [dict get $n actions] 2]]
		after 60 [list notifyd::closed [dict get $n id] 2]
	}
}

proc notifications {watcher} {
	global a
	puts "notification server"
	same "the shell's server owns org.freedesktop.Notifications" [notifyd::start $a -show popup -close {lappend ::asked}] primary
	set ::closedsig {}
	$watcher listen -sender org.freedesktop.Notifications -interface org.freedesktop.Notifications -member NotificationClosed \
		{apply {{m id why} {lappend ::closedsig $id $why}}}
	if {[auto_execok notify-send] ne ""} {
		lassign [program notify-send -p -a "Ribbon tests" -i dialog-information -u critical -t 4000 \
			-h string:x-ribbon-test:yes -h int:value:42 "Hello \u2603" "Body <b>bold</b>"] code id
		set n [lindex $::seen end]
		check "notify-send: the server got it, id $id" {$code == 0 && $id == [dict get $n id]}
		same "  app, icon, summary, body" [dict map {k v} [dict filter $n key app icon summary body] {set v}] \
			[dict create app "Ribbon tests" icon dialog-information summary "Hello \u2603" body "Body <b>bold</b>"]
		same "  hints: urgency critical (y 2), string and int hints, timeout" \
			[list [dict get $n urgency] [dict get $n hints x-ribbon-test] [dict get $n hints value] [dict get $n timeout]] {2 yes 42 4000}
		lassign [program notify-send -p -r $id "Replaced"] code id2
		same "notify-send -r: replaces the same id" $id2 $id
		lassign [program notify-send -A default=Open -A later=Later "Pick one"] code out
		same "notify-send -A: ActionInvoked reaches it (it prints the action)" $out later
		same "  it sent the actions" [dict get [lindex $::seen end] actions] {default Open later Later}
	} else {
		ok "notify-send not installed; the gdbus checks below drive the server"
	}
	lassign [program gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
		--method org.freedesktop.Notifications.Notify -- gdbus 0 "" "From gdbus" "" "\[\]" "{'urgency': <byte 0>}" -1] code out
	set gid [dict get [lindex $::seen end] id]
	same "gdbus call Notify" $out "(uint32 $gid,)"
	same "  urgency low" [dict get [lindex $::seen end] urgency] 0
	lassign [program gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
		--method org.freedesktop.Notifications.GetServerInformation] code out
	same "gdbus call GetServerInformation" $out "('Ribbon shell', 'Ribbon', '0.1', '1.2')"
	lassign [program gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
		--method org.freedesktop.Notifications.CloseNotification $gid] code out
	same "  the popup was asked to close" [lindex $::asked end] $gid
	check "CloseNotification: a listener sees NotificationClosed (reason 3)" {[waitfor {[llength $::closedsig] >= 2}] && [lrange $::closedsig end-1 end] eq [list $gid 3]}
}

proc parts {} { lmap p {props net server monitor} { if {[namespace exists ribbon::dbus::$p]} { set p } else continue } }

# ---- properties and object managers (props.tcl) ---------------------------
proc properties {c} {
	global a b
	puts "properties"
	same "nothing beyond the core loaded so far" [parts] {}
	set ::count 0
	$a export /org/ribbon/Props org.ribbon.P {
		property Volume d readwrite {-value 0.5}
		property Title s read {-value hello}
		property Secret s write {-set {apply {{m v} {set ::secret $v}}}}
		property Count u read {-get {apply {m {incr ::count}}} -emits invalidates}
		property Version s read {-value 1.0 -emits const}
		property Quiet i readwrite {-value 0 -emits false}
		property Checked i readwrite {-value 0 -set {apply {{m v} {if {$v < 0} {throw {DBUS org.ribbon.Error.Negative} "no"}}}}}
		method Ping "" "" {apply {m {}}}
	}
	same "  a property in export loads props.tcl, and only it" [parts] props
	set ::pc {}
	$c listen -sender [$a name] -interface org.freedesktop.DBus.Properties -member PropertiesChanged \
		{apply {{m iface changed invalid} {lappend ::pc [list $iface $changed $invalid]}}}
	set P [list [$a name] /org/ribbon/Props org.freedesktop.DBus.Properties]
	same "Get" [$b call {*}$P Get ss org.ribbon.P Volume] {{d 0.5}}
	same "Get with no interface" [$b call {*}$P Get ss "" Title] {{s hello}}
	same "GetAll: readable ones, the getter asked" [$b call {*}$P GetAll s org.ribbon.P] \
		{{Volume {d 0.5} Title {s hello} Count {u 1} Version {s 1.0} Quiet {i 0} Checked {i 0}}}
	same "Set" [$b call {*}$P Set ssv org.ribbon.P Volume {d 0.75}] {}
	same "  Get sees it" [$b call {*}$P Get ss org.ribbon.P Volume] {{d 0.75}}
	check "  PropertiesChanged with the value" {[waitfor {[llength $::pc]}] && [lindex $::pc 0] eq {org.ribbon.P {Volume {d 0.75}} {}}}
	same "Set a read-only one" [fails {$b call {*}$P Set ssv org.ribbon.P Title {s x}}] {DBUS org.freedesktop.DBus.Error.PropertyReadOnly}
	same "Set with the wrong type" [fails {$b call {*}$P Set ssv org.ribbon.P Volume {s x}}] {DBUS org.freedesktop.DBus.Error.InvalidArgs}
	same "Get a write-only one" [fails {$b call {*}$P Get ss org.ribbon.P Secret}] {DBUS org.freedesktop.DBus.Error.AccessDenied}
	$b call {*}$P Set ssv org.ribbon.P Secret {s hush}
	same "  Set it: the setter gets it" $::secret hush
	check "  and PropertiesChanged invalidates it" {[waitfor {{org.ribbon.P {} Secret} in $::pc}]}
	same "a setter refuses: its error, the value kept" [list [fails {$b call {*}$P Set ssv org.ribbon.P Checked {i -1}}] \
		[$b call {*}$P Get ss org.ribbon.P Checked]] {{DBUS org.ribbon.Error.Negative} {{i 0}}}
	same "an unknown property" [fails {$b call {*}$P Get ss org.ribbon.P Nope}] {DBUS org.freedesktop.DBus.Error.UnknownProperty}
	same "an unknown interface" [fails {$b call {*}$P GetAll s org.ribbon.Q}] {DBUS org.freedesktop.DBus.Error.UnknownInterface}
	set ::pc {}
	$a set /org/ribbon/Props org.ribbon.P Volume 1.0 Title bye
	$a changed /org/ribbon/Props org.ribbon.P Count
	$a set /org/ribbon/Props org.ribbon.P Quiet 5
	$a changed /org/ribbon/Props org.ribbon.P Version
	$c listen -sender [$a name] -member Done {apply {args {set ::done1 1}}}
	$a emit /org/ribbon/Props org.ribbon.P Done
	waitfor {[info exists ::done1]}
	same "local set: one signal for two; invalidates; const and false: none" $::pc \
		[list {org.ribbon.P {Volume {d 1.0} Title {s bye}} {}} {org.ribbon.P {} Count}]
	same "local get" [list [$a get /org/ribbon/Props org.ribbon.P Quiet] [$b call {*}$P Get ss org.ribbon.P Quiet]] {5 {{i 5}}}
	same "local set refuses a bad value" [catch {$a set /org/ribbon/Props org.ribbon.P Quiet x}] 1
	set x [lindex [$b call [$a name] /org/ribbon/Props org.freedesktop.DBus.Introspectable Introspect] 0]
	check "Introspect: properties, their access and EmitsChangedSignal" {
		[string match {*<property name="Volume" type="d" access="readwrite"/>*} $x] &&
		[string match {*<property name="Count" type="u" access="read">*<annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="invalidates"/>*} $x] &&
		[string match {*<interface name="org.freedesktop.DBus.Properties">*} $x]}
	if {[auto_execok gdbus] ne ""} {
		lassign [program gdbus call --session --dest [$a name] --object-path /org/ribbon/Props \
			--method org.freedesktop.DBus.Properties.Set org.ribbon.P Volume "<0.25>"] code out
		same "gdbus sets a property" [list $code [$a get /org/ribbon/Props org.ribbon.P Volume]] {0 0.25}
		lassign [program gdbus introspect --session --dest [$a name] --object-path /org/ribbon/Props] code out
		check "gdbus introspect shows them with values" {[string match {*readwrite d Volume = 0.25;*} $out] && [string match {*writeonly s Secret;*} $out]}
	}

	puts "object manager"
	$a manage /org/ribbon/Mgr
	set M [list [$a name] /org/ribbon/Mgr org.freedesktop.DBus.ObjectManager]
	same "GetManagedObjects, nothing under it yet" [$b call {*}$M GetManagedObjects] {{}}
	set ::om {}
	$c listen -sender [$a name] -interface org.freedesktop.DBus.ObjectManager {apply {{m args} {lappend ::om [dict get $m member] $args}}}
	$a export /org/ribbon/Mgr/disk1 org.ribbon.Disk {property Size t read {-value 512}}
	$a export /org/ribbon/Mgr/disk1 org.ribbon.Fs {method Mount "" "" {apply {m {}}}}
	same "GetManagedObjects: the objects, interfaces and properties" [$b call {*}$M GetManagedObjects] \
		{{/org/ribbon/Mgr/disk1 {org.ribbon.Disk {Size {t 512}} org.ribbon.Fs {}}}}
	$a unexport /org/ribbon/Mgr/disk1
	check "InterfacesAdded for each, InterfacesRemoved for both" {[waitfor {[llength $::om] >= 6}] && $::om eq
		{InterfacesAdded {/org/ribbon/Mgr/disk1 {org.ribbon.Disk {Size {t 512}}}} InterfacesAdded {/org/ribbon/Mgr/disk1 {org.ribbon.Fs {}}} InterfacesRemoved {/org/ribbon/Mgr/disk1 {org.ribbon.Disk org.ribbon.Fs}}}}
	set x [lindex [$b call [$a name] /org/ribbon/Mgr org.freedesktop.DBus.Introspectable Introspect] 0]
	check "Introspect lists ObjectManager at the root" {[string match {*<interface name="org.freedesktop.DBus.ObjectManager">*} $x]}
}

# ---- the rest of the specification -----------------------------------------
proc rarer {c} {
	global a b env here
	puts "match rules, flags, limits"
	set ::ns {}
	$a listen -member NS -arg0namespace org.ribbon {apply {{m s} {lappend ::ns ns $s}}}
	$a listen -member NS -arg0path /a/ {apply {{m s} {lappend ::ns path $s}}}
	foreach v {org.ribbon.X org.ribbonx /a/b /a /} { $c emit /x org.ribbon.Test NS s $v }
	$c call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId
	waitfor {[llength $::ns] >= 6} 1000
	same "arg0namespace and arg0path" $::ns {ns org.ribbon.X path /a/b path /}
	$a export /org/ribbon/Flags org.ribbon.F {method Flags "" u {apply {m {dict get $m flags}}}}
	same "-interactive 1: ALLOW_INTERACTIVE_AUTHORIZATION" [$b call -interactive 1 [$a name] /org/ribbon/Flags org.ribbon.F Flags] 4
	same "32 nested arrays" [llength [ribbon::dbus::types [string repeat a 32]y]] 1
	same "  33 are refused" [fails {ribbon::dbus::types [string repeat a 33]y}] {DBUS org.freedesktop.DBus.Error.InvalidSignature}
	same "  and 33 structs" [fails {ribbon::dbus::types [string repeat ( 33]y[string repeat ) 33]}] {DBUS org.freedesktop.DBus.Error.InvalidSignature}

	puts "eavesdropping and monitoring"
	set e [ribbon::dbus::connect session]
	set ::eaves {}
	$e listen -type method_call -eavesdrop true -interface org.ribbon.Test -member Add {apply {{m x y} {lappend ::eaves [dict get $m destination] $x $y}}}
	same "  B's call to A still answered by A" [$b call [$a name] /org/ribbon/Test org.ribbon.Test Add ii 5 6] 11
	check "eavesdrop: a third connection sees a call meant for A (and doesn't answer it)" {[waitfor {[llength $::eaves]}] && $::eaves eq [list [$a name] 5 6]}
	same "  the core still has only props" [parts] props
	set mon [ribbon::dbus::connect session]
	set ::seenm {}
	$mon monitor {type method_call interface org.ribbon.Test} {apply {m {
		# (the bus also tells the monitor it lost its own name)
		if {[dict get $m type] eq "call"} { lappend ::seenm [dict get $m type] [dict get $m member] [dict get $m body] }
	}}}
	same "  monitor loads monitor.tcl" [parts] {props monitor}
	$b call [$a name] /org/ribbon/Test org.ribbon.Test Add ii 7 8
	check "BecomeMonitor: the monitor sees it" {[waitfor {[llength $::seenm]}] && [lrange $::seenm 0 2] eq {call Add {7 8}}}
	same "  and sends nothing more" [fails {$mon call org.freedesktop.DBus / org.freedesktop.DBus GetId}] {DBUS org.freedesktop.DBus.Error.NotSupported}
	$mon close; $e close

	puts "transports"
	foreach entry [split $env(RIBBON_DBUS_TCP) ";"] {
		set kind [lindex [split $entry :] 0]
		set t [ribbon::dbus::connect $entry]
		same "$kind: DBUS_COOKIE_SHA1, GetId" [list [set ${t}(mech)] [string length [lindex [$t call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId] 0]]] \
			{DBUS_COOKIE_SHA1 32}
		same "  no fds over $kind" [fails {$t call org.freedesktop.DBus / org.freedesktop.DBus GetId h stdin}] {DBUS org.freedesktop.DBus.Error.NotSupported}
		$t close
	}
	same "  net.tcl loaded for them" [lsort [parts]] {monitor net props}
	if {![catch {package require sha1}]} {
		same "SHA-1 as tcllib has it" [lmap s {"" abc "[string repeat x 100]"} { expr {[ribbon::dbus::net::sha1 $s] eq [sha1::sha1 -hex $s]} }] {1 1 1}
	}
	set sock [dict get [lindex [lindex [ribbon::dbus::addresses session] 0] 1] path]
	if {[auto_execok nc] ne ""} { catch {exec nc -h 2>@1} help }
	if {[auto_execok nc] ne "" && [string match *-U* $help]} {
		set u [ribbon::dbus::connect unixexec:path=[auto_execok nc],argv1=-U,argv2=$sock]
		same "unixexec: through nc -U, as through ssh" [string length [lindex [$u call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId] 0]] 32
		$u close
	}

	puts "peer to peer"
	set ::peers {}
	set srv [ribbon::dbus::listen unix:tmpdir=[file dirname $sock] {apply {{p} {
		lappend ::peers $p
		$p export /peer org.ribbon.Peer {
			method Add ii i {apply {{m x y} {expr {$x + $y}}}}
			method Cat h s {apply {{m f} {set d [read $f]; close $f; return $d}}}
		}
	}}}]
	same "  server.tcl loaded" [lsort [parts]] {monitor net props server}
	set p [ribbon::dbus::connect [$srv address] -bus 0]
	same "a peer: a call with no bus in between" [$p call "" /peer org.ribbon.Peer Add ii 20 22] 42
	check "  the server's handler got the connection" {[llength $::peers] == 1}
	set f [file tempfile path]; puts -nonewline $f "peer fd"; close $f; set f [open $path]
	same "  an fd, peer to peer" [$p call "" /peer org.ribbon.Peer Cat h $f] {{peer fd}}
	close $f; file delete $path
	set ::psig {}
	$p listen -member Hi {apply {{m s} {lappend ::psig $s}}}
	[lindex $::peers 0] emit /peer org.ribbon.Peer Hi s there
	check "  a signal from the server" {[waitfor {[llength $::psig]}] && $::psig eq "there"}
	$p export /client org.ribbon.Client {method Who "" s {apply {m {return client}}}}
	same "  the server calls the client back" [[lindex $::peers 0] call "" /client org.ribbon.Client Who] client
	if {[auto_execok dbus-send] ne ""} {
		lassign [program dbus-send --peer=[$srv address] --print-reply /peer org.ribbon.Peer.Add int32:2 int32:3] code out
		check "dbus-send --peer calls it (libdbus's client)" {$code == 0 && [string match "*int32 5" $out]}
	}
	$p close
	$srv close
	set srv [ribbon::dbus::listen tcp:host=127.0.0.1,port=0 -anonymous 1 {apply {{p} {
		$p export /peer org.ribbon.Peer {method Add ii i {apply {{m x y} {expr {$x + $y}}}}}
	}}}]
	set p [ribbon::dbus::connect [$srv address] -bus 0]
	same "a peer over tcp, ANONYMOUS ([$srv address])" [list [set ${p}(mech)] [$p call "" /peer org.ribbon.Peer Add ii 1 2]] {ANONYMOUS 3}
	$p close; $srv close
	set srv [ribbon::dbus::listen tcp:host=127.0.0.1,port=0 {apply {{p} {}}}]
	same "  without -anonymous, tcp lets no one in" [fails {ribbon::dbus::connect [$srv address] -bus 0}] {DBUS org.freedesktop.DBus.Error.AuthFailed}
	$srv close
}

proc measure {c} {
	global a b tconnect rss0 rss1 rss2
	puts "measurements"
	set n 20
	set t0 [clock microseconds]
	for {set i 0} {$i < $n} {incr i} { [ribbon::dbus::connect session] close }
	info_line "connect (EXTERNAL, fd negotiation, Hello): [ms [expr {[clock microseconds] - $t0}] $n] ms (average of $n); the very first [ms $tconnect 1] ms"
	set n 1000
	set t0 [clock microseconds]
	for {set i 0} {$i < $n} {incr i} { $c call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId }
	info_line "round trip to the daemon (GetId): [ms [expr {[clock microseconds] - $t0}] $n] ms"
	set t0 [clock microseconds]
	for {set i 0} {$i < $n} {incr i} { $c call [$a name] /org/ribbon/Test org.ribbon.Test Add ii $i 1 }
	info_line "round trip to an exported object on another connection, same process (Add ii): [ms [expr {[clock microseconds] - $t0}] $n] ms"
	set t0 [clock microseconds]
	for {set i 0} {$i < 200} {incr i} { $c call [$a name] /org/ribbon/Test org.ribbon.Test Echo $::all {*}$::allv }
	info_line "round trip of Echo, 23 values of every type: [ms [expr {[clock microseconds] - $t0}] 200] ms"
	set ::left $n
	set t0 [clock microseconds]
	for {set i 0} {$i < $n} {incr i} {
		$c call -command {apply {{s v} {incr ::left -1}}} [$a name] /org/ribbon/Test org.ribbon.Test Add ii $i 1
	}
	waitfor {$::left == 0} 10000
	info_line "$n calls in flight at once (-command): [ms [expr {[clock microseconds] - $t0}] $n] ms per call"
	set before [rss]
	for {set i 0} {$i < 5000} {incr i} { $c call [$a name] /org/ribbon/Test org.ribbon.Test Add ii $i 1 }
	info_line "a 4 MiB argument (Len ay, the length back): [ms $::tbig 1] ms"
	info_line "memory (VmRSS): [file tail [info nameofexecutable]] alone [expr {$rss0 / 1024}] MB; the package +[expr {$rss1 - $rss0}] kB;\
		the first connection +[expr {$rss2 - $rss1}] kB; now [expr {[rss] / 1024}] MB (3 connections, 10,000 calls, the 4 MiB message);\
		the last 5000 calls +[expr {[rss] - $before}] kB"
	if {[auto_execok dbus-send] ne ""} {
		set t0 [clock microseconds]
		for {set i 0} {$i < 20} {incr i} { program dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetId }
		info_line "for comparison, one dbus-send run (fork, exec, connect, call): [ms [expr {[clock microseconds] - $t0}] 20] ms"
	}
}

coroutine main apply {{} {
	if {[catch tests err]} { bad "the tests stopped" $::errorInfo }
	set ::done 1
}}
if {![info exists ::done]} { vwait ::done }
puts [expr {$failed ? "ribbon::dbus: $failed checks failed" : "ribbon::dbus: all checks passed"}]
exit [expr {$failed ? 1 : 0}]
