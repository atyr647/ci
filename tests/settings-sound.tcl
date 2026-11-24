# settings-sound.tcl - Settings → Sound's backend (apps/settings/sound.tcl) against the fake pactl (tests/fixtures/fake-pactl)
# with no display. Run by tests/steps.d/55-settings-sound.sh with the environment it sets: RIBBON_PACTL, RIBBON_PAREC,
# PACTL_STATE (a copy of tests/fixtures/pactl-json), PACTL_LOG and XDG_CONFIG_HOME (a scratch folder):
#   tclsh8.6 tests/settings-sound.tcl FILES
# FILES is the srcpkgs/ribbon-desktop/files folder. Prints one line per check; exits non-zero on the first failure.
set D [lindex $argv 0]
set LOG $::env(PACTL_LOG)
set fails 0
proc check {what ok} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}

source [file join $D apps settings sound.tcl]

# Run the event loop until ready is true (a script) and no action or read is running; fail after 8 s.
proc settle {{cond 1}} {
	set t [clock milliseconds]
	while {1} {
		if {$snd::busy == 0 && $snd::jobs == 0 && $snd::debounce eq "" && [uplevel #0 [list expr $cond]]} { return 1 }
		if {[clock milliseconds] - $t > 8000} { return 0 }
		update
		after 10
	}
}

proc logged {} {
	global LOG
	if {![file exists $LOG]} { return {} }
	set fh [open $LOG]
	set out [split [string trimright [read $fh] \n] \n]
	close $fh
	return $out
}

# The model's sink or source (by index I) or stream, as a dict.
proc item {list id} {
	foreach it $list { if {[dict get $it id] == $id} { return $it } }
	return {}
}

# ---- the read ------------------------------------------------------------------------
set changes 0
set snd::onchange {incr ::changes}
snd::start
check "the first read finishes" [settle {$snd::loaded}]
set m $snd::model
check "pactl answered" [dict get $m available]
set sinks [dict get $m sinks]
check "three sinks: the built-in, HDMI and Bluetooth" [expr {[llength $sinks] == 3}]
check "the labels are shortened: Speakers, LG UltraGear, WH-1000XM5" \
	[expr {[lmap s $sinks {dict get $s label}] eq {Speakers {LG UltraGear} WH-1000XM5}}]
check "the subs: built-in audio, HDMI, Bluetooth" \
	[expr {[lmap s $sinks {dict get $s sub}] eq {{Built-in audio} HDMI Bluetooth}}]
check "the kinds: speaker, monitor, headphones" \
	[expr {[lmap s $sinks {dict get $s kind}] eq {speaker monitor headphones}}]
check "the volumes are the channels' means: 60, 100, 40" \
	[expr {[lmap s $sinks {dict get $s volume}] eq {60 100 40}}]
check "the built-in balance comes from its channels (70 left, 50 right: -29)" \
	[expr {[dict get [item $sinks 1] balance] == -29 && [dict get [item $sinks 2] balance] == 0}]
check "the default sink is the built-in one" \
	[expr {[lmap s $sinks {dict get $s default}] eq {1 0 0}}]
check "the Bluetooth sink has its address" [expr {[dict get [item $sinks 3] address] eq "AA:BB:CC:DD:EE:01" && [dict get [item $sinks 1] address] eq ""}]
set sources [dict get $m sources]
check "only the real input is listed: the monitors are left out" [expr {[llength $sources] == 1}]
check "the input is the built-in microphone, labelled by its port" \
	[expr {[dict get [lindex $sources 0] label] eq "Internal Microphone" && [dict get [lindex $sources 0] kind] eq "mic"}]
set streams [dict get $m streams]
check "two streams: Firefox and Rhythmbox" [expr {[lmap s $streams {dict get $s app}] eq {Firefox Rhythmbox}}]
check "stream icons: globe for the browser, music for the player" \
	[expr {[lmap s $streams {dict get $s icon}] eq {globe music}}]
check "stream volume and mute: 80 and 50 (muted)" \
	[expr {[lmap s $streams {dict get $s volume}] eq {80 50} && [lmap s $streams {dict get $s muted}] eq {0 1}}]
set cards [dict get $m cards]
check "one Bluetooth card: the ALSA card is left out" [expr {[llength $cards] == 1}]
set card [lindex $cards 0]
check "the card: its address, profile sound, codec LDAC, both profiles" \
	[expr {[dict get $card address] eq "AA:BB:CC:DD:EE:01" && [dict get $card profile] eq "sound" \
		&& [dict get $card codec] eq "High quality (LDAC)" && [lsort [dict get $card profiles]] eq {calls sound}}]
check "subtitle: the default sink and its volume" [expr {[snd::subtitle] eq "Speakers · 60%"}]

# ---- volume, balance, mute, default, card profile ---------------------------------------
# the volume knob: the model moves at once; the channels keep their balance (70, 50 scaled to 40: 47, 33)
set changes 0
snd::set_volume sink 1 40
check "the volume shows at once, before pactl answers" [expr {[dict get [item [dict get $snd::model sinks] 1] volume] == 40}]
check "a volume change is one pactl call with the two channels" \
	[expr {[settle {[llength [logged]] >= 1}] && [lindex [logged] end] eq "set-sink-volume 1 47% 33%"}]
check "and the read keeps 40" [expr {[settle {[dict get [item [dict get $snd::model sinks] 1] volume] == 40}]}]

# OVER no: a stream's volume stops at 100 (its channels, 50 each, go to 100 each)
snd::set_volume stream 22 150
check "a request over 100 is clamped when Louder than 100% is off" \
	[expr {[dict get [item [dict get $snd::model streams] 22] volume] == 100}]
settle
check "the clamped volume goes to pactl" [expr {[lindex [logged] end] eq "set-sink-input-volume 22 100% 100%"}]

# OVER yes: up to 150
snd::conf_set OVER yes
snd::set_volume stream 21 140
settle
check "with Louder than 100% on, 140 is sent (stream 21: 140% 140%)" \
	[expr {[lindex [logged] end] eq "set-sink-input-volume 21 140% 140%"}]
snd::conf_set OVER no

snd::set_mute sink 2 1
settle
check "mute is sent to pactl and the model shows it" \
	[expr {[lindex [logged] end] eq "set-sink-mute 2 1" && [dict get [item [dict get $snd::model sinks] 2] muted] == 1}]
snd::set_mute sink 2 0
settle

snd::set_default sink 3
settle {[dict get [item [dict get $snd::model sinks] 3] default] == 1}
check "a default sink goes to pactl by its name, and the model shows it" \
	[expr {[lindex [logged] end] eq "set-default-sink bluez_output.AA_BB_CC_DD_EE_01.1" \
		&& [dict get [item [dict get $snd::model sinks] 3] default] == 1 && [dict get [item [dict get $snd::model sinks] 1] default] == 0}]
check "subtitle follows the default: the headphones at 40%" [expr {[snd::subtitle] eq "WH-1000XM5 · 40%"}]

snd::set_balance 3 50
settle
check "balance 50 keeps the louder channel (40) and turns the left one down to 20" \
	[expr {[lindex [logged] end] eq "set-sink-volume 3 20% 40%"}]
check "and the model reads balance 50" [expr {[dict get [item [dict get $snd::model sinks] 3] balance] == 50}]

snd::set_mute sink 3 1
settle
check "a muted default sink shows Muted in the subtitle" [expr {[snd::subtitle] eq "WH-1000XM5 · Muted"}]
snd::set_mute sink 3 0
settle

snd::set_card_profile AA:BB:CC:DD:EE:01 calls
settle {[dict get [lindex [dict get $snd::model cards] 0] profile] eq "calls"}
check "calls sends the card's headset profile name" \
	[expr {[lindex [logged] end] eq "set-card-profile bluez_card.AA_BB_CC_DD_EE_01 headset-head-unit"}]
check "and the card shows calls" [expr {[dict get [lindex [dict get $snd::model cards] 0] profile] eq "calls"}]
snd::set_card_profile AA:BB:CC:DD:EE:01 sound
settle {[dict get [lindex [dict get $snd::model cards] 0] profile] eq "sound"}
check "sound sends the A2DP profile name back" \
	[expr {[lindex [logged] end] eq "set-card-profile bluez_card.AA_BB_CC_DD_EE_01 a2dp-sink"}]

# a change made outside (pactl's own events) reaches the model through subscribe
exec $::env(RIBBON_PACTL) set-sink-mute 1 1
check "a change made elsewhere reaches the model (through pactl subscribe)" \
	[settle {[dict get [item [dict get $snd::model sinks] 1] muted] == 1}]
exec $::env(RIBBON_PACTL) set-sink-mute 1 0
settle {[dict get [item [dict get $snd::model sinks] 1] muted] == 0}

# ---- the callback ---------------------------------------------------------------------
check "the model's change callback ran" [expr {$changes > 0}]

# ---- input level --------------------------------------------------------------------
set lvcalls 0
set snd::onlevel {incr ::lvcalls}
snd::level_start
set t [clock milliseconds]
while {$snd::level == 0 && [clock milliseconds] - $t < 8000} { update; after 10 }
check "the input level rises with a steady tone (8000 of 32768: 76)" [expr {$snd::level >= 70 && $snd::level <= 80}]
set t [clock milliseconds]
while {[clock milliseconds] - $t < 1000} { update; after 10 }
check "the level callback runs at most 15 times a second (saw $lvcalls in a second)" \
	[expr {$lvcalls >= 2 && $lvcalls <= 16}]
snd::level_stop
check "stopping the level resets it" [expr {$snd::level == 0 && $snd::levelchan eq ""}]
set snd::onlevel ""

snd::stop
# ---- settings -------------------------------------------------------------------------
file delete -force [snd::conf_file]
check "a setting without a file is its default" \
	[expr {[snd::setting OVER] eq "no" && [snd::setting ALERTS] eq "yes" && [snd::setting BAR] eq "yes" && [snd::setting ALERT_VOLUME] == 70}]
snd::conf_set ALERT_VOLUME 55
snd::conf_set ALERTS no
snd::conf_set ALERTS no
check "the settings round trip, and a key keeps one line" \
	[expr {[snd::setting ALERT_VOLUME] == 55 && [snd::setting ALERTS] eq "no" && [snd::setting BAR] eq "yes"
		&& [llength [lsearch -all -glob [snd::conf_lines] ALERTS=*]] == 1}]
snd::conf_set ALERT_VOLUME 150
check "a bad ALERT_VOLUME falls back to its default" [expr {[snd::setting ALERT_VOLUME] == 70}]
snd::conf_set BAR no
check "the other settings are kept" [expr {[snd::setting BAR] eq "no" && [snd::setting ALERTS] eq "no"}]

# ---- the pure helpers -------------------------------------------------------------------
set j [snd::fromjson {{"a": [1, 2.5, true, false, null, "x\"yé"], "b": {}, "c": -3e2}} x]
check "the JSON reader: numbers, true and false as 1 and 0, null as empty, escapes" \
	[expr {[lindex [dict get $j a] 0] == 1 && [lindex [dict get $j a] 1] == 2.5 && [lindex [dict get $j a] 2] == 1
		&& [lindex [dict get $j a] 3] == 0 && [lindex [dict get $j a] 4] eq "" && [lindex [dict get $j a] 5] eq "x\"yé"
		&& [dict get $j c] == -300}]
set bad {[1,}
check "bad JSON gives the default" [expr {[snd::fromjson $bad none] eq "none"}]
check "channel percentages in order" \
	[expr {[snd::channel_pcts {front-left {value_percent 70%} front-right {value_percent 50%}}] eq {70 50}}]
check "the mean of the channels" [expr {[snd::mean {70 50}] == 60 && [snd::mean {}] == 0}]
check "the balance: left 70, right 50 is -29; right louder is +29; mono and silence are 0" \
	[expr {[snd::balance_of_chans {70 50}] == -29 && [snd::balance_of_chans {50 70}] == 29 \
		&& [snd::balance_of_chans {60}] == 0 && [snd::balance_of_chans {0 0}] == 0}]
check "labels: a built-in port's name, a shortened description, a name kept" \
	[expr {[snd::label {Built-in Audio Analog Stereo} Speakers] eq "Speakers" \
		&& [snd::label {Built-in Audio Analog Stereo} ""] eq "Built-in Audio" \
		&& [snd::label {LG UltraGear Digital Stereo (HDMI)} ""] eq "LG UltraGear" \
		&& [snd::label WH-1000XM5 ""] eq "WH-1000XM5"}]
check "where a device is: Bluetooth, USB, HDMI, built-in" \
	[expr {[snd::sub_of bluetooth bluez_output.x WH "" ] eq "Bluetooth" && [snd::sub_of usb alsa_output.usb X ""] eq "USB" \
		&& [snd::sub_of pci alsa_output.pci-0000_01_00.1.hdmi-stereo "LG UltraGear" ""] eq "HDMI" \
		&& [snd::sub_of pci alsa_output.pci-0000_00_1f.3.analog-stereo "Built-in Audio" ""] eq "Built-in audio"}]
check "kinds: headphones, monitor, speaker; a source is a mic" \
	[expr {[snd::kind_of sink headset Bluetooth] eq "headphones" && [snd::kind_of sink "" HDMI] eq "monitor" \
		&& [snd::kind_of sink "" "Built-in audio"] eq "speaker" && [snd::kind_of source "" "Built-in audio"] eq "mic"}]
check "stream icons: globe, game, music, apps" \
	[expr {[snd::stream_icon firefox firefox] eq "globe" && [snd::stream_icon "" chromium] eq "globe" \
		&& [snd::stream_icon "" steam] eq "game" && [snd::stream_icon rhythmbox rhythmbox] eq "music" \
		&& [snd::stream_icon "" gedit] eq "apps"}]
check "profiles: a2dp is sound, headset and hands-free are calls, off is off" \
	[expr {[snd::card_profile a2dp-sink] eq "sound" && [snd::card_profile headset-head-unit] eq "calls" \
		&& [snd::card_profile handsfree_head_unit] eq "calls" && [snd::card_profile off] eq "off"}]
check "the profile names of each kind" \
	[expr {[snd::profile_names {off a2dp-sink headset-head-unit}] eq {sound a2dp-sink calls headset-head-unit}}]
check "codec labels: from the property, or from the description" \
	[expr {[snd::codec_of "" a2dp-sink "High Fidelity Playback (A2DP Sink, codec LDAC)"] eq "High quality (LDAC)" \
		&& [snd::codec_of "" headset-head-unit "Headset Head Unit (HSP/HFP, codec mSBC)"] eq "Wideband (mSBC)" \
		&& [snd::codec_of "" a2dp-sink "High Fidelity Playback (A2DP Sink)"] eq "" \
		&& [snd::codec_of aptx_hd "" ""] eq "aptX HD" && [snd::codec_of sbc_xq "" ""] eq "Standard (SBC XQ)" \
		&& [snd::codec_of "" a2dp "codec AAC"] eq "AAC"}]
check "a card's address comes from its name" \
	[expr {[snd::card_address bluez_card.AA_BB_CC_DD_EE_01] eq "AA:BB:CC:DD:EE:01" && [snd::card_address alsa_card.pci-0000_00_1f.3] eq ""}]
check "the input level: silence is 0, full scale 100, a steady -12 dB tone about 76" \
	[expr {[snd::level_of 0] == 0 && [snd::level_of 32767] == 100 && [snd::level_of 8000] >= 75 && [snd::level_of 8000] <= 77}]
check "the subtitle: no sink says so; a sink with no default is its first" \
	[expr {[snd::subtitle_for {}] eq "No sound device" && [snd::subtitle_for [list [dict create label X default 0 volume 30 muted 0]]] eq "X · 30%"}]
set fresh [list [dict create id 1 volume 60 channels {70 50} balance -29]]
set prev [list [dict create id 1 volume 47 channels {47 33} balance -30]]
set snd::holds [dict create sink:1 [clock milliseconds]]
check "a knob set less than 250 ms ago keeps its value over the read" \
	[expr {[dict get [lindex [snd::held sink $fresh $prev] 0] volume] == 47}]
set snd::holds [dict create sink:1 [expr {[clock milliseconds] - 1000}]]
check "after 250 ms the read's value is taken" \
	[expr {[dict get [lindex [snd::held sink $fresh $prev] 0] volume] == 60}]

if {$fails} { puts "  $fails sound check(s) failed"; exit 1 }
puts "  all sound checks passed"
