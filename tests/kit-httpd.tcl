# kit-httpd.tcl -- a tiny static HTTP/1.1 server for the kit tests (a repository mirror).
#
#   tclsh8.6 tests/kit-httpd.tcl ROOT LOGFILE      prints the port it listens on, then serves
#
# GET and HEAD of files under ROOT, with ETag / Last-Modified and 304 for conditional requests,
# keep-alive, and one log line per request ("GET /path 200") so the tests can count round trips.

lassign $argv root logfile
set root [file normalize $root]

proc logline {line} {
    set ch [open $::logfile {WRONLY CREAT APPEND}]
    puts $ch $line
    close $ch
}

proc accept {sock addr port} {
    fconfigure $sock -translation {auto crlf} -buffering full -blocking 1
    fileevent $sock readable [list request $sock]
}

proc request {sock} {
    if {[catch {gets $sock line} n] || $n < 0} { catch {close $sock} ; return }
    if {$line eq ""} return
    set hdr [dict create]
    while {[gets $sock h] > 0} {
        if {[regexp {^([^:]+):\s*(.*)$} $h -> k v]} { dict set hdr [string tolower $k] $v }
    }
    lassign $line method uri
    set path [lindex [split $uri ?] 0]
    regsub -all {%([0-9A-Fa-f]{2})} $path {[format %c 0x\1]} path
    set path [subst -nobackslashes -novariables $path]
    set f [file normalize [file join $::root [string trimleft $path /]]]
    set keep [expr {![dict exists $hdr connection] || [string tolower [dict get $hdr connection]] ne "close"}]
    if {[string first $::root/ $f/] != 0 || ![file isfile $f]} {
        reply $sock 404 {} "not found\n" $method
        logline "$method $path 404"
    } else {
        # the ETag comes from the content (a file rewritten within the same second changes it)
        set ch [open $f rb] ; set body [read $ch] ; close $ch
        set etag "\"[string length $body]-[format %08x [zlib crc32 $body]]\""
        set lm [clock format [file mtime $f] -format "%a, %d %b %Y %H:%M:%S GMT" -gmt 1]
        if {[dict exists $hdr if-none-match] && [dict get $hdr if-none-match] eq $etag} {
            reply $sock 304 [list ETag $etag Last-Modified $lm] "" $method
            logline "$method $path 304"
        } else {
            reply $sock 200 [list ETag $etag Last-Modified $lm Content-Type application/octet-stream] $body $method
            logline "$method $path 200"
        }
    }
    if {!$keep} { catch {close $sock} }
}

proc reply {sock code headers body method} {
    set text [dict get {200 OK 304 {Not Modified} 404 {Not Found}} $code]
    puts $sock "HTTP/1.1 $code $text"
    foreach {k v} $headers { puts $sock "$k: $v" }
    if {$code != 304} { puts $sock "Content-Length: [string length $body]" }
    puts $sock ""
    flush $sock
    if {$method ne "HEAD" && $code != 304} {
        fconfigure $sock -translation binary
        puts -nonewline $sock $body
        flush $sock
        fconfigure $sock -translation {auto crlf}
    }
}

set srv [socket -server accept -myaddr 127.0.0.1 0]
puts [lindex [fconfigure $srv -sockname] 2]
flush stdout
vwait forever
