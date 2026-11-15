# kitlink.tcl - THE ONE PLACE Properties talks to kit (docs/KIT-CLI.md).
#
# Everything about kits goes through here: the facts an app's pages show,
# Update / Repair / Uninstall / Install, and the permissions you grant. It
# loads kit's own Tcl library in this process (srcpkgs/ribbon-kit/files/lib,
# installed at /usr/lib/ribbon/kit) and calls its verbs directly:
#
#   Update, Install  ::kit::verbs::Grab   (the one install/update machinery)
#   Repair           ::kit::verbs::Mend
#   Uninstall        ::kit::verbs::Toss
#
# with kit's shared prompt (::kit::ui::ask) drawn by this app: the GUI is
# one more renderer of the same rows and the same question (KIT-CLI.md, "The
# prompt"). Nothing is shelled out to `kit` and parsed. Facts come from the
# installed set (::kit::store), the last update check (::kit::verbs::
# loadUpdates, no network) and the .kit file itself (kitfmt, through kit).
#
# If kit's library changes its names, this file is what changes with it.
#
# Who signed a kit comes from kit's signing infrastructure (kittrust,
# kit/kittrust, docs/KIT-TRUST.md): the root-signed trusted key list names
# each key, its roles, when it is valid and whether it was revoked. Where
# there is no such list (a plain trusted-keys file), the key's comment in
# that file is its name.
#
# Permissions you grant are not part of any kit (KIT-FORMAT.md 4.2: kits
# only request). kit had no place for them yet; KIT-CLI.md, "Permissions you
# grant", now defines one, and grants_read / grants_write here are that
# definition's reader and writer: ~/.config/kit/grants/<kit name>.

namespace eval kitlink {
	variable lib ""      ;# kit's library directory, once loaded
	variable why ""      ;# why it could not be loaded
	variable out ""      ;# what a verb printed (notes such as "... is up to date")
	variable answer ""
	variable data {}       ;# toss's data answers from the Uninstall sheet: kit name -> 1 or 0
}

# ---- loading kit's library ---------------------------------------------------------

proc kitlink::dirs {} {
	set out {}
	if {[info exists ::env(KIT_LIB)] && $::env(KIT_LIB) ne ""} { lappend out $::env(KIT_LIB) }
	lappend out /usr/lib/ribbon/kit [file normalize [file join $::appdir .. .. .. ribbon-kit files lib]]
}

proc kitlink::load {} {
	variable lib
	variable why
	if {$lib ne ""} { return 1 }
	if {$why ne ""} { return 0 }
	foreach d [dirs] {
		if {![file exists [file join $d verbs.tcl]]} continue
		if {[catch {
			uplevel #0 [list source -encoding utf-8 [file join $d core.tcl]]
			foreach m {ui repo net store plan system txn launch verbs} {
				uplevel #0 [list source -encoding utf-8 [file join $d $m.tcl]]
			}
			::kit::init
			if {[info commands ::kit::selfCmd] eq ""} {
				# what launcher entries run (bin/kit defines it as itself)
				proc ::kit::selfCmd {} {
					set k [auto_execok kit]
					if {$k ne ""} { return [lindex $k 0] }
					return [file normalize [file join $::kit::libdir .. bin kit]]
				}
			}
			set ::kit::ui::renderer kitlink::renderer
			if {[info exists ::kit::txn::afterSwitch] && "::kit::verbs::saveUpdates" ni $::kit::txn::afterSwitch} {
				lappend ::kit::txn::afterSwitch ::kit::verbs::saveUpdates
			}
		} err]} {
			set why "kit's library at $d: $err"
			return 0
		}
		set lib $d
		return 1
	}
	set why "kit's library was not found"
	return 0
}

# Whether kit can do anything here: its library and Mk4tcl (which kitfmt
# reads .kit files with). Without them the pages show what they can and
# offer no kit actions.
proc kitlink::usable {} {
	variable usable
	if {[info exists usable]} { return $usable }
	set usable [expr {[load] && ![catch {::kit::mk4}]}]
}

# `kit` itself, for Run (an app runs as its own process): "" if it isn't there.
proc kitlink::kitcmd {} {
	set k [auto_execok kit]
	if {$k ne ""} { return $k }
	# the kit script by a tclsh (wish runs Properties): tclsh, else the one of this Tcl's version
	set t [lindex [concat [auto_execok tclsh] [auto_execok tclsh[info tclversion]]] 0]
	if {$t ne "" && [load] && [file exists [::kit::selfCmd]]} { return [list $t [::kit::selfCmd]] }
	return ""
}

# ---- what the pages show -------------------------------------------------------------

# The kit an app's launcher entry starts: kit writes Exec=kit run NAME into
# the entries it exports (::kit::store::Rewrite). "" for an app that isn't
# a kit.
proc kitlink::for_exec {exec} {
	if {[regexp {(?:^|/)kit\s+run\s+(\S+)} $exec -> name]} { return $name }
	return ""
}

# An installed kit's facts (a dict, see empty), or "" when WORD isn't installed.
proc kitlink::installed {word} {
	if {![load]} { return "" }
	set A [::kit::store::load]
	set l [::kit::store::findLive $A $word]
	if {$l eq ""} { return "" }
	set inf [::kit::store::kinfo [dict get $l root]]
	set K [from_info $inf]
	dict set K installed 1
	dict set K root [dict get $l root]
	dict set K when [expr {[dict exists $inf installed] ? [dict get $inf installed] : ""}]
	set origin [expr {[dict exists $inf origin] ? [dict get $inf origin] : "repo"}]
	dict set K source [expr {$origin eq "repo" ? "Ribbon kits" : [file tail $origin]}]
	set ps [::kit::store::dataPaths $inf]
	set n 0; foreach p $ps { incr n [::kit::store::du $p] }
	dict set K datapaths $ps
	dict set K data $n
	set kf [::kit::path store [dict get $l root] kit]
	dict set K kitfile $kf
	if {[file exists $kf]} {
		dict set K stored [file size $kf]
		dict set K checked [file mtime [::kit::path store [dict get $l root] info]]
		catch { dict set K chunks [dict get [file_info $kf] chunks] }
	}
	# the shared libraries it is locked to (D32)
	set key [::kit::store::key $l]
	set libs {}
	foreach u [dict get $A uses] {
		lassign $u user need lk
		if {$user ne $key} continue
		lassign [split $lk] ln lv
		set range ""
		foreach nd [dict get $inf needs] { if {[lindex $nd 0] eq $need} { set range [lindex $nd 1] } }
		set lshort $ln; set lroot ""
		foreach k [::kit::store::lines $A $ln] {
			catch { set lshort [dict get [::kit::store::kinfo [dict get $k root]] short] }
			if {[dict get $k version] eq $lv} { set lroot [dict get $k root] }
		}
		# the installed kits locked to this very library (old versions kept for rewind don't count)
		set users {}
		foreach uk [::kit::store::users $A $lk] {
			if {[dict exists $A kits $uk] && [dict get $A kits $uk reason] ne "prev"} { lappend users [lindex [split $uk] 0] }
		}
		lappend libs [list $lshort $lv $range $ln [llength [lsort -unique $users]] \
			[expr {$lroot ne "" ? [::kit::store::du [::kit::path store $lroot]] : ""}]]
	}
	dict set K libs $libs
	# where it is on disk: the program (its store entry), its data, and the caches inside its data
	dict set K programdir [::kit::path store [dict get $l root]]
	dict set K programsize [::kit::store::du [dict get $K programdir]]
	dict set K caches [caches $ps]
	dict set K cachesizes [lmap c [dict get $K caches] { ::kit::store::du $c }]
	# each data path without the caches inside it
	dict set K datasizes [lmap p $ps {
		set b [::kit::store::du $p]
		foreach c [dict get $K caches] cb [dict get $K cachesizes] { if {[file dirname $c] eq $p} { set b [expr {$b - $cb}] } }
		set b
	}]
	# held at this version (kit rewind KIT, kit grab KIT@VERSION): check doesn't offer it
	if {[dict get $K name] in [dict get $A holds]} {
		dict set K held 1
		lassign [held_from $l] from when
		dict set K heldfrom $from; dict set K heldwhen $when
	}
	# what the last index says of it (no network): its manifest's hash, and for a held kit the
	# version it would go forward to
	set newest ""
	foreach r [index_records [dict get $K name]] {
		if {[dict get $r version] eq [dict get $K version] && [dict get $r root] eq [dict get $l root]} { dict set K manifest [dict get $r bundle] }
		if {[::kit::vcmp [dict get $r version] [dict get $K version]] > 0 &&
			($newest eq "" || [::kit::vcmp [dict get $r version] [dict get $newest version]] > 0)} { set newest $r }
	}
	if {[dict get $K held] && $newest ne ""} {
		dict set K heldnew [dict create new [dict get $newest version] bytes [dict get $newest download]]
	}
	# the update waiting, from the last check (kit list's source; no network)
	set ups [::kit::verbs::loadUpdates]
	if {[dict exists $ups updates]} {
		foreach u [dict get $ups updates] {
			if {[dict get $u name] eq [dict get $K name]} {
				dict set K update [dict create new [dict get $u new] bytes [dict get $u download] \
					security [expr {"security" in [split [dict get $u flags] ,]}] released ""]
			}
		}
		if {[dict exists $ups checked]} { dict set K indexage [expr {[clock seconds] - [dict get $ups checked]}] }
	}
	dict set K grants [grants_read [dict get $K name]]
	return $K
}

# A .kit file's facts, installed or not (Properties on a .kit in Files).
proc kitlink::kitfile {path} {
	if {![usable]} { error "kit can't read .kit files here" }
	::kit::kitfmt
	set h [::kitfmt open $path]
	set rc [catch {
		set fi [::kitfmt info $h]; set m [::kitfmt manifest $h]
		set f [dict get $m fields]
		set inf [dict create name [dict get $f name] version [dict get $f version] kind [dict get $f kind] \
			short [::kit::shortOf [dict get $f name] [expr {[dict exists $f x-short] ? [dict get $f x-short] : ""}]] \
			summary [expr {[dict exists $f summary] ? [dict get $f summary] : ""}] size [dict get $fi bytes] fields $f \
			needs [dict get $m needs] perms [dict get $m perms] entries [dict get $m entries] effects [dict get $m effects] \
			signer [dict get $fi signature] root [dict get $fi root]]
		set desktop ""
		foreach e [dict get $m effects] {
			if {[lindex $e 0] eq "desktop" && ![catch {::kitfmt read $h [lindex $e 1]} d]} { set desktop [encoding convertfrom utf-8 $d] }
		}
		set chunks [dict get $fi chunks]
	} err opts]
	::kitfmt close $h
	if {$rc} { return -options $opts $err }
	set K [from_info $inf $desktop]
	dict set K file [file normalize $path]
	dict set K kitfile [file normalize $path]
	dict set K stored [file size $path]
	dict set K chunks $chunks
	dict set K source [file tail $path]
	# kit's kind (app or system: who it installs for); its signature was checked just now, on opening it
	dict set K kitkind [dict get $f kind]
	dict set K checked [clock seconds]
	dict set K libs [lmap n [dict get $inf needs] { list [lindex [split [lindex $n 0] .] end] "" [lindex $n 1] [lindex $n 0] "" "" }]
	foreach r [index_records [dict get $K name]] {
		if {[dict get $r version] eq [dict get $K version] && [dict get $r root] eq [dict get $inf root]} { dict set K manifest [dict get $r bundle] }
	}
	dict set K grants [grants_read [dict get $K name]]
	# the same version installed: its pages, with this file's name kept
	set I [installed [dict get $K name]]
	if {$I ne "" && [dict get $I version] eq [dict get $K version]} { dict set I file [dict get $K file]; return $I }
	if {$I ne ""} { dict set K installedversion [dict get $I version] }
	return $K
}

# The facts every kit has, from kit's info dict (store/<root>/info) or a
# .kit's manifest.
proc kitlink::from_info {inf {desktop ""}} {
	set f [dict get $inf fields]
	set K [empty]
	foreach k {name version short summary size} { if {[dict exists $inf $k]} { dict set K $k [dict get $inf $k] } }
	dict set K perms [dict get $inf perms]
	dict set K needs [dict get $inf needs]
	if {[dict exists $inf root]} { dict set K root [dict get $inf root] }
	foreach k {publisher homepage license description} { if {[dict exists $f $k]} { dict set K $k [dict get $f $k] } }
	# the app's own name, kind and icon from its launcher entry
	if {$desktop eq "" && [dict exists $inf exports]} {
		foreach rel [dict get $inf exports] {
			if {![string match applications/* $rel]} continue
			set p [::kit::path store [dict get $inf root] export $rel]
			if {![catch {open $p} fh]} { fconfigure $fh -encoding utf-8; set desktop [read $fh]; close $fh }
		}
	}
	set e [facts::desktop_parse $desktop]
	dict set K title [expr {[dict exists $e Name] ? [dict get $e Name] : [string totitle [dict get $K short]]}]
	dict set K kind [expr {[dict exists $e GenericName] ? [dict get $e GenericName] : [dict get $K summary]}]
	dict set K cats [expr {[dict exists $e Categories] ? [dict get $e Categories] : ""}]
	# the signature and who made it
	set sig [dict get $inf signer]
	if {$sig ne "" && [dict exists $sig state]} {
		dict set K sigstate [dict get $sig state]
		dict set K keyid [dict get $sig keyid]
		lassign [trusted_key [dict get $sig keyid]] key comment
		dict set K key $key
		dict set K signer [expr {$comment ne "" ? $comment : [dict get $sig comment]}]
		# when it was sealed: minisign's own trusted comment ("timestamp:N ..."), which a valid
		# signature covers; any other comment says nothing of when
		if {[dict get $sig state] eq "valid" && [regexp {^timestamp:([0-9]+)(\s|$)} [dict get $sig comment] -> ts]} { dict set K sealed $ts }
		set t [trust [dict get $sig keyid]]
		if {[dict size $t]} {
			foreach k {key keyroles keyfrom keyuntil repository revoked listserial listexpires rootname} { dict set K $k [dict get $t $k] }
			if {[dict get $t name] ne ""} { dict set K signer [dict get $t name] }
			if {[dict get $t revoked] ne ""} { dict set K sigstate revoked }
		}
	}
	return $K
}

proc kitlink::empty {} {
	dict create name "" short "" title "" kind "" cats "" summary "" version "" size 0 installed 0 when "" \
		source "" data "" datapaths {} stored "" checked "" chunks "" indexage "" sigstate "" keyid "" key "" \
		signer "" perms {} needs {} libs {} update "" grants {} file "" kitfile "" root "" installedversion "" \
		keyroles {} keyfrom "" keyuntil "" repository "" revoked "" listserial "" listexpires "" rootname "" manifest "" \
		programdir "" programsize "" datasizes {} caches {} cachesizes {} held 0 heldfrom "" heldwhen "" heldnew "" sealed "" kitkind ""
}

# ---- on disk, held, the index ---------------------------------------------------------------

# The cache directories inside a kit's data (PATHS, kit's dataPaths): .cache, cache or Cache
# directly in one of them. kit keeps no cache of its own for a kit; this is the app's, by the
# names apps use.
proc kitlink::caches {paths} {
	set out {}
	foreach p $paths {
		if {[catch {file type $p} t] || $t ne "directory"} continue
		foreach n {.cache cache Cache} {
			set c [file join $p $n]
			if {![catch {file type $c} t] && $t eq "directory"} { lappend out $c }
		}
	}
	return $out
}

# Empty the caches of the installed kit NAME, or just DIR of them (the directories stay).
# Returns the bytes freed.
proc kitlink::clear_cache {name {dir ""}} {
	set K [installed $name]
	if {$K eq ""} { error "$name is not installed" }
	set n 0
	foreach c [dict get $K caches] {
		if {$dir ne "" && $c ne $dir} continue
		# only ever a cache directory right inside the kit's own data
		if {[file dirname $c] ni [dict get $K datapaths]} continue
		foreach f [glob -nocomplain -directory $c * .*] {
			if {[file tail $f] in {. ..}} continue
			incr n [::kit::store::du $f]
			file delete -force -- $f
		}
	}
	return $n
}

# What a held kit was taken back from: {version time} of the newest change in kit's history that
# brought it to the version it has; {} when history has none (held by version where it was).
proc kitlink::held_from {l} {
	set out {}
	catch {
		foreach id [::kit::txn::history] {
			set e [::kit::txn::entry $id]
			set b [::kit::store::live [::kit::store::parse [dict get $e before]] [dict get $l name]]
			set a [::kit::store::live [::kit::store::parse [dict get $e after]] [dict get $l name]]
			if {$a eq "" || $b eq "" || [dict get $a version] eq [dict get $b version]} continue
			if {[dict get $a version] eq [dict get $l version]} { set out [list [dict get $b version] [dict get $e time]] }
			break
		}
	}
	return $out
}

# The index's records for NAME, from the index kit has here (the pinned one, or the last one
# fetched): the network is not touched. {} when there is none.
proc kitlink::index_records {name} {
	variable idx
	if {![info exists idx]} {
		set idx ""
		catch {
			set pin [::kit::pinned]
			set idx [expr {$pin ne "" ? [::kit::repo::loadPinned $pin] : [::kit::repo::loadCache]}]
		}
	}
	if {$idx eq ""} { return {} }
	lmap r [dict get $idx kits] { if {[dict get $r name] ne $name} continue; set r }
}

# ---- kittrust: the trusted key list -----------------------------------------------------

# What the trusted key lists say about KEYID: {key keyroles keyfrom keyuntil
# repository revoked name listserial listexpires rootname}, or {} (no list
# holds it). The list is kit's own choice (::kit::keyHolder): Ribbon's when
# it holds the key, else the first other repository's that does, so a kit
# from another repository names its signer from that repository's list.
proc kitlink::trust {keyid} {
	if {$keyid eq "" || ![load] || [catch {::kit::kitfmt}]} { return {} }
	set ids [::kit::keyHolder $keyid]
	if {![llength $ids]} { return {} }
	set T [::kit::keyList [lindex $ids 0]]
	if {$T eq ""} { return {} }
	set out [dict create key "" keyroles {} keyfrom "" keyuntil "" repository [dict get $T repository] revoked "" name "" \
		listserial [dict get $T serial] listexpires [dict get $T expires] rootname ""]
	# the root that signs the list (one name when there is one root)
	set roots [dict values [dict get $T roots]]
	if {[llength $roots] == 1} { dict set out rootname [dict get [lindex $roots 0] name] }
	if {[dict exists $T keys $keyid]} {
		set k [dict get $T keys $keyid]
		dict set out key [dict get $k pk]; dict set out keyroles [dict get $k roles]
		dict set out keyfrom [dict get $k from]; dict set out keyuntil [dict get $k until]; dict set out name [dict get $k name]
	} elseif {[dict exists $T revoked $keyid]} {
		set r [dict get $T revoked $keyid]
		dict set out key [dict get $r pk]; dict set out revoked [dict get $r time]
		if {[dict exists $r name]} { dict set out name [dict get $r name] }
	} else { return {} }
	return $out
}

# kitfmt's info for a .kit (the chunk count).
proc kitlink::file_info {path} {
	::kit::kitfmt
	set h [::kitfmt open $path]
	set rc [catch {::kitfmt info $h} fi opts]
	::kitfmt close $h
	if {$rc} { return -options $opts $fi }
	return $fi
}

# The trusted key with this key id and its comment in the trusted-keys file
# (/etc/kit/trusted-keys: "KEY comment" lines).
proc kitlink::trusted_key {keyid} {
	if {$keyid eq "" || [catch {::kit::slurp [::kit::keysFile] utf-8} text] || [catch {::kit::kitfmt}]} { return {"" ""} }
	foreach line [split $text \n] {
		set line [string trim $line]
		if {$line eq "" || [string index $line 0] eq "#"} continue
		set k [lindex [split $line] 0]
		if {[catch {::kitfmt::PubKeyId $k} id] || $id ne $keyid} continue
		return [list $k [string trim [string range $line [string length $k] end]]]
	}
	return {"" ""}
}

# How old the repository index is (seconds), or "".
proc kitlink::index_age {} {
	if {![load]} { return "" }
	set m [::kit::repo::meta]
	if {[dict exists $m checked]} { return [expr {[clock seconds] - [dict get $m checked]}] }
	return ""
}

# ---- doing things: kit's verbs, in this process ------------------------------------------

# Run VERB (Grab Mend Toss) on ARGS with this app drawing kit's prompt.
# Returns {code text}: kit's exit code (0 done, 1 you said no, 2 usage,
# 3 network, 4 verification) and what it said.
proc kitlink::verb {verb args} {
	variable out ""
	if {![load]} { return [list 2 [set kitlink::why]] }
	set ::kit::ui::yes 0
	chan push stdout kitlink::capture
	set rc [catch {
		::kit::prologue
		::kit::txn::recover
		::kit::verbs::$verb {*}$args
	} res opts]
	chan pop stdout
	catch {::kit::unlock}
	catch {::kit::store::closeAll}
	# kit's caches of what is installed are per process; drop them
	catch {array unset ::kit::store::infoCache}
	catch {set ::kit::store::chunkMap ""}
	unset -nocomplain kitlink::idx
	set said [string trim $out]
	if {$rc == 0} { return [list [expr {[string is integer -strict $res] ? $res : 0}] $said] }
	set ec [dict get $opts -errorcode]
	switch -- [lindex $ec 0] {
		KIT { set code [lindex $ec 1] }
		KITFMT { set code [expr {[lindex $ec 1] in {CONFIG NOENT EXISTS} ? 2 : 4}] }
		default { set code 2 }
	}
	return [list $code [string trim "$said\n$res"]]
}

proc kitlink::grab {target} { verb Grab $target }
proc kitlink::mend {name} { verb Mend $name }
proc kitlink::toss {name} { verb Toss $name }
# Rewind: kit goes back to the version before this one (kit rewind KIT). Offered
# only when kit's history has an earlier version of the kit (kitlink::previous).
proc kitlink::rewind {name} { verb Rewind $name }

# 1 when NAME is installed and kit's history has an earlier version, else 0.
proc kitlink::previous {name} {
	if {![load]} { return 0 }
	set ok 0
	catch {
		::kit::prologue
		set A [::kit::store::load]
		set l [::kit::store::findLive $A $name]
		if {$l ne "" && [::kit::verbs::PreviousOf $l] ne ""} { set ok 1 }
	}
	catch {array unset ::kit::store::infoCache}
	catch {::kit::unlock}
	catch {::kit::store::closeAll}
	return $ok
}

# What Uninstall would do, asked before anything is done (kit toss itself asks nothing before it
# removes): {code rows data said}. rows are kit's plan rows (plan::toss), each with the bytes its
# store entry takes; data has one dict per kit with data (name, q: toss's own question, on 0).
# code is 0, or kit's exit code with what it said.
proc kitlink::toss_plan {name} {
	if {![load]} { return [list 2 {} {} [set kitlink::why]] }
	set rc [catch {
		::kit::prologue
		set P [::kit::plan::toss [::kit::store::load] [list $name]]
		set rows {}; set data {}
		foreach r [dict get $P rows] {
			dict set r bytes [::kit::store::du [::kit::path store [dict get $r root]]]
			lappend rows $r
			set ps [::kit::store::dataPaths [::kit::store::kinfo [dict get $r root]]]
			if {![llength $ps]} continue
			set n 0; foreach p $ps { incr n [::kit::store::du $p] }
			set where [join [lmap p $ps { ::kit::tilde $p }] " and "]
			lappend data [dict create name [dict get $r fullname] q "Also remove its data in $where ([::kit::fmtsize $n])?" on 0]
		}
		list $rows $data [join [dict get $P notes] \n]
	} res opts]
	catch {array unset ::kit::store::infoCache}
	catch {::kit::unlock}
	catch {::kit::store::closeAll}
	if {$rc == 0} { return [list 0 {*}$res] }
	set ec [dict get $opts -errorcode]
	return [list [expr {[lindex $ec 0] eq "KIT" ? [lindex $ec 1] : 2}] {} {} $res]
}

# What a verb prints to stdout (a channel transform; kit's notes).
proc kitlink::capture {op chan args} {
	variable out
	switch -- $op {
		initialize { return {initialize finalize write flush clear} }
		write { append out [encoding convertfrom utf-8 [lindex $args 0]]; return "" }
		default { return "" }
	}
}

# kit's prompt (::kit::ui::ask), drawn by Properties: the plan's rows and
# the question on the sheet's button. ANSWER "" means ask.
proc kitlink::renderer {op rows question default given} {
	variable data
	if {$question eq ""} { return 1 }
	if {$given ne ""} { return $given }
	# toss's data question was answered on the Uninstall sheet (its checkbox); a question about data
	# that sheet didn't show keeps the data, as kit's own default does
	if {[string match "Also remove its data in *" $question]} {
		set n [dict get [lindex $rows 0] fullname]
		return [expr {[dict exists $data $n] ? [dict get $data $n] : 0}]
	}
	set kitlink::answer ""
	page::plan_sheet $rows $question $default
	vwait kitlink::answer
	return $kitlink::answer
}

# The prompt's rows as kit's terminal shows them (for the sheet).
proc kitlink::lines {rows} {
	if {[load]} { return [::kit::ui::lines $rows] }
	return {}
}
proc kitlink::fmtsize {n} {
	if {[load]} { return [::kit::fmtsize $n] }
	if {$n < 1000000} { return "[expr {($n + 999) / 1000}] kB" }
	if {$n < 10000000000} { return "[expr {round($n / 1e6)}] MB" }
	return "[expr {round($n / 1e9)}] GB"
}

# Start a kit (kit run: an app of its own, so it runs as its own process).
proc kitlink::run {target} {
	set k [kitcmd]
	if {$k eq ""} { return 0 }
	exec {*}$k run $target </dev/null >/dev/null 2>@1 &
	return 1
}

# ---- the permissions you grant (KIT-CLI.md, "Permissions you grant") -------------------
#
#   ~/.config/kit/grants/<kit name>      written atomically, UTF-8, LF:
#     ribbon-kit-grants 1
#     perm<TAB><name><TAB><value>         as the kit index's perm lines, escaped alike
#
# A line replaces the kit's request of that name; a name with no line gets
# what the kit requests. The file is yours: no kit writes it, grab and mend
# never touch it, toss leaves it (reinstalling keeps your choices).

proc kitlink::grants_file {name} {
	if {[load]} { return [::kit::path config grants $name] }
	set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/"}]
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne "" ? $::env(XDG_CONFIG_HOME) : "$home/.config"}]
	file join $cfg kit grants $name
}

proc kitlink::grants_read {name} {
	if {$name eq "" || [string match *..* $name] || [string match */* $name]} { return {} }
	if {[catch {open [grants_file $name]} fh]} { return {} }
	fconfigure $fh -encoding utf-8
	set lines [split [read $fh] \n]
	close $fh
	if {[lindex $lines 0] ne "ribbon-kit-grants 1"} { return {} }
	set g {}
	foreach line [lrange $lines 1 end] {
		set f [lmap x [split $line \t] { string map [list \\\\ \\ \\t \t \\n \n \\r \r] $x }]
		if {[lindex $f 0] eq "perm" && [regexp {^[a-z][a-z0-9-]*$} [lindex $f 1]]} { dict set g [lindex $f 1] [lindex $f 2] }
	}
	return $g
}

proc kitlink::grants_write {name grants} {
	if {$name eq "" || [string match *..* $name] || [string match */* $name]} { error "not a kit name: $name" }
	set f [grants_file $name]
	if {![dict size $grants]} { file delete $f; return }
	set out "ribbon-kit-grants 1\n"
	foreach k [lsort [dict keys $grants]] {
		set v [string map [list \\ \\\\ \t \\t \n \\n \r \\r] [dict get $grants $k]]
		append out "perm\t$k\t$v\n"
	}
	file mkdir [file dirname $f]
	set tmp $f.tmp[pid]
	set fh [open $tmp w]
	fconfigure $fh -encoding utf-8 -translation lf
	puts -nonewline $fh $out
	close $fh
	file rename -force $tmp $f
}
