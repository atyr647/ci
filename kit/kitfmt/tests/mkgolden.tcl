# mkgolden.tcl -- (re)make the golden test kits in tests/golden/ and their .expect files.
#
#   KITFMT_MK4TCL=<dir with Mk4tcl> tclsh tests/mkgolden.tcl
#
# Needs: Mk4tcl, minisign, mkfs.erofs, veritysetup, and kithelper built with libdeflate (helper/),
# so that every golden kit is written the way production kits are (libdeflate level 12).  The test
# suite itself needs none of them: it reads the committed kits.  The output is reproducible: the
# same tools give the same bytes (fixed dates, sorted names, deterministic salts and signatures).
#
# Valid kits:  app.kit (signed), app-header.kit (starkit header in front, unsigned), system.kit
#              (embedded erofs image, verity root, signed).
# Damaged:     bad-chunk, bad-root, bad-signature, bad-image, truncated, wrong-version,
#              unknown-feature, bad-name: each must be refused as its .expect says.

set here [file dirname [file normalize [info script]]]
encoding system utf-8
set top [file dirname $here]
set gold $here/golden
if {[info exists env(KITFMT_MK4TCL)]} { lappend auto_path $env(KITFMT_MK4TCL) }
lappend auto_path $top
package require Mk4tcl
package require kitfmt

proc die {m} { puts stderr "mkgolden: $m" ; exit 1 }
foreach t {minisign mkfs.erofs veritysetup} { if {[auto_execok $t] eq ""} { die "$t is needed to make the golden kits" } }
if {[catch {exec $top/helper/kithelper version} v] || ![string match "* zlib*" $v]} { die "build helper/kithelper with libdeflate first (make -C helper)" }

set work [::kitfmt::TempDir]
proc spit {path data {mode ""}} {
    file mkdir [file dirname $path]
    set ch [open $path {WRONLY CREAT TRUNC}] ; fconfigure $ch -translation binary ; puts -nonewline $ch $data ; close $ch
    if {$mode ne ""} { file attributes $path -permissions $mode }
}
proc slurp {path} { set ch [open $path rb] ; set d [read $ch] ; close $ch ; return $d }

# a 16x16 PNG, written by hand (no Tk needed): a blue-orange gradient
proc png16 {} {
    set raw ""
    for {set y 0} {$y < 16} {incr y} {
        append raw \x00
        for {set x 0} {$x < 16} {incr x} { append raw [binary format ccc [expr {$x * 16}] [expr {96 + $y * 8}] [expr {255 - $x * 12}]] }
    }
    set chunk {apply {{type data} { return [binary format I [string length $data]]$type$data[binary format I [zlib crc32 $type$data]] }}}
    return "\x89PNG\r\n\x1a\n[{*}$chunk IHDR [binary format IIccccc 16 16 8 2 0 0 0]][{*}$chunk IDAT [zlib compress $raw 9]][{*}$chunk IEND {}]"
}

# ---- the app payload ---------------------------------------------------------------------
set src $work/app
set text ""
for {set i 1} {$i <= 1400} {incr i} { append text "line $i of the golden kit: [expr {($i * 7919) % 10007}]\n" }
spit $src/bin/hello "#!/bin/sh\necho hello from a kit\n" 493
spit $src/lib/big.txt $text 420
set rnd "" ; set x 12345
for {set i 0} {$i < 3000} {incr i} { set x [expr {($x * 1103515245 + 12345) & 0x7fffffff}] ; append rnd [binary format c [expr {$x >> 16}]] }
spit $src/lib/noise.bin $rnd 420
spit $src/share/icons/hello.png [png16] 420
spit $src/share/applications/hello.desktop "\[Desktop Entry\]\nName=Hello\nExec=hello\nIcon=hello\n" 420
spit $src/main.tcl "# the Tcl side of the kit: classic, so a stock tclkit can run it\nputs {hello from main.tcl}\n" 420
spit $src/empty "" 420
spit "$src/docs/r\u00e9sum\u00e9.txt" "A name that is not ASCII.\n" 420
file link -symbolic $src/lib/hello-link ../bin/hello
foreach d [list $src $src/bin $src/lib $src/share $src/share/icons $src/share/applications $src/docs] { file attributes $d -permissions 493 }
spit $work/app.manifest {
    name org.ribbon.golden.app  version 1.2.0  kind app
    summary {Golden test kit (app)}  publisher {Ribbon tests}  license MIT
    needs    {{org.ribbon.runtime.tcl >=8.6} {org.ribbon.runtime.tk >=8.6}}
    provides {{golden-api 1}}
    perms    {network no  home none  display wayland  folders {Documents ro}}
    entries  {{hello bin/hello {} app} {main main.tcl {} cli}}
    effects  {{desktop share/applications/hello.desktop} {icon share/icons/hello.png}}
}
spit $work/header.sh "#!/bin/sh\n# a starkit header: the kit runs under a tclkit\nexec tclkit \"\$0\" \"\$@\"\n"

# ---- the system payload: a tiny erofs image ---------------------------------------------------
set isrc $work/imgsrc
spit $isrc/etc/os-release "NAME=Ribbon\nID=ribbon\n" 420
set mods "" ; for {set i 0} {$i < 400} {incr i} { append mods "kernel/drivers/golden$i.ko\n" }
spit $isrc/lib/modules/modules.order $mods 420
foreach d [list $isrc $isrc/etc $isrc/lib $isrc/lib/modules] { file attributes $d -permissions 493 }
exec mkfs.erofs -T 1700000000 --all-root -U 00000000-0000-0000-0000-00000000c0de $work/base.erofs $isrc 2>@1
spit $work/ssrc/share/doc/README "The system kit's own files: its image is the payload.\n" 420
foreach d [list $work/ssrc $work/ssrc/share $work/ssrc/share/doc] { file attributes $d -permissions 493 }
spit $work/system.manifest {
    name org.ribbon.golden.base  version 2026.11.1  kind system  summary {Golden test kit (system)}  license MIT
    needs {{org.ribbon.kernel >=6.12}}
    effects {{module lib/modules} {service share/doc/README}}
}

# ---- packing --------------------------------------------------------------------------------
set KEY $here/keys/test.key
set common [list -date 1700000000 -chunk 16384 -level 12 -deflate helper -classic main.tcl -q]
proc pack {out srcdir manifest args} {
    global top common
    file delete -force $out
    exec [info nameofexecutable] $top/kitpack {*}$common -manifest $manifest {*}$args $srcdir $out 2>@1
}
file mkdir $gold
foreach f [glob -nocomplain -directory $gold *] { file delete $f }
pack $gold/app.kit $src $work/app.manifest -sign $KEY
pack $gold/app-header.kit $src $work/app.manifest -header $work/header.sh
pack $gold/system.kit $work/ssrc $work/system.manifest -image $work/base.erofs -verity yes -sign $KEY
pack $gold/wrong-version.kit $src $work/app.manifest -x-format 2.0
pack $gold/unknown-feature.kit $src $work/app.manifest -x-requires frobnicate
pack $gold/bad-name.kit $src $work/app.manifest -x-rename lib/noise.bin=..

# ---- damage ---------------------------------------------------------------------------------
proc patchAt {path off bytes} {
    set ch [open $path r+] ; fconfigure $ch -translation binary ; seek $ch $off ; puts -nonewline $ch $bytes ; close $ch
}
# rewrite the seal's statement/signature in place, with a correct checksum (so only what we mean is wrong)
proc reseal {path stmtMap sigMap} {
    set fr [::kitfmt::Frame $path]
    set stmt [string map $stmtMap [dict get $fr statement]]
    set sig [string map $sigMap [dict get $fr signature]]
    if {[string length $stmt] != [string length [dict get $fr statement]] || [string length $sig] != [string length [dict get $fr signature]]} { die "reseal must keep lengths" }
    patchAt $path [dict get $fr sealStart] $stmt$sig
    patchAt $path [expr {[dict get $fr storeStart] - 8}] [binary format I [zlib crc32 $stmt$sig]]
}
# a chunk's bytes, found in the file
proc chunkOffset {kit path i} {
    set h [kitfmt open $kit]
    set e [dict get $::kitfmt::H($h,entries) $path]
    set z [mk::get [dict get $e row].chunks!$i z]
    kitfmt close $h
    set at [string first $z [slurp $kit]]
    if {$at < 0} { die "chunk $i of $path not found in $kit" }
    return [list $at [string length $z]]
}
proc flip {path off} {
    set ch [open $path r+] ; fconfigure $ch -translation binary ; seek $ch $off ; set b [read $ch 1]
    seek $ch $off ; puts -nonewline $ch [binary format c [expr {([scan $b %c] ^ 0x5a) & 0xff}]] ; close $ch
}
file copy $gold/app.kit $gold/bad-chunk.kit
lassign [chunkOffset $gold/bad-chunk.kit lib/big.txt 1] at n
flip $gold/bad-chunk.kit [expr {$at + $n / 2}]

file copy $gold/app.kit $gold/bad-root.kit
set root [dict get [::kitfmt::Frame $gold/app.kit] st root]
set badroot [string map {0 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 a a b b c c d d e e f f 0} [string index $root 0]][string range $root 1 end]
reseal $gold/bad-root.kit [list "root $root" "root $badroot"] {}

file copy $gold/app.kit $gold/bad-signature.kit
set sig [dict get [::kitfmt::Frame $gold/app.kit] signature]
set line [lindex [split $sig \n] 1]
set pos 40
set c [string index $line $pos]
set newline [string replace $line $pos $pos [expr {$c eq "A" ? "B" : "A"}]]
reseal $gold/bad-signature.kit {} [list $line $newline]

file copy $gold/system.kit $gold/bad-image.kit
set off [dict get [dict get [::kitfmt::Frame $gold/system.kit] st] image offset]
flip $gold/bad-image.kit [expr {$off + 1024 + 100}]

file copy $gold/app.kit $gold/truncated.kit
set ch [open $gold/truncated.kit r+] ; chan truncate $ch [expr {[file size $gold/app.kit] * 7 / 10}] ; close $ch

# ---- what readers must see -----------------------------------------------------------------------
kitfmt configure -keys [list [lindex [split [string trim [slurp $here/keys/test.pub]] \n] 1]]
proc expectValid {name} {
    global gold
    set h [kitfmt open $gold/$name]
    set i [kitfmt info $h]
    set out "# $name: what a reader of KIT-FORMAT.md 1.0 must find (signature state with tests/keys/test.pub trusted)\n"
    append out "open ok\n"
    foreach k {kind name version root header entries chunks stored bytes} { append out "$k [dict get $i $k]\n" }
    append out "format [join [dict get $i format] .]\n"
    append out "requires [dict get $i requires]\n"
    append out "signature [dict get $i signature state] [dict get $i signature keyid]\n"
    set im [kitfmt image $h]
    if {$im ne ""} { append out "image [dict get $im fs] [dict get $im offset] [dict get $im length] [dict get $im verity] [dict get $im salt]\n" }
    foreach p [kitfmt walk $h] {
        set s [kitfmt stat $h $p]
        switch -- [dict get $s type] {
            dir { append out [list entry $p dir [dict get $s mode]]\n }
            link { append out [list entry $p link [dict get $s mode] [dict get $s link]]\n }
            file { append out [list entry $p file [dict get $s mode] [dict get $s size] [dict get $s codec] [dict get $s chunks] [dict get $s stored] [::kitfmt::Hash [kitfmt read $h $p]]]\n }
        }
    }
    set v [kitfmt verify $h]
    append out "verify ok [dict get $v ok] image [dict get $v image]\n"
    spit $gold/[file rootname $name].index [encoding convertto utf-8 [kitfmt index $h]]
    kitfmt close $h
    spit $gold/[file rootname $name].expect [encoding convertto utf-8 $out]
}
foreach k {app.kit app-header.kit system.kit} { expectValid $k }
array set damaged {
    bad-chunk.kit     "open ok\nverify fail lib/big.txt 1\nread lib/big.txt HASH\n"
    bad-root.kit      "open fail ROOT\nopen-force ok\nverify fail root\nsignature invalid\n"
    bad-signature.kit "open ok\nsignature invalid\nopen-signed fail SIGNATURE\n"
    bad-image.kit     "open ok\nverify fail image\n"
    truncated.kit     "open fail TRUNCATED\nprobe kit 0\n"
    wrong-version.kit "open fail VERSION\n"
    unknown-feature.kit "open fail FEATURE\n"
    bad-name.kit      "open fail PATH\n"
}
foreach k [lsort [array names damaged]] {
    spit $gold/[file rootname $k].expect "# $k: damaged on purpose; every reader must refuse it as follows\n$damaged($k)"
}
file delete -force $work
set total 0
foreach f [glob -directory $gold *.kit] { incr total [file size $f] }
puts "golden kits written to $gold ([llength [glob -directory $gold *.kit]] kits, $total bytes)"
