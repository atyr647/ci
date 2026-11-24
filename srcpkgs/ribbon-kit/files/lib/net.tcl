# net.tcl -- getting bytes from mirrors: file://, http:// (Tcl's http) and https:// (Tcl's http
# with the tls package when it is installed, else curl).  Conditional requests (ETag /
# Last-Modified), a size cap on every request, and one batch call for many chunks.
#
#   ::kit::net::get URL ?-etag E? ?-lastmod L? ?-max N? ?-file F?
#       -> dict status 200|304 etag E lastmod L ?data D?      (with -file the body goes to F)
#   ::kit::net::getmany {{URL MAX FILE} ...}  -> one result per item: "" (ok) or an error message
#
# Failures raise -errorcode {KIT 3 NET ...}: a network or mirror failure (exit code 3).

namespace eval ::kit::net {
    variable httpLoaded 0
    variable tls ""        ;# "" not tried yet, 0 none, 1 loaded
}

proc ::kit::net::timeout {} { return [expr {int([::kit::cfg timeout 30] * 1000)}] }

proc ::kit::net::err {kind msg} { return -code error -errorcode [list KIT 3 NET $kind] $msg }

proc ::kit::net::scheme {url} {
    if {![regexp {^([a-z]+)://} $url -> s]} { err BADURL "not a URL: $url" }
    return $s
}

proc ::kit::net::get {url args} {
    array set o {-etag "" -lastmod "" -max -1 -file ""}
    array set o $args
    switch -- [scheme $url] {
        file { return [FileGet $url o] }
        http { return [HttpGet $url o] }
        https {
            if {[Tls]} { return [HttpGet $url o] }
            return [CurlGet $url o]
        }
        default { err BADURL "unsupported URL scheme: $url" }
    }
}

# ---- file:// (a local repository) ---------------------------------------------------------------
proc ::kit::net::FilePath {url} {
    # %XX is a byte of the UTF-8 name.  Never `subst` the URL: it comes from a signed index (a kit's root, a chunk's
    # hash), and Tcl's [command] substitution would run what a compromised index key put there, as root in kitd.
    set parts [split [string range $url 7 end] %]
    set out [encoding convertto utf-8 [lindex $parts 0]]
    foreach part [lrange $parts 1 end] {
        if {[regexp {^([0-9A-Fa-f]{2})(.*)$} $part -> hex rest]} {
            append out [binary format H2 $hex] [encoding convertto utf-8 $rest]
        } else {
            append out % [encoding convertto utf-8 $part]
        }
    }
    return [encoding convertfrom utf-8 $out]
}
proc ::kit::net::FileGet {url oName} {
    upvar 1 $oName o
    set p [FilePath $url]
    if {![file isfile $p]} { err NOTFOUND "$url: not found" }
    if {$o(-max) >= 0 && [file size $p] > $o(-max)} { err TOOBIG "$url is larger than expected" }
    set data [::kit::slurp $p]
    # reading a local file costs nothing: the ETag is its content (a rewrite within a second shows)
    set etag "\"[string length $data]-[format %08x [zlib crc32 $data]]\""
    if {$o(-etag) ne "" && $o(-etag) eq $etag} { return [dict create status 304 etag $etag lastmod ""] }
    set r [dict create status 200 etag $etag lastmod ""]
    if {$o(-file) ne ""} { ::kit::spit $o(-file) $data binary } else { dict set r data $data }
    return $r
}

# ---- http:// and https:// through Tcl's http package --------------------------------------------
proc ::kit::net::Http {} {
    variable httpLoaded
    if {!$httpLoaded} {
        package require http
        http::config -useragent "kit/$::kit::version"
        set httpLoaded 1
    }
}
proc ::kit::net::Tls {} {
    variable tls
    if {$tls eq ""} {
        set tls [expr {![catch {package require tls}]}]
        if {$tls} {
            Http
            http::register https 443 [list ::tls::socket -autoservername 1 -require 1 -cadir /etc/ssl/certs]
        }
    }
    return $tls
}

proc ::kit::net::HttpGet {url oName} {
    upvar 1 $oName o
    Http
    set hdr {}
    if {$o(-etag) ne ""} { lappend hdr If-None-Match $o(-etag) }
    if {$o(-lastmod) ne ""} { lappend hdr If-Modified-Since $o(-lastmod) }
    set opts [list -binary 1 -timeout [timeout] -headers $hdr -keepalive 1 -blocksize 65536]
    if {$o(-max) >= 0} { lappend opts -progress [list ::kit::net::Cap $o(-max)] }
    # bodies are read into memory (chunks are at most 1 MiB): Tcl's http with -channel and
    # keep-alive waits for the server to close
    for {set hops 0} {$hops < 5} {incr hops} {
        if {[catch {http::geturl $url {*}$opts} tok]} { err CONNECT "$url: $tok" }
        set st [http::status $tok] ; set code [http::ncode $tok]
        set meta [http::meta $tok]
        if {$st eq "ok" && $code in {301 302 303 307 308}} {
            set loc [MetaGet $meta location]
            http::cleanup $tok
            if {$loc eq ""} break
            if {![regexp {^[a-z]+://} $loc]} { regexp {^[a-z]+://[^/]+} $url base ; set loc $base$loc }
            set url $loc
            continue
        }
        break
    }
    set data [http::data $tok]
    set err [http::error $tok]
    http::cleanup $tok
    if {$st eq "reset"} { err TOOBIG "$url is larger than expected" }
    if {$st ne "ok"} { err CONNECT "$url: [expr {$err ne "" ? $err : $st}]" }
    if {$code == 304} { return [dict create status 304 etag [MetaGet $meta etag $o(-etag)] lastmod [MetaGet $meta last-modified $o(-lastmod)]] }
    if {$code != 200} { err [expr {$code == 404 ? "NOTFOUND" : "HTTP"}] "$url: HTTP $code" }
    set r [dict create status 200 etag [MetaGet $meta etag] lastmod [MetaGet $meta last-modified]]
    if {$o(-file) eq ""} { dict set r data $data } else { ::kit::spit $o(-file) $data binary }
    return $r
}
proc ::kit::net::MetaGet {meta key {default ""}} {
    foreach {k v} $meta { if {[string tolower $k] eq $key} { return $v } }
    return $default
}
proc ::kit::net::Cap {max tok total current} {
    if {$current > $max || ($total > 0 && $total > $max)} { http::reset $tok reset }
}

# ---- https:// through curl (when Tcl has no tls package) -------------------------------------
proc ::kit::net::Curl {} {
    set c [auto_execok curl]
    if {$c eq ""} { err CONNECT "https needs the Tcl tls package or curl, and neither is installed" }
    return $c
}
proc ::kit::net::CurlGet {url oName} {
    upvar 1 $oName o
    ::kit::kitfmt
    set tmp [::kitfmt::TempDir]
    set out [expr {$o(-file) ne "" ? $o(-file) : "$tmp/body"}]
    set cmd [list {*}[Curl] -sS -L --proto =https,http --max-time [expr {[timeout] / 1000}] -D $tmp/hdr -o $out -w {%{http_code}}]
    if {$o(-etag) ne ""} { lappend cmd -H "If-None-Match: $o(-etag)" }
    if {$o(-lastmod) ne ""} { lappend cmd -H "If-Modified-Since: $o(-lastmod)" }
    if {$o(-max) >= 0} { lappend cmd --max-filesize $o(-max) }
    lappend cmd -- $url
    set rc [catch {exec {*}$cmd 2>@1} res]
    set code [string range [string trim $res] end-2 end]
    set hdr "" ; catch {set hdr [::kit::slurp $tmp/hdr utf-8]}
    set meta {}
    foreach line [split $hdr \n] { if {[regexp {^([A-Za-z-]+):\s*(.*?)\s*$} $line -> k v]} { lappend meta $k $v } }
    set data "" ; if {$o(-file) eq "" && [file exists $out]} { set data [::kit::slurp $out] }
    file delete -force $tmp
    if {$rc && ![string is integer -strict $code]} { err CONNECT "$url: $res" }
    if {$code == 304} { return [dict create status 304 etag [MetaGet $meta etag $o(-etag)] lastmod [MetaGet $meta last-modified $o(-lastmod)]] }
    if {$code != 200} { err [expr {$code == 404 ? "NOTFOUND" : "HTTP"}] "$url: HTTP $code" }
    set r [dict create status 200 etag [MetaGet $meta etag] lastmod [MetaGet $meta last-modified]]
    if {$o(-file) eq ""} { dict set r data $data }
    return $r
}

# ---- many files at once (chunks) --------------------------------------------------------------
proc ::kit::net::getmany {items} {
    if {![llength $items]} { return {} }
    set s [scheme [lindex $items 0 0]]
    if {$s eq "https" && ![Tls]} { return [CurlMany $items] }
    set out {}
    foreach it $items {
        lassign $it url max file
        if {[catch {get $url -max $max -file $file} e]} { lappend out $e } else { lappend out "" }
    }
    return $out
}
proc ::kit::net::CurlMany {items} {
    # one --next group per file, each with its own --max-filesize: a mirror that serves more than a chunk can be is
    # cut off by curl itself, not after the whole body is on the disk (--parallel is the one global option)
    set cmd [list {*}[Curl] --parallel --parallel-max 8]
    set n 0
    foreach it $items {
        lassign $it url max file
        if {$n} { lappend cmd --next }
        lappend cmd -sS --proto =https,http --max-time [expr {[timeout] / 1000}] -w "%{http_code} %{url_effective}\n"
        if {$max >= 0} { lappend cmd --max-filesize $max }
        lappend cmd -o $file $url
        incr n
    }
    catch {exec {*}$cmd 2>/dev/null} res
    array set code {}
    foreach line [split $res \n] { if {[regexp {^(\d{3}) (\S+)$} $line -> c u]} { set code($u) $c } }
    set out {}
    foreach it $items {
        lassign $it url max file
        if {![info exists code($url)] || $code($url) != 200} {
            lappend out "$url: [expr {[info exists code($url)] ? "HTTP $code($url)" : "no answer"}]"
        } elseif {![file exists $file]} {
            # curl turned it away before writing (--max-filesize, from the Content-Length it was told)
            lappend out [expr {$max >= 0 ? "$url is larger than expected" : "$url: nothing was received"}]
        } elseif {$max >= 0 && [file size $file] > $max} {
            catch {file delete $file}
            lappend out "$url is larger than expected"
        } else { lappend out "" }
    }
    return $out
}
