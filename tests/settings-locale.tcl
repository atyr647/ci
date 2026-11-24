# settings-locale.tcl - apps/settings/locale.tcl (the logic of Settings → Language and region) with no display: the
# locales offered (a `locale` stand-in whose -a lists them and whose -k gives glibc's real data for en_GB, en_US and
# de_DE, kept in tests/fixtures/locale), their names, the language and the formats from the account's locale.conf, the
# system's file and the environment, every change written to the file (other lines kept, atomic, an unwritable place
# said), the formats following the language, and the examples each locale gives.
#   tclsh8.6 -encoding utf-8 tests/settings-locale.tcl FILESDIR FIXTURES
# The environment (HOME, XDG_CONFIG_HOME, TMPDIR) is the step's (tests/steps.d/57-settings-language.sh).
set D [lindex $argv 0]
set FX [file normalize [lindex $argv 1]]
set fails 0
proc check {what cond} {
	global fails
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
proc slurp {f} { if {[catch {open $f r} fh]} { return "(none)" }; fconfigure $fh -encoding utf-8; set t [read $fh]; close $fh; set t }
# the examples ex are the dict want, key by key
proc same {ex want} {
	if {[dict size $ex] != [dict size $want]} { return 0 }
	dict for {k v} $want { if {![dict exists $ex $k] || [dict get $ex $k] ne $v} { puts "    $k: [dict get $ex $k] (want $v)"; return 0 } }
	return 1
}
proc spit {f t} { file mkdir [file dirname $f]; set fh [open $f w]; fconfigure $fh -encoding utf-8; puts -nonewline $fh $t; close $fh }

set T [file normalize [file join $::env(TMPDIR) loc-[pid]]]
file mkdir $T/bin
# the stand-in: -a prints $T/list, -k under LC_ALL=CODE prints the fixture for CODE (none: as glibc, the C data)
spit $T/bin/locale "#!/bin/sh
if \[ \"\$1\" = -a \]; then cat '$T/list'; exit 0; fi
f='$FX'/\"\$LC_ALL\"
\[ -f \"\$f\" \] || exit 1
cat \"\$f\"
"
file attributes $T/bin/locale -permissions 0755
set ::env(PATH) $T/bin:$::env(PATH)
set ::env(RIBBON_LOCALE_TEST) 1
set ::env(RIBBON_LOCALE_SYSCONF) $T/etc/locale.conf
set ::env(TZ) UTC
set ::env(RIBBON_LOCALE_NOW) [clock scan "2026-11-07 10:42" -format "%Y-%m-%d %H:%M" -timezone :UTC]
set conf [file join $::env(XDG_CONFIG_HOME) locale.conf]
spit $T/list "C\nC.utf8\nPOSIX\nde_DE.utf8\nen_GB.utf8\nen_GB.iso88591\nen_US.utf8\nfr_BE.utf8\nfr_FR.utf8\nen_CA.utf8\nfr_CA.utf8\nsr_RS.utf8@latin\n"
spit $T/etc/locale.conf "LANG=\"en_US.UTF-8\"\n"
unset -nocomplain ::env(LANG) ::env(LC_ALL) ::env(LC_TIME)

source -encoding utf-8 [file join $D apps settings locale.tcl]
set calls 0
set loc::onchange {incr ::calls}
loc::start

# ---- what is offered, and its names
check "the UTF-8 locales only, as a file names them (C, POSIX and ISO-8859 left out)" \
	{$loc::avail eq {de_DE.UTF-8 en_GB.UTF-8 en_US.UTF-8 fr_BE.UTF-8 fr_FR.UTF-8 en_CA.UTF-8 fr_CA.UTF-8 sr_RS.UTF-8@latin}}
check "  the installer's names: Deutsch, English (United Kingdom), Srpski" \
	{[loc::language_name de_DE.UTF-8] eq "Deutsch" && [loc::language_name en_GB.UTF-8] eq "English (United Kingdom)" && [loc::language_name sr_RS.UTF-8@latin] eq "Srpski"}
check "  a language the installer does not list: its own name and the country when there are several (Français (Belgium))" \
	{[loc::language_name fr_BE.UTF-8] eq "Français (Belgium)"}
check "  the formats by country, the language added where a country has two (Canada (English), Canada (Français))" \
	{[loc::region_name en_GB.UTF-8] eq "United Kingdom" && [loc::region_name en_CA.UTF-8] eq "Canada (English)" && [loc::region_name fr_CA.UTF-8] eq "Canada (Français)"}
set m [loc::model]
check "the dropdowns: every locale, sorted by name" \
	{[lmap i [dict get $m languages] { lindex $i 1 }] eq {Deutsch {English (Canada)} {English (United Kingdom)} {English (United States)} Français {Français (Belgium)} {Français (Canada)} Srpski}}

# ---- where the language comes from
check "no file of the account's: the system's /etc/locale.conf (its quotes taken off)" \
	{[dict get $m language] eq "en_US.UTF-8" && [dict get $m formats] eq "en_US.UTF-8" && ![dict get $m changed]}
check "  the subtitle: the language and the formats" {[dict get $m subtitle] eq "English (United States) · United States"}
file delete $T/etc/locale.conf
set ::env(LANG) de_DE.utf8
check "no system file either: LANG from the environment" {[loc::language] eq "de_DE.UTF-8"}
unset ::env(LANG)
check "  nor that: en_US.UTF-8" {[loc::language] eq "en_US.UTF-8"}
spit $T/etc/locale.conf "LANG=en_US.UTF-8\nLC_TIME=en_GB.UTF-8\n"
check "the system's own formats (its LC_TIME)" {[loc::formats] eq "en_GB.UTF-8"}

# ---- changes
set calls 0
check "set_language writes LANG=CODE" {[loc::set_language en_GB.UTF-8] && [slurp $conf] eq "LANG=en_GB.UTF-8\n"}
check "  and says so (onchange)" {$calls >= 1}
check "  the model says from your next login" {[dict get [loc::model] changed] && [string match "* · from your next login" [dict get [loc::model] subtitle]]}
check "  the system's formats were the new language: they follow it (no LC_ lines)" {[loc::formats] eq "en_GB.UTF-8"}
check "a name that is not a UTF-8 locale is refused, the file untouched" {![loc::set_language "en_GB; rm -rf"] && [slurp $conf] eq "LANG=en_GB.UTF-8\n"}
loc::set_formats de_DE.UTF-8
check "set_formats writes the five LC_ lines" \
	{[slurp $conf] eq "LANG=en_GB.UTF-8\nLC_TIME=de_DE.UTF-8\nLC_NUMERIC=de_DE.UTF-8\nLC_MONETARY=de_DE.UTF-8\nLC_MEASUREMENT=de_DE.UTF-8\nLC_PAPER=de_DE.UTF-8\n"}
check "  the formats are then those" {[loc::formats] eq "de_DE.UTF-8" && [loc::language] eq "en_GB.UTF-8"}
loc::set_language de_DE.UTF-8
check "a language that is the formats' takes the LC_ lines out (both follow it again)" {[slurp $conf] eq "LANG=de_DE.UTF-8\n"}
loc::set_language en_US.UTF-8
check "  then a new language: the formats follow it" {[loc::formats] eq "en_US.UTF-8" && [slurp $conf] eq "LANG=en_US.UTF-8\n"}
loc::set_formats en_GB.UTF-8; loc::set_formats en_US.UTF-8
check "formats set back to the language: the LC_ lines go" {[slurp $conf] eq "LANG=en_US.UTF-8\n"}
spit $conf "# mine\nLANG=en_US.UTF-8\nLC_COLLATE=C\nLC_TIME=fr_FR.UTF-8\nLC_NUMERIC=fr_FR.UTF-8\n"
loc::refresh
loc::set_formats en_GB.UTF-8
check "the lines it does not set stay (a comment, LC_COLLATE), its own in place" \
	{[slurp $conf] eq "# mine\nLANG=en_US.UTF-8\nLC_COLLATE=C\nLC_TIME=en_GB.UTF-8\nLC_NUMERIC=en_GB.UTF-8\nLC_MONETARY=en_GB.UTF-8\nLC_MEASUREMENT=en_GB.UTF-8\nLC_PAPER=en_GB.UTF-8\n"}
check "  written whole and renamed: no new file left beside it" {[glob -nocomplain -directory [file dirname $conf] locale.conf.new*] eq {}}
file delete $conf
loc::refresh
loc::set_formats de_DE.UTF-8
check "no file yet: set_formats writes the language too (so it does not change under it)" \
	{[lindex [split [slurp $conf] \n] 0] eq "LANG=en_US.UTF-8" && [loc::formats] eq "de_DE.UTF-8"}
# an unwritable place
file delete $conf
file mkdir $conf
loc::refresh
check "a file that cannot be written: 0, and the subtitle says why" {![loc::set_language en_GB.UTF-8] && [string match "Could not save locale.conf*" [dict get [loc::model] subtitle]]}
file delete -force $conf
loc::refresh

# ---- the examples: glibc's data for each locale
set ex [loc::examples en_GB.UTF-8]
check "en_GB: Saturday 7 November 2026, 07/11/26, 10:42, 1,234,567.89, £1,234.56, Metric · A4" \
	{[same $ex [list date "Saturday 7 November 2026" short 07/11/26 time 10:42 numbers 1,234,567.89 money £1,234.56 measures "Metric · A4"]]}
set ex [loc::examples en_US.UTF-8]
check "en_US: Saturday, November 7, 2026, 11/07/2026, 10:42 AM, \$1,234.56, US · Letter" \
	{[same $ex [list date "Saturday, November 7, 2026" short 11/07/2026 time "10:42 AM" numbers 1,234,567.89 money {$1,234.56} measures "US · Letter"]]}
set ex [loc::examples de_DE.UTF-8]
check "de_DE: Samstag, 7. November 2026, 07.11.2026, 1.234.567,89, 1.234,56 €" \
	{[same $ex [list date "Samstag, 7. November 2026" short 07.11.2026 time 10:42 numbers 1.234.567,89 money "1.234,56\u00a0€" measures "Metric · A4"]]}
check "a locale glibc has no data for: empty examples, no error" {[dict get [loc::examples xx_YY.UTF-8] date] eq ""}
check "digits grouped as the locale says (India's 3;2)" {[loc::group 1234567 , 3\;2] eq "12,34,567"}

# ---- "from your next login" against the session's own LANG and LC_TIME (ribbon-session sets them at login)
spit $conf "LANG=de_DE.UTF-8\n"
set ::env(LANG) en_US.UTF-8
set loc::error ""
loc::start
check "Settings opened again after a change: still from your next login (the session runs en_US, the file says de_DE)" \
	{[dict get [loc::model] changed] && [string match "* · from your next login" [dict get [loc::model] subtitle]]}
set ::env(LANG) de_DE.utf8
check "  a session that already runs the file's language and formats: no next login" {![dict get [loc::model] changed]}
loc::set_formats en_GB.UTF-8
check "  new formats: the session's LC_TIME (the language's, unset) differs, so from your next login" {[dict get [loc::model] changed]}
set ::env(LC_TIME) en_GB.UTF-8
check "  a session started with them (LC_TIME en_GB): no next login" {![dict get [loc::model] changed]}
set ::env(LC_ALL) C.UTF-8
check "  LC_ALL in the session wins over both (C is not a language here: from your next login)" {[dict get [loc::model] changed]}
unset ::env(LANG) ::env(LC_TIME) ::env(LC_ALL)
loc::start
check "  no LANG, LC_TIME or LC_ALL in the environment: what Settings started with" {![dict get [loc::model] changed]}
file delete $conf

file delete -force $T
if {$fails} { puts "language and region: $fails failed"; exit 1 }
puts "language and region: all checks passed"
