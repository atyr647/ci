# appearance-flow.tcl - drive the Appearance app with clicks and keys and
# check what it writes: saving a built-in's edits as a new theme, saving,
# renaming, duplicating and deleting your own, export and import (and
# files that must not import), Apply through ribbon-theme with pkexec
# stubbed, Revert, the backgrounds' settings. RIBBON_APPEARANCE_SCENE=this
# file; tests/test-appearance.sh sets up the home, the stubs and the fake
# /etc. Exits 1 if a check fails.
proc bgerror {msg} { puts stderr "$msg\n$::errorInfo"; exit 1 }
set ::fails 0
proc check {what cond} {
	if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr ::fails }
}
proc key {sym {char ""} {state 0}} { update; page::key $sym $char $state; update }
proc type {text} { foreach ch [split $text ""] { update; page::key [expr {$ch eq " " ? "space" : $ch}] $ch 0 }; update }
proc click {x y} { update; ui::press [expr {$x + $ui::ox}] [expr {$y + $ui::oy}]; ui::release [expr {$x + $ui::ox}] [expr {$y + $ui::oy}]; update }
proc slurp {f} { set fh [open $f]; set d [read $fh]; close $fh; return $d }
proc kv {f k} { if {[regexp -line "^${k}=(.*)\$" [slurp $f] -> v]} { return [string trim $v \"] }; return "" }
# wait for Apply's jobs
proc settle {} {
	set n 0
	while {$page::S(busy) && $n < 600} { after 50; update; incr n }
	update
}
set cfg $::env(XDG_CONFIG_HOME)
set mine [file join $cfg ribbon palettes]
set sys [store::sysdir]
set tmp $::env(APPEARANCE_TMP)

check "built in: Graphite, Fjord, Moss; yours: Dusk" {[store::ids 1] eq {ribbon ribbon-fjord ribbon-moss} && [store::ids 0] eq {dusk}}
check "it starts on the theme in use" {$page::S(sel) eq "ribbon" && $page::S(applied) eq "ribbon"}

# ---- a built-in's edits are saved as a new theme
set before [slurp $sys/ribbon.conf]
page::pick ribbon
key 2 2 8
check "Alt+2: the Colours page" {$page::S(page) eq "colours"}
check "the banner names the new theme" {[ui::fval newname] eq "Graphite (mine)"}
page::role ACCENT
set ui::focus hex
ui::fset hex ""
type #112233
check "typing a hex colour sets the role" {[dict get $page::S(epal) ACCENT] eq "#112233" && $page::S(dirty)}
set ui::focus roles
key Down; key Down; key Down; key Down; key Down; key Down
check "Up/Down move between roles" {$page::S(role) eq "BAR"}
page::slider_set chR 1.0
check "the R slider sets the red channel" {[string range [dict get $page::S(epal) BAR] 1 2] eq "FF"}
check "BG follows BAR" {[dict get $page::S(epal) BG] eq [dict get $page::S(epal) BAR]}
page::mode hsl
page::slider_set chL 0.5
lassign [pal::rgb2hsl {*}[pal::rgb [dict get $page::S(epal) BAR]]] - - l
check "the HSL tab's L slider sets the lightness" {abs($l - 0.5) < 0.01}
page::role DESK_STRIPE
page::slider_set alpha 0.1
check "the stripes have an alpha" {[dict get $page::S(epal) DESK_STRIPE_ALPHA] eq "0.1"}
set ui::focus newname
ui::fset newname ""
type "Coral night"
click 900 680
set id [lindex [store::ids 0] 0]
check "Save as new theme: a theme of yours" {[store::exists coral-night] && [store::get coral-night name] eq "Coral night"}
check "  with the edits" {[kv $mine/coral-night.conf ACCENT] eq "#112233" && [kv $mine/coral-night.conf DESK_STRIPE_ALPHA] eq "0.1"}
check "  the built-in is untouched" {[slurp $sys/ribbon.conf] eq $before && ![file exists $mine/ribbon.conf]}
check "  and is now the one being edited, with no banner" {$page::S(sel) eq "coral-night" && ![store::get coral-night builtin]}

# ---- the Colours page's remaining edits (HANDOFF "Colours page", item 8): a code token, an alpha, the
# bar shadow's three sliders, and a linked key unlinked then relinked; each saved and read back from the .conf
set f $mine/coral-night.conf
set focus0 $ui::focus
page::role SYN_STR
set ui::focus hex
ui::fset hex ""
type #0A0B0C
check "a code token takes a typed hex (SYN_STR)" {[dict get $page::S(epal) SYN_STR] eq "#0A0B0C"}
page::role DESK_STRIPE
page::slider_set alpha 0.25
check "the stripes' alpha takes the slider (DESK_STRIPE_ALPHA)" {[dict get $page::S(epal) DESK_STRIPE_ALPHA] eq "0.25"}
page::role BAR_SHADOW
page::slider_set shDY 0.75
page::slider_set shBLUR 0.5
page::slider_set shA 0.4
lassign [pal::shadow [dict get $page::S(epal) BAR_SHADOW]] dy blur a c
check "the bar shadow: offset 16, blur 24, opacity 0.4" {$dy == 16 && $blur == 24 && $a eq "0.4"}
page::role CLOCK
set ui::focus hex
ui::fset hex ""
type #334455
check "editing a linked key unlinks it (CLOCK)" {![page::linked CLOCK] && [dict get $page::S(epal) CLOCK] eq "#334455"}
key s s 4
check "saved: SYN_STR, DESK_STRIPE_ALPHA, BAR_SHADOW and CLOCK (unlinked) are in the .conf" {[kv $f SYN_STR] eq "#0A0B0C" && [kv $f DESK_STRIPE_ALPHA] eq "0.25" && [kv $f BAR_SHADOW] eq [pal::shadow_make 16 24 0.4 $c] && [kv $f CLOCK] eq "#334455"}
page::relink
check "the reset button relinks CLOCK to FG" {[page::linked CLOCK] && [dict get $page::S(epal) CLOCK] eq [dict get $page::S(epal) FG]}
key s s 4
check "  and the .conf has CLOCK = FG again, with the built-in untouched" {[kv $f CLOCK] eq [kv $f FG] && [kv $f CLOCK] ne "#334455" && [slurp $sys/ribbon.conf] eq $before}
set ui::focus $focus0

# ---- your own theme: save in place, rename, duplicate, delete
page::role FG
page::set_colour #ABCDEF
key s s 4
check "Ctrl+S saves your theme in place" {[kv $mine/coral-night.conf FG] eq "#ABCDEF" && !$page::S(dirty) && [llength [store::ids 0]] == 2}
check "  CLOCK followed FG" {[kv $mine/coral-night.conf CLOCK] eq "#ABCDEF"}
key Escape
check "Esc goes back to Theme" {$page::S(page) eq "theme"}
page::rename_start coral-night
ui::fset rename ""
type "Coral"
key Return
check "rename on the row" {[store::get coral-night name] eq "Coral" && [kv $mine/coral-night.conf NAME] eq "Coral"}
page::duplicate
check "Duplicate" {[store::exists coral-copy] && $page::S(sel) eq "coral-copy"}
page::delete coral-copy
check "Delete asks first" {$page::dialog ne "" && [dict get $page::dialog kind] eq "confirm"}
key Return
check "  Cancel is the default" {$page::dialog eq "" && [store::exists coral-copy]}
page::delete coral-copy
dlg::ok
check "  and Delete deletes" {![store::exists coral-copy] && ![file exists $mine/coral-copy.conf]}
page::pick ribbon
page::delete ribbon
check "a built-in can't be deleted" {$page::dialog eq "" && [store::exists ribbon]}
check "nor renamed" {[catch {store::rename ribbon x}] && [catch {store::save ribbon [store::get ribbon pal]}]}
page::pick ribbon
page::new_from_current
check "New theme from current: a copy of the desktop's colours" {[store::exists graphite-mine] && $page::S(page) eq "colours" && [kv $mine/graphite-mine.conf ACCENT] eq "#FF7A59"}
key Escape
check "no theme of yours can take a built-in's id" {[store::new_id ribbon-fjord] ne "ribbon-fjord" && ![string match ribbon* [store::new_id ribbon]]}

# ---- export and import
page::pick dusk
check "Export writes NAME.ribbon-theme" {[page::export_to $tmp/Dusk] && [file exists $tmp/Dusk.ribbon-theme]}
set id [page::import_from $tmp/Dusk.ribbon-theme]
check "  it imports again, as a new theme" {$id ne "" && $id ne "dusk" && [store::get $id name] eq "Dusk 2"}
set same 1
dict for {k v} [store::get dusk pal] { if {$k ne "NAME" && [dict get [store::get $id pal] $k] ne $v} { set same 0 } }
check "  with the same colours" {$same}
set n [llength [store::ids]]
set bad {
	{unknown key} "NAME=X\nACCENT=#112233\nBAR=#000000\nFIELD=#000000\nPILL=#000000\nBORDER=#000000\nFG=#FFFFFF\nMUTED=#888888\nDESK_TOP=#000000\nDESK_BOTTOM=#000000\nEVIL=1\n"
	{a command for a colour} "ACCENT=\$(touch $tmp/pwned)\n"
	{backquotes in the name} "NAME=`touch $tmp/pwned`\nACCENT=#112233\n"
	{a quote in the name} "NAME=\"a\"b\"\nACCENT=#112233\n"
	{trailing shell} "ACCENT=#112233; touch $tmp/pwned\n"
	{a bad colour} "ACCENT=#12345G\n"
	{an alpha out of range} "DESK_STRIPE_ALPHA=7\n"
	{a key twice} "ACCENT=#112233\nACCENT=#112233\n"
	{not KEY=VALUE} "source /etc/passwd\n"
	{a NUL} "ACCENT=#112233\n\0"
	{not a theme (missing keys)} "ACCENT=#112233\n"
	{lower-case keys} "accent=#112233\n"
}
foreach {what text} $bad {
	set f $tmp/bad.ribbon-theme
	set fh [open $f wb]; puts -nonewline $fh [encoding convertto utf-8 $text]; close $fh
	set r [page::import_from $f]
	check "import refuses $what" {$r eq "" && $page::dialog ne "" && [llength [store::ids]] == $n}
	dlg::close
}
set fh [open $tmp/big.conf wb]; puts -nonewline $fh [string repeat "# x\n" 6000]; close $fh
check "import refuses a file over 16 KB" {[page::import_from $tmp/big.conf] eq ""}
dlg::close
check "import refuses a directory" {[page::import_from $tmp] eq ""}
dlg::close
check "nothing in a refused file ran" {![file exists $tmp/pwned]}

# ---- contrast
check "WCAG contrast: white on black is 21:1" {abs([pal::contrast #FFFFFF #000000] - 21) < 0.001}
check "  Graphite's text on accent is AAA" {[pal::level [pal::contrast #1A0F0B #FF7A59]] eq "AAA"}
check "  a ratio is never rounded up past a level" {[pal::ratio_text 4.49] eq "4.4:1"}

# ---- Apply, through ribbon-theme (pkexec stubbed)
set log $::env(PKEXEC_LOG)
page::pick dusk
set page::S(todesk) 1; set page::S(tologin) 1
page::apply
settle
check "Apply: the desktop has Dusk" {[kv $cfg/ribbon/theme.conf PALETTE] eq "dusk" && [kv $cfg/ribbon/palette.conf ACCENT] eq "#F2A65A"}
check "  the login screen too, through pkexec and the helper" {[regexp {ribbon-login-theme set-palette /\S+/dusk\.conf} [slurp $log]] && [kv $::env(RIBBON_LOGIN_ROOT)/etc/ribbon/palette.conf ACCENT] eq "#F2A65A"}
check "  and it keeps following" {[kv $cfg/ribbon/theme.conf LOGIN_FOLLOWS_THEME] eq "yes"}
check "  the app is drawn in the new colours" {$ui::c(accent) eq "#F2A65A"}
set calls [llength [split [string trim [slurp $log]] \n]]
page::pick ribbon-moss
click 400 684
check "the Login screen switch" {!$page::S(tologin)}
page::apply
settle
check "Apply to the desktop only: no pkexec" {[kv $cfg/ribbon/theme.conf PALETTE] eq "ribbon-moss" && [llength [split [string trim [slurp $log]] \n]] == $calls}
check "  and the login screen no longer follows" {[kv $cfg/ribbon/theme.conf LOGIN_FOLLOWS_THEME] eq "no"}
page::revert
settle
check "Revert: the theme at the start, applied again" {$page::S(sel) eq "ribbon" && [kv $cfg/ribbon/theme.conf PALETTE] eq "ribbon" && $page::S(tologin)}

# ---- the backgrounds (their pages are being redesigned; the settings)
set pic $::env(APPEARANCE_PICTURE)
dict set bg::desk mode picture
dict set bg::desk image $pic
dict set bg::desk fit fit
dict set bg::login same 0
dict set bg::login source colour
dict set bg::login colour #224466
dict set bg::login blur 12
dict set bg::login dim 25
dict set bg::login clock no
set page::S(tologin) 1
page::apply
settle
set wc $cfg/ribbon/wallpaper.conf
check "a picture, fitted: wallpaper.conf" {[kv $wc MODE] eq "picture" && [kv $wc IMAGE] eq [file normalize $pic] && [kv $wc FIT] eq "fit"}
set lo $::env(RIBBON_LOGIN_ROOT)/etc/ribbon/login/options.conf
check "the login screen's look: options.conf" {[file exists $lo] && [kv $lo BLUR] eq "12" && [kv $lo DIM] eq "25" && [kv $lo CLOCK] eq "no" && [kv $lo COLOUR] eq "#224466"}
dict set bg::desk mode slideshow
dict set bg::desk dir [file dirname $pic]
dict set bg::desk interval 3600
dict set bg::desk shuffle no
page::apply
settle
check "a slideshow: its keys, and its first picture shown" {[kv $wc MODE] eq "slideshow" && [kv $wc INTERVAL] eq "3600" && [kv $wc SHUFFLE] eq "no" && [kv $wc IMAGE] ne "" && [kv $wc FIT] eq "fit"}
dict set bg::desk mode video
dict set bg::desk video $::env(APPEARANCE_VIDEO)
dict set bg::desk pause_covered yes
dict set bg::desk bars solid
page::apply
settle
check "a video: PAUSE_FULLSCREEN, PAUSE_COVERED, BARS" {[kv $wc MODE] eq "video" && [kv $wc PAUSE_FULLSCREEN] eq "yes" && [kv $wc PAUSE_COVERED] eq "yes" && [kv $wc PAUSE_GAME] eq "no" && [kv $wc BARS] eq "solid"}
dict set bg::desk mode slideshow
dict set bg::desk interval 10
page::apply
settle
check "a slideshow's interval is at least a minute" {[kv $wc MODE] eq "slideshow" && [kv $wc INTERVAL] eq "60"}
dict set bg::desk mode colour
dict set bg::desk colour #102030
page::apply
settle
check "a plain colour (the slideshow's keys kept)" {[kv $wc MODE] eq "colour" && [kv $wc COLOUR] eq "#102030" && [kv $wc INTERVAL] eq "60"}
dict set bg::desk mode pattern
page::apply
settle
check "back to the pattern" {[kv $wc MODE] eq "pattern" && [kv $wc IMAGE] eq ""}

# ---- keys
page::go theme
set ui::focus ""
key Tab
check "Tab reaches the rail" {$ui::focus eq "rail"}
key Down
check "  Down there: the next page" {$page::S(page) eq "colours"}
puts "  [expr {$::fails ? "FAIL" : "ok  "}] appearance flow: $::fails failed"
exit [expr {$::fails ? 1 : 0}]
