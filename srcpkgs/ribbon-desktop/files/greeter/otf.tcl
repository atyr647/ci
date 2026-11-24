# otf.tcl - the old interface to letter placement, kept for code that has
# not moved to the shell's text.tcl yet (the Appearance app). It wraps
# text.tcl, which reads the font files the same way (advances, GPOS
# kerning) and also gives Tk the right weights; new code uses text.tcl.

if {[info commands ::text::layout] eq ""} {
	source -encoding utf-8 [file join [file dirname [file dirname [file normalize [info script]]]] shell text.tcl]
}
namespace eval otf {}

# Where each character of TEXT starts, in px, and the width: {x0 x1 ... width}.
proc otf::layout {family size text {ls 0}} { text::layout [text::fontof $family $size] $text $ls }

# text.tcl measures letters the font file lacks itself: nothing is missing.
proc otf::missing {family text} { return "" }
