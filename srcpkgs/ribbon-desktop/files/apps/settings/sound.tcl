# sound.tcl - Settings → Sound's backend (namespace snd): the sound devices, the playing streams and the Bluetooth
# cards, read from PipeWire through pipewire-pulse's pactl. Nothing blocks Tk: every pactl run is an asynchronous pipe
# (open "|pactl ..." with a fileevent), and a read or an action is a coroutine that yields until pactl has answered.
# Reads are coalesced like nm.tcl: a refresh asked for during a read runs once more after it. `pactl subscribe` stays
# open and its events (debounced, 80 ms) trigger a refresh.
#
#   snd::start / snd::stop          the first read and the subscription; close it again
#   snd::refresh                    re-read the model
#   snd::model                      available, sinks, sources, streams, cards (see below)
#   snd::set_default sink|source ID, snd::set_volume sink|source|stream ID PCT, snd::set_mute KIND ID 0|1,
#   snd::set_balance SINKID -100..100, snd::set_card_profile ADDRESS sound|calls
#   snd::subtitle                   "<default sink> · <volume>%", "Muted", or "No sound device"
#   snd::level_start / snd::level_stop   the input level (parec on the default source): snd::level, snd::onlevel
#   snd::setting KEY, snd::conf_set KEY VALUE   $XDG_CONFIG_HOME/ribbon/sound.conf (OVER, ALERTS, BAR, ALERT_VOLUME)
#
# A sink or source dict: id (pactl index), name, label, sub, kind, volume (percent, the channels' mean), muted,
# balance, default, address, and channels (the channels' percentages, left then right). A stream: id, app, icon,
# volume, muted, channels. A card: name, address, profile (sound|calls|off), codec, profiles (the kinds it has), names
# (kind -> the profile's name, for set-card-profile). The model is a dict: available (pactl answered), sinks, sources,
# streams, cards. Monitor sources are left out. The pure helpers at the end need no pactl and are tested alone.
# The JSON reader is part of this file: pactl's -f json output is small and the greeter's reader is not installed
# beside the apps.

namespace eval snd {
	variable model {available 0 sinks {} sources {} streams {} cards {}}
	variable defaults {OVER no ALERTS yes BAR yes ALERT_VOLUME 70}
	variable onchange ""     ;# a command run after each model change (the page draws)
	variable loaded 0        ;# the first read has ended
	variable busy 0
	variable again 0
	variable jobs 0          ;# actions running (their pactl run and the refresh after it)
	variable seq 0
	variable buf             ;# pipe name -> output read so far
	variable error ""        ;# the last action's failure, one line
	variable subchan ""
	variable debounce ""
	variable holds {}        ;# "KIND:ID" -> the clock (ms) of the last set: the knob keeps its value meanwhile
	variable defsource ""    ;# the default source's name (the level restarts when it changes)
	variable level 0         ;# the input level, 0..100
	variable onlevel ""      ;# a command run when the level changes (at most 15 times a second)
	variable levelchan ""
	variable levelsrc ""
	variable levelleft ""
	variable levelpeak 0
	variable levelcount 0
	variable levellast 0
}

# ---- pactl ------------------------------------------------------------------------

# The pactl command: RIBBON_PACTL when set (the tests use a fake), else pactl.
# The model (the dict the header describes).
proc snd::model {} { variable model; return $model }

proc snd::cmd {} {
	if {[info exists ::env(RIBBON_PACTL)] && $::env(RIBBON_PACTL) ne ""} { return $::env(RIBBON_PACTL) }
	return pactl
}

# Run pactl with ARGS as a pipe (yields inside a coroutine until it has finished). Returns {ok OUTPUT}: ok is 0 when
# pactl could not be started or exited with an error.
proc snd::run {args} {
	variable buf
	set co [info coroutine]
	if {[catch {open "|[list {*}[snd::cmd] {*}$args] 2>/dev/null" r} ch]} { return [list 0 ""] }
	fconfigure $ch -blocking 0 -translation binary
	set buf($ch) ""
	fileevent $ch readable [list snd::collect $ch $co]
	yield
}

# A pipe is readable: keep what it wrote; at its end, resume the coroutine with {ok OUTPUT}.
proc snd::collect {ch co} {
	variable buf
	if {[catch {read $ch} data]} { set data "" ; set gone 1 } else { set gone [eof $ch] }
	append buf($ch) $data
	if {!$gone} return
	fileevent $ch readable ""
	set out $buf($ch)
	unset buf($ch)
	set ok [expr {![catch {close $ch}]}]
	{*}$co [list $ok $out]
}

# ---- reading --------------------------------------------------------------------

proc snd::refresh {} {
	variable busy; variable again
	if {$busy} { set again 1; return }
	set busy 1
	coroutine ::snd::read[incr ::snd::seq] snd::run_read
}

proc snd::run_read {} {
	variable busy; variable again; variable model; variable onchange; variable loaded
	while {1} {
		set again 0
		set model [snd::fetch $model]
		set loaded 1
		if {!$again} break
	}
	set busy 0
	snd::level_follow
	if {$onchange ne ""} { {*}$onchange }
}

# Read the whole model; yields while pactl answers. OLD is the model before, for the knobs being dragged.
proc snd::fetch {old} {
	set none [dict create available 0 sinks {} sources {} streams {} cards {}]
	lassign [snd::run -f json info] ok out
	if {!$ok} { return $none }
	set info [snd::fromjson $out {}]
	if {![dict exists $info default_sink_name]} { return $none }
	set defsink [dict get $info default_sink_name]
	set defsrc [snd::g $info default_source_name]
	lassign [snd::run -f json list sinks] ok1 out1
	lassign [snd::run -f json list sources] ok2 out2
	lassign [snd::run -f json list sink-inputs] ok3 out3
	lassign [snd::run -f json list cards] ok4 out4
	if {!($ok1 && $ok2 && $ok3 && $ok4)} { return $none }
	variable defsource $defsrc
	set now [clock milliseconds]
	set sinks [snd::held sink [snd::devices 0 [snd::fromjson $out1 {}] $defsink] [dict get $old sinks]]
	set sources [snd::held source [snd::devices 1 [snd::fromjson $out2 {}] $defsrc] [dict get $old sources]]
	set streams [snd::held stream [snd::streams [snd::fromjson $out3 {}]] [dict get $old streams]]
	dict create available 1 sinks $sinks sources $sources streams $streams cards [snd::cards [snd::fromjson $out4 {}]]
}

# The sinks (isource 0) or sources (1) of a pactl list, with the default's name DEFNAME.
proc snd::devices {isource list defname} {
	set out {}
	foreach d $list {
		set name [snd::g $d name]
		if {$isource && ([string match *.monitor $name] || [snd::g $d monitor_of_sink] ne "")} continue
		set props [snd::g $d properties]
		set port [snd::g $d active_port]
		set portdesc ""
		if {[dict exists $d ports $port description]} { set portdesc [dict get $d ports $port description] }
		set desc [snd::g $d description $name]
		set bus [snd::g $props device.bus]
		set sub [snd::sub_of $bus $name $desc $port]
		set type [expr {$isource ? "source" : "sink"}]
		set chs [snd::channel_pcts [snd::g $d volume]]
		lappend out [dict create id [snd::g $d index] name $name label [snd::label $desc $portdesc] sub $sub \
			kind [snd::kind_of $type [snd::g $props device.form_factor] $sub] \
			volume [snd::mean $chs] muted [expr {[snd::g $d mute] ? 1 : 0}] \
			balance [snd::balance_of_chans $chs] default [expr {$name eq $defname ? 1 : 0}] \
			address [snd::g $props api.bluez5.address] channels $chs]
	}
	set out
}

# The playing streams (sink-inputs).
proc snd::streams {list} {
	set out {}
	foreach s $list {
		set props [snd::g $s properties]
		set app [snd::g $props application.name [snd::g $props media.name [snd::g $s name]]]
		set icon [snd::stream_icon [snd::g $props application.icon_name] [snd::g $props application.process.binary]]
		set chs [snd::channel_pcts [snd::g $s volume]]
		lappend out [dict create id [snd::g $s index] app $app icon $icon volume [snd::mean $chs] \
			muted [expr {[snd::g $s mute] ? 1 : 0}] channels $chs]
	}
	set out
}

# The Bluetooth cards: the profile in use, its codec, and the sound and calls profiles the card has.
proc snd::cards {list} {
	set out {}
	foreach c $list {
		set props [snd::g $c properties]
		set name [snd::g $c name]
		if {![string match bluez_card.* $name] && [snd::g $props device.bus] ne "bluetooth"} continue
		set addr [snd::g $props api.bluez5.address [snd::card_address $name]]
		set profiles [snd::g $c profiles]
		set active [snd::g $c active_profile]
		set names [snd::profile_names [dict keys $profiles]]
		set codec ""
		if {[dict exists $profiles $active]} {
			set codec [snd::codec_of [snd::g $props bluez5.codec] $active [dict get $profiles $active description]]
		}
		lappend out [dict create name $name address $addr profile [snd::card_profile $active] codec $codec \
			profiles [dict keys $names] names $names]
	}
	set out
}

# Keep the knobs being dragged: an item set less than 250 ms ago keeps its volume and balance from OLD.
proc snd::held {kind items old} {
	variable holds
	set now [clock milliseconds]
	set out {}
	foreach it $items {
		set key "$kind:[dict get $it id]"
		if {[dict exists $holds $key] && $now - [dict get $holds $key] < 250} {
			foreach o $old {
				if {[dict get $o id] == [dict get $it id]} {
					foreach k {volume channels balance} { dict set it $k [dict get $o $k] }
				}
			}
		}
		lappend out $it
	}
	set out
}

# A dict value, or DEF when the key is missing.
proc snd::g {d key {def ""}} {
	expr {[dict exists $d $key] ? [dict get $d $key] : $def}
}

# ---- subscription --------------------------------------------------------------

proc snd::start {} {
	variable subchan
	snd::refresh
	if {$subchan ne ""} return
	if {[catch {open "|[list [snd::cmd] subscribe] 2>/dev/null" r} ch]} return
	set subchan $ch
	fconfigure $ch -blocking 0
	fileevent $ch readable [list snd::subread $ch]
}

proc snd::subread {ch} {
	variable subchan
	if {[catch {read $ch} data]} { set data "" ; set gone 1 } else { set gone [eof $ch] }
	if {[string trim $data] ne ""} { snd::schedule }
	if {$gone} {
		fileevent $ch readable ""
		catch {close $ch}
		if {$subchan eq $ch} { set subchan "" }
	}
}

proc snd::schedule {} {
	variable debounce
	if {$debounce ne ""} { after cancel $debounce }
	set debounce [after 80 snd::debounced]
}

proc snd::debounced {} {
	variable debounce
	set debounce ""
	snd::refresh
}

proc snd::stop {} {
	variable subchan; variable debounce
	if {$debounce ne ""} { after cancel $debounce; set debounce "" }
	if {$subchan ne ""} {
		fileevent $subchan readable ""
		catch {exec kill -TERM {*}[pid $subchan]}
		catch {close $subchan}
		set subchan ""
	}
}

# ---- actions --------------------------------------------------------------------

# Run an action (a proc and its arguments) in a coroutine, then refresh. Its failure goes to snd::error.
proc snd::job {args} {
	variable jobs
	incr jobs
	coroutine ::snd::job[incr ::snd::seq] snd::run_job {*}$args
}

# An action's pactl run, then the refresh that shows its result (the refresh is running when the job count drops).
proc snd::run_job {args} {
	variable error; variable jobs
	lassign [snd::run {*}$args] ok out
	set error [expr {$ok ? "" : "pactl failed"}]
	snd::refresh
	incr jobs -1
}

# A device's kind as pactl names it: sink or source. Returns the entry's index in the list, or -1.
proc snd::index_of {kind id} {
	variable model
	set list [dict get $model [snd::listname $kind]]
	set i 0
	foreach it $list {
		if {[dict get $it id] == $id} { return $i }
		incr i
	}
	return -1
}

proc snd::listname {kind} {
	switch -- $kind {
		sink { return sinks }
		source { return sources }
		stream { return streams }
	}
	error "snd: no such kind $kind"
}

# Change one field of a device, or stream, in the model and tell the page at once.
proc snd::update_item {kind id args} {
	variable model
	set lname [snd::listname $kind]
	set i [snd::index_of $kind $id]
	if {$i < 0} return
	set list [dict get $model $lname]
	set it [lindex $list $i]
	foreach {k v} $args { dict set it $k $v }
	dict set model $lname [lreplace $list $i $i $it]
	snd::changed
}

proc snd::changed {} {
	variable onchange
	if {$onchange ne ""} { {*}$onchange }
}

proc snd::set_default {kind id} {
	variable model
	set i [snd::index_of $kind $id]
	if {$i < 0} return
	set name [dict get [lindex [dict get $model [snd::listname $kind]] $i] name]
	set cmd [expr {$kind eq "sink" ? "set-default-sink" : "set-default-source"}]
	snd::job $cmd $name
}

# A volume in percent: a sink, a source or a stream. The model changes at once; the channels keep their balance.
proc snd::set_volume {kind id pct} {
	variable model; variable holds
	set max [expr {[snd::setting OVER] eq "yes" ? 150 : 100}]
	set pct [snd::clamp $pct 0 $max]
	set i [snd::index_of $kind $id]
	if {$i < 0} return
	set it [lindex [dict get $model [snd::listname $kind]] $i]
	set chs [dict get $it channels]
	set mean [snd::mean $chs]
	if {[llength $chs] == 2 && $mean > 0} {
		set new {}
		foreach c $chs { lappend new [snd::clamp [expr {int(round(double($c) * $pct / $mean))}] 0 $max] }
	} else {
		set new [list $pct]
	}
	set bal [expr {[llength $new] == 2 ? [snd::balance_of_chans $new] : 0}]
	dict set holds "$kind:$id" [clock milliseconds]
	snd::update_item $kind $id volume $pct channels $new balance $bal
	set args {}
	foreach c $new { lappend args "${c}%" }
	snd::job [snd::volume_cmd $kind] $id {*}$args
}

# The set balance of a sink: the louder channel stays at its volume, the other is turned down.
proc snd::set_balance {id bal} {
	variable model; variable holds
	set bal [snd::clamp $bal -100 100]
	set i [snd::index_of sink $id]
	if {$i < 0} return
	set it [lindex [dict get $model sinks] $i]
	set chs [dict get $it channels]
	if {[llength $chs] != 2} return
	lassign $chs l r
	set top [expr {max($l, $r)}]
	if {$bal >= 0} {
		set r $top
		set l [expr {int(round(double($top) * (100 - $bal) / 100))}]
	} else {
		set l $top
		set r [expr {int(round(double($top) * (100 + $bal) / 100))}]
	}
	dict set holds "sink:$id" [clock milliseconds]
	snd::update_item sink $id channels [list $l $r] balance $bal volume [snd::mean [list $l $r]]
	snd::job set-sink-volume $id "${l}%" "${r}%"
}

proc snd::set_mute {kind id on} {
	set on [expr {$on ? 1 : 0}]
	set i [snd::index_of $kind $id]
	if {$i < 0} return
	snd::update_item $kind $id muted $on
	snd::job [snd::mute_cmd $kind] $id $on
}

# The card's profile: sound (A2DP) or calls (headset/hands-free). The profile's real name is the card's.
proc snd::set_card_profile {address kind} {
	variable model
	set card ""
	foreach c [dict get $model cards] {
		if {[dict get $c address] eq $address} { set card $c }
	}
	if {$card eq "" || ![dict exists $card names $kind]} return
	set name [dict get $card name]
	set list [dict get $model cards]
	set j 0
	foreach c $list {
		if {[dict get $c address] eq $address} {
			dict set c profile $kind
			dict set model cards [lreplace $list $j $j $c]
			snd::changed
			break
		}
		incr j
	}
	snd::job set-card-profile $name [dict get $card names $kind]
}

proc snd::volume_cmd {kind} {
	switch -- $kind {
		sink { return set-sink-volume }
		source { return set-source-volume }
		stream { return set-sink-input-volume }
	}
}

proc snd::mute_cmd {kind} {
	switch -- $kind {
		sink { return set-sink-mute }
		source { return set-source-mute }
		stream { return set-sink-input-mute }
	}
}

# ---- input level ----------------------------------------------------------------

# parec on the default source (RIBBON_PAREC when set): 8 kHz mono, a window of 100 ms at a time.
proc snd::level_start {} {
	variable levelchan; variable levelsrc; variable levelleft; variable levelpeak; variable levelcount; variable levellast
	if {$levelchan ne ""} return
	set cmd [expr {[info exists ::env(RIBBON_PAREC)] && $::env(RIBBON_PAREC) ne "" ? $::env(RIBBON_PAREC) : "parec"}]
	if {[catch {open "|[list $cmd --format=s16le --rate=8000 --channels=1 --latency-msec=60] 2>/dev/null" r} ch]} return
	fconfigure $ch -blocking 0 -translation binary
	set levelchan $ch
	set levelsrc $snd::defsource
	set levelleft ""
	set levelpeak 0
	set levelcount 0
	set levellast 0
	fileevent $ch readable [list snd::level_read $ch]
}

proc snd::level_stop {} {
	variable levelchan; variable level
	if {$levelchan eq ""} return
	set ch $levelchan
	set levelchan ""
	fileevent $ch readable ""
	catch {exec kill -TERM {*}[pid $ch]}
	catch {close $ch}
	set level 0
}

# The default source changed while the level runs: it follows the new one.
proc snd::level_follow {} {
	variable levelchan; variable levelsrc; variable defsource
	if {$levelchan ne "" && $defsource ne $levelsrc} {
		snd::level_stop
		snd::level_start
	}
}

proc snd::level_read {ch} {
	variable levelleft; variable levelpeak; variable levelcount; variable levellast; variable level; variable onlevel
	if {[catch {read $ch} data]} { set data "" ; set gone 1 } else { set gone [eof $ch] }
	set data "$levelleft$data"
	set levelleft ""
	if {[string length $data] % 2} {
		set levelleft [string index $data end]
		set data [string range $data 0 end-1]
	}
	if {![catch {binary scan $data s* samples}]} {
		foreach v $samples {
			set a [expr {abs($v)}]
			if {$a > $levelpeak} { set levelpeak $a }
			incr levelcount
			if {$levelcount >= 800} {
				set level [snd::level_of $levelpeak]
				set levelpeak 0
				set levelcount 0
				set now [clock milliseconds]
				if {$onlevel ne "" && $now - $levellast >= 66} {
					set levellast $now
					{*}$onlevel
				}
			}
		}
	}
	if {$gone} { snd::level_stop }
}

# ---- settings -------------------------------------------------------------------

proc snd::conf_file {} {
	set cfg [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""
		? $::env(XDG_CONFIG_HOME) : [file join [expr {[info exists ::env(HOME)] ? $::env(HOME) : "/tmp"}] .config]}]
	file join $cfg ribbon sound.conf
}

proc snd::conf_lines {} {
	set f [snd::conf_file]
	if {[catch {open $f} fh]} { return {} }
	set t [read $fh]
	close $fh
	if {$t eq ""} { return {} }
	split [string trimright $t \n] \n
}

# A setting: the file's last line for KEY, or its default when the file has none or a bad value.
proc snd::setting {key} {
	variable defaults
	set v [dict get $defaults $key]
	foreach line [snd::conf_lines] {
		if {[regexp "^${key}=(.*)\$" $line -> x]} { set v [string trim $x] }
	}
	if {$key eq "ALERT_VOLUME"} {
		if {[string is integer -strict $v] && $v >= 0 && $v <= 100} { return $v }
		return [dict get $defaults $key]
	}
	if {$v in {yes no}} { return $v }
	return [dict get $defaults $key]
}

# Write KEY=VALUE: its line is replaced (or added), every other line stays. Written to a temp file, then renamed.
proc snd::conf_set {key value} {
	set f [snd::conf_file]
	set out {}
	set done 0
	foreach line [snd::conf_lines] {
		if {[regexp "^${key}=" $line]} {
			if {!$done} { lappend out "${key}=$value"; set done 1 }
		} elseif {$line ne ""} {
			lappend out $line
		}
	}
	if {!$done} { lappend out "${key}=$value" }
	file mkdir [file dirname $f]
	set tmp "$f.tmp"
	set fh [open $tmp w]
	puts $fh [join $out \n]
	close $fh
	file rename -force $tmp $f
}

# ---- the page's subtitle -----------------------------------------------------------

proc snd::subtitle {} {
	variable model
	snd::subtitle_for [dict get $model sinks]
}

# The subtitle for a list of sinks: the default one (else the first) with its volume or "Muted".
proc snd::subtitle_for {sinks} {
	if {[llength $sinks] == 0} { return "No sound device" }
	set sink [lindex $sinks 0]
	foreach s $sinks { if {[dict get $s default]} { set sink $s } }
	set state [expr {[dict get $sink muted] ? "Muted" : "[dict get $sink volume]%"}]
	return "[dict get $sink label] · $state"
}

# ---- pure helpers (no pactl) --------------------------------------------------------

# A pactl JSON document as Tcl values: objects are dicts, arrays lists, true/false 1/0, null "". DEF when it is empty
# or does not parse.
proc snd::fromjson {text def} {
	if {[string trim $text] eq ""} { return $def }
	if {[catch {snd::jparse $text} v]} { return $def }
	set v
}

proc snd::jparse {text} {
	set i 0
	set v [snd::jvalue $text i]
	snd::jskip $text i
	if {$i < [string length $text]} { error "json: trailing data at $i" }
	set v
}

proc snd::jskip {text iv} {
	upvar 1 $iv i
	if {[regexp -start $i -indices {\S} $text m]} { set i [lindex $m 0] } else { set i [string length $text] }
}

proc snd::jvalue {text iv} {
	upvar 1 $iv i
	snd::jskip $text i
	set c [string index $text $i]
	switch -- $c {
		\{ {
			incr i
			set d {}
			snd::jskip $text i
			if {[string index $text $i] eq "\}"} { incr i; return $d }
			while 1 {
				snd::jskip $text i
				set k [snd::jstring $text i]
				snd::jskip $text i
				if {[string index $text $i] ne ":"} { error "json: ':' expected at $i" }
				incr i
				dict set d $k [snd::jvalue $text i]
				snd::jskip $text i
				set c [string index $text $i]
				incr i
				if {$c eq "\}"} { return $d }
				if {$c ne ","} { error "json: ',' expected at [expr {$i - 1}]" }
			}
		}
		\[ {
			incr i
			set l {}
			snd::jskip $text i
			if {[string index $text $i] eq "\]"} { incr i; return $l }
			while 1 {
				lappend l [snd::jvalue $text i]
				snd::jskip $text i
				set c [string index $text $i]
				incr i
				if {$c eq "\]"} { return $l }
				if {$c ne ","} { error "json: ',' expected at [expr {$i - 1}]" }
			}
		}
		\" { return [snd::jstring $text i] }
		t { incr i 4; return 1 }
		f { incr i 5; return 0 }
		n { incr i 4; return "" }
		default {
			if {[regexp -start $i {\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?} $text num]} {
				incr i [string length $num]
				return $num
			}
			error "json: unexpected '$c' at $i"
		}
	}
}

# A JSON string at I (advancing it), with its escapes read.
proc snd::jstring {text iv} {
	upvar 1 $iv i
	if {![regexp -start $i -indices {\A"((?:[^"\\]|\\.)*)"} $text m body]} { error "json: string expected at $i" }
	set s [string range $text [lindex $body 0] [lindex $body 1]]
	set i [expr {[lindex $m 1] + 1}]
	set s [string map [list \\\" \" \\\\ \\ \\/ / \\n \n \\t \t \\r \r \\b \b \\f \f] $s]
	while {[regexp -indices {\\u([0-9a-fA-F]{4})} $s m hex]} {
		set ch [format %c 0x[string range $s [lindex $hex 0] [lindex $hex 1]]]
		set s [string replace $s [lindex $m 0] [lindex $m 1] $ch]
	}
	set s
}

proc snd::clamp {v lo hi} {
	if {$v < $lo} { return $lo }
	if {$v > $hi} { return $hi }
	return $v
}

# The percentages of a pactl volume dict, in channel order ({front-left {value_percent 50%}} -> 50).
proc snd::channel_pcts {vol} {
	set out {}
	dict for {ch v} $vol {
		set p [snd::g $v value_percent 0]
		lappend out [expr {int(round(double([string trimright $p %])))}]
	}
	set out
}

# The mean of the channels' percentages (0 for none).
proc snd::mean {chs} {
	if {[llength $chs] == 0} { return 0 }
	set sum 0
	foreach c $chs { incr sum $c }
	expr {int(round(double($sum) / [llength $chs]))}
}

# The balance (-100 left .. 100 right) of two channel percentages: 0 for mono or silence.
proc snd::balance_of_chans {chs} {
	if {[llength $chs] != 2} { return 0 }
	lassign $chs l r
	set top [expr {max($l, $r)}]
	if {$top == 0} { return 0 }
	expr {int(round(double($r - $l) * 100 / $top))}
}

# The label of a device: its port's name for the built-in audio ("Speakers"), else its description without the
# profile's tail ("Digital Stereo (HDMI)", "Analog Stereo").
proc snd::label {desc portdesc} {
	if {$portdesc ne "" && [regexp {^Built-in Audio} $desc]} { return $portdesc }
	set d [regsub {\s+(Analog|Digital|Pro)\s.*$} $desc ""]
	set d [regsub {\s+(Stereo|Mono|Surround.*)$} $d ""]
	set d [string trim $d]
	expr {$d eq "" ? $desc : $d}
}

# Where a device is: Bluetooth, USB, HDMI (the monitor's speakers) or the built-in audio.
proc snd::sub_of {bus name desc port} {
	if {$bus eq "bluetooth" || [string match bluez_* $name]} { return Bluetooth }
	if {$bus eq "usb"} { return USB }
	if {[regexp -nocase {hdmi|displayport|\mdp\M} "$name $desc $port"]} { return HDMI }
	return "Built-in audio"
}

# The icon of a device: headphones, speaker, monitor (HDMI) or mic (sources).
proc snd::kind_of {type form sub} {
	if {$type eq "source"} { return mic }
	if {$form in {headphone headphones headset}} { return headphones }
	if {$sub eq "HDMI"} { return monitor }
	return speaker
}

# The icon of a stream from its application's icon name and process binary.
proc snd::stream_icon {icon binary} {
	set s "$icon $binary"
	if {[regexp -nocase {firefox|chrom|brave|epiphany|netsurf|browser} $s]} { return globe }
	if {[regexp -nocase {steam|game|lutris|retroarch} $s]} { return game }
	if {[regexp -nocase {spotify|rhythmbox|music|clementine|lollypop|\mmpd\M|vlc|mpv|player} $s]} { return music }
	return apps
}

# A card's profile kind: a2dp* is sound, headset* and handsfree* are calls, anything else (off) is off.
proc snd::card_profile {name} {
	if {[string match a2dp* $name]} { return sound }
	if {[string match headset* $name] || [string match handsfree* $name]} { return calls }
	return off
}

# The profile names of each kind a card has: sound (its A2DP profile) and calls (the headset or hands-free one).
proc snd::profile_names {names} {
	set out {}
	foreach n $names {
		set k [snd::card_profile $n]
		if {$k ne "off" && ![dict exists $out $k]} { dict set out $k $n }
	}
	set out
}

# The codec's label, from the card's bluez5.codec property, else the profile's name or description (as WirePlumber
# writes it, "... (A2DP Sink, codec LDAC)"). "" when none is named.
proc snd::codec_of {prop profile desc} {
	set text [string tolower "$prop $profile $desc"]
	set table {
		ldac {High quality (LDAC)} aptx_hd {aptX HD} aptx aptX aac AAC sbc_xq {Standard (SBC XQ)}
		sbc {Standard (SBC)} msbc {Wideband (mSBC)} lc3 LC3 cvsd CVSD
	}
	foreach {tok label} $table {
		if {[regexp "(^|\[^a-z0-9_\])${tok}(\[^a-z0-9_\]|\$)" $text]} { return $label }
	}
	return ""
}

# The card's address from its name (bluez_card.AA_BB_CC_DD_EE_FF).
proc snd::card_address {name} {
	if {[regexp {bluez_card\.((?:[0-9A-Fa-f]{2}_){5}[0-9A-Fa-f]{2})} $name -> a]} { return [string map {_ :} $a] }
	return ""
}

# The input level of a window's peak sample (0..32767): -50 dBFS is 0 and 0 dBFS is 100, so speech sits mid-scale.
proc snd::level_of {peak} {
	set db [expr {20.0 * log(max($peak, 1) / 32768.0) / log(10)}]
	set v [expr {int(round(($db + 50.0) * 2))}]
	snd::clamp $v 0 100
}
