# hooks.tcl - Text editor (U26): the seams the later editor units plug into. Each is an empty proc that the window
# calls at start-up (or on the event named), so the wiring and its tests exist before the feature does.
#
#   editor::gutter_install     U28  (gutter.tcl) the chevron click; called once when the window is built.
#   editor::gutter_draw G      U28  (gutter.tcl) change bars and fold chevrons; U32 adds its marks here.
#   editor::highlight_install  U27  syntax colours (highlight.tcl): called when a document is created.
#   editor::find_install       U29  (find.tcl) find and replace bar: loads the saved options.
#   editor::split_install      U30  (split.tcl) split view: nothing to load yet.
#   editor::welcome_install    U31  (welcome.tcl) the Welcome page: its fonts and the pinned list.
#   editor::diagnostics_install U32 nagelfar diagnostics. Called once; gutter_draw is where its marks go.

namespace eval editor {}

proc editor::diagnostics_install {} {}
