# kit-cli.tcl -- end-to-end tests of the kit command (docs/KIT-CLI.md), run by tests/run.sh.
#
#   KITFMT_MK4TCL=<dir with Mk4tcl> tclsh8.6 -encoding utf-8 tests/kit-cli.tcl
#
# Builds kits with `kit pack` (signed with kittrust's test-only app key, tests/fixtures/kittrust),
# publishes them with kittrust's kitindex into repositories served by tests/kit-httpd.tcl (and
# file://), with a root-signed test key list as the trust anchor, and drives
# every verb: install, update, check-then-grab, toss with both data answers, rewind (the last change,
# twice, KIT with its hold, a toss, no, --yes, pruned versions fetched by root), offline and pinned
# indexes, an expired index, a bad chunk and a bad signature with mirror fallback, SIGKILL at every
# step of a transaction followed by recovery, list/info/mend/pack/run, the updater's settings and
# conditions, and the exact prompt texts of the spec.
#
# kit run is served by mkkitfs through FUSE: where /dev/fuse is not writable (or no mkkitfs is on the
# PATH, or mkkitfs's Tcl client can't load unix_sockets) its checks print "skip" by name and nothing else
# changes; KIT_TEST_NOFUSE=1 forces that path.

set top [file dirname [file dirname [file normalize [info script]]]]
set B $top/srcpkgs/ribbon-kit/files/bin
set KIT $B/kit
set tclsh [info nameofexecutable]
encoding system utf-8
fconfigure stdout -encoding utf-8
set fails 0
set nok 0

proc ok {name cond {detail ""}} {
    if {[uplevel 1 [list expr $cond]]} { incr ::nok ; puts "  ok   $name" ; return 1 }
    incr ::fails
    puts "  FAIL $name"
    if {$detail ne ""} { foreach l [split [string trimright $detail] \n] { puts "         | $l" } }
    return 0
}
proc spit {path data {mode ""}} {
    file mkdir [file dirname $path]
    set ch [open $path {WRONLY CREAT TRUNC}] ; fconfigure $ch -translation binary ; puts -nonewline $ch $data ; close $ch
    if {$mode ne ""} { file attributes $path -permissions $mode }
}
proc slurp {path} { set ch [open $path rb] ; set d [read $ch] ; close $ch ; return $d }
proc utf {path} { return [encoding convertfrom utf-8 [slurp $path]] }

set W [file normalize [expr {[info exists env(KIT_TEST_TMP)] ? $env(KIT_TEST_TMP) : [exec mktemp -d]}]]
file mkdir $W
set ::env(KIT_NOSYNC) 1
unset -nocomplain ::env(KIT_INDEX) ::env(KIT_CRASH_AT) ::env(XDG_DATA_HOME) ::env(XDG_CACHE_HOME) ::env(XDG_CONFIG_HOME)
# kit run is served by mkkitfs through FUSE (docs/MKKITFS.md): usable when /dev/fuse is writable, a
# mkkitfs binary is on the PATH (tests/test-mkkitfs.sh builds one) and its Tcl client, this tree's, finds
# unix_sockets (on TCLLIBPATH or installed: tcl-unix-sockets, which mkkitfs depends on).
set fuse [expr {![info exists ::env(KIT_TEST_NOFUSE)] && [file writable /dev/fuse] && [auto_execok mkkitfs] ne ""
    && ![catch {exec [info nameofexecutable] << {exit [catch {package require unix_sockets}]} 2>@1}]}]
if {$fuse} {
    # (the existing TCLLIBPATH is a list of directories itself: its entries stay entries, not one element holding them all)
    set ::env(TCLLIBPATH) [concat [list $top/srcpkgs/mkkitfs/files/tcl] [expr {[info exists ::env(TCLLIBPATH)] ? $::env(TCLLIBPATH) : {}}]]
    file mkdir $W/runtime ; file attributes $W/runtime -permissions 0700
    set ::env(XDG_RUNTIME_DIR) $W/runtime
}

# ---- running kit ----------------------------------------------------------------------------------------
# run ?-in TEXT? ?-env {K V ...}? ?-home DIR? ?-conf FILE? ?-cmd PATH? args -> dict code out err
set ::HOME $W/home
set ::CONF $W/kit.conf
proc run {args} {
    set in "" ; set envs {} ; set home $::HOME ; set conf $::CONF ; set cmd $::KIT
    while {[string index [lindex $args 0] 0] eq "-" && [lindex $args 0] in {-in -env -home -conf -cmd}} {
        set args [lassign $args o v]
        switch -- $o { -in { set in $v } -env { set envs $v } -home { set home $v } -conf { set conf $v } -cmd { set cmd $v } }
    }
    set saved [array get ::env]
    set ::env(HOME) $home
    set ::env(KIT_CONF) $conf
    foreach {k v} $envs { if {$v eq ""} { unset -nocomplain ::env($k) } else { set ::env($k) $v } }
    set errf $::W/stderr.[pid]
    set code 0
    # a hard bound on every call: a hang is a failure (status 124), not a stuck test run
    if {[catch {exec timeout -k 5 120 $::tclsh $cmd {*}$args << $in 2> $errf} out opts]} {
        set ec [dict get $opts -errorcode]
        switch -- [lindex $ec 0] {
            CHILDSTATUS { set code [lindex $ec 2] }
            CHILDKILLED { set code killed }
            default { set code error ; set out "$out\n[dict get $opts -errorinfo]" }
        }
    }
    # (never [array unset ::env]: that drops the link to the real environment)
    foreach k [array names ::env] { if {![dict exists $saved $k]} { unset ::env($k) } }
    dict for {k v} $saved { if {![info exists ::env($k)] || $::env($k) ne $v} { set ::env($k) $v } }
    set err [utf $errf]
    file delete $errf
    return [dict create code $code out $out err $err]
}
proc show {r} { return "exit [dict get $r code]\n--- stdout\n[dict get $r out]\n--- stderr\n[dict get $r err]" }

# ---- keys: kittrust's test-only keys; a root-signed key list made from them for this run ------------------
set F $top/tests/fixtures/kittrust
set KT $top/kit/kittrust
set L $W/keys/trusted-keys
file mkdir $W/keys
proc kittool {tool args} {
    if {[catch {exec $::tclsh $::KT/$tool {*}$args 2>@1} out]} { error "$tool $args: $out" }
    return $out
}
kittool kitkey init -repository org.ribbon.test -root $F/test-root.pub $L
# valid from a month ago, so an index can be made "ten days ago" for the expired-index test
kittool kitkey add -role app -from -30d $L $F/test-app.pub
kittool kitkey add -role index -from -30d $L $F/test-index.pub
kittool kitkey sign -key $F/test-root.key $L
# what clients start from (the base system's /etc/kit/trusted-keys): serial 1; $L moves on later
set ANCHOR $W/keys/anchor
file copy $L $ANCHOR ; file copy $L.minisig $ANCHOR.minisig

# ---- the kits ---------------------------------------------------------------------------------------------
proc text {seed n} {
    set out "" ; set x $seed
    for {set i 0} {$i < $n} {incr i} { set x [expr {($x * 1103515245 + 12345) & 0x7fffffff}] ; append out "row $i [expr {$x % 100000}] [format %08x $x]\n" }
    return $out
}
set BIG [text 7 26000]   ;# ~620 KB: five 128 KiB chunks
# a kit source tree: name short version, its files, its manifest additions
proc kitsrc {dir manifest files} {
    file delete -force $dir
    foreach {p data mode} $files { spit $dir/$p $data $mode }
    spit $dir.manifest $manifest
}
proc pack {dir {key app} {out ""}} {
    set opts [expr {$key eq "" ? {} : [list -sign $::F/test-$key.key]}]
    set r [run -cmd $::KIT pack -q {*}$opts $dir {*}[expr {$out eq "" ? "" : [list $out]}]]
    if {[dict get $r code] != 0} { error "kit pack $dir failed: [show $r]" }
}
set APP {#!/usr/bin/env tclsh8.6
set g "no greeting"
foreach d [split [expr {[info exists env(LD_LIBRARY_PATH)] ? $env(LD_LIBRARY_PATH) : ""}] :] {
    if {[file exists $d/greeting.txt]} { set f [open $d/greeting.txt] ; set g [string trim [read $f]] ; close $f ; break }
}
puts "$env(KIT_NAME) $env(KIT_VERSION) $g [join $argv { }]"
exit [expr {[info exists env(APP_EXIT)] ? $env(APP_EXIT) : 0}]
}
set ICON "\x89PNG\r\n\x1a\nnot a real picture, but a file"
proc firefox {v {bigseed 7}} {
    global W APP BIG
    set big $BIG
    if {$bigseed != 7} { set big [string replace $BIG 200000 200099 [string repeat $bigseed 100]] }
    kitsrc $W/src/firefox-$v "name org.mozilla.firefox version $v kind app summary {The Firefox web browser} x-tags {web browser}
needs {{org.ribbon.test.libgreet {>=1 <2}}}
perms {network yes home ro display wayland}
entries {{firefox bin/firefox {} app}}
effects {{desktop share/applications/firefox.desktop} {icon share/icons/firefox.png}}" \
        [list bin/firefox $APP 493 share/applications/firefox.desktop "\[Desktop Entry\]\nName=Firefox\nExec=firefox %u\nTryExec=firefox\nIcon=firefox\nType=Application\n" 420 \
            share/icons/firefox.png $::ICON 420 share/big.txt $big 420 "share/r\u00e9sum\u00e9.txt" "a name that is not ASCII\n" 420]
    pack $W/src/firefox-$v
}
proc libgreet {v} {
    global W
    kitsrc $W/src/libgreet-$v "name org.ribbon.test.libgreet version $v kind app summary {Grüße, shared}
provides {{greet-api $v}}" [list lib/greeting.txt "greet $v\n" 420]
    pack $W/src/libgreet-$v
}
proc simple {dir manifest {key app}} {
    kitsrc $dir $manifest [list bin/app $::APP 493]
    pack $dir $key
}
file mkdir $W/src
cd $W/src
firefox 134.0.1 ; firefox 134.0.2 8 ; firefox 134.0.3 9 ; firefox 134.0.4 6 ; firefox 134.0.5 5
foreach v {1.0 1.1 1.2 2.0} { libgreet $v }
simple $W/src/obs-31.0.1 "name com.obsproject.obs version 31.0.1 kind app summary {Screen recording and streaming} x-data .config/obs-studio
needs {{org.ribbon.test.libgreet >=1}}
entries {{obs bin/app {} app}}"
simple $W/src/base-1 "name org.ribbon.test.base version 1 kind app summary {The base system (a test stand-in)} x-short base x-essential yes
entries {{base bin/app {} cli}}"
simple $W/src/crashy-1.0 "name org.example.crashy version 1.0 kind app summary {Starts, then not}
entries {{crashy bin/app {} app}}"
kitsrc $W/src/crashy-2.0 "name org.example.crashy version 2.0 kind app summary {Starts, then not}
entries {{crashy bin/app {} app}}" [list bin/app "#!/usr/bin/env tclsh8.6\nputs {crashy 2.0 fails}\nexit 3\n" 493]
pack $W/src/crashy-2.0
kitsrc $W/src/faraway-1 "name org.example.faraway version 1 kind app summary {Never fetched before the network goes}
entries {{faraway bin/app {} app}}" [list bin/app $APP 493 share/own.txt [text 99 3000] 420]
pack $W/src/faraway-1
simple $W/src/needy-1 "name org.example.needy version 1 kind app summary {Needs a library nobody has}
needs {{org.ribbon.test.libgreet >=3}}
entries {{needy bin/app {} app}}"
simple $W/src/hello-1 "name org.example.hello version 1 kind app summary {Hello from a file}
entries {{hello bin/app {} cli}}"
simple $W/src/hello-unsigned "name org.example.unsigned version 1 kind app summary {Nobody signed this}
entries {{unsigned bin/app {} cli}}" ""
simple $W/src/hello-other "name org.example.other version 1 kind app summary {Signed by a key nobody trusts}
entries {{other bin/app {} cli}}" other

# ---- repositories and mirrors -------------------------------------------------------------------------------
# publish ?-security? ?-now WHEN? ?-expires DUR? REPO KIT...: add the kits to REPO's kit directory
# and rebuild its signed index with kitindex (serial + 1)
proc publish {repo args} {
    set opts {} ; set sec 0
    while {[string index [lindex $args 0] 0] eq "-"} {
        set a [lindex $args 0]
        if {$a eq "-security"} { set sec 1 ; set args [lrange $args 1 end] } else { lappend opts {*}[lrange $args 0 1] ; set args [lrange $args 2 end] }
    }
    file mkdir $repo.kits
    foreach k $args {
        file copy -force $k $repo.kits/
        if {$sec} { lappend opts -flag [lindex [split [file tail $k] -] 0]=security }
    }
    set r [run -cmd $::KT/kitindex build -key $::F/test-index.key -keys $::L {*}$opts $repo.kits $repo]
    if {[dict get $r code] != 0} { error "kitindex build failed: [show $r]" }
}
proc kitfile {name v} { return [lindex [glob $::W/src/$name-$v.kit] 0] }
set A $W/mirror-a
publish $A [kitfile org.mozilla.firefox 134.0.1] {*}[lmap v {1.0 1.1} { kitfile org.ribbon.test.libgreet $v }] \
    [kitfile com.obsproject.obs 31.0.1] [kitfile org.ribbon.test.base 1] [kitfile org.example.crashy 1.0] [kitfile org.example.needy 1] [kitfile org.example.faraway 1]
proc serve {dir} {
    set log $::W/log-[file tail $dir]
    spit $log ""
    set ch [open |[list $::tclsh $::top/tests/kit-httpd.tcl $dir $log] r]
    set port [gets $ch]
    lappend ::servers $ch
    return [list http://127.0.0.1:$port $log]
}
set servers {}
proc mirrorCopy {from to} { file delete -force $to ; file copy $from $to }
mirrorCopy $A $W/mirror-b
lassign [serve $A] urlA logA
lassign [serve $W/mirror-b] urlB logB
proc conf {file mirrors args} {
    set t "keys = $::ANCHOR\nessential = org.ribbon.test.base\ntimeout = 5\n"
    foreach m $mirrors { append t "mirror = $m\n" }
    foreach a $args { append t "$a\n" }
    spit $file $t
}
conf $CONF [list $urlA $urlB]
conf $W/dead.conf [list http://127.0.0.1:1]
proc syncB {} { mirrorCopy $::A $::W/mirror-b }
proc logmark {log} { return [llength [split [slurp $log] \n]] }
proc logsince {log mark} { return [lrange [split [string trimright [slurp $log] \n] \n] [expr {$mark - 1}] end] }
proc age {home secs} {
    set f $home/.cache/kit/index.meta
    if {![file exists $f]} return
    set m [utf $f] ; dict set m checked [expr {[clock seconds] - $secs}] ; spit $f [encoding convertto utf-8 $m]
}
proc active {home} { return [utf $home/.local/share/kit/active] }
proc kitline {home name} {
    foreach l [split [active $home] \n] { set f [split $l \t] ; if {[lindex $f 0] eq "kit" && [lindex $f 1] eq $name && [lindex $f 4] ne "prev"} { return $f } }
    return ""
}
proc version {home name} { return [lindex [kitline $home $name] 2] }

puts "kit tests in $W"

# ==== the prompt, exactly as the spec draws it ========================================================
set probe {
    source -encoding utf-8 [file join $lib core.tcl] ; source -encoding utf-8 [file join $lib ui.tcl]
    fconfigure stdout -encoding utf-8
    ::kit::init
    set rows {}
    foreach r $spec { lassign $r name old new action mb tags ; lappend rows [dict create name $name old $old new $new action $action bytes [expr {$mb eq "" ? "" : $mb * 1000000}] tags $tags] }
    set q [expr {$question eq "plan" ? [::kit::ui::question $rows] : $question}]
    ::kit::ui::ask $rows $q $default
}
proc prompt {spec question default answer} {
    set script "set lib $::top/srcpkgs/ribbon-kit/files/lib\nset spec [list $spec]\nset question [list $question]\nset default $default\n$::probe"
    spit $::W/probe.tcl [encoding convertto utf-8 $script]
    return [exec $::tclsh $::W/probe.tcl << $answer]
}
set got [prompt {{firefox 134.0.1 134.0.2 update 12 {}}} plan 1 ""]
ok "prompt: one update (KIT-CLI.md, grab)" {$got eq "  firefox      134.0.1 → 134.0.2     12 MB\nUpdate? \[Y/n\] "} $got
set got [prompt {{firefox 134.0.1 134.0.2 update 12 {}} {obs "" 31.0.1 install 88 {}}} plan 1 ""]
ok "prompt: install 1 and update 1" {$got eq "  firefox      134.0.1 → 134.0.2     12 MB\n  obs          new       31.0.1      88 MB\nInstall 1 and update 1? \[Y/n\] "} $got
set got [prompt {{firefox 134.0.1 134.0.2 update 12 {}} {mk-studio 1.4.0 1.5.0 update 3 {}} {openssl 3.0.13 3.0.14 update 1 security}} plan 1 ""]
ok "prompt: kit check's three updates, security tagged" {$got eq "  firefox      134.0.1 → 134.0.2     12 MB\n  mk-studio    1.4.0   → 1.5.0        3 MB\n  openssl      3.0.13  → 3.0.14       1 MB   security\nUpdate? \[Y/n\] "} $got
set got [prompt {{obs 31.0.1 removed remove "" {}}} "Also remove its data in ~/.config/obs-studio (12 MB)?" 0 ""]
ok "prompt: toss's data question" {$got eq "  obs          31.0.1    removed\nAlso remove its data in ~/.config/obs-studio (12 MB)? \[y/N\] "} $got
set got [prompt {{obs "" 31.0.1 install 88 {}}} plan 1 ""]
ok "prompt: Install?" {[lindex [split $got \n] end] eq "Install? \[Y/n\] "} $got
set got [prompt {{mesa 25.2.6 25.2.7 update 40 restart}} plan 1 ""]
ok "prompt: a system kit says (takes effect at restart)" {[lindex [split $got \n] end] eq "Update? (takes effect at restart) \[Y/n\] "} $got

namespace eval ::kit { variable libdir $top/srcpkgs/ribbon-kit/files/lib }
source -encoding utf-8 $top/srcpkgs/ribbon-kit/files/lib/core.tcl
source -encoding utf-8 $top/srcpkgs/ribbon-kit/files/lib/system.tcl
proc cand {kind short {fields {}}} { return [dict create kind $kind short $short ki [dict create fields $fields]] }
ok "restart tag only where SYSTEM-UPDATES.md 7.5 says: glibc, dinit, a kernel kit's restart field; not mesa, not apps" {
    [::kit::system::restart [cand system glibc]] && [::kit::system::restart [cand system dinit]] && [::kit::system::restart [cand system linux {restart yes}]] &&
    ![::kit::system::restart [cand system mesa]] && ![::kit::system::restart [cand app glibc]]}
# U03b: the core libraries join the restart class (SYSTEM-UPDATES.md 7.5). kit refuses system kits, so the
# tagging function is tested on its own, with the candidate dicts plan.tcl passes it.
set core {glibc dinit dbus elogind turnstile greetd libgcc libstdc++ ld.so libcrypto libssl zlib libelogind libsystemd libdbus}
set untagged {}
foreach c $core { if {![::kit::system::restart [cand system $c]]} { lappend untagged $c } }
ok "restart tag: every core library and never-live kit of 7.5, as a system kit" {$untagged eq {}} $untagged
ok "restart tag: the same libraries as app kits are not tagged (apps never wait for a restart)" {
    [llength [lmap c $core { expr {[::kit::system::restart [cand app $c]] ? $c : [continue] }}]] == 0}
ok "restart tag: a system kit that is not in the class is not tagged (zlib2, mesa, ffmpeg)" {
    ![::kit::system::restart [cand system zlib2]] && ![::kit::system::restart [cand system mesa]] && ![::kit::system::restart [cand system ffmpeg]]}
ok "restart tag: the manifest field restart still tags a system kit that is not in the class" {
    [::kit::system::restart [cand system linux {restart yes}]] && ![::kit::system::restart [cand system linux {restart no}]]}

# kit run starts a kit through mkkitfs, which needs FUSE (/dev/fuse), mkkitfs on the PATH and unix_sockets
# for its Tcl client.  Without them the checks of kit run are skipped, by name, and never run some other
# way; KIT_TEST_NOFUSE=1 forces that path (for a check of the skipping itself).
proc fuse {what script} {
    if {$::fuse} { uplevel 1 $script ; return }
    puts "  skip $what (kit run needs FUSE, mkkitfs and unix_sockets)"
}

# ==== basics ==============================================================================================
set r [run]
ok "kit alone prints the table and exits 0" {[dict get $r code] == 0 && [regexp -all -line {^  kit (find|grab|check|toss|list|info|mend|pack|run) } [dict get $r out]] == 9} [show $r]
set r [run help toss]
ok "kit help toss prints its page" {[dict get $r code] == 0 && [string match "kit toss KIT…*asks, each time*" [dict get $r out]]} [show $r]
set r [run frobnicate]
ok "an unknown verb is bad usage (exit 2)" {[dict get $r code] == 2} [show $r]
set r [run grab]
ok "grab with nothing to grab is bad usage (exit 2)" {[dict get $r code] == 2} [show $r]

# ==== find, install ======================================================================================
set r [run find web browser]
ok "find: by summary and tags" {[dict get $r code] == 0 && [regexp -line {^  firefox +134\.0\.1 +The Firefox web browser$} [dict get $r out]]} [show $r]
set r [run find nosuchthing]
ok "find: nothing found is not an error" {[dict get $r code] == 0 && [string match "Nothing found*" [dict get $r out]]} [show $r]
set m [logmark $logA]
set r [run -in n grab firefox]
ok "grab, answered no: exit 1, nothing installed" {[dict get $r code] == 1 && ![file exists $HOME/.local/share/kit/active]} [show $r]
set r [run -in y grab firefox]
set lines [split [dict get $r out] \n]
ok "grab firefox: the plan names firefox and the library it uses" {[dict get $r code] == 0 &&
    [regexp {^  firefox      new       134\.0\.1 +[0-9]+ kB$} [lindex $lines 0]] && [string length [lindex $lines 0]] == 42 &&
    [regexp {^  libgreet     new       1\.1 +[0-9]+ kB$} [lindex $lines 1]] && [lindex $lines 2] eq "Install? \[Y/n\] y"} [show $r]
ok "grab: the newest library version within firefox's range (1.1, not 1.0)" {[version $HOME org.ribbon.test.libgreet] eq "1.1"}
ok "grab: chunks came from the first mirror" {[llength [lsearch -all [logsince $logA $m] "GET /chunks/*"]] > 0 && [llength [lsearch -all [split [slurp $logB] \n] "GET /chunks/*"]] == 0}
fuse {[run run firefox --private]} {
    set r [run run firefox --private]
    ok "run firefox: the entry point, with the locked library composed in" {[dict get $r code] == 0 && [dict get $r out] eq "org.mozilla.firefox 134.0.1 greet 1.1 --private"} [show $r]
}
set desk $HOME/.local/share/applications/kit-org.mozilla.firefox.desktop
ok "grab: a launcher entry that starts the kit through kit run" {[file exists $desk] && [regexp -line "^Exec=.*/kit run org.mozilla.firefox %u$" [utf $desk]] && ![regexp -line {^TryExec} [utf $desk]] && [regexp -line {^Icon=/.*/export/icon.png$} [utf $desk]]} [expr {[file exists $desk] ? [utf $desk] : "no $desk"}]
set r [run grab firefox]
ok "grab again: firefox is up to date, nothing asked" {[dict get $r code] == 0 && [dict get $r out] eq "firefox is up to date"} [show $r]
set r [run list]
ok "list: versions, sizes, the library marked" {[regexp -line {^  firefox +134\.0\.1 +[0-9]+ kB$} [dict get $r out]] && [regexp -line {^  libgreet +1\.1 +[0-9]+ kB +library$} [dict get $r out]]} [show $r]
set r [run info firefox]
ok "info: version, size, permissions, what it uses, signer, installed" {[dict get $r code] == 0 &&
    [string match "firefox (org.mozilla.firefox)*" [dict get $r out]] && [regexp -line {^  Permissions  display wayland, home ro, network yes$} [dict get $r out]] &&
    [regexp -line {^  Uses         org\.ribbon\.test\.libgreet >=1 <2 → 1\.1$} [dict get $r out]] && [regexp -line {^  Signer       valid, key [0-9A-F]{16} \(org\.mozilla\.firefox 134\.0\.1\)$} [dict get $r out]] &&
    [regexp -line {^  Installed    yes, } [dict get $r out]]} [show $r]
set r [run info obs]
ok "info: a kit that is not installed, from the index" {[dict get $r code] == 0 && [regexp -line {^  Version      31\.0\.1 available$} [dict get $r out]] && [regexp -line {^  Installed    no$} [dict get $r out]]} [show $r]

# ==== update: only the changed chunks; conditional refresh; the old version kept until started ===========
publish $A [kitfile org.mozilla.firefox 134.0.2] ; syncB
set m [logmark $logA]
set r [run -in y grab firefox]
ok "grab within the hour does not refresh the index" {[dict get $r out] eq "firefox is up to date" && [lsearch [logsince $logA $m] "GET /index*"] < 0} [show $r]
age $HOME 7200
# the snapshot kitindex wrote with this index (for pinning: KIT_INDEX)
set snapshot $W/snapshot ; file mkdir $snapshot
set sn [lindex [lsort -integer [lmap f [glob -tails -directory $A/snapshots {[0-9]*}] { if {[string match *.minisig $f]} continue ; set f }]] end]
file copy -force $A/snapshots/$sn $snapshot/index ; file copy -force $A/snapshots/$sn.minisig $snapshot/index.minisig
set m [logmark $logA]
# firefox 134.0.1 is "running" (a launch's marker, as kit run leaves one, with a live pid: ours)
set running $HOME/.local/share/kit/running/[lindex [kitline $HOME org.mozilla.firefox] 3].[pid]
spit $running org.mozilla.firefox
set r [run -in y grab firefox]
file delete $running
set lines [split [dict get $r out] \n]
ok "grab after an hour: refreshed, the update shown with the shared prompt" {[dict get $r code] == 0 &&
    [regexp {^  Firefox      134\.0\.1 → 134\.0\.2 +[0-9]+ kB$} [lindex $lines 0]] && [lindex $lines 1] eq "Update? \[Y/n\] y"} [show $r]
ok "grab says what happened, and which running programs still use the old version" {[lrange $lines 2 end] eq
    [list "  Firefox      134.0.2   switched" "Still running old versions: firefox. Restart them to use the new ones."]} [show $r]
set since [logsince $logA $m]
ok "update: the index was fetched again (GET /index 200)" {"GET /index 200" in $since} [join $since \n]
ok "update: only the changed chunk was fetched" {[llength [lsearch -all $since "GET /chunks/*"]] == 1} [join $since \n]
fuse {update: the old version is kept until the new one has st} {
    ok "update: the old version is kept until the new one has started" {[regexp -line {^kit\torg\.mozilla\.firefox\t134\.0\.1\t[0-9a-f]+\tprev\t1$} [active $HOME]]} [active $HOME]
}
set r [run info firefox]
fuse {info says what is kept"} {
    ok "info says what is kept" {[string match "*134.0.1 kept until 134.0.2 has started once*" [dict get $r out]]} [show $r]
}
fuse {[run run firefox]} {
    set r [run run firefox]
    ok "run: the new version starts" {[dict get $r out] eq "org.mozilla.firefox 134.0.2 greet 1.1 "} [show $r]
    # (the old version's files stay in the store for kit rewind: the history entry that replaced it keeps them)
    ok "run: after a good first start the old version goes from the set, and its files stay for kit rewind" {![regexp -line {\tprev\t} [active $HOME]] && [llength [glob -nocomplain $HOME/.local/share/kit/store/*]] == 3} "[active $HOME]\n[glob -nocomplain $HOME/.local/share/kit/store/*]"
}
age $HOME 7200
set m [logmark $logA]
set r [run find web]
set since [logsince $logA $m]
ok "an unchanged index costs one round trip (304, no signature fetched)" {$since eq {{GET /index 304}}} [join $since \n]
set r [run find grüße]
ok "find: a summary that is not ASCII (the index is checked as the bytes that were signed)" {[dict get $r code] == 0 && [regexp -line {^  libgreet +1\.1 +Grüße, shared} [dict get $r out]]} [show $r]
set r [run info firefox]
ok "a kit with a path that is not ASCII installed and verifies (its manifest's index hashes to the root)" {[dict get $r code] == 0 && [string match "*valid*" [dict get $r out]]} [show $r]
set r [run mend firefox]
ok "  ... and mend checks every chunk of it" {[dict get $r code] == 0 && [regexp -line {^  firefox +134\.0\.2 +ok$} [dict get $r out]]} [show $r]
# the key list moves on (serial 2: a second app key); the index names it, so clients fetch it
set OLD $W/mirror-old ; file mkdir $OLD ; foreach f {index index.minisig keys keys.minisig} { file copy $A/$f $OLD/$f }
kittool kitkey add -role app $L $F/test-app2.pub
kittool kitkey sign -key $F/test-root.key $L
publish $A ; syncB
age $HOME 7200
set m [logmark $logA]
set r [run find web]
set since [logsince $logA $m]
ok "a newer key list named by the index is fetched, checked and kept (kittrust update)" {[dict get $r code] == 0 && "GET /keys 200" in $since && [file exists $HOME/.local/share/kit/keys/2.keys]} "[show $r]\n[join $since \n]"
simple $W/src/signed2-1 "name org.example.signedtwo version 1 kind app summary {Signed by the second app key}
entries {{signedtwo bin/app {} cli}}" app2
fuse {[run run [kitfile org.example.signedtwo 1]]} {
    set r [run run [kitfile org.example.signedtwo 1]]
    ok "  ... and a kit signed by the key it added is valid" {[dict get $r code] == 0 && [dict get $r out] eq "org.example.signedtwo 1 no greeting "} [show $r]
}
conf $W/old.conf [list file://$OLD $urlB]
age $HOME 7200
set r [run -conf $W/old.conf find web]
ok "a mirror serving an older index (a replay) is skipped for the next" {[dict get $r code] == 0 && [string match "*firefox*" [dict get $r out]]} [show $r]
conf $W/old-only.conf [list file://$OLD]
age $HOME 7200
set r [run -conf $W/old-only.conf find web]
ok "  ... and with only that mirror, the index already here is used (never the replay)" {[dict get $r code] == 0 && [string match "*no mirror served a valid index*" [dict get $r err]]} [show $r]

# ==== check, then grab ===============================================================================
publish $A [kitfile org.mozilla.firefox 134.0.3] ; publish $A -security [kitfile org.ribbon.test.libgreet 1.2] ; syncB
publish $A [kitfile org.ribbon.test.libgreet 2.0] ; syncB
set m [logmark $logA]
set r [run -in y check]
set out [dict get $r out]
ok "check: refreshes always, shows updates within the ranges, security tagged" {[dict get $r code] == 0 &&
    [regexp -line {^  Firefox      134\.0\.2 → 134\.0\.3 +[0-9]+ kB$} $out] && [regexp -line {^  libgreet     1\.1     → 1\.2 +[0-9]+ kB   security$} $out] &&
    [regexp -line {^Update\? \[Y/n\] y$} $out] && "GET /index 200" in [logsince $logA $m]} [show $r]
ok "check: yes hands them to grab, which does not ask again" {[regexp -all {\[Y/n\]} $out] == 1 && [version $HOME org.mozilla.firefox] eq "134.0.3" && [version $HOME org.ribbon.test.libgreet] eq "1.2"} [show $r]
ok "check: libgreet 2.0 is outside firefox's range and is not offered" {![string match *2.0* $out]} $out
fuse {[run run firefox]} {
    set r [run run firefox]
    ok "run after check: firefox uses the security update" {[dict get $r out] eq "org.mozilla.firefox 134.0.3 greet 1.2 "} [show $r]
}
set r [run check]
ok "check with nothing to update: Up to date, exit 0" {[dict get $r code] == 0 && [dict get $r out] eq "Up to date"} [show $r]
set r [run -in y grab firefox@134.0.2]
set lines [split [dict get $r out] \n]
ok "grab KIT@VERSION goes back, with the same plan and prompt; the row is tagged held (Kit-Sheet-4)" {[dict get $r code] == 0 &&
    [regexp {^  Firefox      134\.0\.3 → 134\.0\.2 +[0-9]+ kB   held$} [lindex $lines 0]] && [lindex $lines 1] eq "Update? \[Y/n\] y" &&
    [lindex $lines 2] eq "  Firefox      134.0.2   switched" && [version $HOME org.mozilla.firefox] eq "134.0.2"} [show $r]
set r [run list]
ok "list marks the kit held" {[regexp -line {^  firefox +134\.0\.2 +[0-9]+ kB +held$} [dict get $r out]]} [show $r]
set r [run check]
ok "check does not offer a held kit" {[dict get $r code] == 0 && [dict get $r out] eq "Up to date"} [show $r]
set m [logmark $logA]
set r [run -conf $W/dead.conf -in y grab firefox@134.0.3]
ok "grab KIT@VERSION of the version still kept here: no download, works offline" {[dict get $r code] == 0 && [version $HOME org.mozilla.firefox] eq "134.0.3" &&
    [regexp -line {^  Firefox      134\.0\.2 → 134\.0\.3 +0 kB   held$} [dict get $r out]] && [lsearch [logsince $logA $m] "GET /chunks/*"] < 0} [show $r]
set r [run -in y grab firefox]
set r2 [run list]
ok "grab KIT takes a held kit forward again (here: it is up to date, and no longer held)" {[dict get $r code] == 0 && [dict get $r out] eq "firefox is up to date" &&
    ![regexp -line {held} [dict get $r2 out]] && ![regexp -line {^hold\t} [active $HOME]]} "[show $r]\n[show $r2]"
fuse {[run run firefox]} {
    set r [run run firefox]
}
publish $A [kitfile org.mozilla.firefox 134.0.4] ; syncB
set r [run -in n check firefox]
ok "check firefox, answered no: exit 1, nothing changed" {[dict get $r code] == 1 && [version $HOME org.mozilla.firefox] eq "134.0.3"} [show $r]
set r [run list]
ok "list marks the update waiting (from the last check, no network)" {[regexp -line {^  firefox +134\.0\.3 +[0-9]+ kB +→ 134\.0\.4$} [dict get $r out]]} [show $r]
set r [run check obs]
ok "check of a kit that is not installed is bad usage" {[dict get $r code] == 2} [show $r]

# ==== grab two: install one, update one ==========================================================================
age $HOME 7200
set r [run -in y grab firefox obs]
set lines [split [dict get $r out] \n]
ok "grab firefox obs: Install 1 and update 1?" {[dict get $r code] == 0 &&
    [regexp {^  Firefox      134\.0\.3 → 134\.0\.4 +[0-9]+ kB$} [lindex $lines 0]] && [regexp {^  obs          new       31\.0\.1 +[0-9]+ kB$} [lindex $lines 1]] &&
    [lindex $lines 2] eq "Install 1 and update 1? \[Y/n\] y"} [show $r]
ok "obs uses the libgreet already installed (no second copy)" {[llength [regexp -all -inline -line {^kit\torg\.ribbon\.test\.libgreet\t} [active $HOME]]] == 1}

# ==== toss ==========================================================================================================
spit $HOME/.config/obs-studio/basic.ini [string repeat "x" 2500]
set r [run -in n toss obs]
ok "toss obs, data kept: the row, then the data question with where and how much" {[dict get $r code] == 0 &&
    [dict get $r out] eq "  obs          31.0.1    removed\nAlso remove its data in ~/.config/obs-studio (3 kB)? \[y/N\] n" && [file exists $HOME/.config/obs-studio/basic.ini] && [version $HOME com.obsproject.obs] eq ""} [show $r]
ok "toss obs: libgreet stays (firefox uses it)" {[version $HOME org.ribbon.test.libgreet] eq "1.2"}
# Kit-Bar-4: the history row of a toss whose data was kept says so; kit rewind --tcl carries it to the shell
set h [lsearch -inline -index 0 [lmap l [split [dict get [run --tcl rewind] out] \n] { if {[lindex $l 0] ne "plan"} continue ; set l }] plan]
set e [expr {$h eq "" ? "" : [lindex [dict get [lindex $h 1] history] 0]}]
ok "toss obs, data kept: the log entry records the answer, and kit rewind --tcl's history says \"obs 31.0.1 · data kept\"" {$e ne "" &&
    [dict get $e title] eq "Uninstalled obs" && [dict get $e sub] eq "obs 31.0.1 · data kept" && [dict get $e cursor] == 1 &&
    [dict get [utf [lindex [lsort [glob $HOME/.local/share/kit/history/*]] end]] data] eq {com.obsproject.obs kept}} $h
set r [run -in y grab obs]
set r [run --yes toss obs]
ok "toss --yes keeps the data (the data question's default is no)" {[dict get $r code] == 0 &&
    [dict get $r out] eq "  obs          31.0.1    removed\nAlso remove its data in ~/.config/obs-studio (3 kB)? \[y/N\] n" && [file exists $HOME/.config/obs-studio/basic.ini]} [show $r]
set h [lsearch -inline -index 0 [lmap l [split [dict get [run --tcl rewind] out] \n] { if {[lindex $l 0] ne "plan"} continue ; set l }] plan]
ok "toss --yes: the history says data kept too" {$h ne "" && [dict get [lindex [dict get [lindex $h 1] history] 0] sub] eq "obs 31.0.1 · data kept"} $h
set r [run -in y grab obs]
fuse {[run run obs]} {
    set r [run run obs]
}
fuse {toss obs with its data (kit run made the data directory)} {
    set r [run -in y toss obs]
    ok "toss obs, data removed: both places named, both gone" {[dict get $r code] == 0 &&
        [string first {Also remove its data in ~/.config/obs-studio and ~/.local/share/kit/data/com.obsproject.obs (3 kB)? [y/N] y} [dict get $r out]] >= 0 &&
        ![file exists $HOME/.config/obs-studio] && ![file exists $HOME/.local/share/kit/data/com.obsproject.obs]} [show $r]
    set h [lsearch -inline -index 0 [lmap l [split [dict get [run --tcl rewind] out] \n] { if {[lindex $l 0] ne "plan"} continue ; set l }] plan]
    ok "toss obs, data removed: the history row has no suffix" {$h ne "" && [dict get [lindex [dict get [lindex $h 1] history] 0] sub] eq "obs 31.0.1"} $h
}
set r [run -in y grab base]
set r [run toss base]
ok "toss refuses an essential kit, names it, changes nothing" {[dict get $r code] == 2 && [string match "*base is needed for the system to run and can't be tossed*" [dict get $r err]] && [version $HOME org.ribbon.test.base] eq "1"} [show $r]
set r [run toss nothere]
ok "toss of a kit that is not installed: nothing to do" {[dict get $r code] == 0 && [dict get $r out] eq "nothere is not installed"} [show $r]

# ==== a plan that can't be met fails before anything is fetched ======================================
set m [logmark $logA]
set r [run -in y grab needy]
ok "nothing provides libgreet >=3: refused (exit 2) before any chunk is fetched" {[dict get $r code] == 2 &&
    [string match "*nothing provides org.ribbon.test.libgreet >=3 (needed by org.example.needy)*" [dict get $r err]] && [lsearch [logsince $logA $m] "GET /chunks/*"] < 0} "[show $r]\n[join [logsince $logA $m] \n]"
set r [run -in y grab [kitfile org.mozilla.firefox 134.0.2]]
ok "grab never downgrades: an older .kit file is in the way" {[dict get $r code] == 2 && [string match "*never downgrades*" [dict get $r err]] && [version $HOME org.mozilla.firefox] eq "134.0.4"} [show $r]

# ==== signatures: unsigned and untrusted refused; the loud developer setting ======================================
set r [run -in y grab [kitfile org.example.unsigned 1]]
ok "an unsigned .kit is refused for install (exit 4)" {[dict get $r code] == 4 && [string match "*unsigned*" [dict get $r err]]} [show $r]
set r [run -in y grab [kitfile org.example.other 1]]
ok "a .kit signed by an untrusted key is refused (exit 4)" {[dict get $r code] == 4 && [string match "*untrusted*" [dict get $r err]]} [show $r]
set r [run run [kitfile org.example.unsigned 1]]
ok "kit run refuses an unsigned .kit too" {[dict get $r code] == 4} [show $r]
conf $W/dev.conf [list $urlA] "allow-unsigned = yes"
set r [run -conf $W/dev.conf -in y grab [kitfile org.example.unsigned 1]]
ok "allow-unsigned = yes installs it, loudly, and tags the row" {[dict get $r code] == 0 && [string match "*WARNING: allow-unsigned = yes*UNSIGNED AND UNTRUSTED KITS CAN BE INSTALLED*" [dict get $r err]] &&
    [regexp -line {^  unsigned +new +1 +[0-9]+ kB   unsigned$} [dict get $r out]]} [show $r]
set r [run -conf $W/dev.conf list]
ok "the developer setting is announced by every command" {[string match "*WARNING: allow-unsigned*" [dict get $r err]]} [show $r]
set r [run -in y toss unsigned]

# ==== run a .kit file; mkkitfs when it exists ====================================================================
fuse {[run run [kitfile org.example.hello 1] a b]} {
    set r [run run [kitfile org.example.hello 1] a b]
    ok "run a .kit file that is not installed" {[dict get $r code] == 0 && [dict get $r out] eq "org.example.hello 1 no greeting a b"} [show $r]
}
# without mkkitfs, kit run says so in one line and exits 5: kits never run from an extracted copy
set sysMk [catch {exec env -u TCLLIBPATH [info nameofexecutable] << "package require mkkitfs"}]
if {$sysMk} {
    set r [run -env [list TCLLIBPATH {}] run firefox]
    ok "kit run without mkkitfs: one line, exit 5, nothing extracted" {[dict get $r code] == 5 &&
        [string match "kit: kit run needs mkkitfs*" [dict get $r err]] && [llength [glob -nocomplain $HOME/.local/share/kit/store/*/tree]] == 0} [show $r]
} else {
    puts "  skip kit run without mkkitfs (mkkitfs is installed for every tclsh on this machine)"
}

# ==== a failed first start goes back to the old version ===========================================================
set r [run -in y grab crashy]
fuse {[run run crashy]} {
    set r [run run crashy]
}
publish $A [kitfile org.example.crashy 2.0] ; syncB
age $HOME 7200
set r [run -in y grab crashy]
fuse {[run run crashy]} {
    set r [run run crashy]
}
fuse {a new version that fails its first start rolls back"} {
    ok "a new version that fails its first start rolls back" {[dict get $r code] == 3 && [string match "*org.example.crashy 2.0 did not start; back to crashy 1.0*" [dict get $r err]] && [version $HOME org.example.crashy] eq "1.0"} "[show $r]\n[active $HOME]"
}
fuse {[run run crashy]} {
    set r [run run crashy]
}
fuse {and the old version runs again"} {
    ok "and the old version runs again" {[dict get $r code] == 0 && [dict get $r out] eq "org.example.crashy 1.0 no greeting "} [show $r]
}

# ==== mend =============================================================================================================
set root [lindex [kitline $HOME org.mozilla.firefox] 3]
set kf $HOME/.local/share/kit/store/$root/kit
set r [run mend]
ok "mend: everything ok" {[dict get $r code] == 0 && [regexp -line {^  firefox +134\.0\.4 +ok$} [dict get $r out]]} [show $r]
# damage one chunk of firefox's big file inside the installed kit
set data [slurp $kf]
set z "" ; foreach f [glob $A/chunks/*/*] { set c [slurp $f] ; if {[string length $c] > 2000 && [string first $c $data] >= 0} { set z $c ; break } }
set at [expr {[string first $z $data] + [string length $z] / 2}]
spit $kf [string replace $data $at $at [expr {[string index $data $at] eq "A" ? "B" : "A"}]]
file delete $desk
set r [run mend firefox]
ok "mend: a damaged chunk is fetched again and the kit repaired" {[dict get $r code] == 0 && [regexp -line {^  firefox +134\.0\.4 +repaired \(1 chunk fetched\)$} [dict get $r out]]} [show $r]
ok "mend: the launcher entry is put back" {[file exists $desk]}
set r [run mend]
ok "mend after repair: ok" {[dict get $r code] == 0 && ![string match *damaged* [dict get $r out]] && ![string match *repaired* [dict get $r out]]} [show $r]
fuse {[run run firefox]} {
    set r [run run firefox]
}
fuse {the repaired kit runs"} {
    ok "the repaired kit runs" {[dict get $r out] eq "org.mozilla.firefox 134.0.4 greet 1.2 "} [show $r]
}
file delete $kf
set r [run mend firefox]
ok "mend: a missing kit file is rebuilt from the mirror" {[dict get $r code] == 0 && [string match "*repaired (kit file rebuilt*" [dict get $r out]]} [show $r]
spit $kf [string replace [slurp $kf] $at $at X]
file delete -force $HOME/.cache/kit/chunks
conf $W/dead.conf [list http://127.0.0.1:1]
set r [run -conf $W/dead.conf mend firefox]
ok "mend offline, with the good chunk not stored here: exit 3" {[dict get $r code] == 3 && [string match "*damaged*" [dict get $r out]]} [show $r]
set r [run mend firefox]

# ==== pack ===============================================================================================================
file delete -force $W/packed ; file mkdir $W/packed
kitsrc $W/packed/tool "name org.example.tool version 0.1 kind app summary {Packed by kit pack}\nentries {{tool bin/app {} cli}}" [list bin/app $APP 493]
set r [run -cmd $KIT pack $W/packed/tool $W/packed/tool.kit]
ok "pack DIR OUT.kit: builds a kit from DIR and DIR.manifest" {[dict get $r code] == 0 && [file exists $W/packed/tool.kit]} [show $r]
set r [run info $W/packed/tool.kit]
ok "the packed kit opens (info), unsigned" {[dict get $r code] == 0 && [regexp -line {^  Signer       unsigned} [dict get $r out]]} [show $r]
file delete $W/packed/tool.manifest
set r [run pack $W/packed/tool]
ok "pack without a manifest is bad usage" {[dict get $r code] == 2 && [string match "*no manifest*" [dict get $r err]]} [show $r]

# ==== offline =========================================================================================================
conf $W/dead.conf [list http://127.0.0.1:1]
age $HOME [expr {2 * 86400 + 60}]
set r [run -conf $W/dead.conf find web]
ok "offline: find uses the last good index and says how old it is" {[dict get $r code] == 0 && [string match "*index from 2 days ago, offline*" [dict get $r err]] && [string match "*firefox*" [dict get $r out]]} [show $r]
set r [run -conf $W/dead.conf -in y grab faraway]
ok "offline: grab of a kit whose chunks are not stored exits 3" {[dict get $r code] == 3} [show $r]
foreach v {list {info firefox}} {
    set r [run -conf $W/dead.conf {*}$v]
    ok "offline: kit $v works" {[dict get $r code] == 0} [show $r]
}
fuse {offline: kit run firefox works} {
    set r [run -conf $W/dead.conf run firefox]
    ok "offline: kit run firefox works" {[dict get $r code] == 0} [show $r]
}
# Download automatically, then install offline from what was fetched
publish $A [kitfile org.mozilla.firefox 134.0.5] ; syncB
spit $HOME/.config/kit/updates.conf "download = yes\n"
set r [run -cmd $B/kit-updater --once]
ok "updater (download automatically): fetched and verified the update in the background" {[dict get $r code] == 0 && [string match "*update* waiting*downloaded and verified*" [dict get $r err]] && [version $HOME org.mozilla.firefox] eq "134.0.4"} [show $r]
set r [run list]
ok "updater: kit list shows its result" {[regexp -line {^  firefox +134\.0\.4 +[0-9]+ kB +→ 134\.0\.5$} [dict get $r out]]} [show $r]
age $HOME 7200
set r [run -conf $W/dead.conf -in y grab firefox]
ok "offline: grab works for an update whose chunks are already stored" {[dict get $r code] == 0 && [string match "*offline*" [dict get $r err]] && [version $HOME org.mozilla.firefox] eq "134.0.5"} [show $r]

# ==== pinned ============================================================================================================
set H2 $W/home-pinned
set m [logmark $logA]
set r [run -home $H2 -env [list KIT_INDEX $snapshot/index] find web]
ok "pinned (KIT_INDEX): says so, and uses the snapshot (134.0.2 newest there)" {[dict get $r code] == 0 && [string match "*index pinned to $snapshot/index*" [dict get $r err]] && [regexp -line {^  firefox +134\.0\.2 } [dict get $r out]]} [show $r]
set r [run -home $H2 -env [list KIT_INDEX $snapshot/index] -in y grab firefox]
ok "pinned: grab installs the snapshot's version" {[dict get $r code] == 0 && [version $H2 org.mozilla.firefox] eq "134.0.2"} [show $r]
ok "pinned: the index is never fetched" {[lsearch [logsince $logA $m] "GET /index*"] < 0 && [lsearch [logsince $logB $m] "GET /index*"] < 0}
conf $W/pinned.conf [list $urlA] "index = $snapshot/index"
set r [run -home $H2 -conf $W/pinned.conf list]
ok "pinned (index = in kit.conf): every command says so" {[string match "*index pinned to $snapshot/index*" [dict get $r err]]} [show $r]
set r [run -home $H2 -conf $W/pinned.conf -cmd $B/kit-updater --once]
ok "pinned: the background refresh is off" {[string match "*pinned*background refresh is off*" [dict get $r err]]} [show $r]
spit $W/snapshot-bad/index [string map {134.0.2 134.0.9} [utf $snapshot/index]] ; file copy -force $snapshot/index.minisig $W/snapshot-bad/
set r [run -home $H2 -env [list KIT_INDEX $W/snapshot-bad/index] find web]
ok "pinned: a snapshot verifies like any index (a changed one is refused, exit 4)" {[dict get $r code] == 4} [show $r]

# ==== an expired index (file:// mirror) =============================================================================
set C $W/mirror-expired
publish $C -now @[expr {[clock seconds] - 10 * 86400}] -expires 1d [kitfile org.mozilla.firefox 134.0.1] [kitfile org.ribbon.test.libgreet 1.1]
conf $W/expired.conf [list file://$C]
set H3 $W/home-expired
set r [run -home $H3 -conf $W/expired.conf find web]
ok "expired: still shown, with a warning" {[dict get $r code] == 0 && [string match "*the index expired 9 days ago*nothing can be installed*" [dict get $r err]] && [string match "*firefox*" [dict get $r out]]} [show $r]
set r [run -home $H3 -conf $W/expired.conf -in y grab firefox]
ok "expired: refused for installs (exit 4)" {[dict get $r code] == 4 && [string match "*expired*" [dict get $r err]] && ![file exists $H3/.local/share/kit/active]} [show $r]

# ==== degraded: a bad chunk and a bad signature, with mirror fallback ======================================================
set D $W/mirror-badchunk
mirrorCopy $A $D
# the victim is a chunk of firefox's share/big.txt (row 2000 of BIG, in every version): grab firefox
# must fetch it.  Not just any "row 2000 ": faraway's own.txt has one too, and glob's order is the
# directory's, so the first match could be a chunk that grab firefox never reads.
set needle [lindex [split $BIG \n] 2000]\n
set victim ""
foreach f [lsort [glob $D/chunks/*/*]] { if {![catch {zlib decompress [slurp $f]} t] && [string first $needle $t] >= 0} { set victim $f ; break } }
if {$victim eq ""} { error "no chunk of mirror $D holds firefox's \"$needle\"" }
set c [slurp $victim] ; spit $victim [string replace $c 20 20 [expr {[string index $c 20] eq "Q" ? "R" : "Q"}]]
conf $W/fallback.conf [list file://$D $urlB]
set H4 $W/home-fallback
set m [logmark $logB]
set r [run -home $H4 -conf $W/fallback.conf -in y grab firefox]
ok "a bad chunk from one mirror is fetched again from the next" {[dict get $r code] == 0 && [string match "*damaged chunk from file://*trying the next mirror*" [dict get $r err]] &&
    [lsearch [logsince $logB $m] "GET /chunks/[string range [file tail $victim] 0 1]/[file tail $victim] 200"] >= 0} "[show $r]\n[join [logsince $logB $m] \n]"
fuse {[run -home $H4 -conf $W/fallback.conf run firefox]} {
    set r [run -home $H4 -conf $W/fallback.conf run firefox]
}
fuse {and what was installed is right"} {
    ok "and what was installed is right" {[dict get $r out] eq "org.mozilla.firefox 134.0.5 greet 1.2 "} [show $r]
}
set F $W/mirror-badsig
mirrorCopy $A $F
spit $F/index [string map {"Firefox web browser" "Firefox web browsr"} [utf $F/index]]
conf $W/badsig.conf [list file://$F $urlB]
set r [run -home $W/home-badsig -conf $W/badsig.conf find web]
ok "a mirror serving a bad index signature is skipped for the next" {[dict get $r code] == 0 && [string match "*The Firefox web browser*" [dict get $r out]]} [show $r]
conf $W/badsig-only.conf [list file://$F]
set r [run -home $W/home-badsig2 -conf $W/badsig-only.conf find web]
ok "with only that mirror: verification failed (exit 4)" {[dict get $r code] == 4} [show $r]

proc storeOk {home} {
    set live [lsort -unique [regexp -all -inline {[0-9a-f]{64}} [active $home]]]
    set kept $live
    foreach f [glob -nocomplain $home/.local/share/kit/history/*] { lappend kept {*}[regexp -all -inline {[0-9a-f]{64}} [utf $f]] }
    set have [lsort [lmap d [glob -nocomplain $home/.local/share/kit/store/*] { file tail $d }]]
    set ok 1
    foreach r $live { if {$r ni $have} { set ok 0 } }
    foreach r $have { if {$r ni $kept} { set ok 0 } }
    return [expr {$ok && ![file exists $home/.local/share/kit/journal] && ![llength [glob -nocomplain $home/.local/share/kit/staging/*]]}]
}

fuse {the SIGKILL checks (they start firefox first)} {
# ==== SIGKILL at every step of a transaction, then recovery =====================================================
set H5 $W/home-crash-base
set r [run -home $H5 -env [list KIT_INDEX $snapshot/index] -in y grab firefox]
fuse {[run -home $H5 run firefox]} {
    set r2 [run -home $H5 run firefox]
}
ok "crash tests: a baseline with firefox 134.0.2, started once" {[version $H5 org.mozilla.firefox] eq "134.0.2" && [lindex [kitline $H5 org.mozilla.firefox] 5] eq "1"} "[show $r]\n[show $r2]"
# the store holds every kit the active set names, and nothing else but what the history keeps for kit rewind
foreach {point after} {fetch 0 begin 0 stage 0 staged 0 synced 0 switch 0 switched 1 exports 1 gc 1 done 1} {
    set h $W/home-crash-$point
    file delete -force $h ; file copy $H5 $h
    age $h 7200
    set r [run -home $h -env [list KIT_CRASH_AT $point] -in y grab firefox]
    set killed [expr {[dict get $r code] eq "killed"}]
    set r2 [run -home $h list]
    set want [expr {$after ? "134.0.5" : "134.0.2"}]
    set rec [expr {$point in {fetch begin done} || [string match "*kit: * an interrupted grab*" [dict get $r2 err]]}]
    set kept [expr {!$after || [regexp -line {^kit\torg\.mozilla\.firefox\t134\.0\.2\t[0-9a-f]+\tprev\t1$} [active $h]]}]
    ok "killed at '$point': recovered to [expr {$after ? "the new set, the old version kept" : "the old set"}]" {$killed && $rec && $kept && [version $h org.mozilla.firefox] eq $want && [storeOk $h] &&
        [regexp -line "^  firefox +$want " [dict get $r2 out]]} "first: [show $r]\nthen: [show $r2]\n[active $h]"
    set r3 [run -home $h mend]
    set r4 [run -home $h run firefox]
    ok "killed at '$point': mend finds nothing broken, and it runs" {[dict get $r3 code] == 0 && ![string match *repaired* [dict get $r3 out]] && [dict get $r4 out] eq "org.mozilla.firefox $want greet 1.1 "} "[show $r3]\n[show $r4]"
    if {!$after} {
        set r5 [run -home $h -in y grab firefox]
        ok "killed at '$point': the next grab completes" {[dict get $r5 code] == 0 && [version $h org.mozilla.firefox] eq "134.0.5" && [storeOk $h]} [show $r5]
    }
}
# the small transaction after a first start, killed after its switch, is finished by the next command
set h $W/home-crash-first
file delete -force $h ; file copy $H5 $h
set r [run -home $h -in y grab firefox]
set r [run -home $h -env [list KIT_CRASH_AT switched] run firefox]
set r2 [run -home $h list]
ok "first start killed after its switch: finished (the old version let go)" {[dict get $r code] eq "killed" &&
    [string match "*finished an interrupted first start*" [dict get $r2 err]] && ![regexp -line {\tprev\t} [active $h]] && [storeOk $h]} "[show $r]\n[show $r2]\n[active $h]"
foreach {point gone} {staged 0 switch 0 switched 1 gc 1} {
    set h $W/home-crash-toss-$point
    file delete -force $h ; file copy $H5 $h
    set r [run -home $h -env [list KIT_CRASH_AT $point] -in n toss firefox]
    set r2 [run -home $h list]
    ok "toss killed at '$point': [expr {$gone ? "removed" : "still installed"}] after recovery" {[dict get $r code] eq "killed" &&
        ([version $h org.mozilla.firefox] eq "") == $gone && ([version $h org.ribbon.test.libgreet] eq "") == $gone && [storeOk $h]} "[show $r]\n[show $r2]\n[active $h]"
}

}

# ==== kit rewind: the last change back, one step at a time; a kit held at its previous version; a toss ====
set R $W/home-rewind
file delete -force $R
proc hcount {home} { return [llength [glob -nocomplain $home/.local/share/kit/history/*]] }
proc held {home} { return [regexp -line {^hold\t} [active $home]] }
set r [run -home $R -in y grab firefox]
ok "rewind: firefox 134.0.5 installed (and its library)" {[dict get $r code] == 0 && [version $R org.mozilla.firefox] eq "134.0.5"} [show $r]
set r [run -home $R -in y grab firefox@134.0.4]
ok "rewind: firefox taken back to 134.0.4 by grab KIT@VERSION, and held" {[dict get $r code] == 0 && [version $R org.mozilla.firefox] eq "134.0.4" && [held $R]} [show $r]
set r [run -home $R -in y rewind firefox]
set lines [split [dict get $r out] \n]
ok "rewind KIT: the previous version (134.0.5) comes back, with the shared prompt, and it is held" {[dict get $r code] == 0 &&
    [regexp {^  Firefox +134\.0\.4 → 134\.0\.5} [lindex $lines 0]] && [lindex $lines 1] eq "Rewind? \[Y/n\] y" &&
    [lindex $lines 2] eq "  Firefox      134.0.5   switched" && [version $R org.mozilla.firefox] eq "134.0.5" && [held $R]} [show $r]
set r [run -home $R list]
ok "list marks it held" {[regexp -line {^  firefox +134\.0\.5 +[0-9]+ kB +held$} [dict get $r out]]} [show $r]
set r [run -home $R check]
ok "check does not offer a held kit" {[dict get $r code] == 0 && [dict get $r out] eq "Up to date"} [show $r]
set r [run -home $R -in y grab firefox]
ok "a plain grab releases the hold (up to date, nothing to fetch)" {[dict get $r code] == 0 && [dict get $r out] eq "firefox is up to date" && ![held $R]} [show $r]
set r [run -home $R -in y rewind]
ok "rewind takes back the last change: the release, so the hold is back" {[dict get $r code] == 0 && [string first "Rewind? \[Y/n\] y" [dict get $r out]] >= 0 && [held $R] && [version $R org.mozilla.firefox] eq "134.0.5"} [show $r]
set r [run -home $R -in y rewind]
ok "rewinding again steps further back: the rewind KIT is taken back (134.0.4, held)" {[dict get $r code] == 0 && [version $R org.mozilla.firefox] eq "134.0.4" && [held $R]} [show $r]
set r [run -home $R -in y rewind]
ok "and again: the grab KIT@VERSION is taken back (134.0.5, not held)" {[dict get $r code] == 0 && [dict get $r out] ne "" && [version $R org.mozilla.firefox] eq "134.0.5" && ![held $R]} [show $r]
set r [run -home $R -in y rewind]
ok "and the first grab: nothing installed, its library with it" {[dict get $r code] == 0 && [version $R org.mozilla.firefox] eq "" && [version $R org.ribbon.test.libgreet] eq "" &&
    [string first "Rewind? \[Y/n\] y" [dict get $r out]] >= 0} [show $r]
ok "history: the log keeps every change and every rewind (8 entries), and nothing is left to rewind" {[hcount $R] == 8} "[glob -nocomplain $R/.local/share/kit/history/*]"
set r [run -home $R rewind]
ok "nothing to rewind: one line, exit 0" {[dict get $r code] == 0 && [dict get $r out] eq "Nothing to rewind"} [show $r]
set r [run -home $R -in y grab firefox]
set r2 [run -home $R -in n rewind]
ok "saying no: exit 1, nothing changed, the change is still there to rewind" {[dict get $r2 code] == 1 && [version $R org.mozilla.firefox] eq "134.0.5" && [hcount $R] == 9} [show $r2]
set r [run -home $R --yes rewind]
ok "--yes answers the prompt" {[dict get $r code] == 0 && [string first "Rewind? \[Y/n\] y" [dict get $r out]] >= 0 && [version $R org.mozilla.firefox] eq ""} [show $r]
# a toss, with its data kept: rewinding it puts the kit back, and its data was never touched
set r [run -home $R -in y grab obs]
spit $R/.config/obs-studio/scenes.json "scenes\n"
set r [run -home $R -in n toss obs]
ok "rewind a toss: obs tossed, its data kept" {[dict get $r code] == 0 && [version $R com.obsproject.obs] eq "" && [file exists $R/.config/obs-studio/scenes.json]} [show $r]
set r [run -home $R -in y rewind]
ok "rewinding the toss installs obs again, and says so (install, with the shared prompt)" {[dict get $r code] == 0 &&
    [regexp -line {^  obs +new +31\.0\.1} [dict get $r out]] && [string first "Rewind? \[Y/n\] y" [dict get $r out]] >= 0 && [version $R com.obsproject.obs] eq "31.0.1"} [show $r]
ok "and its data is still there" {[file exists $R/.config/obs-studio/scenes.json] && [utf $R/.config/obs-studio/scenes.json] eq "scenes\n"} [show $r]
set r [run -home $R -in y rewind]
ok "the grab that installed obs is taken back: nothing installed" {[dict get $r code] == 0 && [version $R com.obsproject.obs] eq "" && [version $R org.ribbon.test.libgreet] eq ""} [show $r]
set r [run -home $R rewind firefox obs]
ok "rewind takes one kit at a time: bad usage is exit 2" {[dict get $r code] == 2} [show $r]
set r [run -home $R rewind obs]
ok "rewind KIT of a kit that is not installed: exit 2" {[dict get $r code] == 2 && [string match "*obs is not installed*" [dict get $r err]]} [show $r]
set r [run -home $R -in y grab obs]
set r2 [run -home $R rewind obs]
ok "rewind KIT of a kit its newest change installed: nothing to go back to, exit 0, nothing changed" {[dict get $r2 code] == 0 &&
    [dict get $r2 out] eq "obs has no earlier version to go back to" && [version $R com.obsproject.obs] eq "31.0.1" && [hcount $R] == 15} [show $r2]
set r [run -home $R -in y rewind]
set r2 [run help rewind]
ok "kit help rewind: the verb's page starts with its usage" {[dict get $r2 code] == 0 && [string first "kit rewind \[KIT\]" [dict get $r2 out]] == 0} [show $r2]
set r2 [run help]
ok "the verb table lists rewind" {[string first "  kit rewind \[KIT\]" [dict get $r2 out]] >= 0} [show $r2]

# SIGKILL in the middle of a rewind: the next kit command finishes it (after the switch) or undoes it (before)
set r [run -home $R -in y grab firefox]
set r [run -home $R -in y grab firefox@134.0.4]
set rb $W/home-rewind-base
file delete -force $rb ; file copy $R $rb
set cur18 [string trim [utf $rb/.local/share/kit/history.cursor]]    ;# the cursor before the rewind: the grab KIT@VERSION
foreach {point after} {staged 0 switched 1 gc 1} {
    set h $W/home-rewind-$point
    file delete -force $h ; file copy $rb $h
    set r [run -home $h -env [list KIT_CRASH_AT $point] -in y rewind]
    set r2 [run -home $h list]
    set want [expr {$after ? "134.0.5" : "134.0.4"}]
    set said [expr {$after ? "finished an interrupted rewind" : "undid an interrupted rewind"}]
    ok "rewind killed at '$point': [expr {$after ? "finished from the journal" : "undone from the journal"}]" {[dict get $r code] eq "killed" &&
        [string match "*kit: $said*" [dict get $r2 err]] && [version $h org.mozilla.firefox] eq $want &&
        [held $h] == !$after && [hcount $h] == [expr {$after ? 19 : 18}] && [storeOk $h] &&
        ([string trim [utf $h/.local/share/kit/history.cursor]] ne $cur18) == $after} "[show $r]\n[show $r2]\n[active $h]"
    set r3 [run -home $h -in y rewind]
    ok "rewind killed at '$point': the next rewind goes on from there" {[dict get $r3 code] == 0 && [hcount $h] == [expr {$after ? 20 : 19}] && [version $h org.mozilla.firefox] eq [expr {$after ? "" : "134.0.5"}] && [storeOk $h]} [show $r3]
}

# a kit a rewind needs, but whose files were pruned from the store and its manifest from the cache: it is
# fetched from a mirror by its root, and checked against that root
set P2 $W/home-rewind-pruned
file delete -force $P2
run -home $P2 -in y grab firefox
run -home $P2 -in y grab firefox@134.0.4
set root5 ""
foreach f [glob -directory $P2/.local/share/kit/history *] {
    if {[regexp {kit\torg\.mozilla\.firefox\t134\.0\.5\t([0-9a-f]{64})} [utf $f] -> x]} { set root5 $x }
}
ok "rewind: the history has the root of 134.0.5" {[string length $root5] == 64} $root5
file delete -force $P2/.local/share/kit/store/$root5 $P2/.cache/kit/manifests/$root5
set r [run -home $P2 -in y rewind]
ok "rewind of a version no longer stored: fetched from a mirror by its root, and installed" {[dict get $r code] == 0 &&
    [version $P2 org.mozilla.firefox] eq "134.0.5" && [file isfile $P2/.local/share/kit/store/$root5/kit] && [storeOk $P2]} "[show $r]\n[active $P2]"

# ==== the log and the cursor: what a plain rewind takes back, and where the cursor goes =============================
proc cursorOf {home} { return [string trim [utf $home/.local/share/kit/history.cursor]] }
set L1 $W/home-log
file delete -force $L1
run -home $L1 -in y grab firefox
run -home $L1 -in y grab obs
set r [run -home $L1 -in y rewind]
ok "log: grab A, grab B, rewind takes back B (obs), and A stays" {[dict get $r code] == 0 && [version $L1 com.obsproject.obs] eq "" && [version $L1 org.mozilla.firefox] eq "134.0.5"} [show $r]
set r [run -home $L1 -in y rewind]
ok "log: rewind again takes back A: back before the first grab, with 4 log entries" {[dict get $r code] == 0 && [version $L1 org.mozilla.firefox] eq "" && [hcount $L1] == 4} "[show $r]\n[glob -nocomplain $L1/.local/share/kit/history/*]"
set r [run -home $L1 rewind]
ok "log: nothing left to rewind: one line, exit 0, the cursor is empty" {[dict get $r code] == 0 && [dict get $r out] eq "Nothing to rewind" && [cursorOf $L1] eq ""} [show $r]

set L2 $W/home-log-grab
file delete -force $L2
run -home $L2 -in y grab firefox
run -home $L2 -in y grab obs
run -home $L2 -in y rewind
set r [run -home $L2 -in y grab firefox@134.0.4]
set c [cursorOf $L2]
ok "log: rewind, then grab: the cursor moves to the new entry, and the log has 4" {[dict get $r code] == 0 && [hcount $L2] == 4 &&
    [file isfile $L2/.local/share/kit/history/$c] && [regexp {134\.0\.4} [utf $L2/.local/share/kit/history/$c]]} "[show $r]\ncursor $c"
set r [run -home $L2 -in y rewind]
ok "log: the next rewind takes back that grab: 134.0.5, not held" {[dict get $r code] == 0 && [version $L2 org.mozilla.firefox] eq "134.0.5" && ![held $L2] && [hcount $L2] == 5} [show $r]

set L3 $W/home-log-hold
file delete -force $L3
run -home $L3 -in y grab firefox@134.0.4
run -home $L3 -in y grab firefox
run -home $L3 -in y rewind firefox
ok "log: rewind KIT after a release: 134.0.4 held, logged" {[version $L3 org.mozilla.firefox] eq "134.0.4" && [held $L3] && [hcount $L3] == 3} [show $r]
set r [run -home $L3 -in y rewind]
ok "log: a plain rewind undoes the rewind KIT: the hold is undone, 134.0.5 is back and not held" {[dict get $r code] == 0 &&
    [version $L3 org.mozilla.firefox] eq "134.0.5" && ![held $L3] && [hcount $L3] == 4} [show $r]

# the log keeps the newest 200 entries, and the cursor's entry even when it is older than those
set L5 $W/home-log-trim
file delete -force $L5
run -home $L5 -in y grab firefox
set src [lindex [glob $L5/.local/share/kit/history/*] 0]
set firefoxId [file tail $src]
for {set i 0} {$i < 205} {incr i} { file copy -force $src $L5/.local/share/kit/history/9000000000000-$i }
run -home $L5 -in y grab obs
set c [cursorOf $L5]
ok "log: 207 entries become 201: the newest 200 and the cursor's entry, which is older than them" {[hcount $L5] == 201 && [file isfile $L5/.local/share/kit/history/$c] &&
    ![file exists $L5/.local/share/kit/history/$firefoxId]} "[glob -nocomplain $L5/.local/share/kit/history/*]"

fuse {kit run: its first start is not logged, so a rewind takes back the grab, not the start} {
    set L4 $W/home-log-start
    file delete -force $L4
    run -home $L4 -in y grab firefox@134.0.4
    run -home $L4 run firefox
    run -home $L4 -in y grab firefox
    set n0 [hcount $L4] ; set c0 [cursorOf $L4]
    set r [run -home $L4 run firefox]
    ok "kit run: the first start of 134.0.5 is not logged, and the cursor stays on the grab" {[dict get $r code] == 0 && [hcount $L4] == $n0 && [cursorOf $L4] eq $c0 &&
        [regexp -line {^kit\torg\.mozilla\.firefox\t134\.0\.5\t[0-9a-f]{64}\t\w+\t1$} [active $L4]]} "[show $r]\n[active $L4]"
    set r [run -home $L4 -in y rewind]
    ok "rewind after the first start: the grab is taken back; 134.0.4 is back, still started" {[dict get $r code] == 0 && [version $L4 org.mozilla.firefox] eq "134.0.4" &&
        [regexp -line {^kit\torg\.mozilla\.firefox\t134\.0\.4\t[0-9a-f]{64}\t\w+\t1$} [active $L4]]} "[show $r]\n[active $L4]"
}

# ==== the updater's settings and conditions ===========================================================================
set H6 $W/home-updater
set r [run -home $H6 -cmd $B/kit-updater --set interval=30m]
ok "updater: an interval under an hour is refused" {[dict get $r code] == 2 && [string match "*1 hour to 7 days*" [dict get $r err]]} [show $r]
set r [run -home $H6 -cmd $B/kit-updater --set interval=12h notify=yes]
set r [run -home $H6 -cmd $B/kit-updater --status]
ok "updater: defaults (notify on, download off, install off) and a changed interval" {[regexp -line {^notify +yes$} [dict get $r out]] && [regexp -line {^download +no$} [dict get $r out]] &&
    [regexp -line {^install +off$} [dict get $r out]] && [regexp -line {^interval +12h$} [dict get $r out]]} [show $r]
set fake $W/fakebin ; file mkdir $fake
spit $fake/dbus-send "#!/bin/sh\necho '   uint32 1'\n" 493
set m [logmark $logA]
set r [run -home $H6 -env [list PATH $fake:$env(PATH)] -cmd $B/kit-updater --once]
ok "updater: skips a metered connection (nothing fetched)" {[string match "*skipped: the connection is metered*" [dict get $r err]] && [lsearch [logsince $logA $m] "GET /index*"] < 0} [show $r]
file delete $fake/dbus-send
foreach {name type capacity status online} {BAT0 Battery 15 Discharging ""  AC Mains "" "" 0} {
    file mkdir $W/sys/class/power_supply/$name
    spit $W/sys/class/power_supply/$name/type $type\n
    if {$capacity ne ""} { spit $W/sys/class/power_supply/$name/capacity $capacity\n ; spit $W/sys/class/power_supply/$name/status $status\n }
    if {$online ne ""} { spit $W/sys/class/power_supply/$name/online $online\n }
}
set r [run -home $H6 -env [list KIT_SYSFS $W/sys] -cmd $B/kit-updater --once]
ok "updater: skips on battery below 20 %" {[string match "*skipped: the battery is below 20 %*" [dict get $r err]]} [show $r]
spit $W/sys/class/power_supply/AC/online 1\n
set r [run -home $H6 -env [list KIT_SYSFS $W/sys] -cmd $B/kit-updater --once]
ok "updater: plugged in, it refreshes and checks" {[dict get $r code] == 0 && [string match "*update*waiting*" [dict get $r err]] && [file exists $H6/.cache/kit/index]} [show $r]
# install automatically at a time: firefox 134.0.2 installed, updates waiting
set r [run -home $H6 -env [list KIT_INDEX $snapshot/index] -in y grab firefox]
spit $W/proc/loadavg "4.50 3.00 2.00 3/300 1234\n"
set t [clock format [expr {[clock seconds] - 120}] -format %H:%M]
set r [run -home $H6 -cmd $B/kit-updater --set install=$t]
set r [run -home $H6 -env [list KIT_PROC $W/proc] -cmd $B/kit-updater --once]
ok "updater (install at a time): postponed while the machine is busy" {[string match "*install postponed: the machine is busy*" [dict get $r err]] && [version $H6 org.mozilla.firefox] eq "134.0.2"} [show $r]
spit $W/proc/loadavg "0.10 0.20 0.30 1/300 1234\n"
set r [run -home $H6 -env [list KIT_PROC $W/proc] -cmd $B/kit-updater --once]
ok "updater (install at a time): idle, so it installs the waiting updates" {[dict get $r code] == 0 && [string match "*installed 2 updates*" [dict get $r err]] && [version $H6 org.mozilla.firefox] eq "134.0.5"} [show $r]
set r [run -home $H6 -env [list KIT_PROC $W/proc] -cmd $B/kit-updater --once]
ok "updater: and only once that day" {![string match "*installed*" [dict get $r err]]} [show $r]

# ==== the dinit service ================================================================================================
set svc $top/srcpkgs/ribbon-kit/files/services/kit-updater
ok "the dinit user service runs kit-updater" {[file exists $svc] && [regexp -line {^command = /usr/lib/ribbon/kit/kit-updater$} [utf $svc]]}

# ==== --tcl: the shell's updates panel reads plans and results as Tcl lists (check and rewind only) ======
# the panel is the prompt: nothing is asked, check --tcl prints the plan and changes nothing, and with
# --yes the grab runs through the same machinery and prints what happened.
proc tclines {r kind} { return [lmap l [split [dict get $r out] \n] { if {[lindex $l 0] ne $kind} continue ; lindex $l 1 }] }
set probe2 [string map {"::kit::ui::ask $rows $q $default" "set ::kit::ui::renderer ::kit::ui::tcl ; ::kit::ui::ask $rows $q $default"} $probe]
spit $W/probe2.tcl [encoding convertto utf-8 "set lib $top/srcpkgs/ribbon-kit/files/lib\nset spec {{mesa 25.2.6 25.2.7 update 40 restart} {obs {} 31.0.1 install 88 {}}}\nset question plan\nset default 1\n$probe2"]
set got [exec $tclsh $W/probe2.tcl << ""]
set d [lindex $got 1]
ok "--tcl: the plan's rows and the question word for word, (takes effect at restart) included" {[lindex $got 0] eq "plan" && [dict get $d question] eq "Install 1 and update 1? (takes effect at restart)" &&
    [dict get [lindex [dict get $d rows] 0] tags] eq "restart"} $got
set G $W/home-panel
file delete -force $G
run -home $G -in y grab firefox
run -home $G -in y grab obs
set Fsave $F ; set F $top/tests/fixtures/kittrust      ;# (F was the bad-signature mirror's directory since the degraded tests)
firefox 134.0.6 4
publish $A -security [kitfile org.mozilla.firefox 134.0.6] ; syncB
set F $Fsave
set r [run -home $G check --tcl]
set plans [tclines $r plan]
set d [lindex $plans 0]
set row [lindex [dict get $d rows] 0]
ok "check --tcl: one plan line, exit 0, nothing asked and nothing changed" {[dict get $r code] == 0 && [llength $plans] == 1 && [dict get $d question] eq "Update?" &&
    [version $G org.mozilla.firefox] eq "134.0.5" && ![string match *Y/n* [dict get $r out]]} [show $r]
ok "check --tcl: the row is what kit check prints (name, from, to, size, security)" {[llength [dict get $d rows]] == 1 && [dict get $row name] eq "Firefox" && [dict get $row old] eq "134.0.5" && [dict get $row new] eq "134.0.6" &&
    [dict get $row action] eq "update" && [string is integer -strict [dict get $row bytes]] && [dict get $row tags] eq "security" && [dict get $d checked] > 0} [show $r]
set r2 [run -home $G -in n check]
ok "check --tcl and kit check show the same plan and question" {[regexp -line {^  Firefox      134\.0\.5 → 134\.0\.6 +[0-9]+ kB   security$} [dict get $r2 out]] &&
    [string first "\nUpdate? \[Y/n\] n" [dict get $r2 out]] > 0 && [string first " [::kit::fmtsize [dict get $row bytes]] " [dict get $r2 out]] > 0} "[show $r2]\nrow $row"
set r [run -home $G grab --tcl firefox]
ok "--tcl is for check and rewind: grab refuses it (exit 2)" {[dict get $r code] == 2 && [string match "*--tcl*" [dict get $r err]]} [show $r]
# firefox 134.0.5 is running, so it keeps the old version until its next start
set running $G/.local/share/kit/running/[lindex [kitline $G org.mozilla.firefox] 3].[pid]
spit $running org.mozilla.firefox
set r [run -home $G check --tcl --yes]
file delete $running
set dones [tclines $r done]
set d [lindex $dones 0]
ok "check --tcl --yes: grabs through the same machinery, prints no plan, then what happened" {[dict get $r code] == 0 && [llength [tclines $r plan]] == 0 && [llength $dones] == 1 &&
    [version $G org.mozilla.firefox] eq "134.0.6" && [dict get [lindex [dict get $d rows] 0] new] eq "switched" && [dict get [lindex [dict get $d rows] 0] old] eq "134.0.6" &&
    [dict get $d stale] eq {{firefox {}}} && [dict get $d restart] eq {} && [dict get $d time] > 0} [show $r]
ok "check --tcl --yes: the lines are the CLI's" {[dict get $d lines] eq {{Still running old versions: firefox. Restart them to use the new ones.}}} $d
set r [run -home $G check --tcl]
ok "check --tcl with nothing to update says Up to date, no plan" {[dict get $r code] == 0 && [dict get $r out] eq "Up to date"} [show $r]
set r [run -home $G -in y rewind firefox]
set r [run -home $G rewind --tcl]
set d [lindex [tclines $r plan] 0]
set h [dict get $d history]
ok "rewind --tcl: the plan and the question Rewind?, nothing changed" {[dict get $r code] == 0 && [dict get $d question] eq "Rewind?" && [version $G org.mozilla.firefox] eq "134.0.5" &&
    [dict get [lindex [dict get $d rows] 0] name] eq "Firefox" && [dict get [lindex [dict get $d rows] 0] old] eq "134.0.5" && [dict get [lindex [dict get $d rows] 0] new] eq "134.0.6"} [show $r]
ok "rewind --tcl: the history, newest first, with its titles (a rewind of one kit holds it)" {[llength $h] == 4 &&
    [dict get [lindex $h 0] title] eq "Rewound firefox" && [dict get [lindex $h 0] sub] eq "134.0.6 → 134.0.5 · held" && [dict get [lindex $h 0] icon] eq "undo" &&
    [dict get [lindex $h 1] title] eq "Updated firefox" && [dict get [lindex $h 1] sub] eq "134.0.5 → 134.0.6" && [dict get [lindex $h 1] icon] eq "up" &&
    [dict get [lindex $h 2] title] eq "Installed obs" && [dict get [lindex $h 2] icon] eq "plus" &&
    [dict get [lindex $h 3] title] eq "Installed 2 kits" && [dict get [lindex $h 3] sub] eq "firefox, libgreet" &&
    [dict get [lindex $h 0] time] > 0 && [regexp {^[0-9]+-[0-9]+$} [dict get [lindex $h 0] id]]} $h
set r [run -home $G rewind --tcl --yes]
set d [lindex [tclines $r done] 0]
ok "rewind --tcl --yes: the rewind runs and says what happened; the rewind is logged on top" {[dict get $r code] == 0 && [llength [tclines $r plan]] == 0 &&
    [version $G org.mozilla.firefox] eq "134.0.6" && [dict get [lindex [dict get $d rows] 0] new] eq "switched" && [hcount $G] == 5} [show $r]
set r [run -home $G rewind --tcl]
set h2 [dict get [lindex [tclines $r plan] 0] history]
ok "rewind --tcl again: the rewind is the top row, and the cursor is on the update under it" {[llength $h2] == 5 &&
    [dict get [lindex $h2 0] title] eq "Rewound firefox" && [dict get [lindex $h2 0] sub] eq "134.0.5 → 134.0.6" && [dict get [lindex $h2 0] icon] eq "undo" && [dict get [lindex $h2 0] cursor] == 0 &&
    [dict get [lindex $h2 2] title] eq "Updated firefox" && [dict get [lindex $h2 2] cursor] == 1} [show $r]
set R2 $W/home-empty
file delete -force $R2
set r [run -home $R2 rewind --tcl]
ok "rewind --tcl with nothing to rewind: Nothing to rewind, exit 0" {[dict get $r code] == 0 && [dict get $r out] eq "Nothing to rewind"} [show $r]

# ==== data N (U03d): going back below the data the installed version wrote warns, once per kit row ====
# notesKit V DATA: a small app kit whose manifest says `data DATA` (no data field when DATA is "")
proc notesKit {v data} {
    set man "name org.example.notes version $v kind app summary {Notes, with a data format}\nentries {{notes bin/app {} app}}"
    if {$data ne ""} { append man "\ndata $data" }
    kitsrc $::W/src/notes-$v $man [list bin/app $::APP 493]
    set r [run -cmd $::KIT pack -q -sign $::top/tests/fixtures/kittrust/test-app.key $::W/src/notes-$v $::W/src/notes-$v.kit]
    if {[dict get $r code] != 0} { error "kit pack notes-$v failed: [show $r]" }
    return $::W/src/notes-$v.kit
}
proc warnLine {r text} { return [expr {[lsearch -exact [lmap l [split [dict get $r out] \n] { string trim $l }] $text] >= 0}] }
proc warnCount {r} { set n 0 ; foreach l [split [dict get $r out] \n] { if {[string match "*may not open*" $l]} { incr n } } ; return $n }
set N09 [notesKit 0.9 ""] ; set N10 [notesKit 1.0 1] ; set N12 [notesKit 1.2 2] ; set N15 [notesKit 1.5 2]

# (1) a home that goes 1.0 (data 1) -> 1.2 -> 1.5 (data 2 each), then back to 1.2 (equal data): no warning
set DH $W/home-data
file delete -force $DH
run -home $DH -in y grab $N10
set r [run -home $DH -in y grab $N12]
ok "data: an update 1.0 -> 1.2 (data 1 -> 2) shows no warning" {[dict get $r code] == 0 && [version $DH org.example.notes] eq "1.2" &&
    ![string match "*may not open*" [dict get $r out]]} [show $r]
set r [run -home $DH -in y grab $N15]
set r [run -home $DH -in y grab org.example.notes@1.2]
ok "data: going back from 1.5 to 1.2 (data 2 to 2, equal) shows no warning" {[dict get $r code] == 0 && [version $DH org.example.notes] eq "1.2" &&
    ![string match "*may not open*" [dict get $r out]]} [show $r]
set r [run -home $DH -in n grab org.example.notes@1.0]
ok "data: grab KIT@VERSION below the installed data (1.2 wrote 2, 1.0 has 1) shows one warning row, and saying no changes nothing" {
    [dict get $r code] == 1 && [warnLine $r "notes 1.0 may not open data written by 1.2"] && [version $DH org.example.notes] eq "1.2" &&
    [warnCount $r] == 1} [show $r]

# (2) a plain rewind takes back 1.0 -> 1.5 (data 1 -> 2): going below the data the installed 1.5 wrote
set DW $W/home-data-rewind
file delete -force $DW
run -home $DW -in y grab $N10
run -home $DW -in y grab $N15
set r [run -home $DW --tcl rewind]
set plans [tclines $r plan]
set d [lindex $plans 0]
set row [lindex [dict get $d rows] 0]
ok "data: rewind --tcl: the row carries the warning as its note, and nothing changes" {[llength $plans] == 1 && [dict get $row name] eq "notes" &&
    [dict get $row note] eq "notes 1.0 may not open data written by 1.5" && [version $DW org.example.notes] eq "1.5"} [show $r]
set r [run -home $DW -in n rewind]
ok "data: rewind asks with the warning row above the question, and saying no changes nothing" {[dict get $r code] == 1 &&
    [warnLine $r "notes 1.0 may not open data written by 1.5"] && [version $DW org.example.notes] eq "1.5"} [show $r]

# (3) a version without data is unknown: no warning, in either direction
set DN $W/home-data-none
file delete -force $DN
run -home $DN -in y grab $N09
run -home $DN -in y grab $N10
set r [run -home $DN -in n grab org.example.notes@0.9]
ok "data: going back to a version without data (0.9) shows no warning (unknown)" {[dict get $r code] == 1 &&
    ![string match "*may not open*" [dict get $r out]]} [show $r]

# (4) kit pack refuses a data field that is not a whole number (kitpack: 0, or no leading zero, at most 9 digits)
foreach {tag val} {letters x leading01 01 tooLong 1234567890} {
    kitsrc $W/src/bad-data-$tag "name org.example.baddata version 1 kind app\ndata $val" [list bin/app $APP 493]
    set r [run -cmd $KIT pack $W/src/bad-data-$tag $W/src/bad-data-$tag.kit]
    ok "pack: data $val is refused (kitpack's message, nonzero exit, nothing written)" {[dict get $r code] != 0 && [string match "*data must be a whole number*" [dict get $r err]] &&
        ![file exists $W/src/bad-data-$tag.kit]} [show $r]
}

# ==== display names (U03n): a row shows the Name= of the kit's launcher entry; a library keeps its kit name ====
set DN $W/home-names
file delete -force $DN
set FF1 [kitfile org.mozilla.firefox 134.0.1] ; set FF2 [kitfile org.mozilla.firefox 134.0.2]
set r [run -home $DN -in n grab $FF1]
ok "names: a kit not installed yet shows its short name (its launcher is read from the store, after it is installed)" {
    [regexp -line {^  firefox +new +134\.0\.1 } [dict get $r out]]} [show $r]
set r [run -home $DN -in y grab $FF1]
ok "names: firefox 134.0.1 installed from its file" {[dict get $r code] == 0 && [version $DN org.mozilla.firefox] eq "134.0.1"} [show $r]
set r [run -home $DN -in n grab $FF2]
ok "names: an update's row shows the launcher's Name= (Firefox)" {[dict get $r code] == 1 &&
    [regexp -line {^  Firefox +134\.0\.1 → 134\.0\.2 +[0-9]+ [kMG]B$} [dict get $r out]]} [show $r]
set r [run -home $DN -in n grab org.ribbon.test.libgreet@1.1]
ok "names: a library (no launcher) keeps its kit name in the row" {[regexp -line {^  libgreet +[0-9.]+ +→ 1\.1 } [dict get $r out]]} [show $r]
set r [run -home $DN list]
ok "names: kit list keeps the short name (the name kit grab takes)" {[dict get $r code] == 0 &&
    [regexp -line {^  firefox +134\.0\.1 } [dict get $r out]] && ![regexp {Firefox} [dict get $r out]]} [show $r]
set r [run -home $DN --tcl rewind]
set plans [tclines $r plan]
set row0 [lindex [dict get [lindex $plans 0] rows] 0]
ok "names: rewind --tcl: the row's name is the launcher's, and short is the kit's own (the shell's icon key)" {[llength $plans] == 1 &&
    [dict get $row0 name] eq "Firefox" && [dict get $row0 short] eq "firefox"} [show $r]

# ==== how fast kit list starts =========================================================================================
set t0 [clock microseconds]
for {set i 0} {$i < 10} {incr i} { run list }
set ms [expr {([clock microseconds] - $t0) / 10000.0}]
set t0 [clock microseconds]
for {set i 0} {$i < 10} {incr i} { exec $tclsh << {exit 0} }
set base [expr {([clock microseconds] - $t0) / 10000.0}]
puts [format "  note kit list: %.1f ms per run (%d kits installed; tclsh alone %.1f ms)" $ms [llength [regexp -all -inline -line {^kit\t} [active $HOME]]] $base]
ok "kit list starts quickly (under 150 ms)" {$ms < 150} "$ms ms"

# the session server this run started (kit run) goes; its socket is in W
if {$fuse} { catch {exec env XDG_RUNTIME_DIR=$W/runtime [info nameofexecutable] $top/srcpkgs/mkkitfs/files/tcl/mkkitfsd ctl quit} }
foreach ch $servers { catch {exec kill [pid $ch]} ; catch {close $ch} }
if {![info exists env(KIT_TEST_KEEP)]} { file delete -force $W }
puts "  kit: $nok checks passed, $fails failed"
exit [expr {$fails ? 1 : 0}]
