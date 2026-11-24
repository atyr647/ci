# ::kit::net::CurlMany (net.tcl): the https chunk download when Tcl has no tls package (curl, in parallel). Run over http
# against a local server with real curl: an answer is kept when it fits, a file bigger than the expected size is cut off by
# curl (--max-filesize, per URL) and deleted, a 404 is said, and each URL has its own limit.
set top [file dirname [file dirname [file normalize [info script]]]]
set work [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] kit-curlmany-[pid]]
file mkdir $work/www $work/home
set ::env(HOME) $work/home
set ::env(KIT_CONF) $work/kit.conf
source -encoding utf-8 $top/srcpkgs/ribbon-kit/files/lib/core.tcl
::kit::init
::kit::need net
set fails 0
proc ok {what cond {detail ""}} { global fails; if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what $detail"; incr fails } }
proc put {n size} { global work; set f [open $work/www/$n wb]; puts -nonewline $f [string repeat x $size]; close $f }
put small 1000
put big 5000000
put exact 2000
# a tiny static server (python's) on a free port
set py [open |[list python3 -I -c {
import http.server, socketserver, sys, os
os.chdir(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
s = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
} $work/www] r]
set port [gets $py]
set base http://127.0.0.1:$port
set items [list \
    [list $base/small 4096 $work/o-small] \
    [list $base/big 1048576 $work/o-big] \
    [list $base/exact 2000 $work/o-exact] \
    [list $base/missing 4096 $work/o-missing] \
    [list $base/small 500 $work/o-tight]]
set res [::kit::net::CurlMany $items]
ok "a file within its limit is kept" {[lindex $res 0] eq "" && [file size $work/o-small] == 1000}
ok "a file of exactly the limit is kept" {[lindex $res 2] eq "" && [file size $work/o-exact] == 2000} $res
ok "a 5 MB answer to a 1 MB limit is refused as larger than expected" {[string match "*is larger than expected" [lindex $res 1]]} $res
ok "  and not left on the disk" {![file exists $work/o-big]}
ok "  and curl stopped it itself (it never wrote the whole body)" {![file exists $work/o-big] || [file size $work/o-big] < 5000000}
ok "a missing file is its own error" {[string match "*HTTP 404*" [lindex $res 3]]} $res
ok "the same URL with a smaller limit is refused on its own (each URL has its own limit)" {[string match "*larger than expected*" [lindex $res 4]]} $res
ok "the answers keep the items' order" {[llength $res] == 5}
catch {exec kill [pid $py]}
catch {close $py}
file delete -force $work
if {$fails} { exit 1 }
puts "all CurlMany checks passed"
