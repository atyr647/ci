# settings-units.tcl - the Settings registry, rail items, search and the updates
# chip's count, with no display (tclsh8.6 tests/settings-units.tcl ROOT, where
# ROOT is the repo's ribbon-desktop/files folder). Exits 1 on any failure.
set D [lindex $argv 0]
set fails 0
proc check {what ok} {
	global fails
	if {$ok} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails }
}
set apps [file join $D apps settings]
namespace eval ui {}
foreach f {registry rail search page-appearance} { source -encoding utf-8 [file join $apps $f.tcl] }

# the rail: sixteen items, four groups, Appearance first (Settings-A-Rail, STYLE 3)
set ids [settings::ids]
check "the rail has sixteen items (got [llength $ids])" [expr {[llength $ids] == 16}]
check "Appearance is first" [expr {[lindex $ids 0] eq "appearance"}]
check "the first group is Appearance, Display, Sound, Accessibility" \
	[expr {[lrange $ids 0 3] eq {appearance display sound access}}]
check "the second group is Network, Bluetooth, Printers" \
	[expr {[lrange $ids 4 6] eq {network bluetooth printers}}]
check "the last group is Users, Updates, Date and time, Language and region, About" \
	[expr {[lrange $ids 11 15] eq {users updates datetime language about}}]
check "Power sits between Network and Keyboard and mouse, with Game overlay" \
	[expr {[lrange $ids 7 10] eq {power game keyboard defaults}}]
check "the rail's own icons: Accessibility, Printers, Language and region, and Game overlay's as the board draws it" \
	[expr {[info exists ::ui::paths(access)] && [info exists ::ui::paths(printer)] && [info exists ::ui::paths(lang)] && [settings::get access icon] eq "access" && [settings::get printers icon] eq "printer" && [settings::get language icon] eq "lang" && [settings::get game icon] eq "overlay" && [info exists ::ui::paths(overlay)]}]
check "the rail's pitch is 32: sixteen items from 132 end at 689 with the three rules' 15" \
	[expr {$::settings::pitch == 32 && $::settings::rowtop + 16 * $::settings::pitch + 3 * $::settings::groupgap == 689}]
check "the Appearance page is registered with its title and row labels" \
	[expr {[settings::get appearance title] eq "Appearance" && [settings::get appearance draw] eq "settings::draw_appearance"}]
check "an item with no page has no draw proc" [expr {[settings::get sound draw] eq ""}]

# search: a row label finds its page, case does not matter, a miss finds nothing
check "a row label (Duplicate) finds Appearance" [expr {[settings::matching Duplicate] eq {appearance}}]
check "case does not matter" [expr {[settings::matching duplicate] eq {appearance}}]
check "a title finds its item" [expr {[settings::matching bluetooth] eq {bluetooth}}]
check "an empty query keeps all sixteen" [expr {[llength [settings::matching ""]] == 16}]
check "a miss finds nothing" [expr {[settings::matching zzzzqq] eq {}}]

# registration: an unknown item or option is an error
check "an unknown item is refused" [expr {[catch {settings::page nosuch -title X}] == 1}]
check "an unknown option is refused" [expr {[catch {settings::page appearance -nope 1}] == 1}]

# the updates count, read as the shell reads it (kit's cache file)
set T [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] settings-units-[pid]]
file mkdir [file join $T kit]
set cache [file join $T kit updates]
set env(XDG_CACHE_HOME) $T
proc write {text} { global cache; set fh [open $cache w]; puts -nonewline $fh $text; close $fh }
write {notify yes updates {{firefox 1.0} {git 2.0} {kernel 3.0} {mesa 4.0} {zlib 5.0}}}
check "five waiting updates with notify on give 5" [expr {[settings::updates_read] == 5}]
write {notify no updates {{firefox 1.0}}}
check "notify off gives 0 (the chip is hidden)" [expr {[settings::updates_read] == 0}]
write {not a dict at all {}}
check "a broken file gives 0" [expr {[settings::updates_read] == 0}]
file mkdir [file join $T ribbon]
set sys [file join $T ribbon system-updates]
set fh [open $sys w]; puts -nonewline $fh {checked 1794000000 updates {{name linux6.18 short linux6.18 version 6.18.62_1 new 6.18.63_1 flags restart download 0}}}; close $fh
write {notify yes updates {{firefox 1.0} {git 2.0}}}
check "the system's waiting packages count too (ribbon update --tcl's file): 2 + 1" [expr {[settings::updates_read] == 3}]
write {notify no updates {{firefox 1.0}}}
check "kit's notify off hides the system's count too" [expr {[settings::updates_read] == 0}]
file delete $cache
check "only the system's file: its count" [expr {[settings::updates_read] == 1}]
file delete $sys
check "no cache file gives 0" [expr {[settings::updates_read] == 0}]
file delete -force $T

if {$fails} { puts "settings units: $fails failure(s)"; exit 1 }
puts "settings units: all passed"
