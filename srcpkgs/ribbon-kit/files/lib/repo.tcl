# repo.tcl -- the repository: its signed, expiring index (D13-D15), the kits' signed manifests,
# and chunks, from mirrors that are tried in order.
#
# A repository is static files (KIT.md section 7.4); any web host, CDN or directory works:
#
#   <mirror>/index            the repository index (below)
#   <mirror>/index.minisig    its minisign signature, by an index key of the key list
#   <mirror>/keys(.minisig)   the root-signed key list the index was made with (KIT-TRUST.md)
#   <mirror>/kits/<root>      the manifest of the kit whose root (KIT-FORMAT.md section 6.2) is <root>
#   <mirror>/chunks/<h2>/<h>  every chunk, classic file and header, by the SHA-256 of its stored bytes
#
# The repository index, UTF-8, LF after every line, fields separated by one TAB and escaped
# like the kit index (\\ \t \n \r):
#
#   ribbon-kit-repo 1
#   generated <seconds since the epoch>
#   expires   <seconds since the epoch>      after this the index installs nothing (D15)
#   serial, repository, keys, mirror, revoked, snapshot    kittrust's lines (KIT-TRUST.md section 4)
#   kit <name> <version> <kind> <root> <manifest sha256> <size> <download> <short> <flags> <provides> <summary> <tags>
#   title <name> <title>                  the name people know the kit by (KIT-FORMAT.md 4.1: the manifest's
#                                         title, else its launcher entry's Name), one line per kit name
#
# one kit line per kit version, sorted; flags is "-" or a comma list (security); provides is "-" or
# a comma list of name=version.  A kit's manifest file binds three things to the index (whose
# signature covers its SHA-256): the kit's seal statement and minisign signature (which sign the
# root), the kit's index text (whose SHA-256 is the root and which lists every chunk hash), and
# the stored size of each chunk:
#
#   ribbon-kit-manifest 1\n statement <n>\n<n bytes> signature <n>\n<n bytes> index <n>\n<n bytes> sizes <n>\n<n bytes>
#
# sizes holds "<sha256> <bytes>" lines.  So a kit installs only if an index key signed the
# index (kittrust: the right repository, no replay, the current key list), the index has not
# expired, an app key signed the statement, and every chunk matches its hash: nothing
# unverified is used.  Repositories are built by kittrust's kitindex.

namespace eval ::kit::repo {
    variable I ""          ;# the index in use (dict), loaded by ensure
    variable refreshed 0   ;# 1 if this process fetched a new index
    variable bad           ;# mirrors that failed in this process (tried last)
    array set bad {}
}

# ---- parsing --------------------------------------------------------------------------------------
proc ::kit::repo::parse {bytes} {
    set lines [split [encoding convertfrom utf-8 $bytes] \n]
    if {[lindex $lines 0] ne "ribbon-kit-repo 1"} { ::kit::fail 4 "not a kit repository index (or a version this kit doesn't know)" }
    set d [dict create generated 0 expires 0 kits {}]
    set kits {} ; set titles [dict create]
    foreach line [lrange $lines 1 end] {
        if {$line eq ""} continue
        set f [::kit::tsplit $line]
        switch -- [lindex $f 0] {
            generated - expires { dict set d [lindex $f 0] [lindex $f 1] }
            kit {
                lassign $f - name version kind root bundle size download short flags provides summary tags
                # the root and the bundle hash become URL and file names (kits/$root, the cache): hex or nothing
                if {![regexp {^[0-9a-f]{64}$} $root]} { ::kit::fail 4 "the repository index names a kit ($name) with no valid root hash" }
                lappend kits [dict create name $name version $version kind $kind root $root bundle $bundle \
                    size $size download $download short $short flags [expr {$flags eq "-" ? {} : [split $flags ,]}] \
                    provides [expr {$provides eq "-" ? {} : [lmap p [split $provides ,] { split $p = }]}] \
                    summary $summary tags $tags title ""]
            }
            title {
                if {[llength $f] == 3 && [lindex $f 2] ne ""} { dict set titles [lindex $f 1] [string map [list \n " " \r " " \t " "] [lindex $f 2]] }
            }
        }
    }
    foreach k {generated expires} {
        if {![string is wideinteger -strict [dict get $d $k]] || [dict get $d $k] <= 0} { ::kit::fail 4 "the repository index has no valid $k line" }
    }
    # a title line is for every version of its kit; kittrust's reader ignores it (a line it doesn't know), the
    # signature covers it all the same
    dict set d kits [lmap k $kits { if {[dict exists $titles [dict get $k name]]} { dict set k title [dict get $titles [dict get $k name]] } ; set k }]
    return $d
}

# Check an index (its bytes, as signed) with kittrust (docs/KIT-TRUST.md section 4): the index
# key's signature, the repository, the key list it was made with, and with -prev no replay.
# Raises -errorcode {KIT 4 KITTRUST <code>}; a revocation it announces applies from then on.
proc ::kit::repo::checkIndex {bytes sig args} {
    ::kit::kitfmt
    if {[catch {::kittrust index $bytes $sig {*}$args} r opts]} {
        set code [lindex [dict get $opts -errorcode] 1]
        if {[::kit::allowUnsigned] && $code in {SIGNATURE CONFIG}} {
            set st [expr {[catch {::kittrust check $bytes $sig} c] ? "unchecked" : [dict get $c state]}]
            if {$st ne "invalid"} { ::kit::warn "the index is $st, used only because allow-unsigned = yes" ; return {} }
        }
        return -code error -errorcode [list KIT 4 KITTRUST $code] $r
    }
    return $r
}

proc ::kit::repo::expired {I} { return [expr {[dict get $I expires] <= [::kit::now]}] }

# ---- the cached index -----------------------------------------------------------------------------
#   cache/index       the index text, as fetched and verified
#   cache/index.meta  a dict: sig etag lastmod checked (last time a mirror answered) mirror generated
proc ::kit::repo::meta {} {
    if {[catch {::kit::slurp [::kit::path cache index.meta] utf-8} m] || [catch {dict size $m}]} { return {} }
    return $m
}
proc ::kit::repo::writeMeta {m} { ::kit::spit [::kit::path cache index.meta] $m }

proc ::kit::repo::loadCache {} {
    set m [meta]
    if {![dict exists $m generated] || [catch {::kit::slurp [::kit::path cache index]} text]} { return "" }
    if {[catch {parse $text} I]} { return "" }
    # checked once per command, so the revocations it announces apply to .kit files too (and an
    # index whose meta came from another refresh, after a crash between the renames, fails here)
    if {[catch {checkIndex $text [dict get $m sig]} err]} { ::kit::warn "the saved index is not usable ($err)" ; return "" }
    dict set I checked [expr {[dict exists $m checked] ? [dict get $m checked] : 0}]
    dict set I source cache
    return $I
}

# ---- getting an index to work with ----------------------------------------------------------------
# maxage: refresh when the last successful check is older than this many seconds (0 = always).
# Returns the index dict (also in ::kit::repo::I) with: source pinned|cache|fresh, checked, and the
# kits.  Offline it uses the last good one and says how old it is.  An expired index is returned
# with a warning; installing from it is refused by needFresh.
proc ::kit::repo::ensure {maxage} {
    variable I
    if {$I ne "" && ([dict get $I source] ne "cache" || ($maxage > 0 && [::kit::now] - [dict get $I checked] <= $maxage))} { return $I }
    set pin [::kit::pinned]
    if {$pin ne ""} {
        set I [loadPinned $pin]
    } else {
        set I [loadCache]
        if {$I eq "" || $maxage == 0 || [::kit::now] - [dict get $I checked] > $maxage} { set I [refresh $I] }
    }
    if {[expired $I]} {
        ::kit::warn "the index expired [::kit::fmtage [expr {[::kit::now] - [dict get $I expires]}]]: it is shown, but nothing can be installed from it"
    }
    return $I
}

proc ::kit::repo::loadPinned {pin} {
    if {[catch {::kit::slurp $pin} text]} { ::kit::fail 2 "the pinned index $pin can't be read" }
    set sig "" ; catch {set sig [::kit::slurp $pin.minisig]}
    if {[catch {checkIndex $text $sig -pinned 1} err]} { ::kit::fail 4 "the pinned index $pin is refused: $err" }
    set I [parse $text]
    dict set I source pinned
    dict set I checked [file mtime $pin]
    return $I
}

proc ::kit::repo::mirrorOrder {} {
    variable bad
    set good {} ; set worse {}
    foreach m [::kit::mirrors] { if {[info exists bad($m)]} { lappend worse $m } else { lappend good $m } }
    return [concat $good $worse]
}

# Conditional requests: an unchanged index costs one round trip (304).  A mirror that fails, serves
# a bad signature, or serves an index older than the one we have (a replay) is skipped for the next.
proc ::kit::repo::refresh {cached} {
    variable refreshed ; variable bad
    set m [meta]
    set ms [mirrorOrder]
    if {![llength $ms]} {
        if {$cached ne ""} { return [offline $cached "no mirror is configured"] }
        ::kit::fail 3 "no mirror is configured (add mirror = URL to [::kit::path conf])"
    }
    set why {} ; set expiredBest ""
    foreach mirror $ms {
        set cond [expr {$cached ne "" && [dict exists $m mirror] && [dict get $m mirror] eq $mirror}]
        set rc [catch {
            ::kit::net::get $mirror/index -max 268435456 \
                -etag [expr {$cond && [dict exists $m etag] ? [dict get $m etag] : ""}] \
                -lastmod [expr {$cond && [dict exists $m lastmod] ? [dict get $m lastmod] : ""}]
        } r opts]
        if {$rc} { set bad($mirror) 1 ; lappend why net "$mirror: $r" ; continue }
        if {[dict get $r status] == 304} {
            dict set m checked [::kit::now]
            writeMeta $m
            dict set cached checked [dict get $m checked]
            return $cached
        }
        set text [dict get $r data]
        set sig ""
        if {[catch {::kit::net::get $mirror/index.minisig -max 65536} s]} {
            if {![::kit::allowUnsigned]} { set bad($mirror) 1 ; lappend why net "$mirror: $s" ; continue }
        } else { set sig [dict get $s data] }
        set prev "" ; set prevsig ""
        if {$cached ne "" && ![catch {::kit::slurp [::kit::path cache index]} p]} { set prev $p ; set prevsig [dict get $m sig] }
        set rc [catch {checkIndex $text $sig -prev $prev -prevsig $prevsig} res opts]
        if {$rc && [lindex [dict get $opts -errorcode] 3] eq "KEYS"} {
            # the index was made with a newer key list: take it from this mirror (it must chain
            # from the one here), then check again, once
            if {![catch {Keys $mirror} kerr]} { set rc [catch {checkIndex $text $sig -prev $prev -prevsig $prevsig} res opts] } else { set res $kerr }
        }
        if {$rc} { set bad($mirror) 1 ; lappend why sig "$mirror: $res" ; continue }
        if {[catch {parse $text} new]} { set bad($mirror) 1 ; lappend why sig "$mirror: $new" ; continue }
        set fresh [list $new $text $sig $mirror $r]
        if {[expired $new]} {
            if {$expiredBest eq "" || [dict get $new generated] > [dict get [lindex $expiredBest 0] generated]} { set expiredBest $fresh }
            lappend why sig "$mirror: its index has expired"
            continue
        }
        return [keep {*}$fresh]
    }
    if {$expiredBest ne "" && ($cached eq "" || [dict get [lindex $expiredBest 0] generated] > [dict get $cached generated])} {
        return [keep {*}$expiredBest]
    }
    set kinds [lmap {k -} $why { set k }]
    if {$cached eq ""} {
        set msg "no index yet: [join [lmap {- w} $why { set w }] {; }]"
        ::kit::fail [expr {"net" in $kinds ? 3 : 4}] $msg
    }
    return [offline $cached [expr {"sig" in $kinds ? "no mirror served a valid index" : "offline"}]]
}

# A newer key list from a mirror (docs/KIT-TRUST.md section 3): kept only if it chains.
proc ::kit::repo::Keys {mirror} {
    set k [::kit::net::get $mirror/keys -max 1048576]
    set ks [::kit::net::get $mirror/keys.minisig -max 65536]
    if {[catch {::kittrust update [dict get $k data] [dict get $ks data]} r]} { error "its key list is refused: $r" }
    # every repository's keys, not only Ribbon's: the other lists' kits stay trusted in this process
    ::kitfmt configure -keys [::kit::allKeys]
    return $r
}

proc ::kit::repo::offline {cached how} {
    ::kit::note "index from [::kit::fmtage [expr {[::kit::now] - [dict get $cached checked]}]], $how"
    dict set cached offline 1
    return $cached
}

proc ::kit::repo::keep {new text sig mirror r} {
    variable refreshed
    file mkdir [::kit::path cache]
    set now [::kit::now]
    ::kit::spit [::kit::path cache index] $text binary
    writeMeta [dict create sig $sig etag [dict get $r etag] lastmod [dict get $r lastmod] checked $now \
        mirror $mirror generated [dict get $new generated]]
    set refreshed 1
    dict set new checked $now
    dict set new source fresh
    return $new
}

# Installing needs an index that has not expired (a stale or replayed index installs nothing).
proc ::kit::repo::needFresh {} {
    variable I
    if {$I eq ""} return
    if {[expired $I]} {
        ::kit::fail 4 "the index expired [::kit::fmtage [expr {[::kit::now] - [dict get $I expires]}]]; nothing can be installed from it until a fresh one is fetched"
    }
}

# Kits of the index called NAME: the full reverse-DNS name, or the short name.
proc ::kit::repo::records {I name} {
    set out {}
    foreach k [dict get $I kits] {
        if {[dict get $k name] eq $name || [dict get $k short] eq $name} { lappend out $k }
    }
    return $out
}

# ---- kit manifests (the signed part a kit is installed from) ---------------------------------------
proc ::kit::repo::bundleParse {data} {
    set nl [string first \n $data]
    if {[string range $data 0 [expr {$nl - 1}]] ne "ribbon-kit-manifest 1"} { ::kit::fail 4 "not a kit manifest" }
    set pos [expr {$nl + 1}]
    set b [dict create]
    foreach key {statement signature index sizes} {
        set nl [string first \n $data $pos]
        if {$nl < 0 || ![regexp "^$key (\[0-9\]+)\$" [string range $data $pos [expr {$nl - 1}]] -> n]} { ::kit::fail 4 "a damaged kit manifest" }
        set pos [expr {$nl + 1}]
        dict set b $key [string range $data $pos [expr {$pos + $n - 1}]]
        incr pos $n
    }
    set sizes [dict create]
    foreach line [split [dict get $b sizes] \n] { if {[llength $line] == 2} { dict set sizes {*}$line } }
    dict set b sizes $sizes
    return $b
}
proc ::kit::repo::bundleText {b} {
    set sz [join [lmap {h n} [dict get $b sizes] { list $h $n }] \n]
    set out "ribbon-kit-manifest 1\n"
    foreach key {statement signature index} { append out "$key [string length [dict get $b $key]]\n[dict get $b $key]" }
    append out "sizes [string length $sz]\n$sz"
    return $out
}

# Check a manifest: its statement's root is the root we expect, the index text hashes to it, and
# the signature is valid (or acceptable by policy).  Returns {statement-dict signature-dict}.
proc ::kit::repo::bundleCheck {b root} {
    ::kit::kitfmt
    if {[catch {::kitfmt::ParseStatement [dict get $b statement]} st]} { ::kit::fail 4 "the kit's statement is damaged: $st" }
    if {$root ne "" && [dict get $st root] ne $root} { ::kit::fail 4 "the kit's statement does not name root $root" }
    if {[::kitfmt::Hash [dict get $b index]] ne [dict get $st root]} { ::kit::fail 4 "[dict get $st name]: the kit index does not match its signed root" }
    set sig [::kitfmt::SigCheck [dict get $b statement] [dict get $b signature]]
    return [list $st $sig]
}

# The manifest of an index record: from the cache, else from a mirror (checked against the
# SHA-256 the signed index gives for it, and then on its own).
proc ::kit::repo::bundle {rec} {
    set root [dict get $rec root]
    set f [::kit::path cache manifests $root]
    if {[file isfile $f]} {
        set data [::kit::slurp $f]
        ::kit::kitfmt
        if {[::kitfmt::Hash $data] eq [dict get $rec bundle]} { return [bundleParse $data] }
    }
    set data [fetchVerified kits/$root [dict get $rec bundle] 67108864]
    set b [bundleParse $data]
    bundleCheck $b $root
    ::kit::spit $f $data binary
    return $b
}

# One small file from the mirrors, by its known SHA-256 (a bad copy: try the next mirror).
proc ::kit::repo::fetchVerified {rel hash max} {
    variable bad
    ::kit::kitfmt
    set why {}
    foreach mirror [mirrorOrder] {
        if {[catch {::kit::net::get $mirror/$rel -max $max} r]} { set bad($mirror) 1 ; lappend why net "$mirror: $r" ; continue }
        set data [dict get $r data]
        if {[::kitfmt::Hash $data] ne $hash} { set bad($mirror) 1 ; lappend why hash "$mirror/$rel does not match its signed hash" ; continue }
        return $data
    }
    set kinds [lmap {k -} $why { set k }]
    if {![llength $why]} { ::kit::fail 3 "no mirror is configured (add mirror = URL to [::kit::path conf])" }
    ::kit::fail [expr {"hash" in $kinds ? 4 : 3}] [join [lmap {- w} $why { set w }] "; "]
}

# ---- chunks ---------------------------------------------------------------------------------------
proc ::kit::repo::chunkPath {h} { return [::kit::path cache chunks [string range $h 0 1] $h] }

# Fetch every chunk in hashes that is not in the chunk cache, each checked against its hash before
# it is kept; a chunk that fails is fetched again from the next mirror.  sizes: hash -> stored bytes.
proc ::kit::repo::fetchChunks {hashes sizes {progress ""}} {
    variable bad
    ::kit::kitfmt
    set todo {}
    foreach h [lsort -unique $hashes] {
        # a hash becomes a URL and a cache path: 64 hex digits or the kit is refused
        if {![regexp {^[0-9a-f]{64}$} $h]} { ::kit::fail 4 "a kit names a chunk with no valid hash" }
        if {![file exists [chunkPath $h]]} { lappend todo $h }
    }
    if {![llength $todo]} return
    set tmpdir [::kit::path cache chunks tmp]
    file mkdir $tmpdir
    array set why {}
    foreach mirror [mirrorOrder] {
        if {![llength $todo]} break
        set left {}
        for {set i 0} {$i < [llength $todo]} {incr i 64} {
            set batch [lrange $todo $i [expr {$i + 63}]]
            set items [lmap h $batch {
                list $mirror/chunks/[string range $h 0 1]/$h [expr {[dict exists $sizes $h] ? [dict get $sizes $h] : 1049000}] $tmpdir/[pid]-$h
            }]
            set res [::kit::net::getmany $items]
            set got {} ; set datas {}
            foreach h $batch r $res {
                if {$r ne ""} { set bad($mirror) 1 ; lappend why($h) net ; lappend left $h ; catch {file delete $tmpdir/[pid]-$h} ; continue }
                lappend got $h
                lappend datas [::kit::slurp $tmpdir/[pid]-$h]
            }
            foreach h $got hx [::kitfmt::HashMany $datas] {
                if {$hx ne $h} {
                    set bad($mirror) 1 ; lappend why($h) hash ; lappend left $h
                    file delete $tmpdir/[pid]-$h
                    ::kit::note "kit: a damaged chunk from $mirror; trying the next mirror"
                    continue
                }
                file mkdir [file dirname [chunkPath $h]]
                file rename -force $tmpdir/[pid]-$h [chunkPath $h]
            }
            if {$progress ne ""} { {*}$progress [llength $got] }
            ::kit::crashpoint fetch
        }
        set todo $left
    }
    if {[llength $todo]} {
        set h [lindex $todo 0]
        if {![llength [::kit::mirrors]]} { ::kit::fail 3 "no mirror is configured (add mirror = URL to [::kit::path conf])" }
        if {[info exists why($h)] && "hash" in $why($h)} { ::kit::fail 4 "chunk $h failed verification on every mirror" }
        ::kit::fail 3 "[llength $todo] chunks could not be fetched from any mirror"
    }
}

# Chunks no installed kit holds and no pending download needs are removed (all of them by default).
proc ::kit::repo::pruneChunks {keep} {
    set k [dict create]
    foreach h $keep { dict set k $h 1 }
    foreach f [glob -nocomplain -directory [::kit::path cache chunks] -type f */*] {
        set h [file tail $f]
        if {[file tail [file dirname $f]] eq "tmp"} {
            if {![regexp {^([0-9]+)-} $h -> p] || ![::kit::pidAlive $p]} { catch {file delete $f} }
            continue
        }
        if {![dict exists $k $h]} { catch {file delete $f} }
    }
}
