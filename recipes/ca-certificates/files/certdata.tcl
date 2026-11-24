# certdata.tcl CERTDATA BLACKLIST OUT - the certificates Mozilla trusts to identify web sites, from NSS's certdata.txt,
# as one PEM bundle at OUT: those whose trust object says CKT_NSS_TRUSTED_DELEGATOR for server authentication, less the
# labels in BLACKLIST (Debian's list), in certdata's order, each after a line naming it. What Debian's certdata2pem.py
# does, without the Python cryptography module it reads expiry dates with (only to print a warning).
lassign $argv cd bl out
set black {}
set f [open $bl]; fconfigure $f -encoding utf-8
foreach l [split [read $f] \n] {
	set l [string trim [lindex [split $l #] 0]]
	if {$l ne ""} { lappend black $l }
}
close $f
# the objects: a dict per object, from CKA_CLASS to the next blank line; MULTILINE_OCTAL values as bytes
set objs {}; set o {}; set ml ""
set f [open $cd]; fconfigure $f -encoding utf-8
foreach l [split [read $f] \n] {
	if {$ml ne ""} {
		if {[string match END* $l]} { dict set o $ml [binary format c* $bytes]; set ml ""; continue }
		foreach {- d} [regexp -all -inline {\\([0-3][0-7][0-7])} $l] { lappend bytes [scan $d %o] }
		continue
	}
	if {[string trim $l] eq "" || [string match #* $l]} {
		if {[dict size $o]} { lappend objs $o; set o {} }
		continue
	}
	if {[string match BEGINDATA* $l]} continue
	set p [split [string trim $l] " "]
	set name [lindex $p 0]; set type [lindex $p 1]
	if {$type eq "MULTILINE_OCTAL"} { set ml $name; set bytes {}; continue }
	dict set o $name [join [lrange $p 2 end] " "]
}
close $f
if {[dict size $o]} { lappend objs $o }
set trust {}
foreach o $objs {
	if {![dict exists $o CKA_CLASS] || [dict get $o CKA_CLASS] ne "CKO_NSS_TRUST"} continue
	set lb [dict get $o CKA_LABEL]
	if {$lb in $black} continue
	if {[dict get $o CKA_TRUST_SERVER_AUTH] eq "CKT_NSS_TRUSTED_DELEGATOR"} { dict set trust $lb 1 }
}
set n 0
set w [open $out w]; fconfigure $w -encoding utf-8 -translation lf
foreach o $objs {
	if {![dict exists $o CKA_CLASS] || [dict get $o CKA_CLASS] ne "CKO_CERTIFICATE"} continue
	set lb [dict get $o CKA_LABEL]
	if {![dict exists $trust $lb]} continue
	puts $w "# [string range $lb 1 end-1]"
	puts $w "-----BEGIN CERTIFICATE-----"
	set b [binary encode base64 [dict get $o CKA_VALUE]]
	for {set i 0} {$i < [string length $b]} {incr i 64} { puts $w [string range $b $i [expr {$i + 63}]] }
	puts $w "-----END CERTIFICATE-----"
	incr n
}
close $w
if {$n < 100} { puts stderr "certdata.tcl: only $n certificates trusted, from [llength $objs] objects"; exit 1 }
puts "certdata.tcl: $n certificates"
