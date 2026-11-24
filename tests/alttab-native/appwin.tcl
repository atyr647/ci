# appwin.tcl CLASS TITLE COLOUR KEYLOG - a managed X11 window that stands in for an app: a solid colour with
# its title in big letters, and a log of the keys it receives.
package require Tk
lassign $argv cls title col keylog
wm withdraw .
toplevel .w -class $cls -background $col
wm title .w $title
wm geometry .w 640x400+60+60
label .w.l -text $title -font {Helvetica 40 bold} -background $col -foreground white
pack .w.l -expand 1 -fill both
bind .w <Key> [list apply {{f k} { set c [open $f a]; puts $c "key $k"; close $c }} $keylog %K]
update
focus -force .w
puts mapped
