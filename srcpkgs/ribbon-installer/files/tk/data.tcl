# data.tcl - what the installer offers before it knows the machine:
# languages, keyboard layouts, time zones, apps.

namespace eval data {
	# native name, English name (for searching), locale
	variable languages {
		{English (United States)} {English} en_US.UTF-8
		{English (United Kingdom)} {English British} en_GB.UTF-8
		Deutsch German de_DE.UTF-8
		Español Spanish es_ES.UTF-8
		Français French fr_FR.UTF-8
		Italiano Italian it_IT.UTF-8
		Nederlands Dutch nl_NL.UTF-8
		Polski Polish pl_PL.UTF-8
		{Português (Brasil)} {Portuguese Brazil} pt_BR.UTF-8
		日本語 Japanese ja_JP.UTF-8
		{English (Australia)} {English Australia} en_AU.UTF-8
		{English (Canada)} {English Canada} en_CA.UTF-8
		{English (India)} {English India} en_IN.UTF-8
		{English (Ireland)} {English Ireland} en_IE.UTF-8
		{Español (México)} {Spanish Mexico} es_MX.UTF-8
		{Français (Canada)} {French Canada} fr_CA.UTF-8
		{Português (Portugal)} Portuguese pt_PT.UTF-8
		Català Catalan ca_ES.UTF-8
		Čeština Czech cs_CZ.UTF-8
		Dansk Danish da_DK.UTF-8
		Eesti Estonian et_EE.UTF-8
		Suomi Finnish fi_FI.UTF-8
		Hrvatski Croatian hr_HR.UTF-8
		Magyar Hungarian hu_HU.UTF-8
		{Bahasa Indonesia} Indonesian id_ID.UTF-8
		Lietuvių Lithuanian lt_LT.UTF-8
		Latviešu Latvian lv_LV.UTF-8
		{Norsk bokmål} Norwegian nb_NO.UTF-8
		Română Romanian ro_RO.UTF-8
		Slovenčina Slovak sk_SK.UTF-8
		Slovenščina Slovenian sl_SI.UTF-8
		Srpski Serbian sr_RS.UTF-8@latin
		Svenska Swedish sv_SE.UTF-8
		Türkçe Turkish tr_TR.UTF-8
		Ελληνικά Greek el_GR.UTF-8
		Български Bulgarian bg_BG.UTF-8
		Русский Russian ru_RU.UTF-8
		Українська Ukrainian uk_UA.UTF-8
		עברית Hebrew he_IL.UTF-8
		العربية Arabic ar_EG.UTF-8
		हिन्दी Hindi hi_IN.UTF-8
		ไทย Thai th_TH.UTF-8
		{Tiếng Việt} Vietnamese vi_VN.UTF-8
		한국어 Korean ko_KR.UTF-8
		{中文 (简体)} {Chinese Simplified} zh_CN.UTF-8
		{中文 (繁體)} {Chinese Traditional} zh_TW.UTF-8
	}
	# label, XKB layout, XKB variant
	variable layouts {
		{English (US)} us {}
		{English (UK)} gb {}
		{English (US, international)} us intl
		German de {}
		{French (AZERTY)} fr {}
		Spanish es {}
		Dvorak us dvorak
		Colemak us colemak
		Italian it {}
		Portuguese pt {}
		{Portuguese (Brazil)} br {}
		{Spanish (Latin American)} latam {}
		{French (Canada)} ca {}
		{German (Switzerland)} ch {}
		{French (Switzerland)} ch fr
		Belgian be {}
		Dutch nl {}
		Danish dk {}
		Norwegian no {}
		Swedish se {}
		Finnish fi {}
		Icelandic is {}
		Irish ie {}
		Polish pl {}
		Czech cz {}
		Slovak sk {}
		Hungarian hu {}
		Romanian ro {}
		Croatian hr {}
		Slovenian si {}
		Estonian ee {}
		Latvian lv {}
		Lithuanian lt {}
		Greek gr {}
		Turkish tr {}
		Russian ru {}
		Ukrainian ua {}
		Bulgarian bg {}
		Hebrew il {}
		Arabic ara {}
		Japanese jp {}
		Korean kr {}
		Chinese cn {}
		Thai th {}
		Vietnamese vn {}
		Hindi in {}
	}
	# Well-known places, offered next to a search result in the same time
	# (nearest first). Searching covers every zone.
	variable major {
		Europe/London Europe/Dublin Europe/Lisbon Atlantic/Reykjavik Africa/Accra
		Europe/Paris Europe/Berlin Europe/Madrid Europe/Rome Europe/Amsterdam
		Europe/Brussels Europe/Vienna Europe/Zurich Europe/Stockholm Europe/Oslo
		Europe/Copenhagen Europe/Helsinki Europe/Warsaw Europe/Prague
		Europe/Budapest Europe/Athens Europe/Bucharest Europe/Kyiv Europe/Istanbul
		Europe/Moscow Africa/Cairo Africa/Johannesburg Africa/Lagos Africa/Nairobi
		Africa/Casablanca Asia/Dubai Asia/Karachi Asia/Kolkata Asia/Dhaka
		Asia/Bangkok Asia/Jakarta Asia/Singapore Asia/Hong_Kong Asia/Shanghai
		Asia/Taipei Asia/Seoul Asia/Tokyo Asia/Manila Asia/Jerusalem Asia/Tehran
		Asia/Riyadh Australia/Perth Australia/Adelaide Australia/Sydney
		Australia/Melbourne Australia/Brisbane Pacific/Auckland America/New_York
		America/Toronto America/Chicago America/Mexico_City America/Denver
		America/Phoenix America/Los_Angeles America/Vancouver America/Anchorage
		Pacific/Honolulu America/Halifax America/St_Johns America/Sao_Paulo
		America/Argentina/Buenos_Aires America/Santiago America/Bogota America/Lima
		America/Caracas
	}
	variable zones {}       ;# every zone name
	variable coords         ;# zone -> {lat lon}
	array set coords {}
	# id, name, what it is for (installed after the first start)
	variable apps {
		steam Steam Games
		heroic Heroic {Epic and GOG}
		lutris Lutris {Every other game}
		discord Discord Chat
		spotify Spotify Music
		obs {OBS Studio} Recording
		vlc VLC Video
		libreoffice LibreOffice Documents
	}
}

# Zones and their places from tzdata (zone.tab: "CC +DDMM+DDDMM Zone").
proc data::load_zones {} {
	variable zones
	variable coords
	variable major
	set zones {}
	foreach f {/usr/share/zoneinfo/zone1970.tab /usr/share/zoneinfo/zone.tab} {
		if {[catch {open $f} fh]} continue
		fconfigure $fh -encoding utf-8
		foreach line [split [read $fh] \n] {
			if {[string index $line 0] eq "#" || $line eq ""} continue
			lassign [split $line \t] cc pos zone
			if {$zone eq ""} continue
			if {$zone ni $zones} { lappend zones $zone }
			if {[regexp {^([+-]\d+)([+-]\d+)$} $pos -> la lo]} {
				set coords($zone) [list [deg $la] [deg $lo]]
			}
		}
		close $fh
	}
	foreach z $major { if {$z ni $zones} { lappend zones $z } }
	if {"UTC" ni $zones} { lappend zones UTC }
	set zones [lsort -dictionary $zones]
}

# ISO 6709 "+DDMM[SS]" / "+DDDMM[SS]" -> degrees
proc data::deg {s} {
	set sign [expr {[string index $s 0] eq "-" ? -1 : 1}]
	set d [string range $s 1 end]
	set n [string length $d]
	set dl [expr {$n % 2 ? 3 : 2}]
	set deg [scan [string range $d 0 [expr {$dl - 1}]] %d]
	set rest [string range $d $dl end]
	set min [expr {[string length $rest] >= 2 ? [scan [string range $rest 0 1] %d] : 0}]
	set sec [expr {[string length $rest] >= 4 ? [scan [string range $rest 2 3] %d] : 0}]
	expr {$sign * ($deg + $min / 60.0 + $sec / 3600.0)}
}

proc data::distance {a b} {
	variable coords
	if {![info exists coords($a)] || ![info exists coords($b)]} { return 1e9 }
	lassign $coords($a) la1 lo1; lassign $coords($b) la2 lo2
	set k [expr {acos(-1) / 180.0}]
	set x [expr {sin($la1*$k)*sin($la2*$k) + cos($la1*$k)*cos($la2*$k)*cos(($lo2-$lo1)*$k)}]
	expr {acos(max(-1.0, min(1.0, $x))) * 6371.0}
}

# Offset in seconds and abbreviation of ZONE at time NOW (cached per zone).
proc data::zone_now {zone now} {
	variable znow
	if {![info exists znow($zone,$now)]} {
		if {[catch {clock format $now -timezone :$zone -format {%z %Z %H:%M}} out]} { set out {+0000 UTC --:--} }
		lassign $out off abbr hm
		set s [expr {[string index $off 0] eq "-" ? -1 : 1}]
		set secs [expr {$s * ([scan [string range $off 1 2] %d] * 3600 + [scan [string range $off 3 4] %d] * 60)}]
		# tzdata's numeric abbreviations ("+01") read better as UTC+1
		if {[regexp {^[+-]\d+$} $abbr]} { set abbr "UTC[string index $abbr 0][scan [string range $abbr 1 end] %d]" }
		set znow($zone,$now) [list $secs $abbr $hm]
	}
	return $znow($zone,$now)
}

# Zones for a search: the matches, then (to fill the list) well-known places
# in the same time as the best match, nearest first.
proc data::zone_search {query selected now {fill 5}} {
	variable zones
	variable major
	set q [string tolower [string map {" " _} [string trim $query]]]
	set out {}
	if {$q eq ""} {
		set anchor $selected
		lappend out $selected
	} else {
		foreach z $zones {
			set city [string tolower [lindex [split $z /] end]]
			if {[string first $q $city] == 0} { lappend out $z }
		}
		foreach z $zones {
			if {$z ni $out && [string first $q [string tolower $z]] >= 0} { lappend out $z }
		}
		set anchor [lindex $out 0]
	}
	if {$anchor eq "" || [llength $out] >= $fill} { return $out }
	set off [lindex [zone_now $anchor $now] 0]
	set near {}
	foreach z $major {
		if {$z in $out} continue
		lappend near [list $z [distance $anchor $z]]
	}
	foreach p [lsort -real -index 1 $near] {
		set z [lindex $p 0]
		if {[lindex [zone_now $z $now] 0] != $off} continue
		lappend out $z
		if {[llength $out] >= $fill} break
	}
	return $out
}
