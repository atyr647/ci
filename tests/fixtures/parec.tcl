# parec.tcl - a fake parec: 8 kHz mono s16le at a steady sample value (8000, about -12 dBFS) in 100 ms blocks, until
# it is killed or its reader goes away.
fconfigure stdout -translation binary
set block [binary format s* [lrepeat 800 8000]]
while 1 {
	if {[catch {puts -nonewline stdout $block; flush stdout}]} { exit 0 }
	after 100
}
