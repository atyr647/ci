# kitq.tcl - the Catalogue's kit side, run as its own process so the window never waits on the
# network: tclsh kitq.tcl apps | info NAME | grab NAME
#
# It loads kit's own library (KIT_LIB, /usr/lib/ribbon/kit, or this tree's ribbon-kit) and calls
# kit's machinery directly, the way Properties does (properties/kitlink.tcl): the index, the
# installed set and grab are kit's, never re-implemented. What it says for the Catalogue is one
# line per answer, "catalogue: KIND DATA" (DATA a Tcl list); every other line is kit's own text.
#
#   apps        catalogue: apps {RECORD...} CHECKED      the index's apps, newest version of each
#                                                        (kind app, providing no library), with
#                                                        what is installed of each, and its title
#                                                        (the launcher entry's Name, else the
#                                                        index's title); CHECKED is
#                                                        when a mirror last answered (0: never)
#               catalogue: noindex REASON                 no index (offline, never fetched)
#   info NAME   catalogue: info DICT                      what kit info says: requests, uses,
#                                                        signer, installed
#   grab NAME   kit's grab, with kit's prompt asked here:
#               catalogue: plan {ROWS QUESTION DEFAULT}  then one line on stdin, 1 or 0
#               catalogue: progress DONE TOTAL            bytes of the chunks fetched so far
#               catalogue: phase install                  everything is fetched; kit switches now
#               catalogue: end CODE                       kit's exit code (0 done, 1 no, 3 network,
#                                                        4 verification, 2 anything else)

set here [file dirname [file normalize [info script]]]
encoding system utf-8
fconfigure stdout -encoding utf-8 -translation lf
fconfigure stdin -encoding utf-8
if {[llength $argv] < 1} { puts stderr "usage: kitq.tcl apps | info NAME | grab NAME"; exit 2 }

proc say {kind args} { puts "catalogue: $kind [join [lmap a $args { list $a }] { }]"; flush stdout }

set lib ""
foreach d [list [expr {[info exists env(KIT_LIB)] ? $env(KIT_LIB) : ""}] /usr/lib/ribbon/kit \
		[file normalize [file join $here .. .. .. .. ribbon-kit files lib]]] {
	if {$d ne "" && [file exists [file join $d verbs.tcl]]} { set lib $d; break }
}
if {$lib eq ""} { say noindex "kit is not installed"; exit 2 }
source -encoding utf-8 [file join $lib core.tcl]
foreach m {ui repo net store plan system txn launch verbs} { ::kit::need $m }
::kit::init
if {[info commands ::kit::selfCmd] eq ""} {
	# what the launcher entries kit writes run (bin/kit defines it as itself)
	proc ::kit::selfCmd {} {
		set k [auto_execok kit]
		if {$k ne ""} { return [lindex $k 0] }
		return [file normalize [file join $::kit::libdir .. bin kit]]
	}
}

# kit's exit code from an error
proc code {opts} {
	set ec [dict get $opts -errorcode]
	switch -- [lindex $ec 0] {
		KIT { return [lindex $ec 1] }
		KITFMT { return [expr {[lindex $ec 1] in {CONFIG NOENT EXISTS} ? 2 : 4}] }
	}
	return 2
}

# ---- apps -----------------------------------------------------------------------------------------
# What the app is called: the installed kit's launcher entry's Name, else the index's title for it ("" when
# neither has one: the window makes one of its short name)
proc Title {l r} {
	set t ""
	if {$l ne ""} { set t [::kit::store::launcherName [dict get $l root] [dict get $r name]] }
	if {$t eq "" && [dict exists $r title]} { set t [dict get $r title] }
	return $t
}
proc apps {} {
	if {[catch {::kit::repo::ensure 3600} I]} {
		# offline: the index fetched last, else why there is none (what ensure said, its first line)
		set why [lindex [split $I \n] 0]
		set I [::kit::repo::loadCache]
		if {$I eq ""} { say noindex $why; return 0 }
	}
	set A [::kit::store::load]
	set newest [dict create]
	foreach r [dict get $I kits] {
		if {[dict get $r kind] ne "app" || [llength [dict get $r provides]]} continue
		set n [dict get $r name]
		if {![dict exists $newest $n] || [::kit::vcmp [dict get $r version] [dict get $newest $n version]] > 0} { dict set newest $n $r }
	}
	set out {}
	dict for {n r} $newest {
		set l [::kit::store::live $A $n]
		lappend out [dict create name $n short [dict get $r short] version [dict get $r version] summary [dict get $r summary] \
			tags [dict get $r tags] size [dict get $r size] download [dict get $r download] \
			installed [expr {$l ne "" ? [dict get $l version] : ""}] \
			title [Title $l $r]]
	}
	say apps $out [expr {[dict exists $I checked] ? [dict get $I checked] : 0}]
	catch {::kit::verbs::done}
	return 0
}

# ---- info -----------------------------------------------------------------------------------------
# Who signed: the name the trusted key lists give the key (::kit::keyHolder: Ribbon's list when it has
# the key, else the other repository's that does), else its comment in the trusted-keys file.
proc signer {keyid} {
	set out [dict create name "" key ""]
	if {$keyid eq ""} { return $out }
	if {![catch {::kit::kitfmt}]} {
		set ids [::kit::keyHolder $keyid]
		if {[llength $ids]} {
			set T [::kit::keyList [lindex $ids 0]]
			if {$T ne "" && [dict exists $T keys $keyid]} {
				dict set out name [dict get $T keys $keyid name]
				dict set out key [dict get $T keys $keyid pk]
				return $out
			}
		}
	}
	if {![catch {::kit::slurp [::kit::keysFile] utf-8} text]} {
		foreach line [split $text \n] {
			set line [string trim $line]
			if {$line eq "" || [string index $line 0] eq "#"} continue
			set k [lindex [split $line] 0]
			if {[string length $k] < 40 || [catch {::kitfmt::PubKeyId $k} id] || $id ne $keyid} continue
			dict set out key $k
			dict set out name [string trim [string range $line [string length $k] end]]
		}
	}
	return $out
}

proc info_ {word} {
	set A [::kit::store::load]
	set line [::kit::store::findLive $A $word]
	set I [::kit::verbs::index 3600 1]
	set rec ""
	if {$I ne ""} {
		set name [expr {$line ne "" ? [dict get $line name] : $word}]
		set rec [::kit::plan::newest [::kit::repo::records $I $name]]
	}
	if {$line eq "" && $rec eq ""} { ::kit::fail 2 "there is no kit called $word" }
	set D [dict create installed "" when "" checked [expr {$I ne "" && [dict exists $I checked] ? [dict get $I checked] : 0}]]
	if {$rec ne ""} {
		foreach k {name short version summary size download} { dict set D $k [dict get $rec $k] }
		dict set D perms {} ; dict set D needs {} ; dict set D sig {}
		if {![catch {::kit::repo::bundle $rec} b] && ![catch {::kit::repo::bundleCheck $b [dict get $rec root]} cs]} {
			set ki [::kit::store::kitIndex [dict get $b index]]
			dict set D perms [dict get $ki perms]
			dict set D needs [dict get $ki needs]
			dict set D sig [lindex $cs 1]
		}
	}
	if {$line ne ""} {
		set inf [::kit::store::kinfo [dict get $line root]]
		foreach k {name short summary size perms needs} { if {[dict exists $inf $k]} { dict set D $k [dict get $inf $k] } }
		if {[dict exists $inf signer]} { dict set D sig [dict get $inf signer] }
		dict set D installed [dict get $line version]
		if {$rec eq ""} { dict set D version [dict get $line version] }
		dict set D when [expr {[dict exists $inf installed] ? [dict get $inf installed] : ""}]
		# what each library it uses resolved to
		set uses {}
		foreach u [dict get $A uses] {
			if {[lindex $u 0] eq [::kit::store::key $line]} { lappend uses [lindex $u 1] [lindex [split [lindex $u 2]] 1] }
		}
		dict set D uses $uses
	}
	set sig [dict get $D sig]
	set keyid [expr {[dict exists $sig keyid] ? [dict get $sig keyid] : ""}]
	dict set D signer [signer $keyid]
	dict set D keyid $keyid
	dict set D sigstate [expr {[dict exists $sig state] ? [dict get $sig state] : ""}]
	say info $D
	catch {::kit::verbs::done}
	return 0
}

# ---- grab -----------------------------------------------------------------------------------------
namespace eval catq { variable said 0 }
# kit's prompt (::kit::ui::ask), asked of the Catalogue
proc catq::render {op rows question default answer} {
	if {$op ne "show"} return
	if {$answer ne ""} { return $answer }
	say plan [list $rows $question $default]
	if {[gets stdin line] < 0} { return 0 }
	return [expr {[string trim $line] eq "1"}]
}
# Chunks are fetched in groups, so the window can show how far the download is; each group is
# kit's own fetch (verified, from the next mirror on failure), and the chunks already in the
# cache are not fetched again.
rename ::kit::repo::fetchChunks ::kit::repo::fetchChunks_
proc ::kit::repo::fetchChunks {hashes sizes {progress ""}} {
	set todo {}; set total 0
	foreach h [lsort -unique $hashes] {
		if {[file exists [::kit::repo::chunkPath $h]]} continue
		lappend todo $h
		incr total [expr {[dict exists $sizes $h] ? [dict get $sizes $h] : 0}]
	}
	set done 0
	say progress 0 $total
	for {set i 0} {$i < [llength $todo]} {incr i 16} {
		set g [lrange $todo $i [expr {$i + 15}]]
		::kit::repo::fetchChunks_ $g $sizes $progress
		foreach h $g { incr done [expr {[dict exists $sizes $h] ? [dict get $sizes $h] : 0}] }
		say progress $done $total
	}
	say phase install
}

proc grab {word} {
	set ::kit::ui::renderer catq::render
	::kit::prologue
	::kit::txn::recover
	return [::kit::verbs::Grab $word]
}

lassign $argv verb word
set rc [catch {
	switch -- $verb {
		apps { apps }
		info { info_ $word }
		grab { grab $word }
		default { ::kit::fail 2 "unknown request $verb" }
	}
} res opts]
catch {::kit::unlock}
catch {::kit::store::closeAll}
if {$rc} {
	set c [code $opts]
	puts stderr $res
	if {$verb eq "grab"} { say end $c }
	exit $c
}
set c [expr {[string is integer -strict $res] ? $res : 0}]
if {$verb eq "grab"} { say end $c }
exit $c
