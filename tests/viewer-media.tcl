# viewer-media.tcl - the Image viewer's videos and Steam screenshots without Tk (apps/viewer/video.tcl, games.tcl,
# nav.tcl, crop.tcl): the folder walk with and without a player, mpv's IPC lines read into the transport's model
# and the commands written to it, the time labels; Steam's screenshot folders found, named by their appmanifests,
# counted, sized and ordered newest first, the list's days and the covers in both library-cache layouts; the copy
# a crop of a WebP, a GIF or a transparent picture saves.
#   tclsh8.6 -encoding utf-8 tests/viewer-media.tcl WORKDIR
set work [lindex $argv 0]
file mkdir $work
set root [file dirname [file dirname [file normalize [info script]]]]
set app [file join $root srcpkgs ribbon-desktop files apps viewer]
foreach f {nav video games} { source -encoding utf-8 [file join $app $f.tcl] }
source -encoding utf-8 [file join $root srcpkgs ribbon-desktop files apps settings games.tcl]

set fails 0
proc check {label ok} {
	global fails
	if {$ok} { puts "  ok   $label" } else { puts "  FAIL $label"; incr fails }
}

# ---- the folder walk: videos only when they can be played
set d [file join $work walk]
file mkdir $d
foreach n {b.jpg a.mp4 c.MKV d.txt e.webm} { close [open [file join $d $n] w] }
set nav::play 0
check "no player: the videos are left out" [expr {[lmap p [nav::items $d] {file tail $p}] eq {b.jpg}}]
set nav::play 1
check "with mpv: the videos are walked in Files' order" [expr {[lmap p [nav::items $d] {file tail $p}] eq {a.mp4 b.jpg c.MKV e.webm}}]
check "video::is by extension" [expr {[video::is x/a.MOV] && ![video::is x/a.jpg]}]
check "a path as a file URI keeps spaces and UTF-8 (a video's Copy, the trash's Path)" [expr {![catch {nav::escape "/a b/\u00e9t\u00e9 1.mp4"} u] && $u eq "/a%20b/%C3%A9t%C3%A9%201.mp4"}]

# ---- mpv's IPC socket: never at a path in /tmp anyone could take first
set save_rt [expr {[info exists env(XDG_RUNTIME_DIR)] ? $env(XDG_RUNTIME_DIR) : ""}]
set rt [file join $work rt]; file mkdir $rt; file attributes $rt -permissions 0700
set env(XDG_RUNTIME_DIR) $rt
set s1 [video::sockpath]
check "a private runtime folder holds the socket" [expr {[file dirname $s1] eq $rt}]
file attributes $rt -permissions 0755
set s2 [video::sockpath]
set d2 [file dirname $s2]
file stat $d2 st2
check "a runtime folder others can enter is not used: a private 0700 folder of the viewer's own ($d2)" [expr {$d2 ne $rt && [file owned $d2] && ($st2(mode) & 0o777) == 0o700}]
unset env(XDG_RUNTIME_DIR)
set s3 [video::sockpath]
check "no XDG_RUNTIME_DIR: the same private folder, not /tmp itself" [expr {[file dirname $s3] eq $d2 && [file dirname $s3] ne "/tmp"}]
check "each mpv its own socket" [expr {$s2 ne $s3}]
video::cleanup
check "the viewer's own folder goes as it exits" [expr {![file exists $d2]}]
set env(TMPDIR) [file join $work nowhere]
check "no private folder to be had: no socket, so no mpv is started" [expr {[video::sockpath] eq ""}]
unset env(TMPDIR)
if {$save_rt ne ""} { set env(XDG_RUNTIME_DIR) $save_rt }

# ---- the transport's model from mpv's events
namespace eval viewer {}
proc viewer::draw {} { incr ::drawn }
set drawn 0
set video::dur 0.0; set video::pos 0.0; set video::shown [video::key]
video::event {{"event":"property-change","id":2,"name":"duration","data":135.04}}
video::event {{"event":"property-change","id":1,"name":"time-pos","data":42.3}}
check "duration and position read" [expr {$video::dur == 135.04 && $video::pos == 42.3}]
check "the transport is drawn again when what it shows changed" [expr {$drawn > 0}]
set video::shown [video::key]; set drawn 0
video::event {{"event":"property-change","id":1,"name":"time-pos","data":42.31}}
check "not drawn again for a change it does not show" [expr {$drawn == 0}]
video::event {{"event":"property-change","id":3,"name":"pause","data":true}}
video::event {{"event":"property-change","id":5,"name":"mute","data":true}}
video::event {{"event":"property-change","id":4,"name":"volume","data":70.000000}}
video::event {{"event":"property-change","id":6,"name":"eof-reached","data":false}}
check "pause, mute, volume, eof read" [expr {$video::paused && $video::muted && $video::vol == 70 && !$video::eof}]
video::event {{"event":"property-change","id":1,"name":"time-pos"}}
check "a property without data (unavailable) leaves the model" [expr {$video::pos == 42.31}]
set video::drag scrub
video::event {{"event":"property-change","id":1,"name":"time-pos","data":10.0}}
check "the position is not taken from mpv while the scrubber is held" [expr {$video::pos == 42.31}]
set video::drag ""
check "time labels" [expr {[video::hms 42.9] eq "0:42" && [video::hms 135] eq "2:15" && [video::hms 3725] eq "1:02:05"}]
check "IPC command JSON" [expr {[video::json {set_property pause true}] eq {["set_property","pause",true]}
	&& [video::json {seek 12.5 absolute+exact}] eq {["seek",12.5,"absolute+exact"]}
	&& [video::json [list screenshot-to-file {/a "b"\c.png} video]] eq {["screenshot-to-file","/a \"b\"\\c.png","video"]}}]
check "the scrubber's fraction is clamped" [expr {[video::frac 100 {200 440}] == 0.0 && [video::frac 420 {200 440}] == 0.5 && [video::frac 900 {200 440}] == 1.0}]

# volume and mute are kept
set env(XDG_CONFIG_HOME) [file join $work config]
set video::vol 40; set video::muted 1
video::save_conf
set video::vol 100; set video::muted 0
video::load_conf
check "volume and mute kept in viewer.conf" [expr {$video::vol == 40 && $video::muted == 1}]

# ---- Steam: a library with two games of account 7, one manifest in a second library folder
set home [file join $work home]
set sr [file join $home .local share Steam]
set lib2 [file join $work lib2]
file mkdir [file join $sr steamapps] [file join $lib2 steamapps] [file join $sr appcache librarycache 1145350]
set fh [open [file join $sr steamapps libraryfolders.vdf] w]
puts $fh "\"libraryfolders\"\n\{\n\t\"0\"\n\t\{\n\t\t\"path\"\t\t\"$sr\"\n\t\}\n\t\"1\"\n\t\{\n\t\t\"path\"\t\t\"$lib2\"\n\t\}\n\}"
close $fh
foreach {lib id name} [list $sr 1091500 {Cyberpunk 2077} $lib2 1145350 {Hades II}] {
	set fh [open [file join $lib steamapps appmanifest_$id.acf] w]
	puts $fh "\"AppState\"\n\{\n\t\"appid\"\t\t\"$id\"\n\t\"name\"\t\t\"$name\"\n\}"
	close $fh
}
proc shot {dir name size} {
	file mkdir $dir
	set fh [open [file join $dir $name] w]; fconfigure $fh -translation binary; puts -nonewline $fh [string repeat x $size]; close $fh
}
set rem [file join $sr userdata 7 760 remote]
shot [file join $rem 1091500 screenshots] 20261108213104_1.jpg 1000
shot [file join $rem 1091500 screenshots] 20261101120000_1.jpg 1000
shot [file join $rem 1091500 screenshots] 20261107080000_2.jpg 1000
shot [file join $rem 1091500 screenshots thumbnails] 20261108213104_1.jpg 10
shot [file join $rem 1145350 screenshots] 20261109100000_1.png 500
shot [file join $rem 999 screenshots] notes.txt 5
shot [file join $rem 2000000001 screenshots] 20251224100000_1.jpg 300
set f [file join $rem 1091500 screenshots 20261108213104_1.jpg]
set w [steam::where $f]
check "a Steam screenshot is found by its folder" [expr {[dict get $w root] eq [file normalize $sr] && [dict get $w account] eq 7 && [dict get $w appid] eq 1091500}]
check "a file elsewhere is not" [expr {[steam::where [file join $work walk b.jpg]] eq {}}]
set items [steam::items [file dirname $f]]
check "a game's screenshots newest first, thumbnails left out" [expr {[lmap p $items {file tail $p}] eq {20261108213104_1.jpg 20261107080000_2.jpg 20261101120000_1.jpg}}]
check "taken from Steam's name" [expr {[steam::taken $f] == [clock scan 20261108213104 -format %Y%m%d%H%M%S]}]
set games [steam::games [dict get $w root] 7]
check "three games with screenshots (an empty folder left out)" [expr {[llength $games] == 3}]
check "the games latest first" [expr {[lmap g $games {dict get $g appid}] eq {1145350 1091500 2000000001}}]
check "named by appmanifests, in every library folder" [expr {[dict get [lindex $games 0] name] eq "Hades II" && [dict get [lindex $games 1] name] eq "Cyberpunk 2077"}]
check "a game without a manifest is named by its app id" [expr {[dict get [lindex $games 2] name] eq "2000000001"}]
check "counts and sizes" [expr {[dict get [lindex $games 1] count] == 3 && [dict get [lindex $games 1] bytes] == 3000}]
check "the summary" [expr {[steam::summary $games] eq "5 screenshots · 3 games · 3.8 kB"}]
check "bytes as Files gives them" [expr {[steam::bytes 6200000000] eq "6.2 GB" && [steam::bytes 233000000] eq "233 MB" && [steam::bytes 12] eq "12 B"}]
set now [clock scan {2026-11-08 22:00} -format {%Y-%m-%d %H:%M}]
proc at {s} { clock scan $s -format {%Y-%m-%d %H:%M} }
check "days: today" [expr {[steam::day [at {2026-11-08 09:00}] $now] eq "Today"}]
check "days: this week by weekday" [expr {[steam::day [at {2026-11-05 09:00}] $now] eq "Thu 5 Nov" && [steam::day [at {2026-11-01 09:00}] $now] eq "Sun 1 Nov"}]
check "days: earlier this year by date" [expr {[steam::day [at {2026-10-18 09:00}] $now] eq "18 Oct"}]
check "days: another year with it" [expr {[steam::day [at {2025-12-24 09:00}] $now] eq "24 Dec 2025"}]
# covers: the new layout's hashed icon, the old layout's _icon, the header as the last resort
shot [file join $sr appcache librarycache 1145350] 0123456789abcdef0123456789abcdef01234567.jpg 10
shot [file join $sr appcache librarycache 1145350] header.jpg 10
shot [file join $sr appcache librarycache] 1091500_icon.jpg 10
shot [file join $sr appcache librarycache] 2000000001_header.jpg 10
check "cover: the new layout's icon" [expr {[file tail [steam::cover $sr 1145350]] eq "0123456789abcdef0123456789abcdef01234567.jpg"}]
check "cover: the old layout's icon" [expr {[file tail [steam::cover $sr 1091500]] eq "1091500_icon.jpg"}]
check "cover: the header" [expr {[file tail [steam::cover $sr 2000000001]] eq "2000000001_header.jpg"}]
check "cover: none" [expr {[steam::cover $sr 42] eq ""}]
# the Flatpak's Steam
set fw [steam::where [file join $home .var app com.valvesoftware.Steam .local share Steam userdata 3 760 remote 10 screenshots a.jpg]]
check "the Flatpak's screenshots" [expr {[dict get $fw appid] eq 10 && [dict get $fw account] eq 3}]

# ---- crop on a picture Save cannot write back: the copy is a JPEG, or a PNG when it has transparency
if {[auto_execok ffmpeg] ne ""} {
	source -encoding utf-8 [file join $app crop.tcl]
	namespace eval viewer { variable file ""; variable applied "" }
	proc viewer::applied {path errs} { set ::viewer::applied $path }
	set cd [file join $work cropcopy]
	file mkdir $cd
	exec ffmpeg -nostdin -v error -f lavfi -i color=c=0x285a8c:s=320x240 -frames:v 1 -c:v libwebp [file join $cd opaque.webp]
	exec ffmpeg -nostdin -v error -f lavfi -i color=c=0x285a8c80:s=320x240,format=rgba -frames:v 1 -c:v libwebp [file join $cd clear.webp]
	exec ffmpeg -nostdin -v error -f lavfi -i color=c=0x285a8c:s=320x240 -frames:v 1 [file join $cd anim.gif]
	check "a WebP is not written back" [expr {![crop::can_write [file join $cd opaque.webp]]}]
	check "an opaque WebP's copy is a JPEG" [expr {[file tail [crop::copy_name [file join $cd opaque.webp]]] eq "opaque (edited).jpg"}]
	check "a transparent WebP's copy is a PNG" [expr {[file tail [crop::copy_name [file join $cd clear.webp]]] eq "clear (edited).png"}]
	check "a GIF's copy is a PNG" [expr {[file tail [crop::copy_name [file join $cd anim.gif]]] eq "anim (edited).png"}]
	set viewer::file [file join $cd opaque.webp]
	set before [file mtime $viewer::file]
	set crop::rot 1; set crop::flip 0; set crop::ang 0.0; set crop::fr {0 0 1 1}
	check "Save over a WebP is refused" [expr {![crop::save over] && [file mtime $viewer::file] == $before}]
	check "Save as copy writes the JPEG copy, turned" [expr {[crop::save copy] && $viewer::applied eq [file join $cd "opaque (edited).jpg"]}]
	set probe [exec ffprobe -v error -show_entries stream=codec_name,width,height -of csv=p=0 [file join $cd "opaque (edited).jpg"]]
	check "the copy is a real JPEG, 240 x 320" [expr {[string trim $probe] eq "mjpeg,240,320"}]
}

puts [expr {$fails ? "viewer media: $fails checks failed" : "viewer media: all checks passed"}]
exit [expr {$fails > 0}]
