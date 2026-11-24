# locale.tcl - the logic of Settings → Language and region (no Tk): the language and the formats of this account,
# kept in its locale.conf, and how dates, times, numbers, money and measures show in the formats chosen. The page is
# page-language.tcl.
#
#   loc::start / loc::refresh       read the locales and the files; loc::onchange is called when something changed
#   loc::model                      language formats languages regions examples changed error subtitle
#                                   languages, regions: {code label} pairs for the two dropdowns
#                                   examples: a dict date short time numbers money measures (in the formats)
#                                   changed: the file's language or formats differ from the session's own (LANG and
#                                   LC_TIME in the environment, which ribbon-session set from the files at login), so
#                                   reopening Settings still says "from your next login"; with neither variable set,
#                                   from what Settings started with
#   loc::set_language CODE          LANG=CODE; formats that followed the language keep following it
#   loc::set_formats CODE           LC_TIME LC_NUMERIC LC_MONETARY LC_MEASUREMENT LC_PAPER = CODE (none of them when
#                                   CODE is the language: the formats then follow it)
#   loc::language_name CODE / loc::region_name CODE / loc::examples CODE
#
# The file: $XDG_CONFIG_HOME/locale.conf (~/.config/locale.conf), KEY=VALUE lines as systemd's and Void's
# /etc/locale.conf, which ribbon-session reads after /etc/locale.conf at login. Lines it does not set (LC_COLLATE,
# comments) are kept; it is written whole to a new file and renamed over the old one. With no file of its own, the
# account has the system's: /etc/locale.conf, else LANG in the environment, else en_US.UTF-8.
#
# The locales offered are the UTF-8 ones this system has made (`locale -a`; Ribbon's installer makes only those it was
# asked for), named as the installer names them: the language in its own language, the country in English (the Ribbon
# apps are in English). The examples come from glibc's own data for the formats (`locale -k` under LC_ALL=CODE).
#
# Tests: with RIBBON_LOCALE_TEST set, RIBBON_LOCALE_SYSCONF (in place of /etc/locale.conf) and RIBBON_LOCALE_NOW (the
# seconds the examples show) are read; `locale` is whatever PATH finds.

namespace eval loc {
	variable onchange ""
	variable error ""
	variable avail {}          ;# the UTF-8 locales, normalised (xx_YY.UTF-8[@mod])
	variable conf              ;# KEY -> VALUE of the account's file as read
	array set conf {}
	variable lines {}          ;# the file's lines as read (kept on write)
	variable started ""        ;# language and formats this session started with
	variable cache             ;# CODE -> examples
	array set cache {}
	variable FORMATS {LC_TIME LC_NUMERIC LC_MONETARY LC_MEASUREMENT LC_PAPER}
	# the installer's list (ribbon-installer data.tcl): the native name of each language it offers
	variable NAMES {
		en_US {English (United States)} en_GB {English (United Kingdom)} de_DE Deutsch es_ES Español fr_FR Français
		it_IT Italiano nl_NL Nederlands pl_PL Polski pt_BR {Português (Brasil)} ja_JP 日本語 en_AU {English (Australia)}
		en_CA {English (Canada)} en_IN {English (India)} en_IE {English (Ireland)} es_MX {Español (México)}
		fr_CA {Français (Canada)} pt_PT {Português (Portugal)} ca_ES Català cs_CZ Čeština da_DK Dansk et_EE Eesti
		fi_FI Suomi hr_HR Hrvatski hu_HU Magyar id_ID {Bahasa Indonesia} lt_LT Lietuvių lv_LV Latviešu
		nb_NO {Norsk bokmål} ro_RO Română sk_SK Slovenčina sl_SI Slovenščina sr_RS@latin Srpski sv_SE Svenska
		tr_TR Türkçe el_GR Ελληνικά bg_BG Български ru_RU Русский uk_UA Українська he_IL עברית ar_EG العربية
		hi_IN हिन्दी th_TH ไทย vi_VN {Tiếng Việt} ko_KR 한국어 zh_CN {中文 (简体)} zh_TW {中文 (繁體)}
	}
	# a language with no entry above: its own name, and the country's in brackets when there are several
	variable LANGS {
		en English de Deutsch es Español fr Français it Italiano nl Nederlands pl Polski pt Português ja 日本語 ca Català
		cs Čeština da Dansk et Eesti fi Suomi hr Hrvatski hu Magyar id {Bahasa Indonesia} lt Lietuvių lv Latviešu
		nb {Norsk bokmål} nn {Norsk nynorsk} ro Română sk Slovenčina sl Slovenščina sr Српски sv Svenska tr Türkçe
		el Ελληνικά bg Български ru Русский uk Українська he עברית ar العربية hi हिन्दी th ไทย vi {Tiếng Việt}
		ko 한국어 zh 中文 ga Gaeilge cy Cymraeg eu Euskara gl Galego is Íslenska mt Malti sq Shqip mk Македонски
		be Беларуская ka ქართული hy Հայերեն fa فارسی ms {Bahasa Melayu} bn বাংলা ta தமிழ் af Afrikaans
	}
	# the countries, in English
	variable COUNTRIES {
		US {United States} GB {United Kingdom} DE Germany AT Austria CH Switzerland ES Spain MX Mexico AR Argentina
		CO Colombia CL Chile FR France BE Belgium CA Canada IT Italy NL Netherlands PL Poland BR Brazil PT Portugal
		JP Japan AU Australia NZ {New Zealand} IN India IE Ireland ZA {South Africa} CZ Czechia DK Denmark EE Estonia
		FI Finland HR Croatia HU Hungary ID Indonesia LT Lithuania LV Latvia NO Norway RO Romania SK Slovakia
		SI Slovenia RS Serbia SE Sweden TR Turkey GR Greece CY Cyprus BG Bulgaria RU Russia UA Ukraine IL Israel
		EG Egypt SA {Saudi Arabia} AE {United Arab Emirates} MA Morocco TH Thailand VN Vietnam KR {South Korea}
		CN China TW Taiwan HK {Hong Kong} SG Singapore LU Luxembourg IS Iceland MT Malta AL Albania MK {North Macedonia}
		BY Belarus GE Georgia AM Armenia IR Iran MY Malaysia BD Bangladesh LK {Sri Lanka} PH Philippines
	}
}

proc loc::test {} { info exists ::env(RIBBON_LOCALE_TEST) }
proc loc::path {} {
	set d [expr {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne "" ? $::env(XDG_CONFIG_HOME) : [file join $::env(HOME) .config]}]
	file join $d locale.conf
}
proc loc::syspath {} {
	if {[test] && [info exists ::env(RIBBON_LOCALE_SYSCONF)]} { return $::env(RIBBON_LOCALE_SYSCONF) }
	return /etc/locale.conf
}
proc loc::now {} {
	if {[test] && [info exists ::env(RIBBON_LOCALE_NOW)]} { return $::env(RIBBON_LOCALE_NOW) }
	clock seconds
}

# A locale's name as `locale -a` gives it (en_GB.utf8, sr_RS.utf8@latin) as a file sets it (en_GB.UTF-8[@latin]);
# "" for one that is not UTF-8, and for C and POSIX.
proc loc::norm {name} {
	if {![regexp {^([a-z]{2,3}(?:_[A-Z]{2})?)\.(?:utf8|UTF-8)(@[A-Za-z]+)?$} $name -> base mod]} { return "" }
	return $base.UTF-8$mod
}
# CODE without its encoding: en_GB, sr_RS@latin
proc loc::bare {code} { regsub {\.[^@]*} $code "" }

# KEY=VALUE lines (quotes taken off), as a dict.
proc loc::parse {text} {
	set d [dict create]
	foreach line [split $text \n] {
		if {[regexp {^\s*([A-Z_]+)=(.*)$} $line -> k v]} {
			set v [string trim $v]
			if {[regexp {^"(.*)"$} $v -> q] || [regexp {^'(.*)'$} $v -> q]} { set v $q }
			dict set d $k $v
		}
	}
	return $d
}
proc loc::slurp {f} {
	if {[catch {set h [::open $f r]}]} { return "" }
	fconfigure $h -encoding utf-8
	if {[catch {::read $h} t]} { set t "" }
	::close $h
	return $t
}

proc loc::start {} {
	variable started
	refresh
	set started [list [language] [formats]]
}

proc loc::refresh {} {
	variable avail; variable conf; variable lines; variable error
	set avail {}
	if {[catch {exec locale -a 2>/dev/null} out]} { set out "" }
	foreach l [split $out \n] {
		set n [norm [string trim $l]]
		if {$n ne "" && $n ni $avail} { lappend avail $n }
	}
	set text [slurp [path]]
	set lines [split [string trimright $text \n] \n]
	if {$text eq ""} { set lines {} }
	array unset conf
	array set conf [parse $text]
	notify
}
proc loc::notify {} {
	variable onchange
	if {$onchange ne ""} { uplevel #0 $onchange }
}

# The language: the account's LANG, else the system's, else the environment's.
proc loc::system {} {
	set d [parse [slurp [syspath]]]
	if {[dict exists $d LANG] && [dict get $d LANG] ne ""} { return [dict get $d LANG] }
	if {[info exists ::env(LANG)] && [norm $::env(LANG)] ne ""} { return [norm $::env(LANG)] }
	return en_US.UTF-8
}
proc loc::language {} {
	variable conf
	if {[info exists conf(LANG)] && $conf(LANG) ne ""} { return $conf(LANG) }
	system
}
# The formats: the account's LC_TIME (the five are written together), else the system's, else the language.
proc loc::formats {} {
	variable conf
	if {[info exists conf(LC_TIME)] && $conf(LC_TIME) ne ""} { return $conf(LC_TIME) }
	if {![info exists conf(LANG)]} {
		set d [parse [slurp [syspath]]]
		if {[dict exists $d LC_TIME] && [dict get $d LC_TIME] ne ""} { return [dict get $d LC_TIME] }
	}
	language
}

proc loc::language_name {code} {
	variable NAMES; variable LANGS; variable avail
	set b [bare $code]
	if {[dict exists $NAMES $b]} { return [dict get $NAMES $b] }
	regexp {^([a-z]+)(?:_([A-Z]+))?} $b -> l cc
	if {![dict exists $LANGS $l]} { return $b }
	set name [dict get $LANGS $l]
	# the country in brackets when this system has the language for more than one
	set n 0
	foreach a $avail { if {[string match ${l}_* $a]} { incr n } }
	if {$n > 1 && $cc ne ""} { append name " ([country $cc])" }
	return $name
}
proc loc::country {cc} {
	variable COUNTRIES
	if {[dict exists $COUNTRIES $cc]} { return [dict get $COUNTRIES $cc] }
	return $cc
}
# A formats' name: the country, and the language in brackets when this system has the country in more than one.
proc loc::region_name {code} {
	variable avail
	if {![regexp {^([a-z]+)_([A-Z]+)} [bare $code] -> l cc]} { return [bare $code] }
	set langs {}
	foreach a $avail { if {[regexp {^([a-z]+)_([A-Z]+)} $a -> al acc] && $acc eq $cc && $al ni $langs} { lappend langs $al } }
	set name [country $cc]
	if {[llength $langs] > 1} {
		variable LANGS
		append name " ([expr {[dict exists $LANGS $l] ? [dict get $LANGS $l] : $l}])"
	}
	return $name
}

# The dropdowns' items: this system's locales, and the one in use first when it is not one of them.
proc loc::items {cur namer} {
	variable avail
	set codes $avail
	if {$cur ne "" && $cur ni $codes} { set codes [linsert $codes 0 $cur] }
	set its [lmap c $codes { list $c [$namer $c] }]
	lsort -dictionary -index 1 $its
}

# ---- writing ------------------------------------------------------------------------------------------------

# The file with KEYS set as VALUES says (a value "" takes the key out), the other lines kept.
proc loc::write {changes} {
	variable lines; variable error
	set out {}
	set done {}
	foreach line $lines {
		if {[regexp {^\s*([A-Z_]+)=} $line -> k] && [dict exists $changes $k]} {
			if {$k in $done} continue
			lappend done $k
			if {[dict get $changes $k] ne ""} { lappend out "$k=[dict get $changes $k]" }
			continue
		}
		lappend out $line
	}
	dict for {k v} $changes { if {$k ni $done && $v ne ""} { lappend out "$k=$v" } }
	set f [path]
	set tmp $f.new[pid]
	if {[catch {
		file mkdir [file dirname $f]
		if {[file isdirectory $f]} { error "it is a folder" }
		set h [::open $tmp w]
		fconfigure $h -encoding utf-8 -translation lf
		puts -nonewline $h [expr {[llength $out] ? "[join $out \n]\n" : ""}]
		::close $h
		file rename -force $tmp $f
	} msg]} {
		catch { file delete $tmp }
		set error "Could not save [file tail $f]: $msg"
		notify
		return 0
	}
	set error ""
	refresh
	return 1
}

proc loc::valid {code} { expr {[norm $code] eq $code} }

proc loc::set_language {code} {
	variable conf; variable FORMATS
	if {![valid $code]} { return 0 }
	set ch [dict create LANG $code]
	# formats chosen as the old language (written out with it) follow the new one
	if {[info exists conf(LC_TIME)] && $conf(LC_TIME) eq $code} { foreach k $FORMATS { dict set ch $k "" } }
	if {![info exists conf(LC_TIME)] && [formats] ne [language] && [formats] ne $code} {
		# the system's own formats differed from its language: keep them for this account
		foreach k $FORMATS { dict set ch $k [formats] }
	}
	write $ch
}
proc loc::set_formats {code} {
	variable FORMATS; variable conf
	if {![valid $code]} { return 0 }
	set ch [dict create]
	if {![info exists conf(LANG)]} { dict set ch LANG [language] }
	foreach k $FORMATS { dict set ch $k [expr {$code eq [language] ? "" : $code}] }
	write $ch
}

# ---- the examples ----------------------------------------------------------------------------------------------

# glibc's data for CODE's formats: `locale -k` keys (upper case) -> values. LOCPATH, when set, is where glibc looks.
proc loc::data {code} {
	# read as UTF-8 whatever this process's own encoding: CODE is a UTF-8 locale
	if {[catch {
		set h [::open |[list env LC_ALL=$code locale -k LC_TIME LC_NUMERIC LC_MONETARY LC_MEASUREMENT LC_PAPER 2>/dev/null] r]
		fconfigure $h -encoding utf-8
		set out [::read $h]
		::close $h
	}]} { catch { ::close $h }; return {} }
	set d [dict create]
	foreach line [split $out \n] {
		if {[regexp {^([a-z_0-9]+)=(.*)$} $line -> k v]} {
			if {[regexp {^"(.*)"$} $v -> q]} { set v $q }
			dict set d [string toupper $k] $v
		}
	}
	return $d
}

# STR with Tcl's strftime done in CODE's names (%a %A %b %B %p from glibc), so the examples are in that language.
proc loc::strf {fmt secs d} {
	set days [split [dict get $d DAY] \;]; set abdays [split [dict get $d ABDAY] \;]
	set mons [split [dict get $d MON] \;]; set abmons [split [dict get $d ABMON] \;]
	set ampm [split [dict get $d AM_PM] \;]
	lassign [clock format $secs -format {%w %N %H %e %k}] w m h e k
	set map [list %A [lindex $days $w] %a [lindex $abdays $w] %B [lindex $mons [expr {$m - 1}]] \
		%b [lindex $abmons [expr {$m - 1}]] %h [lindex $abmons [expr {$m - 1}]] %p [lindex $ampm [expr {$h >= 12}]] \
		%P [string tolower [lindex $ampm [expr {$h >= 12}]]] { %Z} "" %Z "" \
		%-d [string trim $e] %-m $m %-I [expr {($h + 11) % 12 + 1}] %-H [string trim $k]]
	clock format $secs -format [string map $map $fmt]
}

proc loc::group {digits sep grouping} {
	set g [lmap x [split $grouping \;] { expr {[string is integer -strict $x] ? $x : -1} }]
	if {$sep eq "" || ![llength $g] || [lindex $g 0] <= 0} { return $digits }
	set out ""
	set i 0
	while {1} {
		set n [lindex $g [expr {min($i, [llength $g] - 1)}]]
		if {$n <= 0 || [string length $digits] <= $n} { set out $digits$out; break }
		set out $sep[string range $digits end-[expr {$n - 1}] end]$out
		set digits [string range $digits 0 end-$n]
		incr i
	}
	return $out
}

proc loc::examples {code} {
	variable cache
	set secs [now]
	set key $code,[clock format $secs -format %Y%m%d%H%M]
	if {[info exists cache($key)]} { return $cache($key) }
	set d [data $code]
	if {![dict exists $d DAY] || ![dict exists $d D_FMT]} {
		return [dict create date "" short "" time "" numbers "" money "" measures ""]
	}
	set dfmt [dict get $d D_FMT]
	# the long date: glibc has none, so in the order the short one has (month first, or the day first)
	set l [lindex [split [loc::bare $code] _] 0]
	set mpos [lsort -integer [lmap t {%m %b %B %-m} { expr {[string first $t $dfmt] < 0 ? 999 : [string first $t $dfmt]} }]]
	set dpos [lsort -integer [lmap t {%d %e %-d} { expr {[string first $t $dfmt] < 0 ? 999 : [string first $t $dfmt]} }]]
	if {$l in {ja zh ko}} {
		set long "$dfmt %A"
	} elseif {[regexp {%-?[de]\.%-?m} $dfmt]} {
		# the day as an ordinal (Sonntag, 8. November 2026)
		set long "%A, %-d. %B %Y"
	} elseif {[lindex $mpos 0] < [lindex $dpos 0]} {
		set long "%A, %B %-d, %Y"
	} else {
		set long "%A %-d %B %Y"
	}
	set tfmt [dict get $d T_FMT]
	if {$tfmt in {%r}} { set tfmt [dict get $d T_FMT_AMPM] }
	set tfmt [string map {%T %H:%M %r %I:%M:%S\ %p} $tfmt]
	regsub {[:.]%S} $tfmt "" tfmt
	set dp [dict get $d DECIMAL_POINT]; set ts [dict get $d THOUSANDS_SEP]
	set numbers [group 1234567 $ts [dict get $d GROUPING]]$dp[string range 89 0 1]
	set mdp [dict get $d MON_DECIMAL_POINT]; set mts [dict get $d MON_THOUSANDS_SEP]
	set frac [dict get $d FRAC_DIGITS]
	if {![string is integer -strict $frac] || $frac < 0 || $frac > 4} { set frac 2 }
	set amount [group 1234 $mts [dict get $d MON_GROUPING]]
	if {$frac} { append amount $mdp[string range 5600 0 [expr {$frac - 1}]] }
	set sym [dict get $d CURRENCY_SYMBOL]
	set space [expr {[dict get $d P_SEP_BY_SPACE] eq "1" ? " " : ""}]
	set money [expr {[dict get $d P_CS_PRECEDES] eq "1" ? "$sym$space$amount" : "$amount$space$sym"}]
	set measures [expr {[dict get $d MEASUREMENT] eq "2" ? "US" : "Metric"}]
	set ph [dict get $d HEIGHT]; set pw [dict get $d WIDTH]
	set paper [expr {"$pw $ph" eq "210 297" ? "A4" : "$pw $ph" in {{216 279} {215 279}} ? "Letter" : "$pw × $ph mm"}]
	set r [dict create date [strf $long $secs $d] short [strf $dfmt $secs $d] time [strf $tfmt $secs $d] \
		numbers $numbers money $money measures "$measures · $paper"]
	set cache($key) $r
	return $r
}

# The language and formats this session runs in: LC_ALL over both, else LANG and LC_TIME (the formats follow LANG
# when LC_TIME is not set). "" when the environment names neither (not a Ribbon session).
proc loc::session {} {
	# a locale that is not a language here (C.UTF-8, POSIX) is still the session's: kept as it is
	set get {{k} {
		if {![info exists ::env($k)] || $::env($k) eq ""} { return "" }
		set n [loc::norm $::env($k)]
		expr {$n ne "" ? $n : $::env($k)}
	}}
	set all [apply $get LC_ALL]
	if {$all ne ""} { return [list $all $all] }
	set lang [apply $get LANG]; set fmt [apply $get LC_TIME]
	if {$lang eq "" && $fmt eq ""} { return "" }
	if {$fmt eq ""} { set fmt $lang }
	list $lang $fmt
}

proc loc::model {} {
	variable started; variable error
	set lang [language]; set fmt [formats]
	set now [session]
	if {$now eq ""} { set now $started }
	set changed [expr {$now ne "" && $now ne [list $lang $fmt]}]
	set sub "[language_name $lang] · [region_name $fmt]"
	if {$changed} { append sub " · from your next login" }
	if {$error ne ""} { set sub $error }
	dict create language $lang formats $fmt languages [items $lang loc::language_name] \
		regions [items $fmt loc::region_name] examples [examples $fmt] changed $changed error $error subtitle $sub
}
