# properties-scene.tcl - put Properties into one of its boards' states
# (design/mockups/Props-A*), on a 1440 x 900 desktop, for screenshots and
# pixel comparison (RIBBON_PROPERTIES_SCENE=this file, run by
# properties/main.tcl; the home from tests/properties-fixture.tcl).
#   RIBBON_SCENE = rail | permissions | storage | libraries | signature | held (the boards:
#                  Props-A-Rail, A2, A5, A6, A7, A11); photo | folder (the Rail's General
#                  page, which only a .kit that kit can't read still gets); kitfile | notkit (A8, A9);
#                  sheet | install | uninstall | rewind | long (kit's prompt: Kit-Sheet-2, -1, -3, -4, -5);
#                  longcheck (long, scrolled by the wheel and End, said on stdout)
#   RIBBON_PROPERTIES_SHOT = file: take a screenshot (ImageMagick import)
#   RIBBON_PROPERTIES_EXIT = ms: quit after drawing; any Tcl error fails
set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "rail"}]
if {[info exists ::env(RIBBON_PROPERTIES_EXIT)] || [info exists ::env(RIBBON_PROPERTIES_SHOT)]} {
	proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
}
set ui::caretfix off
# the boards show kit's actions, whatever this machine has
proc kitlink::usable {} { return 1 }
proc kitlink::kitcmd {} { return kit }
proc today {hm} { clock scan "[clock format [clock seconds] -format %Y-%m-%d] $hm" -format {%Y-%m-%d %H:%M} }
proc at {s} { clock scan $s -format {%Y-%m-%d %H:%M} }

# Firefox as the boards have it: 134.0.1 installed, 134.0.2 waiting
proc firefox {} {
	set K [kitlink::empty]
	set K [dict merge $K [dict create name org.mozilla.firefox short firefox title Firefox kind {Web browser} cats {Network;WebBrowser;} \
		version 134.0.1 size 248000000 installed 1 when [at {2026-10-12 10:00}] source {Ribbon kits} data 412000000 \
		signer {Ribbon release key} key RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3 keyid 53E9B1D2E3F00C64 \
		sigstate valid keyroles app keyfrom [at {2026-05-01 00:00}] keyuntil [at {2027-05-01 00:00}] repository org.ribbon.kits \
		checked [today 09:12] chunks 1284 indexage 3600 stored 251000000 \
		root 6f1c0a7e0b5d9a1f4c2e8b3d7a9f0e1c2b3d4e5f60718293a4b5c6d7e8f90a1b]]
	dict set K perms {{network yes} {folders {Downloads rw}} {display wayland} {audio 1} {gpu 1} {dbus org.freedesktop.Notifications}}
	dict set K grants {nested 1}
	dict set K libs {{gtk3 3.24.43 {>=3.24} org.gtk.gtk3} {nss 3.104 {>=3.100} org.mozilla.nss} {ffmpeg 7.1 {>=7 <8} org.ffmpeg.ffmpeg}
		{mesa 25.0.0 {} org.freedesktop.mesa} {pipewire 1.2.7 {} org.pipewire.pipewire} {libvpx 1.14.1 {} org.webmproject.libvpx}
		{dbus 1.16.0 {} org.freedesktop.dbus} {libpng 1.6.44 {} org.libpng.libpng}}
	dict set K update [dict create new 134.0.2 bytes 12000000 security 1 released {5 Nov}]
	dict set K datapaths [list [file join $::env(HOME) .mozilla] [file join $::env(HOME) .local share kit data org.mozilla.firefox]]
	return $K
}

# ... and as the Storage, Libraries and Signature boards have it (Props-A5, A6, A7)
proc firefox_disk {} {
	set K [firefox]
	set base [file join $::env(HOME) .local share kit org.mozilla.firefox]
	dict set K programdir $base/134.0.1; dict set K programsize 248000000
	dict set K datapaths [list $base/home]; dict set K datasizes 108000000
	dict set K caches [list $base/home/.cache]; dict set K cachesizes 304000000
	set libs {}
	foreach {n v r u b} {dbus 1.16.0 >=1.14 22 2 ffmpeg 7.1 {>=7 <8} 6 21 fontconfig 2.15.0 >=2.13 20 1 gtk3 3.24.43 >=3.24 14 38
		harfbuzz 10.1.0 >=8.0 18 3 libpng 1.6.44 {>=1.6 <1.7} 31 1 libvpx 1.14.1 >=1.13 2 3 libwebp 1.4.0 >=1.3 7 1 mesa 25.2.7 >=24.0 11 64
		nss 3.104 >=3.101 1 9 pipewire 1.2.7 >=1.0 9 4 sqlite 3.47.2 >=3.40 12 2} {
		lappend libs [list $n $v $r org.example.$n $u [expr {$b * 1000000}]]
	}
	dict set K libs $libs
	set K [dict merge $K [dict create listserial 12 listexpires [at {2027-11-01 12:00}] rootname {Ribbon root key} \
		keyfrom [at {2026-09-01 12:00}] keyuntil [at {2027-02-28 12:00}] \
		manifest 9f2c7d1e0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829341ab sealed [at {2026-11-03 12:00}]]]
	return $K
}
# MK Studio held at 1.4.0 (Props-A11-Held)
proc mkstudio {} {
	set K [dict merge [firefox] [dict create name org.equi4.mk-studio short mk-studio title {MK Studio} kind {Database editor} cats {Development;Database;} \
		version 1.4.0 size 18000000 when [at {2026-09-21 10:00}] data 6000000 chunks 96 update "" \
		held 1 heldfrom 1.5.0 heldwhen [at {2026-11-05 10:00}] heldnew [dict create new 1.5.0 bytes 3000000]]]
	dict set K perms {{folders {Documents rw Downloads ro}} {display wayland} {dbus org.freedesktop.Notifications}}
	dict set K grants {}
	dict set K libs {{tcl 9.0.1 {} org.tcl.tcl 4 1} {tk 9.0.1 {} org.tcl.tk 3 1} {mk4tcl 2.4.9.7 {} org.equi4.mk4tcl 2 1}
		{sqlite 3.47.2 {} org.sqlite.sqlite 12 1} {fontconfig 2.15.0 {} org.fc.fontconfig 20 1} {libpng 1.6.44 {} org.libpng.libpng 31 1}}
	return $K
}

# OBS Studio 31.0.1 as a .kit in Downloads, not installed (Props-A8-KitFile, Kit-Sheet-1)
proc obs {} {
	set K [kitlink::empty]
	set K [dict merge $K [dict create name com.obsproject.obs short obs title {OBS Studio} kind {Screen recorder} cats {AudioVideo;Recorder;} \
		version 31.0.1 size 214000000 installed 0 source obs-studio-31.0.1.kit file [file join $::env(HOME) Downloads obs-studio-31.0.1.kit] \
		signer {Ribbon release key} key RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3 keyid 53E9B1D2E3F00C64 \
		sigstate valid keyroles app checked [clock seconds] chunks 1026 stored 214000000 sealed [at {2026-10-28 12:00}] \
		root 0b1c0a7e0b5d9a1f4c2e8b3d7a9f0e1c2b3d4e5f60718293a4b5c6d7e8f90a1b]]
	dict set K perms {{network yes} {display wayland} {audio mic} {gpu 1} {camera 1} {screencast 1}}
	dict set K libs {{qt6-base 6.8.1 {} org.qt.qt6-base {} {}} {ffmpeg 7.1.1 {} org.ffmpeg.ffmpeg {} {}} {x264 0.164 {} org.videolan.x264 {} {}}
		{pipewire 1.2.7 {} org.pipewire.pipewire {} {}} {mesa 25.2.7 {} org.freedesktop.mesa {} {}} {libvpx 1.14.1 {} org.webmproject.libvpx {} {}}}
	dict set K released [at {2026-10-28 12:00}]
	return $K
}
# the last index lists OBS Studio 31.0.1
proc kitlink::index_records {name} {
	if {$name eq "com.obsproject.obs"} { return [list [dict create name $name version 31.0.1 root "" bundle ""]] }
	return {}
}
# Mousepad, an app installed with the system and not a kit (Props-A9-NotKit)
proc mousepad {} {
	set d [file join $::env(HOME) .local share applications org.xfce.mousepad.desktop]
	set fh [open $d w]; fconfigure $fh -encoding utf-8
	puts $fh "\[Desktop Entry\]\nType=Application\nName=Mousepad\nGenericName=Text editor\nComment=Simple text editor\nExec=mousepad %U\nTerminal=false"
	puts $fh "Categories=Utility;TextEditor;\nMimeType=text/plain;text/markdown;text/x-tcl;application/x-shellscript;"
	close $fh
	set K [page::app_only [page::desktop_entry $d]]
	# where the board's system has it
	dict set K desktop /usr/share/applications/org.xfce.mousepad.desktop
	return $K
}
# kit's plan rows as plan.tcl makes them
proc row {name full action old new bytes {tags {}}} {
	dict create name $name short $name fullname $full action $action old $old new $new bytes $bytes tags $tags kind app root ""
}

# the boards' file and folder: their dates, size and owner
proc photo {} {
	set p [file join $::env(HOME) Pictures Iceland Jökulsárlón.jpg]
	page::open path $p
	set page::F [dict merge $page::F [dict create mime image/jpeg typename {JPEG image} size 4218903 owner ada \
		btime [at {2026-08-14 21:47}] mtime [at {2026-08-15 10:02}] atime [today 08:31]]]
	proc fp::me {} { return ada }
	fp::start
	set fp::dims {4032 3024}
	set fp::exif {Make FUJIFILM Model X-T5 LensModel {XF16-55mmF2.8 R LM WR} ExposureTime 0.004 FNumber 8.0 ISO 160 FocalLength 23.0 DateTimeOriginal {2026:08:14 21:47:03}}
}
proc folder {} {
	page::open path [file join $::env(HOME) Pictures Iceland]
	set page::F [dict merge $page::F [dict create owner ada btime [at {2026-06-02 18:20}] mtime [clock add [today 22:14] -1 day]]]
	proc fp::me {} { return ada }
	fp::start
	set fp::drive {System 412000000000}
	# let the count finish, then the boards' numbers
	while {$facts::W(busy)} { update }
	array set facts::W {files 198 dirs 16 bytes 3104226817 photos,n 164 photos,b 2400000000 videos,n 12 videos,b 640000000
		documents,n 6 documents,b 38000000 other,n 16 other,b 16000000}
}

switch -- $scene {
	rail { page::open_app [firefox] }
	permissions {
		page::open_app [firefox]
		page::go permissions
		set ap::E [perms::set_ $ap::E folder:Pictures ro]
		set ap::E [perms::set_ $ap::E input 1]
		page::menu_toggle [dict create id audio x 1060 y 237 top 197 cur 1 script {ap::set_ audio} \
			items {{0 Off x} {1 Playback vol} {mic {Playback and microphone} mic}}]
		set page::menu_hover 2
	}
	kitfile { page::open_app [obs] }
	notkit {
		# shared-mime-info's name for Tcl (not on every test machine)
		file mkdir [file join $::env(XDG_DATA_HOME) mime text]
		set fh [open [file join $::env(XDG_DATA_HOME) mime text x-tcl.xml] w]
		puts $fh {<?xml version="1.0"?><mime-type xmlns="http://www.freedesktop.org/standards/shared-mime-info" type="text/x-tcl"><comment>Tcl script</comment></mime-type>}
		close $fh
		page::open_app [mousepad]
		# the 600 px window, centred where the 720 one would be
		set ui::oy [expr {104 + (720 - $page::WH) / 2}]; set ui::by $ui::oy
	}
	sheet {
		# kit's prompt, as Update shows it (Kit-Sheet-2)
		page::open_app [firefox]
		page::plan_sheet [list [row Firefox org.mozilla.firefox update 134.0.1 134.0.2 12000000 security]] Update? 1
	}
	install {
		# Install from the .kit: the app from its file, a library new and one updated (Kit-Sheet-1)
		page::open_app [obs]
		page::plan_sheet [list [row {OBS Studio} com.obsproject.obs install "" 31.0.1 214000000] [row qt6-base org.qt.qt6-base install "" 6.8.1 38000000] \
			[row ffmpeg org.ffmpeg.ffmpeg update 7.1 7.1.1 4000000]] {Install 2 and update 1?} 1
	}
	uninstall {
		# Uninstall: the plan, toss's data question as a checkbox, off (Kit-Sheet-3)
		page::open_app [firefox]
		page::plan_sheet [list [row Firefox org.mozilla.firefox remove 134.0.1 removed 248000000] [row nss org.mozilla.nss remove 3.104 removed 9000000]] Uninstall? 1 \
			[dict create data [list [dict create name org.mozilla.firefox q "Also remove its data in ~/.local/share/kit/org.mozilla.firefox/home (412 MB)?" on 0]] done {apply {args {}}}]
	}
	rewind {
		# Rewind: back to 1.4.0, nothing to download (Kit-Sheet-4)
		page::open_app [dict merge [mkstudio] [dict create version 1.5.0 held 0 heldfrom "" heldwhen "" heldnew "" chunks 97]]
		proc kitlink::previous {name} { return 1 }
		page::plan_sheet [list [row {MK Studio} org.equi4.mk-studio update 1.5.0 1.4.0 0 held]] Rewind? 1
	}
	long - longcheck {
		# Install from the .kit with twelve libraries: more rows than the window holds (Kit-Sheet-5-Long)
		page::open_app [obs]
		set rows [list [row {OBS Studio} com.obsproject.obs install "" 31.0.1 214000000]]
		foreach {n v b} {qt6-base 6.8.1 38000000 qt6-svg 6.8.1 2000000 qt6-wayland 6.8.1 3000000} { lappend rows [row $n org.qt.$n install "" $v $b] }
		lappend rows [row ffmpeg org.ffmpeg.ffmpeg update 7.1 7.1.1 4000000 security]
		foreach {n v b} {x264 0.164 2000000 x265 4.1 3000000 libvpx 1.14.1 2000000 librist 0.2.11 1000000 srt 1.5.4 1000000
			mbedtls 3.6.2 1000000 luajit 2.1 1000000 jansson 2.14 1000000 speexdsp 1.2.1 1000000} { lappend rows [row $n org.x.$n install "" $v $b] }
		page::plan_sheet $rows {Install 12 and update 1?} 1
		if {$scene eq "longcheck"} {
			# the sheet stays inside the window; the wheel and the keys scroll the rows, the buttons stay put
			after 300 {
				set P [page::sheet_plan $page::dialog]
				puts "sheet [dict get $P h] fit [dict get $P fit] shown [dict get $P shown]"
				set w [lsearch -inline -index 4 $ui::wheels {page::sheet_scroll *}]
				ui::scroll [expr {[lindex $w 0] + 10 + $ui::ox}] [expr {[lindex $w 1] + 10 + $ui::oy}] 1
				puts "wheel $page::sheetoff"
				# the keys, as page::key gets them with the rows focused (Tab), Return on them doing nothing
				set ui::focus plist
				page::key Down {} 0
				page::key Return {} 0
				puts "down $page::sheetoff"
				page::key End {} 0
				puts "end $page::sheetoff"
				set yes [lsearch -inline -index 0 $ui::focusables pyes]
				puts "button [lindex $yes 3]"
				exit 0
			}
		}
	}
	storage { page::open_app [firefox_disk]; set ap::DRV {System 412000000000 953000000000}; page::go storage }
	libraries { page::open_app [firefox_disk]; page::go libraries }
	signature { page::open_app [firefox_disk]; page::go signature }
	held { page::open_app [mkstudio] }
	photo { photo }
	folder { folder }
}
page::draw

if {[info exists ::env(RIBBON_PROPERTIES_SHOT)]} {
	after 600 {
		update
		exec import -window root $::env(RIBBON_PROPERTIES_SHOT)
		exit 0
	}
} elseif {[info exists ::env(RIBBON_PROPERTIES_EXIT)]} {
	after $::env(RIBBON_PROPERTIES_EXIT) { update; exit 0 }
}
