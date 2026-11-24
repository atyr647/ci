# publish.tcl -- building a repository (docs/KIT-TRUST.md section 5), for kitindex.
#
#   <repo>/index               the index (srcpkgs/ribbon-kit lib/repo.tcl's format, plus
#   <repo>/index.minisig         serial, repository, keys, mirror, revoked lines), by an index key
#   <repo>/snapshots/<serial>  a signed snapshot of that index for pinning (KIT_INDEX=FILE),
#   <repo>/snapshots/<serial>.minisig   with a snapshot line and a longer expiry
#   <repo>/keys, keys.minisig  the root-signed key list the index was made with (clients update from it)
#   <repo>/kits/<root>         each kit's manifest: statement, signature, kit index, chunk sizes
#   <repo>/chunks/<h2>/<h>     every chunk, classic file and header, named by SHA-256 of its bytes
#
# Content first, the index last: a client never sees an index naming files that aren't there.

namespace eval ::kittrust::repo {}

# The manifest a client installs from (repo.tcl's bundleParse): byte lengths, the kit index as
# its UTF-8 bytes (what the root is the SHA-256 of).
proc ::kittrust::repo::Bundle {stmt sig index sizes} {
    set out "ribbon-kit-manifest 1\n"
    foreach {key val} [list statement $stmt signature $sig index [encoding convertto utf-8 $index]] {
        append out "$key [string length $val]\n$val"
    }
    set sz [join [lmap {h n} $sizes { list $h $n }] \n]
    append out "sizes [string length $sz]\n$sz"
    return $out
}

# Keep one blob (content-addressed; an existing copy of the right size is kept).
proc ::kittrust::repo::Blob {repo hash data} {
    if {[::kitfmt hash $data] ne $hash} { ::kittrust::Fail SIGNATURE "a blob does not match its hash $hash" }
    set f [file join $repo chunks [string range $hash 0 1] $hash]
    if {[file isfile $f] && [file size $f] == [string length $data]} return
    ::kittrust::Spit $f $data
}

# Open a kit (signature through the key list, every chunk checked), copy its blobs into the
# repository, write its manifest, and return its index record (13 fields, without "kit").
# flags: the record's flags ("" = none).
proc ::kittrust::repo::AddKit {path repo flags} {
    set h [::kitfmt open $path]
    set rc [catch {
        set inf [::kitfmt info $h]
        set sig [dict get $inf signature]
        if {[dict get $sig state] ne "valid"} {
            ::kittrust::Fail SIGNATURE "[file tail $path]: the kit's signature is [dict get $sig state]: [dict get $sig detail]"
        }
        set v [::kitfmt verify $h]
        if {![dict get $v ok]} {
            ::kittrust::Fail SIGNATURE "[file tail $path] failed verification: [lindex [dict get $v bad] 0]"
        }
        set m [::kitfmt manifest $h]
        set f [dict get $m fields]
        set sizes [dict create]
        foreach p [::kitfmt walk $h] {
            set e [::kitfmt::Entry $h $p]
            if {[dict get $e type] ne "file"} continue
            set row [dict get $e row]
            if {[dict get $e codec] eq "classic"} {
                Blob $repo [dict get $e hash] [mk::get $row contents]
                dict set sizes [dict get $e hash] [dict get $e stored]
                continue
            }
            set i 0
            foreach hx [dict get $e hashes] n [dict get $e lens] {
                Blob $repo $hx [mk::get $row.chunks!$i z]
                dict set sizes $hx $n
                incr i
            }
        }
        set fr $::kitfmt::H($h,frame)
        set st [dict get $fr st]
        if {[dict get $st header] > 0} {
            Blob $repo [dict get $st headerHash] [::kitfmt::ReadAt $path 0 [dict get $st header]]
            dict set sizes [dict get $st headerHash] [dict get $st header]
        }
        set b [Bundle [dict get $fr statement] [dict get $fr signature] [::kitfmt index $h] $sizes]
        set root [dict get $inf root]
        ::kittrust::Spit [file join $repo kits $root] $b
        set download 0
        dict for {hx n} $sizes { incr download $n }
        # a system kit is fetched whole (D46 A, D58 B: its image is activated, not its files): the file beside its
        # bundle, kits/<root>.kit, and its size is what a grab downloads
        if {[dict get $f kind] eq "system"} {
            file copy -force $path [file join $repo kits $root.kit]
            set download [file size $path]
        }
        set short [expr {[dict exists $f x-short] ? [dict get $f x-short] : [lindex [split [dict get $f name] .] end]}]
        set prov [lmap p [dict get $m provides] { join $p = }]
        list [dict get $f name] [dict get $f version] [dict get $f kind] $root [::kitfmt hash $b] \
            [dict get $inf bytes] $download $short [expr {$flags eq "" ? "-" : $flags}] \
            [expr {[llength $prov] ? [join $prov ,] : "-"}] \
            [expr {[dict exists $f summary] ? [dict get $f summary] : ""}] \
            [expr {[dict exists $f x-tags] ? [dict get $f x-tags] : ""}]
    } res opts]
    ::kitfmt close $h
    if {$rc} { return -options $opts $res }
    return $res
}

# The index text (UTF-8 bytes) for these records.
#   o: generated expires serial repository keys keysHash snapshot mirrors revoked(dict id -> {t why})
proc ::kittrust::repo::IndexText {o records} {
    set L ::kittrust::Line
    set out [list "ribbon-kit-repo 1"]
    foreach k {generated expires serial repository} { lappend out [$L $k [dict get $o $k]] }
    lappend out [$L keys [dict get $o keys] [dict get $o keysHash]]
    if {[dict get $o snapshot] ne ""} { lappend out [$L snapshot [dict get $o snapshot]] }
    foreach m [dict get $o mirrors] { lappend out [$L mirror $m] }
    set g {}
    dict for {id r} [dict get $o revoked] { lappend g [$L revoked $id {*}$r] }
    lappend out {*}[lsort $g]
    set g {}
    foreach r $records { lappend g [encoding convertto utf-8 [$L kit {*}$r]] }
    set g [lmap l [lsort $g] { encoding convertfrom utf-8 $l }]
    lappend out {*}$g
    return [encoding convertto utf-8 "[join $out \n]\n"]
}

# The index already published in repo, checked with the key list ("" if there is none).
# check 1: its signature must still be good (refresh re-signs its records, so they must be ours).
proc ::kittrust::repo::Previous {repo check} {
    set f [file join $repo index]
    if {![file isfile $f]} { return "" }
    set text [::kittrust::Slurp $f]
    set sig "" ; catch {set sig [::kittrust::Slurp $f.minisig]}
    if {$check} { ::kittrust index $text $sig }
    return [::kittrust parseindex $text]
}

# Write the index, its snapshot and the key list in use.  o: -key -expires -snapshotExpires
# -mirrors -revoke (dict id -> why) -serial; records: the kit records.  -> summary dict
proc ::kittrust::repo::Publish {repo prev records args} {
    array set o {-key "" -expires 604800 -snapshotExpires 7776000 -mirrors {} -revoke {} -serial ""}
    array set o $args
    set cur [::kittrust list]
    set T [dict get $cur list] ; set Ttext [dict get $cur text]
    set now [::kittrust::Now]
    set serial [expr {$prev eq "" ? 1 : [dict get $prev serial] + 1}]
    if {$o(-serial) ne ""} {
        if {$prev ne "" && $o(-serial) <= [dict get $prev serial]} {
            ::kittrust::Fail ROLLBACK "-serial $o(-serial) is not above the published serial [dict get $prev serial]"
        }
        set serial $o(-serial)
    }
    # revocations: carried forward until the key list itself revokes the key
    set rev [dict create]
    if {$prev ne ""} { dict for {id r} [dict get $prev revoked] { if {![dict exists $T revoked $id]} { dict set rev $id $r } } }
    dict for {id why} $o(-revoke) { dict set rev $id [list $now $why] }
    set mirrors [expr {[llength $o(-mirrors)] || $prev eq "" ? $o(-mirrors) : [dict get $prev mirrors]}]
    set d [dict create generated $now expires [expr {$now + $o(-expires)}] serial $serial \
        repository [dict get $T repository] keys [dict get $T serial] keysHash [::kitfmt hash $Ttext] \
        snapshot "" mirrors $mirrors revoked $rev]
    set text [IndexText $d $records]
    set sig [::kittrust sign $text $o(-key) "ribbon-kit-repo [dict get $T repository] serial $serial"]
    # the key must be a valid index key now: check what we are about to publish
    set res [::kittrust index $text $sig]
    dict set d snapshot $serial
    dict set d expires [expr {$now + $o(-snapshotExpires)}]
    set stext [IndexText $d $records]
    set ssig [::kittrust sign $stext $o(-key) "ribbon-kit-repo [dict get $T repository] snapshot $serial"]
    ::kittrust index $stext $ssig -pinned 1
    ::kittrust::Spit [file join $repo snapshots $serial.minisig] $ssig
    ::kittrust::Spit [file join $repo snapshots $serial] $stext
    ::kittrust::Spit [file join $repo keys.minisig] [dict get $cur sig]
    ::kittrust::Spit [file join $repo keys] $Ttext
    ::kittrust::Spit [file join $repo index.minisig] $sig
    ::kittrust::Spit [file join $repo index] $text
    return $res
}

# Manifests and blobs that neither the index nor any snapshot still in snapshots/ uses: removed
# (delete old snapshots first to let their kits go).  -> how many files were removed
proc ::kittrust::repo::Prune {repo} {
    set keepK [dict create] ; set keepC [dict create]
    foreach f [concat [list [file join $repo index]] [glob -nocomplain -directory [file join $repo snapshots] -type f {[0-9]*}]] {
        if {[string match *.minisig $f] || [catch {::kittrust parseindex [::kittrust::Slurp $f]} I]} continue
        foreach r [dict get $I kits] {
            set root [lindex $r 3]
            if {[dict exists $keepK $root]} continue
            dict set keepK $root 1
            if {[catch {::kittrust::Slurp [file join $repo kits $root]} b]} continue
            foreach hx [regexp -all -inline {(?n)^[0-9a-f]{64}(?= [0-9]+$)} $b] { dict set keepC $hx 1 }
        }
    }
    set n 0
    foreach f [glob -nocomplain -directory [file join $repo kits] -type f *] {
        if {![dict exists $keepK [file tail $f]]} { file delete $f ; incr n }
    }
    foreach f [glob -nocomplain -directory [file join $repo chunks] -type f */*] {
        if {![dict exists $keepC [file tail $f]]} { file delete $f ; incr n }
    }
    return $n
}
