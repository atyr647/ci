# tests/kit-keyholder.tcl -- who holds a signing key among kit's trusted key lists (srcpkgs/ribbon-kit/files/lib/core.tcl
# ::kit::keyHolder, ::kit::keyList) and the names readers give a signer from them: Properties (properties/kitlink.tcl
# kitlink::trust) and the Catalogue (apps/catalogue/kitq.tcl signer).  Ribbon's list and another repository's, made
# with kittrust's kitkey and the test-only keys; no Mk4tcl needed.
#   tclsh8.6 -encoding utf-8 tests/kit-keyholder.tcl
set top [file dirname [file dirname [file normalize [info script]]]]
set KT $top/kit/kittrust
set F $top/tests/fixtures/kittrust
set tclsh [info nameofexecutable]
encoding system utf-8
fconfigure stdout -encoding utf-8
set fails 0
proc ok {name cond {detail ""}} {
    if {$cond} { puts "  ok   $name" } else { puts "  FAIL $name" ; if {$detail ne ""} { puts "       [string range $detail 0 1500]" } ; incr ::fails }
}
proc spit {p d} { file mkdir [file dirname $p] ; set f [open $p w] ; fconfigure $f -translation binary ; puts -nonewline $f [encoding convertto utf-8 $d] ; close $f }
proc tool {args} { if {[catch {exec {*}$args 2>@1} out]} { error "$args: $out" } ; return $out }
if {[auto_execok minisign] eq ""} { puts "  skip the key holder (no minisign)" ; exit 0 }

set W [file normalize [exec mktemp -d]]
set env(HOME) $W/home
file mkdir $W/home
foreach v {XDG_DATA_HOME XDG_CACHE_HOME XDG_CONFIG_HOME KIT_LIB} { unset -nocomplain env($v) }
set L $W/keys/trusted-keys
file mkdir $W/keys
tool $tclsh $KT/kitkey init -repository org.ribbon.main -root $F/test-root.pub $L
tool $tclsh $KT/kitkey add -role app -from -30d -name "Ribbon test app key" $L $F/test-app.pub
tool $tclsh $KT/kitkey sign -key $F/test-root.key $L
set R $W/repos.d
tool $tclsh $KT/kitkey init -repository com.example.other -root $F/test-root2.pub $W/other.keys
tool $tclsh $KT/kitkey add -role app -from -30d -name "Example Apps key" $W/other.keys $F/test-other.pub
# the other repository's list also copies Ribbon's app key under another name: Ribbon's list still names it
tool $tclsh $KT/kitkey add -role app -from -30d -name "A copy" $W/other.keys $F/test-app.pub
tool $tclsh $KT/kitkey sign -key $F/test-root2.key $W/other.keys
file mkdir $R
file copy $W/other.keys $R/com.example.other.keys
file copy $W/other.keys.minisig $R/com.example.other.keys.minisig
spit $R/com.example.other.conf "# a test repository\n"
spit $W/kit.conf "keys = $L\nrepos = $R\n"
set env(KIT_CONF) $W/kit.conf

# kit's library as Properties loads it (kitlink::load: core and the verbs' modules, once)
namespace eval facts { proc desktop_parse {t} { return {} } }
set ::appdir $top/srcpkgs/ribbon-desktop/files/properties
source -encoding utf-8 $::appdir/kitlink.tcl
ok "Properties loads kit's library" [kitlink::load] $kitlink::why
::kit::kitfmt
proc kid {pub} { return [::kitfmt::PubKeyId [lindex [split [string trim [tool cat $pub]] \n] end]] }
set app [kid $F/test-app.pub] ; set other [kid $F/test-other.pub] ; set none [kid $F/test-index2.pub]
ok "keyHolder: Ribbon's own key is held by Ribbon's list first, then the list that copies it" [expr {[::kit::keyHolder $app] eq {org.ribbon.main com.example.other}}] [::kit::keyHolder $app]
ok "keyHolder: another repository's key, by that repository's list" [expr {[::kit::keyHolder $other] eq {com.example.other}}] [::kit::keyHolder $other]
ok "keyHolder: a key in no list, by none" [expr {[::kit::keyHolder $none] eq {}}]
ok "keyList: each repository's list by its id" [expr {[dict get [::kit::keyList com.example.other] repository] eq "com.example.other" && [dict get [::kit::keyList org.ribbon.main] repository] eq "org.ribbon.main" && [::kit::keyList org.example.none] eq ""}]

# Properties: the signer named from the list that holds the key
set t [kitlink::trust $other]
ok "Properties names a signer from another repository's list (its name, roles, repository)" \
    [expr {[dict size $t] && [dict get $t name] eq "Example Apps key" && [dict get $t repository] eq "com.example.other" && [dict get $t keyroles] eq "app"}] $t
set t [kitlink::trust $app]
ok "... and Ribbon's key by Ribbon's list, whatever another list calls it" [expr {[dict get $t name] eq "Ribbon test app key" && [dict get $t repository] eq "org.ribbon.main"}] $t
ok "... and nothing for a key no list holds" [expr {[kitlink::trust $none] eq {}}]

# the Catalogue's signer (kitq.tcl info), in a process of its own
set q [tool $tclsh -encoding utf-8 << "
    set argv {} ; set argc 0
    source -encoding utf-8 $top/srcpkgs/ribbon-kit/files/lib/core.tcl
    ::kit::init
    set src \[read \[open $top/srcpkgs/ribbon-desktop/files/apps/catalogue/kitq.tcl\]\]
    regexp {proc signer \\{keyid\\} \\{.*?\\n\\}\\n} \$src body
    eval \$body
    puts \[signer $other\]
"]
ok "the Catalogue names the other repository's signer too" [expr {[dict get $q name] eq "Example Apps key"}] $q

file delete -force $W
if {$fails} { puts "kit key holder: $fails checks failed" ; exit 1 }
puts "kit key holder: all checks passed"
