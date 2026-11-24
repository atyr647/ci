# mail-scene.tcl - puts the Mail window into one of its boards' states (design/mockups Mail-A-Ledger, -A2-Thread,
# -A3-Reply, -A4-Search, -A5-Caught-up, -A7-Compose), on the fixture Maildirs (tests/fixtures/maildir) at the boards'
# time (Sat 7 Nov 2026, 10:42, +0100). Run by apps/mail/main.tcl through RIBBON_MAIL_SCENE=this file.
#   RIBBON_SCENE          ledger | thread | reply | search | caught | compose | earlier | replymode (Mail-A12-Reply-mode) |
#                         from (Mail-A13-From)
#   RIBBON_MAIL_FIXTURES  a scratch folder: the fixture Maildirs are copied there (the mail root) with the cache
#   RIBBON_MAIL_SHOT      file: a screenshot of the window, then exit
# The accounts provider is tests/mail-accounts-standin.tcl (RIBBON_MAIL_ACCOUNTS). Any Tcl error fails.
set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "ledger"}]
set dir $::env(RIBBON_MAIL_FIXTURES)
proc bgerror {msg} { puts stderr "mail-scene: $msg\n$::errorInfo"; exit 1 }
set here [file dirname [file normalize [info script]]]
file delete -force $dir
file mkdir $dir
file copy [file join $here fixtures maildir] [file join $dir Mail]
mail::store::set_root [file join $dir Mail]
mail::store::set_cache_root [file join $dir cache]
set mail::thread::tz +0100
set ::mailapp::now [clock scan "2026-11-07 10:42" -format "%Y-%m-%d %H:%M" -timezone +0100]
set ::mailapp::checked $::mailapp::now
set ::mailapp::open Personal
# the composer's caret does not blink in a picture
proc file_of {name size} {
	global dir
	set f [file join $dir $name]
	set fh [open $f wb]
	puts -nonewline $fh [string repeat x $size]
	close $fh
	return $f
}

switch -- $scene {
	ledger {
		mailapp::show_view inboxes
	}
	thread {
		mailapp::show_view inboxes
		foreach c $::mailapp::convs { if {[dict get $c subject] eq "Sunday lunch?"} { mailapp::select [dict get $c key] } }
	}
	reply {
		mailapp::show_view inboxes
		mailapp::reply_open all
		$::mailapp::rtext insert 1.0 "Lovely. Here is the run sheet with the demo moved to 19:10, after the talks, so the room is settled.\nI will bring the HDMI cable myself."
		mailapp::attach_files reply [list [file_of run-sheet-v2.pdf 184000]]
		mailapp::reply_save
		set ::mailapp::pscroll [mailapp::pane_max]
		mailapp::paint
	}
	search {
		mailapp::show_view inboxes
		mailapp::search_focus
		mailapp::search_set "from:Anna floor plan"
	}
	caught {
		foreach a [mail::store::accounts] {
			set inbox [mail::store::folder_of $a inbox]
			foreach k [mail::store::keys $a $inbox] { mail::store::move $k $a Archive }
		}
		mailapp::show_view inboxes
	}
	compose {
		mailapp::show_view inboxes
		mailapp::compose_new [dict create account Studio from {{} maya@hearth.studio} \
			to {{{Anna Berg} anna@hearth.studio} {{Jonas Ek} jonas@hearth.studio} {{Lea Moreau} lea@moreau.fr}} \
			cc {{ribbon-dev ribbon-dev@lists.ribbon.org}} subject "Release notes for the 0.9 launch" \
			text "Hi all,\nHere are the release notes for Thursday, one page as promised. I will print forty copies at the studio on Wednesday afternoon.\nJonas, the kit numbers are from your mail of Tuesday. Could you check them before I print?" \
			atts {} inreplyto "" references {} key "" answers "" mode new]
		mailapp::attach_files compose [list [file_of release-notes-0.9.pdf 212000] [file_of run-sheet-v2.pdf 184000]]
		mailapp::compose_save
		mailapp::compose_paint
	}
	replymode - from {
		if {$scene eq "replymode"} {
			mailapp::show_view inboxes
			mailapp::reply_open all
			$::mailapp::rtext insert 1.0 "Lovely. Here is the run sheet with the demo moved to 19:10, after the talks, so the room is settled.\nI will bring the HDMI cable myself."
			mailapp::attach_files reply [list [file_of run-sheet-v2.pdf 184000]]
			mailapp::reply_save
			set ::mailapp::pscroll [mailapp::pane_max]
			mailapp::paint
			set hits $::ui::hits
		} else {
			mailapp::show_view inboxes
			mailapp::compose_new [dict create account Studio from {{} maya@hearth.studio} \
				to {{{Anna Berg} anna@hearth.studio} {{Jonas Ek} jonas@hearth.studio} {{Lea Moreau} lea@moreau.fr}} \
				cc {{ribbon-dev ribbon-dev@lists.ribbon.org}} subject "Release notes for the 0.9 launch" \
				text "Hi all,\nHere are the release notes for Thursday, one page as promised. I will print forty copies at the studio on Wednesday afternoon.\nJonas, the kit numbers are from your mail of Tuesday. Could you check them before I print?" \
				atts {} inreplyto "" references {} key "" answers "" mode new]
			mailapp::attach_files compose [list [file_of release-notes-0.9.pdf 212000] [file_of run-sheet-v2.pdf 184000]]
			mailapp::compose_save
			mailapp::compose_paint
			set hits $::mailapp::cui(ui:hits)
		}
		# the chip pressed, as a click would
		foreach h $hits { if {[string match "::mailapp::[expr {$scene eq "from" ? "from_menu" : "reply_mode_menu"}] *" [lindex $h 4]]} { uplevel #0 [lindex $h 4] } }
	}
	earlier {
		mailapp::show_view inboxes
		set ::mailapp::lscroll 600
		mailapp::paint
	}
}
update
# there is no window manager here to keep the new message over Mail
if {[winfo exists .compose]} { raise .compose; update }
if {[info exists ::env(RIBBON_MAIL_SHOT)]} {
	after 300 [list mailapp::shot_and_exit $::env(RIBBON_MAIL_SHOT)]
}
