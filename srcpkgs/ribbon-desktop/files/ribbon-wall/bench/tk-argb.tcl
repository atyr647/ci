# tk-argb.tcl - does Tk 8.6 write alpha on a 32-bit TrueColor visual?
#   wish tk-argb.tcl ./xtest   (on XWayland)
# Prints the pixels Tk wrote, read back with xtest: the alpha byte is 0xff
# everywhere. (Drawing #ffffff text on that visual aborts with X BadValue
# in X_QueryColors.)
wm withdraw .
toplevel .t -visual {truecolor 32} -colormap new -background #102030 -borderwidth 0 -highlightthickness 0
wm overrideredirect .t 1
wm geometry .t 600x200+100+100
canvas .t.c -width 600 -height 200 -highlightthickness 0 -bd 0 -background #102030
pack .t.c
set p [image create photo -width 150 -height 200]; $p put #0000ff -to 0 0 150 200
.t.c create image 150 0 -image $p -anchor nw
.t.c create rectangle 300 0 450 200 -fill #00ff00 -width 0
update
puts "frame [wm frame .t] id [winfo id .t] canvas [winfo id .t.c]"
puts [exec [lindex $argv 0] alpha [winfo id .t.c]]
puts [exec [lindex $argv 0] alpha [wm frame .t]]
exit
