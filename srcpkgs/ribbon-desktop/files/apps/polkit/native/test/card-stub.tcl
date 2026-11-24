# card-stub.tcl - TEST TOOL: stands in for the Tk card. A window under XWayland that wants keys.
# Logs every key the toplevel gets, and focus changes, to the file named by argv 0.
set log [open [lindex $argv 0] a]
fconfigure $log -buffering line
wm geometry . 440x260+420+200
label .l -text "card (Tk under XWayland)" -font {Helvetica 14}
pack .l -expand 1
bind all <KeyPress> {puts $log "tk key %K"}
bind all <ButtonPress> {puts $log "tk click"}
bind . <FocusIn> {puts $log "tk focusin %d"}
bind . <FocusOut> {puts $log "tk focusout %d"}
update
focus -force .
puts $log "tk mapped [winfo ismapped .]"
