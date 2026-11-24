# store.tcl -- what is installed: the active set, the store of kit versions, the launcher
# exports, and garbage collection.
#
#   data/active             the live set (switched by one rename, see txn.tcl):
#                             ribbon-kit-active 1
#                             txn  <id>                                   the transaction that wrote it
#                             kit  <name> <version> <root> <reason> <started>
#                             use  <name> <version> <need> <lib name> <lib version>    the lock (D32)
#                             hold <name>          grabbed as NAME@VERSION: check leaves it there
#                           reason: user (asked for), dep (a shared library some kit uses), prev
#                           (the old version, kept until the new one has started once)
#   data/store/<root>/      one directory per kit version, never changed once there (one copy
#                           per version, content-addressed by the kit's signed root):
#                             kit        the .kit file (what mkkitfs serves)
#                             manifest   its signed manifest (statement, signature, index, sizes)
#                             info       a Tcl dict (D12): identity, manifest, entries, data paths
#                             export/    its launcher entry, icons, MIME, fonts, D-Bus files
#                             (a kit's files are never extracted: mkkitfs serves kit, from here)
#   data/data/<name>/       the kit's private data (D9), the sandbox's home

namespace eval ::kit::store {
    variable kitHandles   ;# root -> open kitfmt handle (chunk reuse)
    array set kitHandles {}
    variable chunkMap ""  ;# hash -> root, over installed kits
}

# ---- the active set ---------------------------------------------------------------------------
proc ::kit::store::empty {} { return [dict create txn "" kits {} uses {} holds {}] }

proc ::kit::store::load {{file ""}} {
    if {$file eq ""} { set file [::kit::path active] }
    if {![file exists $file]} { return [empty] }
    return [parse [::kit::slurp $file utf-8] $file]
}

# A set as store::text writes it (also: the before and after texts of a history entry).
proc ::kit::store::parse {text {file "the installed set"}} {
    set lines [split $text \n]
    if {[lindex $lines 0] ne "ribbon-kit-active 1"} { ::kit::fail 4 "the installed set ($file) is damaged: run kit mend" }
    set A [empty]
    set uses {}
    foreach line [lrange $lines 1 end] {
        set f [split $line \t]
        switch -- [lindex $f 0] {
            txn { dict set A txn [lindex $f 1] }
            kit {
                lassign $f - name version root reason started
                dict set A kits "$name $version" [dict create name $name version $version root $root reason $reason started $started]
            }
            use { lassign $f - n v need ln lv ; lappend uses [list "$n $v" $need "$ln $lv"] }
            hold { dict lappend A holds [lindex $f 1] }
        }
    }
    dict set A uses $uses
    return $A
}

proc ::kit::store::text {A} {
    set out [list "ribbon-kit-active 1" "txn\t[dict get $A txn]"]
    foreach key [lsort [dict keys [dict get $A kits]]] {
        set k [dict get $A kits $key]
        lappend out [join [list kit [dict get $k name] [dict get $k version] [dict get $k root] [dict get $k reason] [dict get $k started]] \t]
    }
    foreach u [lsort -unique [dict get $A uses]] {
        lassign $u user need lib
        lappend out [join [list use {*}[split $user] $need {*}[split $lib]] \t]
    }
    foreach h [lsort -unique [dict get $A holds]] { lappend out "hold\t$h" }
    return "[join $out \n]\n"
}

# Lines by name (all versions, prev included), newest first.
proc ::kit::store::lines {A name} {
    set out {}
    dict for {key k} [dict get $A kits] { if {[dict get $k name] eq $name} { lappend out $k } }
    return [lsort -command [list apply {{a b} { ::kit::vcmp [dict get $b version] [dict get $a version] }}] $out]
}
# The live line of a name: user before dep, newest first; prev lines are never live.
proc ::kit::store::live {A name} {
    set best ""
    foreach k [lines $A $name] {
        if {[dict get $k reason] eq "prev"} continue
        if {$best eq "" || ([dict get $k reason] eq "user" && [dict get $best reason] ne "user")} { set best $k }
    }
    return $best
}
proc ::kit::store::key {k} { return "[dict get $k name] [dict get $k version]" }

# Find an installed kit by what people type: its full name or its short name.
proc ::kit::store::findLive {A word} {
    set k [live $A $word]
    if {$k ne ""} { return $k }
    set hits {}
    foreach name [lsort -unique [lmap {key k} [dict get $A kits] { dict get $k name }]] {
        set l [live $A $name]
        if {$l ne "" && [dict get [kinfo [dict get $l root]] short] eq $word} { lappend hits $l }
    }
    if {[llength $hits] > 1} { ::kit::fail 2 "$word is ambiguous: [join [lmap h $hits { dict get $h name }] {, }]" }
    return [lindex $hits 0]
}

# Who uses a line (keys of the lines whose lock names it).
proc ::kit::store::users {A key} {
    set out {}
    foreach u [dict get $A uses] { if {[lindex $u 2] eq $key} { lappend out [lindex $u 0] } }
    return [lsort -unique $out]
}

# Drop dep lines nobody uses any more (and their own locks), until nothing changes.
proc ::kit::store::prune {A} {
    while {1} {
        set used [dict create]
        foreach u [dict get $A uses] { dict set used [lindex $u 2] 1 }
        set gone {}
        dict for {key k} [dict get $A kits] {
            if {[dict get $k reason] eq "dep" && ![dict exists $used $key]} { lappend gone $key }
        }
        if {![llength $gone]} { return $A }
        foreach key $gone { dict unset A kits $key }
        dict set A uses [lmap u [dict get $A uses] { if {[lindex $u 0] in $gone} continue ; set u }]
    }
}

# ---- per-version info -----------------------------------------------------------------------------
proc ::kit::store::kinfo {root} {
    variable infoCache
    if {[::info exists infoCache($root)]} { return $infoCache($root) }
    set f [::kit::path store $root info]
    if {[catch {::kit::slurp $f utf-8} d] || [catch {dict size $d}]} {
        # not staged yet, or damaged (kit mend writes it again): not remembered
        return [dict create name ? version ? short ? kind app summary "" size 0 fields {} needs {} provides {} perms {} \
            entries {} effects {} exports {} signer {} installed 0 origin repo]
    }
    set infoCache($root) $d
    return $d
}

# The data a kit keeps outside the store: its x-data paths (relative to home) and data/<name>/.
proc ::kit::store::dataPaths {info} {
    set out {}
    set f [dict get $info fields]
    if {[dict exists $f x-data]} {
        foreach p [dict get $f x-data] {
            set p [string trimleft [regsub {^~/} $p ""] /]
            if {$p eq "" || [string match *..* $p]} continue
            lappend out [file join [::kit::path home] $p]
        }
    }
    lappend out [::kit::path appdata [dict get $info name]]
    # an empty directory (kit run makes the private one) holds no data
    return [lmap p $out { if {![file exists $p] || ([file isdirectory $p] && ![llength [glob -nocomplain -directory $p * .?*]])} continue ; set p }]
}

proc ::kit::store::du {path} {
    if {[catch {file lstat $path s}]} { return 0 }
    if {$s(type) eq "directory"} {
        set n 0
        foreach c [glob -nocomplain -directory $path * .*] {
            if {[file tail $c] in {. ..}} continue
            incr n [du $c]
        }
        return $n
    }
    return [expr {$s(type) eq "file" ? $s(size) : 0}]
}

proc ::kit::store::essential {info} {
    set f [dict get $info fields]
    if {[dict exists $f x-essential] && [::kit::truthy [dict get $f x-essential]]} { return 1 }
    foreach n [::kit::cfgAll essential] { if {[dict get $info name] in $n} { return 1 } }
    return 0
}

# The Name= of a kit's launcher entry, from the desktop file store::Exports exported for it (U03n): the name
# the updates panel and the CLI rows show.  "" when the kit has none (a library, or no desktop effect).
proc ::kit::store::launcherName {root name} {
    if {[catch {::kit::slurp [::kit::path store $root export applications kit-$name.desktop] utf-8} text]} { return "" }
    set in 0
    foreach line [split $text \n] {
        set line [string trimright $line "\r"]
        if {[regexp {^\[(.*)\]$} $line -> group]} { set in [expr {$group eq "Desktop Entry"}] ; continue }
        if {$in && [regexp {^Name=(.*)$} $line -> n] && [string trim $n] ne ""} { return [string trim $n] }
    }
    return ""
}

# ---- the kit index (KIT-FORMAT.md section 6.2: UTF-8 bytes), parsed back into rows -------------
proc ::kit::store::kitIndex {bytes} {
    set text [encoding convertfrom utf-8 $bytes]
    set d [dict create fields {} needs {} provides {} perms {} entries {} effects {} dirs {} files {} links {} image "" requires {} format {1 0} rootmode 493]
    foreach line [split $text \n] {
        if {$line eq ""} continue
        set f [::kit::tsplit $line]
        set tag [lindex $f 0]
        switch -- $tag {
            format { dict set d format [split [lindex $f 1] .] }
            requires { dict set d requires [lindex $f 1] }
            manifest { dict set d fields [lindex $f 1] [lindex $f 2] }
            need { dict lappend d needs [lrange $f 1 2] }
            provide { dict lappend d provides [lrange $f 1 2] }
            perm { dict lappend d perms [lrange $f 1 2] }
            entry { dict lappend d entries [lrange $f 1 4] }
            effect { dict lappend d effects [lrange $f 1 2] }
            rootdir { dict set d rootmode [lindex $f 1] }
            dir { dict lappend d dirs [lrange $f 1 2] }
            file { dict lappend d files [lrange $f 1 7] }
            link { dict lappend d links [lrange $f 1 4] }
            image { dict set d image [lrange $f 1 end] }
        }
    }
    return $d
}

# Every blob a kit is made of: {hash ...} (chunks, classic files, the header).
proc ::kit::store::blobs {ki st} {
    set out {}
    foreach f [dict get $ki files] {
        set hs [lindex $f 6]
        if {$hs ne ""} { lappend out {*}[split $hs ,] }
    }
    if {[dict get $st header] > 0} { lappend out [dict get $st headerHash] }
    return [lsort -unique $out]
}

# hash -> root, for every installed kit (its chunks can be reused without fetching them again).
proc ::kit::store::chunkMap {} {
    variable chunkMap
    if {$chunkMap ne ""} { return $chunkMap }
    set chunkMap [dict create]
    foreach d [glob -nocomplain -directory [::kit::path store] -type d *] {
        set root [file tail $d]
        if {![file isfile $d/kit] || [catch {::kit::repo::bundleParse [::kit::slurp $d/manifest]} b]} continue
        ::kit::kitfmt
        if {[catch {::kitfmt::ParseStatement [dict get $b statement]} st]} continue
        foreach h [blobs [kitIndex [dict get $b index]] $st] { dict set chunkMap $h $root }
    }
    return $chunkMap
}

# Which of these blobs are neither in the chunk cache nor in an installed kit.
proc ::kit::store::missing {hashes} {
    set m [chunkMap]
    return [lmap h $hashes { if {[dict exists $m $h] || [file exists [::kit::repo::chunkPath $h]]} continue ; set h }]
}

# The stored bytes of a blob: from the chunk cache, else out of an installed kit.  The result is
# checked again as a whole when the new kit is verified, before anything is switched.
proc ::kit::store::blob {h} {
    set f [::kit::repo::chunkPath $h]
    if {[file exists $f]} { return [::kit::slurp $f] }
    set m [chunkMap]
    if {![dict exists $m $h]} { ::kit::fail 3 "chunk $h is not stored here" }
    set root [dict get $m $h]
    set k [kitOpen $root]
    if {$h eq [dict get $::kitfmt::H($k,frame) st headerHash]} {
        return [::kitfmt::ReadAt [::kit::path store $root kit] 0 [dict get $::kitfmt::H($k,frame) st header]]
    }
    # kitfmt has no call for a chunk's stored bytes; its entry rows are the reference reader's own
    dict for {p e} $::kitfmt::H($k,entries) {
        if {[dict get $e type] ne "file"} continue
        if {[dict get $e codec] eq "classic"} {
            if {[dict get $e hash] eq $h} { return [mk::get [dict get $e row] contents] }
            continue
        }
        set i [lsearch -exact [dict get $e hashes] $h]
        if {$i >= 0} { return [mk::get [dict get $e row].chunks!$i z] }
    }
    ::kit::fail 4 "chunk $h is not where the installed kit's manifest says"
}

# An installed kit, opened once per process (read-only).
proc ::kit::store::kitOpen {root} {
    variable kitHandles
    if {[::info exists kitHandles($root)]} { return $kitHandles($root) }
    ::kit::kitfmt
    set kitHandles($root) [::kitfmt open [::kit::path store $root kit] -force 1]
    return $kitHandles($root)
}
proc ::kit::store::closeAll {} {
    variable kitHandles
    foreach {r h} [array get kitHandles] { catch {::kitfmt close $h} }
    array unset kitHandles
}

# ---- writing a kit file from its manifest and its chunks ---------------------------------------
# The store written here has exactly the rows of the signed index, so it rebuilds to the same root
# and the publisher's statement and signature seal it unchanged.
proc ::kit::store::assemble {b out} {
    ::kit::kitfmt ; ::kit::mk4
    set st [::kitfmt::ParseStatement [dict get $b statement]]
    set ki [kitIndex [dict get $b index]]
    # app kits carry files in chunks and are assembled from them; a kit with an embedded image (a system kit, D58 B)
    # is fetched whole instead (system.tcl fetch), never assembled
    if {[dict get $ki image] ne ""} { ::kit::fail 2 "[dict get $st name]: a kit with an embedded image is fetched whole (kitd), not assembled from chunks" }
    set tmp $out.store
    file delete -force $tmp
    mk::file open w $tmp
    set rc [catch {
        mk::view layout w.kit {format:S major:I minor:I requires:S writer:S}
        mk::view layout w.manifest {key:S value:S}
        mk::view layout w.needs {name:S range:S}
        mk::view layout w.provides {name:S version:S}
        mk::view layout w.perms {name:S value:S}
        mk::view layout w.entries {name:S path:S args:S type:S}
        mk::view layout w.effects {type:S value:S}
        mk::view layout w.dirs {name:S parent:I mode:I {files {name:S size:I date:I contents:B mode:I link:S fsize:L codec:S csize:I hash:S {chunks {z:B hash:S}}}}}
        mk::view layout w.image {fs:S len:L pad:I seg:I verity:S salt:S {segs {hash:S}} data:B}
        lassign [dict get $ki format] major minor
        mk::row append w.kit format ribbon-kit major $major minor $minor requires [dict get $ki requires] writer "kit $::kit::version"
        dict for {k v} [dict get $ki fields] { mk::row append w.manifest key $k value $v }
        foreach {v cols} {needs {name range} provides {name version} perms {name value} entries {name path args type} effects {type value}} {
            foreach r [dict get $ki $v] {
                set row {}
                foreach c $cols x $r { lappend row $c $x }
                mk::row append w.$v {*}$row
            }
        }
        mk::row append w.dirs name <root> parent -1 mode [dict get $ki rootmode]
        set drow [dict create "" 0]
        set n 0
        foreach d [lsort -command ::kit::store::BytesCmp [dict get $ki dirs]] {
            lassign $d p mode
            set k [string last / $p]
            set parent [dict get $drow [expr {$k < 0 ? "" : [string range $p 0 [expr {$k - 1}]]}]]
            mk::row append w.dirs name [string range $p [expr {$k + 1}] end] parent $parent mode $mode
            dict set drow $p [incr n]
        }
        set pending 0
        foreach f [dict get $ki files] {
            lassign $f p mode date fsize codec csize hs
            set k [string last / $p]
            set parent [dict get $drow [expr {$k < 0 ? "" : [string range $p 0 [expr {$k - 1}]]}]]
            set name [string range $p [expr {$k + 1}] end]
            set size [expr {$fsize > 0x7fffffff ? -1 : $fsize}]
            if {$codec eq "classic"} {
                set row [mk::row append w.dirs!$parent.files name $name size $size date $date mode $mode link "" \
                    fsize $fsize codec classic csize 0 hash $hs]
                set z [blob $hs]
                mk::set $row contents $z
                incr pending [string length $z]
            } else {
                set row [mk::row append w.dirs!$parent.files name $name size $size date $date mode $mode link "" \
                    fsize $fsize codec $codec csize $csize hash ""]
                if {$hs ne ""} {
                    foreach h [split $hs ,] {
                        set z [blob $h]
                        mk::row append $row.chunks z $z hash $h
                        incr pending [string length $z]
                        if {$pending > 268435456} { mk::file commit w ; set pending 0 }
                    }
                }
            }
        }
        foreach l [dict get $ki links] {
            lassign $l p mode date target
            set k [string last / $p]
            set parent [dict get $drow [expr {$k < 0 ? "" : [string range $p 0 [expr {$k - 1}]]}]]
            mk::row append w.dirs!$parent.files name [string range $p [expr {$k + 1}] end] size 0 date $date mode $mode \
                link $target fsize 0 codec "" csize 0 hash ""
        }
        mk::file commit w
    } err opts]
    mk::file close w
    if {$rc} { file delete -force $tmp ; return -options $opts $err }
    set header [expr {[dict get $st header] > 0 ? [blob [dict get $st headerHash]] : ""}]
    set body [dict get $b statement][dict get $b signature]
    set B 4096
    while {[string length $body] + 32 > $B} { incr B 512 }
    set seal $body[string repeat \x00 [expr {$B - 32 - [string length $body]}]]
    append seal KITSEAL\x1a [binary format IIIIII 1 $B [string length [dict get $b statement]] \
        [string length [dict get $b signature]] [zlib crc32 $body] 0]
    set o [::open $out {WRONLY CREAT TRUNC}]
    fconfigure $o -translation binary
    puts -nonewline $o $header$seal
    set in [::open $tmp rb]
    fcopy $in $o
    close $in
    close $o
    file delete $tmp
}
proc ::kit::store::BytesCmp {a b} {
    return [string compare [encoding convertto utf-8 [lindex $a 0]] [encoding convertto utf-8 [lindex $b 0]]]
}

# A manifest made from a .kit file (for kits grabbed from a file), as kitindex writes them.
proc ::kit::store::bundleOf {h} {
    set fr $::kitfmt::H($h,frame)
    set sizes [dict create]
    foreach p [::kitfmt walk $h] {
        if {[dict get [::kitfmt stat $h $p] type] ne "file"} continue
        foreach c [::kitfmt chunks $h $p] { dict set sizes [lindex $c 2] [lindex $c 1] }
    }
    set st [dict get $fr st]
    if {[dict get $st header] > 0} { dict set sizes [dict get $st headerHash] [dict get $st header] }
    # the index is kept as the UTF-8 bytes the root is the hash of
    return [dict create statement [dict get $fr statement] signature [dict get $fr signature] \
        index [encoding convertto utf-8 [::kitfmt index $h]] sizes $sizes]
}

# ---- staging one kit version into the store --------------------------------------------------
# dir is a fresh directory under staging/; kitfile is the .kit already in it.  Opens and verifies
# it completely (signature by policy, root, every chunk), then writes manifest, info and exports.
proc ::kit::store::stage {dir b origin} {
    ::kit::kitfmt
    set h [::kitfmt open $dir/kit]
    set rc [catch {
        set inf [::kitfmt info $h]
        set sig [dict get $inf signature]
        if {![::kit::sigAcceptable [dict get $sig state]]} {
            ::kit::fail 4 "[dict get $inf name] [dict get $inf version]: the kit's signature is [dict get $sig state] ([dict get $sig detail])"
        }
        set v [::kitfmt verify $h]
        if {![dict get $v ok]} {
            set first [lindex [dict get $v bad] 0]
            ::kit::fail 4 "[dict get $inf name] [dict get $inf version] failed verification: [lindex $first 0] [lindex $first 2]"
        }
        set m [::kitfmt manifest $h]
        set f [dict get $m fields]
        if {$b eq ""} { set b [bundleOf $h] }
        ::kit::spit $dir/manifest [::kit::repo::bundleText $b] binary
        set short [::kit::shortOf [dict get $f name] [expr {[dict exists $f x-short] ? [dict get $f x-short] : ""}]]
        # a system kit's desktop, icon, mime, font and dbus files are in its image, so in /usr with the view: none exported
        set exports [expr {[systemScope] ? {} : [Exports $h $dir [dict get $f name] [dict get $m effects]]}]
        set d [dict create name [dict get $f name] version [dict get $f version] kind [dict get $f kind] short $short \
            summary [expr {[dict exists $f summary] ? [dict get $f summary] : ""}] size [dict get $inf bytes] \
            fields $f needs [dict get $m needs] provides [dict get $m provides] perms [dict get $m perms] \
            entries [dict get $m entries] effects [dict get $m effects] exports $exports \
            signer [dict create state [dict get $sig state] keyid [dict get $sig keyid] comment [dict get $sig comment]] \
            origin $origin installed [::kit::now] root [dict get $inf root]]
        ::kit::spit $dir/info $d
    } err opts]
    ::kitfmt close $h
    if {$rc} { return -options $opts $err }
    return $d
}

# The launcher entry and the other app effects, ready to be linked in (D: no install scripts:
# kit itself applies declared effects).
proc ::kit::store::Exports {h dir name effects} {
    set out {}
    set icon ""
    foreach e $effects {
        lassign $e type value
        if {$type eq "icon" && ![catch {::kitfmt read $h $value} data]} {
            set icon $dir/export/icon[file extension $value]
            ::kit::spit $icon $data binary
        }
    }
    foreach e $effects {
        lassign $e type value
        switch -- $type {
            icon { }
            desktop - dbus {
                if {[catch {::kitfmt read $h $value} data]} { ::kit::fail 4 "$name: its $type file $value is missing" }
                set rel [expr {$type eq "desktop" ? "applications/kit-$name.desktop" : "dbus-1/services/kit-$name-[file tail $value]"}]
                ::kit::spit $dir/export/$rel [Rewrite [encoding convertfrom utf-8 $data] $name $icon]
                lappend out $rel
            }
            mime - font {
                if {[catch {::kitfmt read $h $value} data]} { ::kit::fail 4 "$name: its $type file $value is missing" }
                set rel [expr {$type eq "mime" ? "mime/packages/kit-$name-[file tail $value]" : "fonts/kit-$name/[file tail $value]"}]
                ::kit::spit $dir/export/$rel $data binary
                lappend out $rel
            }
            default { ::kit::system::effect $name $type $value }
        }
    }
    return $out
}

# Exec= lines start the kit through `kit run` (so the launcher, the dock and D-Bus all start the
# installed version); Icon= points at the exported icon.
proc ::kit::store::Rewrite {text name icon} {
    set out {}
    foreach line [split $text \n] {
        if {[regexp {^Exec=\S+(.*)$} $line -> rest]} {
            set line "Exec=[::kit::selfCmd] run $name$rest"
        } elseif {[string match TryExec=* $line]} {
            continue
        } elseif {$icon ne "" && [string match Icon=* $line]} {
            set line "Icon=$icon"
        }
        lappend out $line
    }
    return [join $out \n]
}

# ---- after a switch: exports in place, garbage collected ------------------------------------------
# kitd's system scope (system.tcl scope): XDG data is ROOT/usr/share, the read-only /usr view
proc ::kit::store::systemScope {} { expr {[info exists ::kit::system::scope] && $::kit::system::scope eq "system"} }

proc ::kit::store::syncExports {A} {
    # system kits export nothing (their files are in the view); kit-* files there would be in the read-only view
    if {[systemScope]} return
    set want [dict create]
    dict for {key k} [dict get $A kits] {
        if {[dict get $k reason] eq "prev"} continue
        set l [live $A [dict get $k name]]
        if {[dict get $l root] ne [dict get $k root]} continue
        foreach rel [dict get [kinfo [dict get $k root]] exports] {
            dict set want $rel [::kit::path store [dict get $k root] export $rel]
        }
    }
    set base [::kit::path xdgdata]
    set changedMime 0
    # what kit put there before: everything named kit-*
    foreach pat {applications/kit-*.desktop dbus-1/services/kit-* mime/packages/kit-* fonts/kit-*/*} {
        foreach f [glob -nocomplain -directory $base $pat] {
            set rel [string range $f [expr {[string length $base] + 1}] end]
            if {![dict exists $want $rel]} {
                file delete $f
                if {[string match mime/* $rel]} { set changedMime 1 }
                if {[string match fonts/* $rel]} { catch {file delete [file dirname $f]} }
            }
        }
    }
    dict for {rel src} $want {
        set dst $base/$rel
        if {[file exists $dst] && [file size $dst] == [file size $src] && [::kit::slurp $dst] eq [::kit::slurp $src]} continue
        file mkdir [file dirname $dst]
        file copy -force $src $dst.tmp[pid]
        file rename -force $dst.tmp[pid] $dst
        if {[string match mime/* $rel]} { set changedMime 1 }
    }
    if {$changedMime && [auto_execok update-mime-database] ne ""} { catch {exec update-mime-database $base/mime 2>@1} }
}

# Roots kept: every line of the set (prev included), anything running, and the given extra ones.
proc ::kit::store::gc {A {keep {}}} {
    set live [dict create]
    foreach r $keep { dict set live $r 1 }
    dict for {key k} [dict get $A kits] { dict set live [dict get $k root] 1 }
    foreach r [running] { dict set live $r 1 }
    # what the changes nearest the history cursor replaced, so kit rewind can put it back without a download
    if {[llength [info commands ::kit::txn::historyRoots]]} { foreach r [::kit::txn::historyRoots] { dict set live $r 1 } }
    foreach d [glob -nocomplain -directory [::kit::path store] *] {
        if {![dict exists $live [file tail $d]]} {
            catch {file attributes $d -permissions 0700}
            Rmtree $d
        }
    }
    # chunks now inside installed kits (or 30 days old) are no longer needed in the cache
    variable chunkMap
    set chunkMap ""
    set m [chunkMap]
    set old [expr {[::kit::now] - 30 * 86400}]
    foreach f [glob -nocomplain -directory [::kit::path cache chunks] -type f */*] {
        set h [file tail $f]
        if {[file tail [file dirname $f]] eq "tmp"} {
            if {![regexp {^([0-9]+)-} $h -> p] || ![::kit::pidAlive $p]} { catch {file delete $f} }
        } elseif {[dict exists $m $h] || [file mtime $f] < $old} { catch {file delete $f} }
    }
}

# Remove a directory tree (a store entry, staging, a data directory), making read-only directories
# writable first.
proc ::kit::store::Rmtree {d} {
    if {[catch {file delete -force $d}]} {
        catch {exec chmod -R u+rwx $d}
        catch {file delete -force $d}
    }
}

# Roots in use by running launches (data/running/<root>.<pid>), dead ones cleaned up.
proc ::kit::store::running {} {
    set out {}
    foreach f [glob -nocomplain -directory [::kit::path running] *] {
        if {[regexp {^([0-9a-f]{64})\.([0-9]+)$} [file tail $f] -> r p] && [::kit::pidAlive $p]} { lappend out $r } else { catch {file delete $f} }
    }
    return $out
}
