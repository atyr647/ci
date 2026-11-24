# catalogue-source.tcl - the Catalogue's model without Tk (apps/catalogue/source.tcl): flatpak's
# outputs read, Flathub's requests in Properties' words, a .flatpakref, search across both sources,
# and the Flathub side end to end against a stand-in flatpak on the PATH that logs what it is asked
# (remote-add, remote-ls, list, remote-info, remotes, install with progress, a failed and a
# cancelled install, install --from a .flatpakref, run).
#   tclsh8.6 tests/catalogue-source.tcl
set top [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 $top/srcpkgs/ribbon-desktop/files/apps/catalogue/source.tcl
set fails 0
proc ok {name cond {detail ""}} {
	if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name"; if {$detail ne ""} { puts "       $detail" }; incr ::fails }
}
proc wait {cond {ms 10000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]] && [clock milliseconds] < $end} { after 20 { set ::tick 1 }; vwait ::tick }
	uplevel #0 [list expr $cond]
}
set W [file normalize [exec mktemp -d]]
proc spit {p d} { file mkdir [file dirname $p]; set f [open $p w]; fconfigure $f -encoding utf-8; puts -nonewline $f $d; close $f }
proc slurp {p} { set f [open $p]; fconfigure $f -encoding utf-8; set d [read $f]; close $f; return $d }

# ---- reading flatpak's outputs ---------------------------------------------------------------------
ok "sizes as kit says them" [expr {[cat::fmtsize 98200000] eq "98 MB" && [cat::fmtsize 850000] eq "850 kB" && [cat::fmtsize 0] eq ""}]
ok "flatpak's sizes read" [expr {[cat::bytes "98.2 MB"] == 98200000 && [cat::bytes "1.1 GB"] == 1100000000 && [cat::bytes "850.0 kB"] == 850000 && [cat::bytes junk] eq ""}]
set L [cat::parse_remote_ls "com.discordapp.Discord\tDiscord\t0.0.76\tMessaging, voice and video\t98.2 MB\norg.videolan.VLC\tVLC\t3.0.21\tPlay videos and music\t40.1 MB\n"]
ok "remote-ls: one app a line, sorted by name" [expr {[llength $L] == 2 && [dict get [lindex $L 0] title] eq "Discord" && [dict get [lindex $L 0] download] == 98200000 && [dict get [lindex $L 1] id] eq "org.videolan.VLC"}] $L
set I [cat::parse_list "org.videolan.VLC\tVLC\t3.0.21\tPlay videos\tflathub\tuser\n"]
ok "list: what is installed" [expr {[dict get $I org.videolan.VLC version] eq "3.0.21" && [dict get $I org.videolan.VLC installation] eq "user"}]
set R [cat::parse_remote_info "Discord - Messaging\n\n          ID: com.discordapp.Discord\n     Version: 0.0.76\n     License: LicenseRef-proprietary\n   Installed: 263.4 MB\n     Runtime: org.freedesktop.Platform/x86_64/24.08\n"]
ok "remote-info's facts" [expr {[dict get $R ID] eq "com.discordapp.Discord" && [dict get $R Runtime] eq "org.freedesktop.Platform/x86_64/24.08" && [cat::licence [dict get $R License]] eq "Proprietary"}] $R
set Q [cat::flat_requests "\[Context\]\nshared=network;ipc;\nsockets=wayland;x11;pulseaudio;\ndevices=all;\nfilesystems=home;xdg-download:ro;\n\[Session Bus Policy\]\norg.freedesktop.Notifications=talk\n"]
set Qs [join [lmap q $Q { join $q / }] ,]
ok "a Flatpak's requests, in Properties' words and order" [expr {$Qs eq "globe/Network/,home/Home/read & write,download/Downloads/read only,monitor/Display/Wayland,vol/Audio/,chip/GPU/,pad/Controllers/,camera/Camera/,bell/Notifications/"}] $Qs
ok "an app that asks for nothing asks for nothing" [expr {[cat::flat_requests "\[Application\]\nname=x\n"] eq ""}]
set F [cat::parse_flatpakref "\[Flatpak Ref\]\nName=com.example.App\nTitle=Example\nBranch=stable\nUrl=https://dl.flathub.org/repo/\n"]
ok ".flatpakref read" [expr {[dict get $F Name] eq "com.example.App" && [dict get $F Branch] eq "stable"}]
ok "a file that is not a .flatpakref is refused" [catch {cat::parse_flatpakref "\[Desktop Entry\]\nName=x\n"}]
# a ref's Name goes to flatpak: one that is not an application id (an option, a path) is refused
ok "a .flatpakref whose Name is an option is refused" [expr {[catch {cat::parse_flatpakref "\[Flatpak Ref\]\nName=--command=sh\nUrl=https://dl.flathub.org/repo/\n"}] && [catch {cat::parse_flatpakref "\[Flatpak Ref\]\nName=../x\n"}]}]
ok "a tile's glyph from what the app is" [expr {[cat::glyph Firefox org.mozilla.firefox {}] eq "globe" && [cat::glyph Bottles x {Run Windows software}] eq "wine" && [cat::glyph Foo bar baz] eq "box"}]

# ---- searching both sources ----------------------------------------------------------------------------
set cat::kits [list [dict create source kit id org.gimp.gimp name org.gimp.gimp short gimp title Gimp summary {Edit photos} version 3.0.2 size 1 download 1 installed "" tags {image paint}] \
	[dict create source kit id org.mk.studio name org.mk.studio short mk-studio title {Mk studio} summary {Database editor} version 1.5.0 size 1 download 1 installed 1.5.0 tags {}]]
set cat::flat $L
set cat::flatinst $I
lassign [cat::matching all edit] K Fl
ok "every word, in the name, summary or tags, of both sources" [expr {[llength $K] == 2 && [llength $Fl] == 0}]
lassign [cat::matching all "video play"] K Fl
ok "Flathub's apps matched too" [expr {[llength $K] == 0 && [llength $Fl] == 1 && [dict get [lindex $Fl 0] installed] eq "3.0.21"}]
lassign [cat::matching kits ""] K Fl
ok "Ribbon kits: only kits" [expr {[llength $K] == 2 && ![llength $Fl]}]
lassign [cat::matching installed ""] K Fl
ok "Installed: what is installed of each" [expr {[lmap r $K { dict get $r id }] eq "org.mk.studio" && [lmap r $Fl { dict get $r id }] eq "org.videolan.VLC"}]
lassign [cat::matching all paint] K Fl
ok "tags are searched" [expr {[lmap r $K { dict get $r id }] eq "org.gimp.gimp"}]
# flatpak list's version column is empty for an app whose appdata names no release
# (app/flatpak-builtins-list.c): such an app is still installed
set cat::flatinst [cat::parse_list "org.videolan.VLC\tVLC\t\tPlay videos\tflathub\tuser\tstable\norg.example.Gone\tGone\t\t\tother\tuser\tbeta\n"]
lassign [cat::matching installed ""] K Fl
ok "an installed app with no version in flatpak list is Installed" [expr {[lmap r $Fl { dict get $r id }] eq "org.videolan.VLC org.example.Gone" && [dict get [lindex $Fl 0] installed] eq "3.0.21" && [dict get [lindex $Fl 1] installed] eq "beta"}] $Fl
set cat::detail [dict create source flathub id org.example.Gone title Gone summary "" version 2.0 download "" installed "" state ready requests {} facts {}]
cat::after_flat org.example.Gone 0 "org.example.Gone\tGone\t\t\tflathub\tuser\tstable\n" ""
ok "... and its page says so once it has installed" [expr {[dict get $cat::detail installed] eq "2.0"}] $cat::detail
set cat::flatinst $I

# ---- Flathub end to end, against a stand-in flatpak -----------------------------------------------------
set B $W/bin
spit $B/flatpak {#!/bin/sh
# a stand-in flatpak: logs its arguments, answers as flatpak does
log=$STANDIN/log; st=$STANDIN/installed
echo "$*" >> "$log"
case "$1" in
remote-add) exit 0 ;;
remote-ls) printf 'com.discordapp.Discord\tDiscord\t0.0.76\tMessaging, voice and video\t98.2 MB\norg.videolan.VLC\tVLC\t3.0.21\tPlay videos and music\t40.1 MB\n' ;;
list) [ -f "$st" ] && cat "$st"; exit 0 ;;
remotes) printf 'flathub\thttps://dl.flathub.org/repo/\n' ;;
remote-info)
	if [ "$3" = "--show-metadata" ]; then printf '[Context]\nshared=network;\nsockets=x11;pulseaudio;\n'
	else printf 'Discord - Messaging, voice and video\n\n          ID: com.discordapp.Discord\n     Version: 0.0.76\n    Download: 98.2 MB\n   Installed: 263.4 MB\n'; fi ;;
install)
	if [ -f "$STANDIN/fail" ]; then echo "error: No remote refs found for 'nope'"; exit 1; fi
	# flatpak's own outputs: --noninteractive is its quiet transaction (one line an operation, no
	# progress at all); otherwise, with FLATPAK_FANCY_OUTPUT=0, its CLI transaction prints a progress
	# line per update (app/flatpak-quiet-transaction.c, flatpak-cli-transaction.c)
	case " $* " in
	*" --noninteractive "*) printf 'Installing app/com.discordapp.Discord/x86_64/stable\n'; [ -f "$STANDIN/slow" ] && sleep 4 ;;
	*) printf 'Installing…\n'
		for p in 5 40 80 100; do printf 'Installing… ████▍               %3s%%  2.1 MB/s\n' "$p"; [ -f "$STANDIN/slow" ] && sleep 1; sleep 0.1; done ;;
	esac
	printf 'Installation complete.\n'
	printf 'com.discordapp.Discord\tDiscord\t0.0.76\tMessaging\tflathub\tuser\n' >> "$st" ;;
run) exit 0 ;;
esac
}
file attributes $B/flatpak -permissions 0755
set ::env(PATH) $B:$::env(PATH)
set ::env(STANDIN) $W
spit $W/flathub.flatpakrepo x
set ::env(CATALOGUE_FLATHUB_REPO) $W/flathub.flatpakrepo
set cat::flat {}; set cat::flatinst {}
cat::load_flat
ok "Flathub's list loads" [wait {$cat::flatstate eq "ready" && [llength $cat::flat] == 2}] "$cat::flatstate $cat::flatwhy"
set log [slurp $W/log]
ok "the user's flathub remote is added as the welcome adds it" [string match "*remote-add --user --if-not-exists -- flathub $W/flathub.flatpakrepo*" $log] $log
ok "remote-ls asks the user's flathub for apps" [string match "*remote-ls --user --app --columns=application,name,version,description,download-size -- flathub*" $log]
cat::open_app [lindex $cat::flat 0]
ok "remote-info names the remote and the app after --" [wait {[string match "*remote-info --user -- flathub com.discordapp.Discord*" [slurp $W/log]] && [string match "*remote-info --user --show-metadata -- flathub com.discordapp.Discord*" [slurp $W/log]]}]
ok "an app's page: remote-info's facts and its requests" [wait {[dict get $cat::detail state] eq "ready" && [llength [dict get $cat::detail requests]] == 3}] $cat::detail
ok "... the installed size and download from remote-info" [expr {[dict get $cat::detail download] == 98200000 && [dict get $cat::detail facts Installed] eq "263.4 MB"}]
set pcts {}
set cat::changed {if {[dict size $cat::job] && [dict get $cat::job pct] >= 0} { lappend ::pcts [dict get $cat::job pct] }}
cat::install {}
ok "Install runs flatpak install for this user, from flathub" [wait {![dict size $cat::job]}]
ok "... its progress followed" [expr {"40" in $pcts && "100" in $pcts}] $pcts
ok "... and it ends done, installed" [wait {[dict get $cat::detail installed] eq "0.0.76"}] $cat::detail
ok "... with the arguments flatpak needs" [string match "*install --user -y -- flathub com.discordapp.Discord*" [slurp $W/log]]
ok "... and nothing to say" [expr {[dict get $cat::last phase] eq "done"}] $cat::last
# a failure keeps flatpak's words for the window
file delete $W/installed
set cat::detail [dict merge $cat::detail {installed ""}]
spit $W/fail 1
cat::install {}
wait {![dict size $cat::job]}
ok "a failed install says flatpak's words" [expr {[dict get $cat::last phase] eq "failed" && [string match "*No remote refs*" [dict get $cat::last said]]}] $cat::last
file delete $W/fail
# Cancel stops it
spit $W/slow 1
cat::install {}
wait {[dict size $cat::job] && [dict get $cat::job pct] >= 5}
cat::cancel
ok "Cancel stops the install" [wait {![dict size $cat::job]} 5000]
ok "... and it ends cancelled, not installed" [expr {[dict get $cat::last code] == 130 && [dict get $cat::detail installed] eq ""}] $cat::last
file delete $W/slow $W/installed
# a .flatpakref
spit $W/Downloads/com.discordapp.Discord.flatpakref "\[Flatpak Ref\]\nName=com.discordapp.Discord\nTitle=Discord\nBranch=stable\nUrl=https://dl.flathub.org/repo/\nIsRuntime=false\n"
cat::open_ref $W/Downloads/com.discordapp.Discord.flatpakref
ok "a .flatpakref finds its remote among the user's" [wait {[dict get $cat::detail state] eq "ready" && [dict get $cat::detail remote] eq "flathub"}] $cat::detail
cat::install {}
wait {![dict size $cat::job]}
ok "... and installs with flatpak install --from" [string match "*install --user -y --from -- $W/Downloads/com.discordapp.Discord.flatpakref*" [slurp $W/log]]
ok "Open runs flatpak run" [expr {[cat::launch] eq "" && [wait {[string match "*run -- com.discordapp.Discord*" [slurp $W/log]]} 3000]}]
# without flatpak: Flathub says so and the kits stay
set ::env(PATH) /nonexistent
unset -nocomplain ::auto_execs
cat::load_flat
ok "no flatpak: Flathub says why, nothing breaks" [expr {$cat::flatstate eq "none" && $cat::flatwhy ne ""}]
# Install when flatpak cannot be run: it ends at once, failed, with why; the next Install is not blocked
set cat::changed {}
set cat::detail [dict create source ref id com.discordapp.Discord name com.discordapp.Discord title Discord summary "" version "" download "" installed "" file $W/Downloads/com.discordapp.Discord.flatpakref state ready requests {} facts {} remote ""]
set cat::last {}
catch {cat::install {}} e
ok "an install that cannot start ends failed, saying why" [expr {[wait {![dict size $cat::job]} 3000] && [dict size $cat::last] && [dict get $cat::last phase] eq "failed" && [dict get $cat::last said] ne ""}] "job=$cat::job last=$cat::last err=$e"

file delete -force $W
if {$fails} { puts "catalogue source: $fails checks failed"; exit 1 }
puts "catalogue source: all checks passed"
