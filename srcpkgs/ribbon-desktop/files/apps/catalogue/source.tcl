# source.tcl - what the Catalogue knows, without Tk: the apps Ribbon's kits and Flathub list,
# what is installed, one app's details, and installing one. The window (page.tcl) draws this
# model and calls its actions; tests drive it alone (tests/catalogue-source.tcl).
#
#   Ribbon kits   kit's own library, in a process of its own (kitq.tcl): the signed index, kit's
#                 prompt and kit's grab, the same machinery as `kit grab` and Properties.
#   Flathub       the flatpak command, on the user's installation and its "flathub" remote (the one
#                 the welcome adds; the Catalogue adds it the same way when it is missing):
#                 remote-ls for the list, list for what is installed, remote-info for one app's
#                 facts and --show-metadata for what it asks for, install for installing.
#   .flatpakref   a [Flatpak Ref] file (double-clicked in Files): its fields, and the remote's
#                 facts when the ref points at a remote this user has; flatpak install --from.
#
# Every command runs without blocking (cat::run): the window never waits on the network.

namespace eval cat {
	variable here [file dirname [file normalize [info script]]]
	variable kits {}        ;# the index's apps: dicts name short title summary version size download installed tags
	variable kitstate loading   ;# loading | ready | none
	variable kitwhy ""
	variable checked 0      ;# when kit's mirror last answered
	variable flat {}        ;# Flathub's apps: dicts id name summary version download
	variable flatstate loading
	variable flatwhy ""
	variable flatinst {}    ;# installed Flatpak apps: id -> dict name summary version origin installation
	variable remote flathub
	variable changed ""     ;# a command prefix called when the model changes (the window redraws)
	variable job {}         ;# the install running: source name fh phase done total pct said
	variable last {}        ;# the install that ended last (the window says why one failed)
	variable detail {}      ;# the app shown: source (kit|flathub|ref) id, and what is known of it
	variable pipes
	array set pipes {}
}

proc cat::notify {} {
	variable changed
	if {$changed ne ""} { uplevel #0 $changed }
}

# ---- running commands ----------------------------------------------------------------------------

# Run ARGV with stdin from nowhere; DONE gets {code out err} when it has finished. Returns the channel.
proc cat::run {argv done} {
	variable pipes
	set err [file tempfile errf]
	close $err
	if {[catch {::open |[list {*}$argv </dev/null 2>$errf] r} fh]} {
		file delete $errf
		after idle [list {*}$done 127 "" $fh]
		return ""
	}
	fconfigure $fh -blocking 0 -encoding utf-8 -translation lf
	set pipes($fh) [list "" $errf $done]
	fileevent $fh readable [list cat::run_read $fh]
	return $fh
}
proc cat::run_read {fh} {
	variable pipes
	lassign $pipes($fh) out errf done
	append out [read $fh]
	lset pipes($fh) 0 $out
	if {![eof $fh]} return
	fconfigure $fh -blocking 1
	set code 0
	if {[catch {close $fh} e opts]} {
		set ec [dict get $opts -errorcode]
		set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : 1}]
	}
	set err ""
	catch { set f [::open $errf]; fconfigure $f -encoding utf-8; set err [read $f]; close $f }
	file delete $errf
	unset pipes($fh)
	uplevel #0 [list {*}$done $code $out $err]
}

proc cat::tclsh {} {
	if {[info exists ::env(CATALOGUE_TCLSH)]} { return $::env(CATALOGUE_TCLSH) }
	set t [concat [auto_execok tclsh] [auto_execok tclsh[info tclversion]]]
	expr {$t ne "" ? [lindex $t 0] : [info nameofexecutable]}
}
proc cat::flatpak {} {
	set f [auto_execok flatpak]
	expr {$f ne "" ? [lindex $f 0] : ""}
}
proc cat::kitq {args} { list [tclsh] -encoding utf-8 [file join $cat::here kitq.tcl] {*}$args }

# The protocol lines kitq.tcl says ("catalogue: KIND DATA..."), in order: {KIND DATA}...
proc cat::said {out} {
	set r {}
	foreach line [split $out \n] {
		if {[string match "catalogue: *" $line] && ![catch {lrange $line 1 end} l] && [llength $l]} { lappend r $l }
	}
	return $r
}

# ---- sizes -------------------------------------------------------------------------------------------
# kit's sizes (::kit::fmtsize): kB below a megabyte, whole MB below 10 GB
proc cat::fmtsize {n} {
	if {![string is wide -strict $n] || $n <= 0} { return "" }
	if {$n < 1000000} { return "[expr {($n + 999) / 1000}] kB" }
	if {$n < 10000000000} { return "[expr {round($n / 1e6)}] MB" }
	return "[expr {round($n / 1e9)}] GB"
}
# flatpak's "98.2 MB", "1.1 GB", "850.0 kB" in bytes ("" when it is not a size)
proc cat::bytes {s} {
	set s [string map {  " "} [string trim $s]]
	if {![regexp {^([0-9]+(?:[.,][0-9]+)?)\s*(bytes|B|kB|KB|MB|GB|TB)?$} $s -> n u]} { return "" }
	set n [string map {, .} $n]
	set m [dict get {"" 1 bytes 1 B 1 kB 1e3 KB 1e3 MB 1e6 GB 1e9 TB 1e12} $u]
	expr {wide(round($n * $m))}
}

# ---- a tile's glyph ------------------------------------------------------------------------------------
# What an app is, from its name, id and words (properties/facts.tcl's app_icon_for, without categories)
proc cat::glyph {name id words} {
	set k [string tolower "$name $id $words"]
	foreach {re g} {
		{firefox|chrom|browser|web} globe {terminal} terminal {steam|game|heroic|lutris} game
		{bottles|wine|windows} wine {chat|messag|discord} chat
		{record|stream|obs} rec {video|movie|film|vlc|mpv} film {music|audio|spotify|podcast} music
		{database|sql} db {photo|image|gimp|krita|picture} image {draw|paint|vector|inkscape} brush
		{code|develop|ide} code {office|document|writer} doc
	} { if {[regexp $re $k]} { return $g } }
	return box
}

# ---- Ribbon kits ----------------------------------------------------------------------------------------
proc cat::load_kits {} {
	variable kitstate loading
	run [kitq apps] cat::kits_done
}
proc cat::kits_done {code out err} {
	variable kits
	variable kitstate
	variable kitwhy
	variable checked
	set kitstate none
	set kitwhy [string trim $err]
	foreach l [said $out] {
		lassign $l kind a b
		switch -- $kind {
			apps {
				set kits [lmap r $a {
					if {![dict exists $r title] || [dict get $r title] eq ""} { dict set r title [title [dict get $r short] [dict get $r summary]] }
					dict set r source kit
					dict set r id [dict get $r name]
					set r
				}]
				set checked $b
				set kitstate ready
			}
			noindex { set kitwhy $a }
		}
	}
	notify
}
# A kit's display name: the index has only its short name (obs, firefox), so a kit that is not
# installed is called by it, capitalised; an installed one by its launcher entry's Name (kitq.tcl).
proc cat::title {short summary} {
	set t [string map {- " " _ " "} $short]
	return "[string toupper [string index $t 0]][string range $t 1 end]"
}

# ---- Flathub ----------------------------------------------------------------------------------------------
proc cat::load_flat {} {
	variable flatstate loading
	variable flatwhy
	if {[flatpak] eq ""} { set flatstate none; set flatwhy "Flatpak is not installed"; notify; return }
	# the user's flathub remote, added as the welcome adds it, when it is not there yet
	set repo [expr {[info exists ::env(CATALOGUE_FLATHUB_REPO)] ? $::env(CATALOGUE_FLATHUB_REPO) : "/usr/share/ribbon/flatpak/flathub.flatpakrepo"}]
	run [list [flatpak] remote-add --user --if-not-exists -- flathub $repo] cat::flat_remote
}
proc cat::flat_remote {code out err} {
	variable remote
	run [list [flatpak] remote-ls --user --app --columns=application,name,version,description,download-size -- $remote] cat::flat_done
	load_flatinst
}
proc cat::flat_done {code out err} {
	variable flat
	variable flatstate
	variable flatwhy
	if {$code != 0} { set flatstate none; set flatwhy [string trim $err]; notify; return }
	set flat [parse_remote_ls $out]
	set flatstate ready
	notify
}
proc cat::load_flatinst {} {
	if {[flatpak] eq ""} return
	run [list [flatpak] list --app --columns=application,name,version,description,origin,installation,branch] cat::flatinst_done
}
proc cat::flatinst_done {code out err} {
	variable flatinst
	if {$code == 0} { set flatinst [parse_list $out] }
	notify
}

# flatpak remote-ls --columns=application,name,version,description,download-size: one app a line, TAB
# between columns (flatpak prints a header only to a terminal)
proc cat::parse_remote_ls {text} {
	set out {}
	set seen {}
	foreach line [split $text \n] {
		set f [split $line \t]
		if {[llength $f] < 2} continue
		lassign $f id name version summary dl
		if {$id eq "" || [dict exists $seen $id] || $id eq "Application ID"} continue
		dict set seen $id 1
		if {$name eq ""} { set name $id }
		lappend out [dict create source flathub id $id name $id title $name summary $summary version $version \
			download [bytes $dl] installed ""]
	}
	lsort -dictionary -command {apply {{a b} { string compare -nocase [dict get $a title] [dict get $b title] }}} $out
}
# flatpak list --app --columns=application,name,version,description,origin,installation,branch
proc cat::parse_list {text} {
	set out {}
	foreach line [split $text \n] {
		set f [split $line \t]
		if {[llength $f] < 2} continue
		lassign $f id name version summary origin inst branch
		if {$id eq "" || $id eq "Application ID"} continue
		dict set out $id [dict create name $name version $version summary $summary origin $origin installation $inst branch $branch]
	}
	return $out
}
# What an installed app's row and page say it is at: flatpak list's version, which is empty for an
# app whose appdata names no release (it is still installed), then the version KNOWN from the
# remote, then its branch; never "" (an empty one means not installed)
proc cat::instver {i {known ""}} {
	foreach v [list [dict get $i version] $known [expr {[dict exists $i branch] ? [dict get $i branch] : ""}]] { if {$v ne ""} { return $v } }
	return installed
}
# flatpak remote-info's facts ("     Key: value" lines under the title line): a dict of them
proc cat::parse_remote_info {text} {
	set d {}
	foreach line [split $text \n] {
		if {[regexp {^\s*([A-Za-z][A-Za-z ]*):\s(.*)$} $line -> k v]} { dict set d [string trim $k] [string trim $v] }
	}
	return $d
}
# A key file ([Group] then key=value lines): dict group -> dict key -> value
proc cat::parse_keyfile {text} {
	set d {}; set g ""
	foreach line [split $text \n] {
		set line [string trim $line]
		if {$line eq "" || [string index $line 0] eq "#"} continue
		if {[regexp {^\[(.+)\]$} $line -> g]} { if {![dict exists $d $g]} { dict set d $g {} }; continue }
		if {$g ne "" && [regexp {^([^=]+?)\s*=\s*(.*)$} $line -> k v]} { dict set d $g $k $v }
	}
	return $d
}
# What a Flatpak app asks for (its metadata's [Context] and session bus policy), as the Overview's
# chips: {icon label state}, in Properties' order and words (properties/perms.tcl, perms::allowed).
proc cat::flat_requests {metadata} {
	set m [parse_keyfile $metadata]
	set ctx [expr {[dict exists $m Context] ? [dict get $m Context] : {}}]
	set get {apply {{ctx k} { if {[dict exists $ctx $k]} { split [string trim [dict get $ctx $k] ";"] ";" } }}}
	set shared [{*}$get $ctx shared]; set sockets [{*}$get $ctx sockets]; set devices [{*}$get $ctx devices]
	set fs [{*}$get $ctx filesystems]
	set out {}
	if {"network" in $shared} { lappend out {globe Network ""} }
	set folders {}; set home ""
	foreach f $fs {
		set mode [expr {[string match *:ro $f] ? "read only" : "read & write"}]
		set f [regsub {:(ro|rw|create)$} $f ""]
		switch -glob -- $f {
			host - host-os - host-etc { lappend folders [list disk {All files} $mode] }
			home - ~ { set home [list home Home $mode] }
			xdg-download* { lappend folders [list download Downloads $mode] }
			xdg-documents* { lappend folders [list file Documents $mode] }
			xdg-pictures* { lappend folders [list image Pictures $mode] }
			xdg-music* { lappend folders [list music Music $mode] }
			xdg-videos* { lappend folders [list film Videos $mode] }
		}
	}
	if {$home ne ""} { lappend out $home }
	foreach f [lsort -unique $folders] { lappend out $f }
	if {"wayland" in $sockets} { lappend out {monitor Display Wayland} } elseif {"x11" in $sockets || "fallback-x11" in $sockets} { lappend out {monitor Display X11} }
	if {"pulseaudio" in $sockets} { lappend out {vol Audio ""} }
	if {"dri" in $devices || "all" in $devices} { lappend out {chip GPU ""} }
	if {"all" in $devices} { lappend out {pad Controllers ""} {camera Camera ""} }
	set bus [expr {[dict exists $m {Session Bus Policy}] ? [dict get $m {Session Bus Policy}] : {}}]
	if {[dict exists $bus org.freedesktop.Notifications] || "session-bus" in $sockets} { lappend out {bell Notifications ""} }
	return $out
}
# A .flatpakref: its [Flatpak Ref] fields, or an error when it is not one
proc cat::parse_flatpakref {text} {
	set d [parse_keyfile $text]
	if {![dict exists $d {Flatpak Ref} Name]} { error "not a .flatpakref" }
	# the Name goes to flatpak (remote-info, install, run): only an application id, never an option or a path
	if {![appid [dict get $d {Flatpak Ref} Name]]} { error "not a .flatpakref: its Name is not an application id" }
	dict get $d {Flatpak Ref}
}
# flatpak's application ids (flatpak_is_valid_name): three or more elements of letters, digits, _ and -, at most 255 bytes
proc cat::appid {s} {
	expr {[string length $s] <= 255 && [regexp {^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$} $s]}
}
proc cat::licence {s} {
	if {[string match -nocase LicenseRef-proprietary* $s]} { return Proprietary }
	return $s
}

# ---- what the list shows ---------------------------------------------------------------------------------
# The apps for NAV (all | kits | flathub | installed) matching every word of QUERY (name, id, summary,
# tags), as {kits flathub}; installed Flatpak apps carry their installed version.
proc cat::matching {nav query} {
	variable kits
	variable flat
	variable flatinst
	set words [lmap w [split [string tolower [string trim $query]]] { if {$w eq ""} continue; set w }]
	set ok {apply {{words r} {
		set hay [string tolower "[dict get $r title] [dict get $r id] [dict get $r summary] [expr {[dict exists $r tags] ? [dict get $r tags] : ""}]"]
		foreach w $words { if {[string first $w $hay] < 0} { return 0 } }
		return 1
	}}}
	set K {}; set F {}
	if {$nav ne "flathub"} {
		set K [lsort -command {apply {{a b} { string compare -nocase [dict get $a title] [dict get $b title] }}} \
			[lmap r $kits { if {![{*}$ok $words $r]} continue; set r }]]
	}
	if {$nav ne "kits"} {
		set have {}
		foreach r $flat {
			if {[dict exists $flatinst [dict get $r id]]} { dict set r installed [instver [dict get $flatinst [dict get $r id]] [dict get $r version]] }
			dict set have [dict get $r id] 1
			if {[{*}$ok $words $r]} { lappend F $r }
		}
		# installed apps the remote no longer lists (or another remote's) still show under Installed
		if {$nav eq "installed"} {
			dict for {id i} $flatinst {
				if {[dict exists $have $id]} continue
				set r [dict create source flathub id $id name $id title [expr {[dict get $i name] ne "" ? [dict get $i name] : $id}] \
					summary [dict get $i summary] version [dict get $i version] download "" installed [instver $i] origin [dict get $i origin]]
				if {[{*}$ok $words $r]} { lappend F $r }
			}
		}
	}
	if {$nav eq "installed"} {
		set K [lmap r $K { if {[dict get $r installed] eq ""} continue; set r }]
		set F [lmap r $F { if {[dict get $r installed] eq ""} continue; set r }]
	}
	list $K $F
}

# ---- one app -------------------------------------------------------------------------------------------------
# Show ROW's details: what the list knows at once, kit info or flatpak remote-info as they come.
proc cat::open_app {row} {
	variable detail
	set detail [dict merge $row [dict create state loading requests {} needs {} facts {}]]
	switch -- [dict get $row source] {
		kit { run [kitq info [dict get $row name]] [list cat::kitinfo_done [dict get $row id]] }
		flathub { flat_info [dict get $row id] $cat::remote }
	}
	notify
}
proc cat::kitinfo_done {id code out err} {
	variable detail
	if {[dict get $detail id] ne $id} return
	dict set detail state ready
	foreach l [said $out] {
		lassign $l kind D
		if {$kind ne "info"} continue
		foreach k {version size download summary installed when needs uses checked sigstate keyid} { if {[dict exists $D $k]} { dict set detail $k [dict get $D $k] } }
		dict set detail perms [dict get $D perms]
		dict set detail signer [dict get $D signer]
	}
	if {$code != 0 && [string trim $err] ne ""} { dict set detail why [string trim $err] }
	notify
}
proc cat::flat_info {id remote} {
	if {[flatpak] eq ""} return
	run [list [flatpak] remote-info --user -- $remote $id] [list cat::flatinfo_done $id]
	run [list [flatpak] remote-info --user --show-metadata -- $remote $id] [list cat::flatmeta_done $id]
}
proc cat::flatinfo_done {id code out err} {
	variable detail
	if {[dict get $detail id] ne $id} return
	if {$code == 0} {
		set f [parse_remote_info $out]
		dict set detail facts $f
		if {[dict exists $f Version] && [dict get $f Version] ne ""} { dict set detail version [dict get $f Version] }
		if {[dict exists $f Download]} { dict set detail download [bytes [dict get $f Download]] }
		# the title line: "Name - summary"
		set first [string trim [lindex [split [string trim $out] \n] 0]]
		if {[regexp {^(.+?) - (.+)$} $first -> n s] && ![dict exists $f $first]} {
			if {[dict get $detail source] eq "ref" || [dict get $detail title] eq $id} { dict set detail title $n }
			if {[dict get $detail summary] eq ""} { dict set detail summary $s }
		}
	} else { dict set detail why [string trim $err] }
	dict set detail state ready
	notify
}
proc cat::flatmeta_done {id code out err} {
	variable detail
	if {[dict get $detail id] ne $id} return
	if {$code == 0} { dict set detail requests [flat_requests $out] }
	notify
}

# A .flatpakref FILE: its page (the remote's facts when the ref points at one of this user's remotes)
proc cat::open_ref {file} {
	variable detail
	set fh [::open $file]; fconfigure $fh -encoding utf-8; set text [read $fh]; ::close $fh
	set R [parse_flatpakref $text]
	set id [dict get $R Name]
	set title [expr {[dict exists $R Title] ? [dict get $R Title] : $id}]
	set detail [dict create source ref id $id name $id title $title summary "" version "" download "" installed "" file $file \
		branch [expr {[dict exists $R Branch] ? [dict get $R Branch] : ""}] url [expr {[dict exists $R Url] ? [dict get $R Url] : ""}] \
		state loading requests {} facts {} remote ""]
	if {[dict exists $cat::flatinst $id]} { dict set detail installed [instver [dict get $cat::flatinst $id]] }
	if {[flatpak] eq ""} { dict set detail state ready; notify; return }
	run [list [flatpak] remotes --user --columns=name,url] [list cat::ref_remotes $id]
	notify
}
proc cat::ref_remotes {id code out err} {
	variable detail
	if {[dict get $detail id] ne $id} return
	set want [string trimright [dict get $detail url] /]
	foreach line [split $out \n] {
		lassign [split $line \t] name url
		if {$name ne "" && $want ne "" && [string trimright $url /] eq $want} {
			dict set detail remote $name
			flat_info $id $name
			return
		}
	}
	dict set detail state ready
	notify
}

# ---- installing ---------------------------------------------------------------------------------------------
# Install the app shown. A kit: kit's grab (kitq.tcl), whose prompt comes back through ASK (called
# with rows question default, it answers with cat::answer). Flathub: flatpak install, for this user.
proc cat::install {ask} {
	variable detail
	variable job
	if {[dict size $job]} return
	set src [dict get $detail source]
	switch -- $src {
		kit { set argv [kitq grab [dict get $detail name]] }
		flathub { set argv [list [flatpak] install --user -y -- $cat::remote [dict get $detail id]] }
		ref { set argv [list [flatpak] install --user -y --from -- [dict get $detail file]] }
	}
	# -y, not --noninteractive: that is flatpak's quiet transaction, which prints no progress; -y is
	# the CLI transaction answering yes, which (FLATPAK_FANCY_OUTPUT=0) prints a line per update, "NN%"
	set ::env(FLATPAK_FANCY_OUTPUT) 0
	if {[catch {::open |[list {*}$argv 2>@1] r+} fh]} {
		set job [dict create source $src id [dict get $detail id] fh "" phase download done 0 total 0 pct -1 said "$fh\n" buf "" ask $ask code 127]
		job_end 127
		return
	}
	fconfigure $fh -blocking 0 -buffering line -encoding utf-8 -translation lf
	set job [dict create source $src id [dict get $detail id] fh $fh phase [expr {$src eq "kit" ? "asking" : "download"}] \
		done 0 total 0 pct -1 said "" buf "" ask $ask code ""]
	fileevent $fh readable cat::job_read
	notify
}
# kit's prompt answered: 1 installs, 0 does not
proc cat::answer {yes} {
	variable job
	if {![dict size $job] || [dict get $job phase] ne "plan"} return
	puts [dict get $job fh] [expr {$yes ? 1 : 0}]
	flush [dict get $job fh]
	dict set job phase [expr {$yes ? "download" : "asking"}]
	notify
}
proc cat::job_read {} {
	variable job
	set fh [dict get $job fh]
	set data [read $fh]
	dict append job buf $data
	# lines end in \n, flatpak's progress in \r
	set buf [dict get $job buf]
	set parts [split $buf "\r\n"]
	dict set job buf [lindex $parts end]
	foreach line [lrange $parts 0 end-1] { job_line $line }
	if {![eof $fh]} return
	if {[dict get $job buf] ne ""} { job_line [dict get $job buf] }
	fconfigure $fh -blocking 1
	set code 0
	if {[catch {close $fh} e opts]} {
		set ec [dict get $opts -errorcode]
		set code [expr {[lindex $ec 0] eq "CHILDSTATUS" ? [lindex $ec 2] : 1}]
	}
	if {[dict get $job code] ne ""} { set code [dict get $job code] }
	job_end $code
}
proc cat::job_line {line} {
	variable job
	if {[dict get $job source] eq "kit" && [string match "catalogue: *" $line]} {
		set l [lrange $line 1 end]
		switch -- [lindex $l 0] {
			plan {
				lassign [lindex $l 1] rows question default
				dict set job phase plan
				notify
				uplevel #0 [list {*}[dict get $job ask] $rows $question $default]
				return
			}
			progress {
				dict set job done [lindex $l 1]; dict set job total [lindex $l 2]
				dict set job pct [expr {[lindex $l 2] > 0 ? 100.0 * [lindex $l 1] / [lindex $l 2] : 100}]
				dict set job phase download
			}
			phase { dict set job phase install }
			end { dict set job code [lindex $l 1] }
		}
		notify
		return
	}
	if {[string trim $line] eq ""} return
	if {[dict get $job source] ne "kit" && [regexp {(\d{1,3})\s*%} $line -> p]} {
		dict set job pct [expr {min(100, $p)}]
		notify
		return
	}
	dict append job said "[string trim $line]\n"
}
proc cat::job_end {code} {
	variable job
	variable detail
	dict set job phase [expr {$code == 0 ? "done" : ($code == 1 && [dict get $job source] eq "kit" ? "no" : "failed")}]
	dict set job code $code
	set j $job
	set job {}
	# what is installed now
	if {[dict get $j source] eq "kit"} { load_kits; if {[dict get $detail id] eq [dict get $j id]} { open_app $detail } } else {
		run [list [flatpak] list --app --columns=application,name,version,description,origin,installation,branch] [list cat::after_flat [dict get $j id]]
	}
	variable last $j
	notify
}
proc cat::after_flat {id code out err} {
	variable flatinst
	variable detail
	if {$code == 0} { set flatinst [parse_list $out] }
	if {[dict size $detail] && [dict get $detail id] eq $id && [dict exists $flatinst $id]} { dict set detail installed [instver [dict get $flatinst $id] [dict get $detail version]] }
	notify
}
# Cancel: the download stops (kit: only while it downloads; nothing has changed yet)
proc cat::cancel {} {
	variable job
	if {![dict size $job] || [dict get $job fh] eq ""} return
	if {[dict get $job source] eq "kit" && [dict get $job phase] ni {download}} return
	catch {exec kill -TERM {*}[pid [dict get $job fh]]}
	dict set job code 130
}
# The app's own command: kit run NAME, flatpak run ID
proc cat::launch {} {
	variable detail
	if {[dict get $detail source] eq "kit"} {
		set k [auto_execok kit]
		if {$k eq ""} { set k [list [tclsh] [file normalize [file join $cat::here .. .. .. .. ribbon-kit files bin kit]]] }
		set argv [list {*}$k run [dict get $detail name]]
	} else { set argv [list [flatpak] run -- [dict get $detail id]] }
	if {[catch {exec {*}$argv </dev/null >/dev/null 2>/dev/null &} err]} { return $err }
	return ""
}
