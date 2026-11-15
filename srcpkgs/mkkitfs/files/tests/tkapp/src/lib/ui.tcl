# ui.tcl -- the window of the start-up test's app
package require Tk
namespace eval ui {}
proc ui::build {top icon} {
    wm title $top "Hello from a kit"
    if {$top eq "."} { set top "" }
    image create photo ui::icon -file $icon
    ttk::frame $top.f -padding 12
    ttk::label $top.f.i -image ui::icon
    ttk::label $top.f.t -text "Hello from a kit" -font {TkHeadingFont 14}
    ttk::entry $top.f.e
    $top.f.e insert 0 "some text"
    ttk::combobox $top.f.c -values {one two three}
    ttk::checkbutton $top.f.k -text "A choice"
    ttk::progressbar $top.f.p -value 40
    ttk::treeview $top.f.tv -columns {a b} -height 4
    foreach i {1 2 3} { $top.f.tv insert {} end -text "row $i" -values [list $i [expr {$i * $i}]] }
    canvas $top.f.cv -width 200 -height 60 -highlightthickness 0
    $top.f.cv create oval 10 10 50 50 -fill steelblue
    $top.f.cv create text 120 30 -text "canvas"
    ttk::button $top.f.b -text "Close" -command exit
    grid $top.f.i $top.f.t -sticky w
    foreach w {e c k p tv cv b} { grid $top.f.$w - -sticky ew -pady 2 }
    pack $top.f -fill both -expand 1
}
