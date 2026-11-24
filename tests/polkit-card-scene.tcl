# polkit-card-scene.tcl - ribbon-polkit's card in one of the boards' states, for screenshots and pixel comparison
# (RIBBON_POLKIT_SCENE=this file, run by tests/steps.d/70-polkit-card.sh under xvfb).
#   RIBBON_SCENE = card     Polkit-A-Card: you are the admin, no picker, eight dots and the caret
#                  choose   Polkit-A2-Choose: two accounts, the first chosen
#                  error    the card after a wrong password (the message line) with the field empty
#                  details  the card with Details open
#   RIBBON_POLKIT_SHOT   = file: a grab of the screen (ImageMagick import), then the app exits
#   RIBBON_POLKIT_RESULT = file: "LEFT TOP WIDTH HEIGHT" of the card on the screen
# The sub line is the board's "kit · 5 updates" given as the program: polkit has nothing that says "5 updates".
set scene [expr {[info exists ::env(RIBBON_SCENE)] ? $::env(RIBBON_SCENE) : "card"}]
set ids {{uid 1000 name ada display {Ada Lovelace} kind user} {uid 1001 name grace display {Grace Hopper} kind user}}
set choose [expr {$scene eq "choose"}]
set info [dict create action org.ribbon.kit.system-update message {Authentication is required to install system updates} icon "" \
	details [dict create program {kit · 5 updates} polkit.caller-pid 1 user ada] \
	identities [expr {$choose ? $ids : [list [lindex $ids 0]]}] identity ada choose $choose]
card::show r1 $info
card::prompt r1 {Password: } 0
switch -- $scene {
	card - choose { card::key r1 count 8 }
	error { card::problem r1 "Sorry, that didn't work. Please try again." }
	details { card::key r1 count 8; set card::open 1; card::relayout }
}
if {[info exists ::env(RIBBON_POLKIT_SHOT)]} {
	update; after 500; update
	set f [::open $::env(RIBBON_POLKIT_RESULT) w]; puts $f "$card::left $card::top $card::W $ui::H"; close $f
	exec import -window root $::env(RIBBON_POLKIT_SHOT)
	exit 0
}
