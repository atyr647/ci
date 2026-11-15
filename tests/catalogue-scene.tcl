# catalogue-scene.tcl - put the Catalogue into one of its boards' states (design/mockups/Catalogue-*)
# on a 1440 x 900 desktop, with the boards' apps standing in for kit's index and Flathub
# (RIBBON_CATALOGUE_SCENE=this file, run by apps/catalogue/main.tcl).
#   RIBBON_SCENE = browse | search | kit | sheet | installing | installed | flathub | flatpakref
#   RIBBON_CATALOGUE_SHOT = file: take a screenshot (ImageMagick import)
#   RIBBON_CATALOGUE_EXIT = ms: quit after drawing; any Tcl error fails
set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "browse"}]
proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
set ui::caretfix on

proc kit {short title summary version size {installed ""}} {
	dict create source kit id org.example.$short name org.example.$short short $short title $title summary $summary \
		version $version size $size download $size installed $installed tags {}
}
proc flat {id title summary version download {installed ""}} {
	dict create source flathub id $id name $id title $title summary $summary version $version download $download installed $installed
}
set cat::kits [list [kit blender Blender {3D modelling, animation and rendering} 4.3.2 312000000] \
	[kit firefox Firefox {The Firefox web browser} 134.0.1 248000000 134.0.1] [kit gimp GIMP {Edit photos and pictures} 3.0.2 96000000] \
	[kit inkscape Inkscape {Draw vector graphics} 1.4 88000000] [kit mk-studio {MK Studio} {Database editor} 1.5.0 18000000 1.5.0] \
	[kit obs {OBS Studio} {Screen recording and streaming} 31.0.1 214000000]]
set cat::kitstate ready
set flat [list [flat com.usebottles.bottles Bottles {Run Windows software} 51.17 62000000] \
	[flat com.discordapp.Discord Discord {Messaging, voice and video} 0.0.76 98000000] \
	[flat com.heroicgameslauncher.hgl {Heroic Games Launcher} {Games from Epic, GOG and Amazon} 2.15.2 141000000] \
	[flat com.spotify.Client Spotify {Music and podcasts} 1.2.52 0]]
set more [list [flat org.kde.kdenlive Kdenlive {Edit videos} 24.12.2 152000000] [flat org.shotcut.Shotcut Shotcut {Edit videos} 25.01.25 118000000] \
	[flat org.videolan.VLC VLC {Play videos and music} 3.0.21 0]]
# 2,614 on Flathub, as the board counts them: the board's, then more that match nothing searched
set cat::flat [concat $flat $more]
for {set i [llength $cat::flat]} {$i < 2614} {incr i} { lappend cat::flat [flat org.example.app$i "zz App $i" {} 1 1000000] }
set cat::flatinst [dict create com.spotify.Client {name Spotify version 1.2.52 summary {} origin flathub installation user} \
	org.videolan.VLC {name VLC version 3.0.21 summary {} origin flathub installation user}]
set cat::flatstate ready
proc cat::load_kits {} {}
proc cat::run {argv done} { return "" }

proc obs {} {
	set r [lindex $cat::kits 5]
	dict merge $r [dict create state ready perms {{network yes} {display wayland} {audio mic} {gpu 1} {camera 1}} \
		needs {{org.qt.qt6-base {>=6.8}} {org.ffmpeg.ffmpeg {>=7}} {org.videolan.x264 {}} {org.pipewire.pipewire {}} {org.freedesktop.mesa {}} {org.webmproject.libvpx {}}} \
		uses {org.qt.qt6-base 6.8.1 org.ffmpeg.ffmpeg 7.1.1 org.videolan.x264 0.164 org.pipewire.pipewire 1.2.7 org.freedesktop.mesa 25.2.7 org.webmproject.libvpx 1.14.1} \
		signer {name {Ribbon release key} key RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3} keyid 53E9B1D2E3F00C64 sigstate valid \
		checked [expr {[clock seconds] - 3600}] when "" requests {} facts {}]
}
proc discord {} {
	dict merge [lindex $cat::flat 1] [dict create state ready requests [cat::flat_requests {[Application]
name=com.discordapp.Discord
[Context]
shared=network;ipc;
sockets=x11;pulseaudio;
devices=dri;
filesystems=xdg-download;
[Session Bus Policy]
org.freedesktop.Notifications=talk
}] facts [cat::parse_remote_info {Discord - Messaging, voice and video

          ID: com.discordapp.Discord
         Ref: app/com.discordapp.Discord/x86_64/stable
        Arch: x86_64
      Branch: stable
     Version: 0.0.76
     License: LicenseRef-proprietary
      Origin: flathub
    Download: 98.2 MB
   Installed: 263.4 MB
     Runtime: org.freedesktop.Platform/x86_64/24.08
}]]
}

switch -- $scene {
	browse { }
	search { ui::fset q edit; set ui::focus q }
	kit { set cat::detail [obs]; set page::view app }
	installed {
		set cat::detail [dict merge [obs] [dict create installed 31.0.1 when [expr {[clock seconds] - 30}]]]
		set page::view app
	}
	sheet - installing {
		set cat::detail [obs]; set page::view app
		set rows [list [dict create name obs fullname org.example.obs old "" new 31.0.1 action install bytes 172000000 tags {}] \
			[dict create name qt6-base fullname org.qt.qt6-base old "" new 6.8.1 action install bytes 38000000 tags {}] \
			[dict create name ffmpeg fullname org.ffmpeg.ffmpeg old 7.1 new 7.1.1 action update bytes 4000000 tags {}]]
		if {$scene eq "sheet"} {
			page::plan_sheet $rows {Install 2 and update 1?} 1
		} else {
			set cat::job [dict create source kit id org.example.obs fh "" phase download done 86000000 total 214000000 pct 40.0 said "" code ""]
		}
	}
	flathub { set cat::detail [discord]; set page::view app; set page::nav flathub }
	flatpakref {
		set cat::detail [dict merge [discord] [dict create source ref file $::env(HOME)/Downloads/com.discordapp.Discord.flatpakref remote flathub url https://dl.flathub.org/repo/ branch stable]]
		set page::view app; set page::nav flathub
	}
}
page::draw

if {[info exists ::env(RIBBON_CATALOGUE_SHOT)]} {
	after 800 {
		update
		exec import -window root $::env(RIBBON_CATALOGUE_SHOT)
		exit 0
	}
} elseif {[info exists ::env(RIBBON_CATALOGUE_EXIT)]} {
	after $::env(RIBBON_CATALOGUE_EXIT) { update; exit 0 }
}
