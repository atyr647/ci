# settings-printers-scene.tcl - Settings → Printers (page-printers.tcl) in its board's state (Settings-A12-Printers)
# with the REAL printers.tcl over a stand-in CUPS (tests/fixtures/cups/fake-cups as lpstat, lpq, lpoptions, lp, cancel,
# lpadmin and ippfind) and the REAL ribbon-printers-helper behind a pkexec stand-in. The page is grabbed for the board,
# then used as a person would: the list, the default, the paper, two-sided, a job cancelled, the test page, a nearby
# printer added and one removed, a refused prompt, and CUPS not running. Each change is read back from the stand-in's
# state and its log. Sourced by apps/settings/main.tcl through RIBBON_SETTINGS_SCENE.
#   FAKE_CUPS          = the stand-in's directory (state, log)
#   RIBBON_PRN_SHOT    = file: a grab of the window (ImageMagick import)
#   RIBBON_PRN_RESULT  = file: the checks, one per line ("ok ..." or "FAIL ...")
proc bgerror {msg} { puts stderr "bgerror: $msg\n$::errorInfo"; exit 3 }
set ui::caretfix off
namespace eval pscene { variable fails 0; variable lines {} }
proc pscene::check {what cond} { variable fails; variable lines; if {[uplevel #0 [list expr $cond]]} { lappend lines "ok   $what" } else { lappend lines "FAIL $what"; incr fails } }
proc pscene::click {x y} { page::draw_now; ui::press [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; ui::release [expr {$x + $::ui::ox}] [expr {$y + $::ui::oy}]; update; page::draw_now; update }
proc pscene::state {} { set h [open $::env(FAKE_CUPS)/state]; fconfigure $h -encoding utf-8; set t [read $h]; close $h; set t }
proc pscene::log {} { set h [open $::env(FAKE_CUPS)/log]; fconfigure $h -encoding utf-8; set t [read $h]; close $h; set t }
proc pscene::put {s} { set h [open $::env(FAKE_CUPS)/state w]; fconfigure $h -encoding utf-8; puts -nonewline $h $s; close $h }
proc pscene::wait {cond {ms 8000}} {
	set end [expr {[clock milliseconds] + $ms}]
	while {![uplevel #0 [list expr $cond]]} {
		if {[clock milliseconds] > $end} { return 0 }
		after 20 {set ::pscene::tick 1}; vwait ::pscene::tick
	}
	page::draw_now; update
	return 1
}
proc pscene::names {} { lmap p [dict get [prn::model] printers] { dict get $p label } }

# the rail item: registry.tcl's, after Bluetooth in the second group
pscene::check "the rail lists Printers after Bluetooth (the second group: Network, Bluetooth, Printers)" \
	{[lrange [settings::ids] 4 6] eq {network bluetooth printers} && [settings::get printers icon] eq "printer"}
pscene::check "the page registers itself on the rail item" {[settings::get printers draw] eq "settings::draw_printers" && "Two-sided" in [settings::get printers rows]}
settings::select printers
page::draw_now; update
pscene::wait {!$prn::scanning}
pscene::check "the board's state: three printers, the default first and the offline one last" \
	{[pscene::names] eq {{Brother HL-L2350DW} {HP OfficeJet 8010} {Canon MF4410}}}
pscene::check "  their states: Ready, Ready, Offline (offline-report)" \
	{[lmap p [dict get [prn::model] printers] { dict get $p state }] eq {ready ready offline}}
pscene::check "  the network's two driverless printers under NEARBY (ippfind)" \
	{[lmap n [dict get [prn::model] nearby] { dict get $n label }] eq {{Epson ET-2850} {HP LaserJet M110w}}}
pscene::check "  the network's printers CUPS can reach but that are not added (lpstat -e lists them) are not on the list" \
	{[lmap p [dict get [prn::model] printers] { dict get $p name }] eq {Brother_HL_L2350DW HP_OfficeJet_8010 Canon_MF4410}}
if {[info exists ::env(RIBBON_PRN_SHOT)]} { after 500; update; exec import -window [winfo id $::settings::win] $::env(RIBBON_PRN_SHOT) }

# the queue: the x on the waiting job cancels it
pscene::click 1046 579
pscene::check "the x on Boarding pass.pdf cancels it (cancel 13)" {[string match "*cancel 13*" [pscene::log]] && [llength [dict get [pscene::state] jobs]] == 1}
# two-sided, paper
pscene::click 830 447
pscene::check "Two-sided Off: lpoptions -p Brother_HL_L2350DW -o Duplex=None" {[dict get [pscene::state] opts Brother_HL_L2350DW Duplex] eq "None"}
pscene::click 990 399
pscene::check "a click on Paper opens its list without the custom size" {$sctl::pop eq "prn-paper" && [lmap i [dict get $sctl::popd items] { lindex $i 0 }] eq {A4 A5 Letter Legal}}
settings::key Down "" 0; settings::key Down "" 0; settings::key Return "" 0; update; page::draw_now; update
pscene::check "  Down, Down, Return: Letter (lpoptions -o PageSize=Letter)" {[dict get [pscene::state] opts Brother_HL_L2350DW PageSize] eq "Letter"}
# another printer: chosen, then made the default
pscene::click 400 197
pscene::check "a click on HP OfficeJet 8010 shows it" {[dict get [prp::chosen [prn::model]] label] eq "HP OfficeJet 8010"}
pscene::click 1041 351
pscene::check "  Default printer on: lpoptions -d HP_OfficeJet_8010 (this account's), the list's check moves" \
	{[dict get [pscene::state] default] eq "HP_OfficeJet_8010" && [lindex [pscene::names] 0] eq "HP OfficeJet 8010"}
# the test page
pscene::click 1000 684
pscene::check "Print a test page: lp -d HP_OfficeJet_8010 on CUPS's page" {[string match "*lp -d HP_OfficeJet_8010 -t {Test page} *testprint*" [pscene::log]]}
# a nearby printer: added through the helper (pkexec)
pscene::click 400 337
pscene::check "a click on Epson ET-2850 says Adding… while the helper runs" {$prp::adding eq "ipp://EPSON-ET-2850.local:631/ipp/print" || [string match "*lpadmin -p Epson_ET-2850*" [pscene::log]]}
pscene::wait {!$prn::busy}
pscene::check "  the helper ran lpadmin -p Epson_ET-2850 -E -v URI -m everywhere, as root's pkexec would" \
	{[string match "*lpadmin -p Epson_ET-2850 -E -v ipp://EPSON-ET-2850.local:631/ipp/print -m everywhere*" [pscene::log]]}
pscene::check "  it is in the list, and no longer nearby" {"Epson ET-2850" in [pscene::names] && "Epson ET-2850" ni [lmap n [dict get [prn::model] nearby] { dict get $n label }]}
# Remove, refused at the prompt: nothing changes, the subtitle says so
set prp::sel Epson_ET-2850
set ::env(FAKE_PKEXEC_REFUSE) 1
pscene::click 850 684
pscene::wait {!$prn::busy}
pscene::check "Remove refused by polkit (127): the printer stays, the subtitle says why" \
	{"Epson ET-2850" in [pscene::names] && [dict get [prn::model] subtitle] eq "Not allowed to change the printers"}
unset ::env(FAKE_PKEXEC_REFUSE)
pscene::click 850 684
pscene::wait {!$prn::busy}
pscene::check "  allowed: lpadmin -x Epson_ET-2850, gone from the list" {[string match "*lpadmin -x Epson_ET-2850*" [pscene::log]] && "Epson ET-2850" ni [pscene::names]}
pscene::check "the helper refuses a name that is not a queue's (prn::remove checks first, nothing runs)" {![prn::remove "x; rm -rf /"]}
# CUPS running with no queue added (lpstat -p fails with "No destinations added."): set up, no printers
set s0 [pscene::state]; set s $s0; dict set s printers {}; pscene::put $s
prn::refresh; page::draw_now; update
pscene::check "CUPS running, no printer added: the page is there and says No printers" \
	{[dict get [prn::model] available] && [dict get [prn::model] printers] eq {} && [dict get [prn::model] subtitle] eq "No printers"}
pscene::put $s0
# CUPS not running
set s [pscene::state]; dict set s down 1; pscene::put $s
prn::refresh; page::draw_now; update
pscene::check "CUPS not running: no list, the subtitle says so" {![dict get [prn::model] available] && [dict get [prn::model] subtitle] eq "Printing is not set up on this computer"}

if {[info exists ::env(RIBBON_PRN_RESULT)]} { set f [open $::env(RIBBON_PRN_RESULT) w]; puts $f [join $pscene::lines \n]; close $f } else { puts [join $pscene::lines \n] }
exit [expr {$pscene::fails > 0}]
