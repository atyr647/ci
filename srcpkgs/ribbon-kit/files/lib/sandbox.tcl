# sandbox.tcl -- kit run's sandbox: what a kit app may reach, and the bubblewrap command that
# confines it to that (docs/KIT.md section 5 and D6 C, D9 A, D21 A, D22 A; KIT-CLI.md
# "Permissions you grant").  No Tk, no exec of the app: launch.tcl runs what plan returns.
#
# What an app gets is its kit's request (the manifest's perms, KIT-FORMAT.md 4.2, vocabulary 1.0)
# with your grants laid over it (~/.config/kit/grants/<kit name>, written by Properties): a grant
# line replaces the request of that name, a name with no line gets the request, and a name nobody
# mentions gets nothing.  Each name maps to one mechanism:
#
#   network  no|yes          no: its own network namespace (only lo); yes: the host's network
#   home     none|ro|rw      none: the app's private data (~/.local/share/kit/data/<name>) is its
#                            $HOME; ro/rw: your real home, and the private data at its own path
#   folders  Folder ro|rw …  each folder bound at its own path: an XDG name (Downloads, from
#                            user-dirs.dirs), a name under your home, or an absolute path
#                            (/mnt/games, /run/media); never /, your home or a folder holding
#                            it, a folder in kit's own state, /proc, /sys, /dev, /run (but
#                            /run/media), the runtime directory or a folder holding X's sockets,
#                            whether named or reached through a link
#   display  none|wayland|x11  the compositor's socket (or the X server's and its Xauthority)
#   audio    0|1|mic         PipeWire's socket and its PulseAudio one
#   gpu input camera  0|1    /dev/dri and /dev/nvidia*; /dev/input, /dev/uinput, /dev/hidraw*;
#                            /dev/video* and /dev/media* (with sysfs and udev's data, read-only)
#   dbus     none|NAME …     the session bus through xdg-dbus-proxy, talking only to NAME …
#   notifications 0|1        (the desktop's own) adds org.freedesktop.Notifications to that list
#   nested   0|1             (the desktop's own) 0: no user namespaces inside (bwrap
#                            --disable-userns), 1: allowed (Steam, Chromium)
#
# Always: every other namespace unshared, the system (/usr, /etc) read-only, the kit read-only
# at /app (mkkitfs::compose, DECISIONS-DELEGATED 29), its libraries read-only at /run/kit/lib/N
# (on LD_LIBRARY_PATH), a private /tmp, /run and runtime directory, your appearance settings
# (GTK, fontconfig, fonts, icons, themes) read-only, and kit's own state (its store, other kits'
# data, the grants) never visible.  kit-landlock (files/landlock) runs first inside: it closes
# every descriptor but 0, 1 and 2 (none that kit run inherited reaches the app), and where the
# kernel has Landlock it also allows writes only beneath the app's writable places, no TCP when
# the network is not granted, no abstract sockets or signals outside the sandbox.

namespace eval ::kit::sandbox {
    # the names a grants file may set: vocabulary 1.0 and the desktop's own (KIT-CLI.md)
    variable names {network home folders display audio gpu input camera dbus screencast notifications autostart nested}
    variable defaults {network no home none folders {} display none audio 0 gpu 0 input 0 camera 0 dbus none
        screencast 0 notifications 0 autostart 0 nested 0}
    # XDG user directory names -> their user-dirs.dirs keys
    variable xdg {Desktop DESKTOP Documents DOCUMENTS Downloads DOWNLOAD Music MUSIC Pictures PICTURES
        Videos VIDEOS Templates TEMPLATES Public PUBLICSHARE}
    # where things are inside the sandbox
    variable app /app
    variable inner /run/kit
    variable landlockAbi       ;# cached: the kernel's Landlock ABI as kit-landlock reports it
}

# ---- the grants file ------------------------------------------------------------------------------
#   ribbon-kit-grants 1
#   perm<TAB><name><TAB><value>      as the kit index's perm lines: \\ \t \n \r escaped
proc ::kit::sandbox::grantsFile {name} { return [::kit::path config grants $name] }

proc ::kit::sandbox::grants {name} {
    variable names
    if {$name eq "" || [string match *..* $name] || [string match */* $name]} { return {} }
    if {[catch {::open [grantsFile $name]} fh]} { return {} }
    fconfigure $fh -encoding utf-8
    set lines [split [read $fh] \n]
    close $fh
    if {[lindex $lines 0] ne "ribbon-kit-grants 1"} { return {} }
    set g {}
    foreach line [lrange $lines 1 end] {
        set f [lmap x [split $line \t] { string map [list \\\\ \\ \\t \t \\n \n \\r \r] $x }]
        if {[lindex $f 0] eq "perm" && [llength $f] == 3 && [lindex $f 1] in $names} { dict set g [lindex $f 1] [lindex $f 2] }
    }
    return $g
}

# One value in its canonical form (as Properties' perms::norm reads them).
proc ::kit::sandbox::norm {k v} {
    switch -- $k {
        network { return [expr {[string tolower $v] in {yes 1 true on} ? "yes" : "no"}] }
        home { return [expr {$v in {ro rw} ? $v : "none"}] }
        display { set v [string tolower $v]; return [expr {$v in {wayland x11} ? $v : ($v eq "both" ? "wayland" : "none")}] }
        audio { return [expr {$v eq "mic" ? "mic" : ([string tolower $v] in {1 yes true on playback} ? 1 : 0)}] }
        folders {
            set out {}
            if {[catch {llength $v}]} { return {} }
            foreach {d m} $v { if {$d ne ""} { lappend out $d [expr {$m eq "rw" ? "rw" : "ro"}] } }
            return $out
        }
        dbus {
            if {[catch {llength $v}]} { return none }
            set out [lsearch -all -inline -regexp $v {^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*)+(\.\*)?$}]
            return [expr {[llength $out] ? $out : "none"}]
        }
        default { return [expr {[string tolower $v] in {1 yes true on} ? 1 : 0}] }
    }
}

# What the app gets: every name, from its kit's request and your grants.
proc ::kit::sandbox::effective {info} {
    variable defaults
    set r $defaults
    foreach p [dict get $info perms] {
        lassign $p k v
        if {[dict exists $defaults $k]} { dict set r $k [norm $k $v] }
    }
    # a request for the notification service is the notifications switch (as Properties shows
    # it), so a grant of notifications 0 takes it away
    set r [Notifications $r]
    dict for {k v} [grants [dict get $info name]] { dict set r $k [norm $k $v] }
    return [Notifications $r]
}
proc ::kit::sandbox::Notifications {r} {
    set n org.freedesktop.Notifications
    if {[dict get $r dbus] ne "none" && $n in [dict get $r dbus]} {
        dict set r notifications 1
        set rest [lsearch -all -inline -exact -not [dict get $r dbus] $n]
        dict set r dbus [expr {[llength $rest] ? $rest : "none"}]
    }
    return $r
}

# ---- the host's facts -------------------------------------------------------------------------------
proc ::kit::sandbox::Home {} { return [::kit::path home] }
proc ::kit::sandbox::Runtime {} { return [::kit::env XDG_RUNTIME_DIR] }

# An XDG user directory: user-dirs.dirs's entry, else ~/<Name>.
proc ::kit::sandbox::UserDir {name} {
    variable xdg
    set home [Home]
    set f [file join [::kit::env XDG_CONFIG_HOME $home/.config] user-dirs.dirs]
    if {[dict exists $xdg $name] && ![catch {::open $f} fh]} {
        fconfigure $fh -encoding utf-8
        set text [read $fh]
        close $fh
        foreach line [split $text \n] {
            if {[regexp {^\s*XDG_([A-Z]+)_DIR\s*=\s*"([^"]*)"} $line -> key val] && $key eq [dict get $xdg $name]} {
                set val [string map [list {$HOME} $home] $val]
                if {[file pathtype $val] eq "absolute"} { return [file normalize $val] }
            }
        }
    }
    return [file join $home $name]
}

# A folder grant's path on the host, or "" when it may not be bound.
proc ::kit::sandbox::FolderPath {name} {
    variable xdg
    set home [Home]
    if {[dict exists $xdg $name]} {
        set p [UserDir $name]
    } elseif {[string match ~/* $name]} {
        set p [file join $home [string range $name 2 end]]
    } elseif {[file pathtype $name] eq "absolute"} {
        set p $name
    } else {
        set p [file join $home $name]
    }
    if {[string match *..* $p]} { return "" }
    set p [file normalize $p]
    # what bubblewrap binds is where the path leads, its last link followed too
    foreach q [list $p [Resolve $p]] {
        if {$q in [list / /home]} { return "" }
        # your whole home (or a folder holding it), a folder in kit's own state (its store, every
        # kit's data, the grants: a folder holding it gets the mask below), and a folder holding
        # the X server's sockets (display none means none)
        foreach no [list $home [Resolve $home] /tmp/.X11-unix] { if {[Within $no $q]} { return "" } }
        foreach no [list [::kit::path data] [::kit::path config]] {
            if {[Within $q $no] || [Within $q [Resolve $no]]} { return "" }
            # (the mask is made at the folder's own path: a link to a folder holding it gets none)
            if {$q ne $p && [Within $no $q]} { return "" }
        }
        # the kernel's, the runtime directories and /run (the sockets of the session and the
        # system); of /run only removable media
        set rt [Runtime]
        foreach no [list /proc /sys /dev /run/user {*}[expr {$rt ne "" ? [list $rt [Resolve $rt]] : {}}]] {
            if {[Within $q $no] || [Within $no $q]} { return "" }
        }
        if {[Within $q /run] && ![Within $q /run/media]} { return "" }
    }
    return $p
}

# A path with every link in it followed (the last one too), as far as it exists.
proc ::kit::sandbox::Resolve {p} {
    for {set i 0} {$i < 40 && ![catch {file type $p} ty] && $ty eq "link"} {incr i} {
        if {[catch {file readlink $p} t]} break
        set p [file normalize [file join [file dirname $p] $t]]
    }
    return $p
}

proc ::kit::sandbox::Within {path dir} { expr {$path eq $dir || [string match [string trimright $dir /]/* $path]} }

# kit-landlock: next to kit's library (installed), or $KIT_LANDLOCK; "" without one (none).
proc ::kit::sandbox::helper {} {
    set exe [::kit::env KIT_LANDLOCK [file join $::kit::libdir kit-landlock]]
    expr {$exe eq "none" || ![file executable $exe] ? "" : $exe}
}
# ... and "" also without Landlock in the kernel.
proc ::kit::sandbox::landlock {} {
    variable landlockAbi
    set exe [helper]
    if {$exe eq ""} { return "" }
    if {![info exists landlockAbi($exe)]} {
        if {[catch {exec $exe --abi 2>/dev/null} v] || ![string is integer -strict [string trim $v]]} { set v 0 }
        set landlockAbi($exe) [string trim $v]
    }
    return [expr {$landlockAbi($exe) > 0 ? $exe : ""}]
}

# ---- the plan -----------------------------------------------------------------------------------------
# plan INFO TREE CMD LIBS RECORD -> dict
#   bwrap     bubblewrap's options (the command follows them)
#   cmd       the command to run inside (CMD with TREE as /app, behind kit-landlock where there is one)
#   env       variables to set for it, unset: variables to remove
#   proxy     xdg-dbus-proxy's command line ("" when the app gets no bus), proxysock: its socket
#   perms     what the app gets (effective)
# RECORD is this launch's directory in the runtime directory ("" for none): the bus proxy's
# socket goes there.
proc ::kit::sandbox::plan {info tree cmd libs {record ""}} {
    variable app
    variable inner
    set E [effective $info]
    set home [Home]
    set rt [Runtime]
    set data [::kit::path appdata [dict get $info name]]
    set a {}
    set env [dict create]
    set unset {}
    set real {}        ;# host paths bound at their own place (for the masks and chdir)
    set rw {}          ;# writable places inside (for kit-landlock)

    # namespaces
    lappend a --unshare-all --unshare-user
    if {[dict get $E network] eq "yes"} { lappend a --share-net }
    if {![dict get $E nested]} { lappend a --disable-userns }
    lappend a --die-with-parent --cap-drop ALL
    # an app is not on its terminal's session (no TIOCSTI); a command-line entry keeps its terminal
    set entry [::kit::launch::entry $info]
    if {[lindex $entry 3] ne "cli"} { lappend a --new-session }

    # the system, read-only, and the private filesystems
    lappend a --ro-bind /usr /usr
    foreach d {bin sbin lib lib32 lib64 libx32} {
        if {[catch {file type /$d} ty]} continue
        if {$ty eq "link" && ![catch {file readlink /$d} t]} {
            lappend a --symlink $t /$d
        } elseif {[file isdirectory /$d]} {
            lappend a --ro-bind /$d /$d
        }
    }
    lappend a --ro-bind /etc /etc --ro-bind-try /var/lib/dbus/machine-id /var/lib/dbus/machine-id
    lappend a --proc /proc --dev /dev --tmpfs /tmp --tmpfs /var/tmp --tmpfs /run --symlink ../run /var/run
    lappend rw /tmp /var/tmp /dev /proc
    if {$rt ne ""} {
        lappend a --perms 0700 --dir $rt
        lappend rw $rt
    }

    # the kit at /app, its libraries at /run/kit/lib/N
    if {[info commands ::mkkitfs::compose] ne ""} {
        lappend a {*}[::mkkitfs::compose $tree -dest $app -overlay none]
    } else {
        lappend a --ro-bind $tree $app
    }
    set lp {}
    set i 0
    foreach l $libs {
        lappend a --ro-bind $l $inner/lib/$i
        if {[file isdirectory $l/lib]} { lappend lp $inner/lib/$i/lib }
        incr i
    }
    if {[::kit::env LD_LIBRARY_PATH] ne ""} { lappend lp [::kit::env LD_LIBRARY_PATH] }
    if {[llength $lp]} { dict set env LD_LIBRARY_PATH [join $lp :] } else { lappend unset LD_LIBRARY_PATH }

    # home: the private data, or your home and the private data at its own place
    file mkdir $data
    switch -- [dict get $E home] {
        none {
            lappend a --bind $data $home
            lappend rw $home
            set kitdata $home
            set cfg [::kit::env XDG_CONFIG_HOME $home/.config]
            set dat [::kit::env XDG_DATA_HOME $home/.local/share]
            foreach p [list $cfg/gtk-3.0 $cfg/gtk-4.0 $cfg/fontconfig $dat/fonts $dat/icons $dat/themes \
                    $home/.icons $home/.fonts $home/.themes] {
                if {[file exists $p] && [Within $p $home]} { lappend a --ro-bind $p $p }
            }
        }
        default {
            lappend a [expr {[dict get $E home] eq "rw" ? "--bind" : "--ro-bind"}] $home $home
            lappend real $home
            if {[dict get $E home] eq "rw"} { lappend rw $home }
            set kitdata $data
        }
    }
    # folders
    foreach {name mode} [dict get $E folders] {
        set p [FolderPath $name]
        if {$p eq ""} { puts stderr "kit: [dict get $info short]: the folder $name is not given to an app" ; continue }
        lappend a [expr {$mode eq "rw" ? "--bind-try" : "--ro-bind-try"}] $p $p
        lappend real $p
        if {$mode eq "rw"} { lappend rw $p }
    }
    # kit's own state is never the app's to read or change: a tmpfs over it wherever a bound
    # folder holds it; then the app's private data, which lives in it
    # (one that does not exist holds nothing to hide, and can't be a mount point in a read-only home)
    foreach d [list [::kit::path data] [::kit::path config]] {
        if {![file isdirectory $d]} continue
        foreach r $real { if {[Within $d $r]} { lappend a --tmpfs $d ; break } }
    }
    if {[dict get $E home] ne "none"} {
        lappend a --bind $data $data
        lappend rw $data
    }

    # display
    set wl [::kit::env WAYLAND_DISPLAY wayland-0]
    if {[file pathtype $wl] ne "absolute" && $rt ne ""} { set wl [file join $rt $wl] }
    switch -- [dict get $E display] {
        wayland {
            if {[file pathtype $wl] eq "absolute"} { lappend a --ro-bind-try $wl $wl ; dict set env WAYLAND_DISPLAY $wl }
            lappend unset DISPLAY XAUTHORITY
        }
        x11 {
            if {[regexp {^[^:]*:(\d+)} [::kit::env DISPLAY] -> n]} { lappend a --ro-bind-try /tmp/.X11-unix/X$n /tmp/.X11-unix/X$n }
            set xa [::kit::env XAUTHORITY]
            if {$xa ne ""} { lappend a --ro-bind-try $xa $xa }
            lappend unset WAYLAND_DISPLAY
        }
        default { lappend unset WAYLAND_DISPLAY DISPLAY XAUTHORITY }
    }
    # sound
    if {[dict get $E audio] ne "0" && $rt ne ""} {
        lappend a --ro-bind-try $rt/pipewire-0 $rt/pipewire-0 --ro-bind-try $rt/pulse/native $rt/pulse/native
    } else {
        lappend unset PULSE_SERVER PIPEWIRE_REMOTE
    }
    # devices
    set dev {}
    if {[dict get $E gpu]} { lappend dev /dev/dri {*}[lsort [glob -nocomplain /dev/nvidia*]] }
    if {[dict get $E input]} { lappend dev /dev/input /dev/uinput {*}[lsort [glob -nocomplain /dev/hidraw*]] }
    if {[dict get $E camera]} { lappend dev {*}[lsort [glob -nocomplain /dev/video* /dev/media*]] }
    foreach d $dev { lappend a --dev-bind-try $d $d }
    if {[dict get $E gpu] || [dict get $E input] || [dict get $E camera]} {
        foreach d {/sys/bus /sys/class /sys/dev /sys/devices /run/udev} { lappend a --ro-bind-try $d $d }
    }
    # the session bus, filtered
    set talk [expr {[dict get $E dbus] eq "none" ? {} : [dict get $E dbus]}]
    if {[dict get $E notifications] && "org.freedesktop.Notifications" ni $talk} { lappend talk org.freedesktop.Notifications }
    set proxy "" ; set proxysock ""
    set bus [::kit::env DBUS_SESSION_BUS_ADDRESS]
    if {[llength $talk] && $bus ne "" && $rt ne "" && $record ne ""} {
        set px [auto_execok xdg-dbus-proxy]
        if {$px eq ""} {
            puts stderr "kit: [dict get $info short] runs without the session bus: xdg-dbus-proxy is not installed"
            lappend unset DBUS_SESSION_BUS_ADDRESS
        } else {
            set proxysock [file join $record bus]
            set proxy [list {*}$px $bus $proxysock --filter {*}[lmap n $talk { string cat --talk= $n }]]
            lappend a --ro-bind $proxysock $rt/bus
            dict set env DBUS_SESSION_BUS_ADDRESS unix:path=$rt/bus
        }
    } else {
        lappend unset DBUS_SESSION_BUS_ADDRESS
    }
    # the network's name service: resolv.conf is often a link into /run, which is the sandbox's own
    if {[dict get $E network] eq "yes" && ![catch {file type /etc/resolv.conf} ty] && $ty eq "link"} {
        set t [file normalize /etc/resolv.conf]
        if {![Within $t /etc]} { lappend a --ro-bind-try $t $t }
    }

    # where it starts: here if the sandbox has this folder, else its home
    set cwd [pwd]
    set chdir $home
    foreach r $real { if {[Within $cwd $r]} { set chdir $cwd ; break } }
    lappend a --chdir $chdir

    # the command, the kit at /app, behind kit-landlock: no inherited descriptor, and the Landlock
    # layer where the kernel has one
    set exe [lindex $cmd 0]
    if {[Within $exe $tree]} { set exe $app[string range $exe [string length [string trimright $tree /]] end] }
    set cmd [lreplace $cmd 0 0 $exe]
    set hx [helper]
    set ll [landlock]
    if {$hx ne ""} {
        lappend a --ro-bind $hx $inner/landlock
        set pre [list $inner/landlock]
        if {$ll eq ""} { lappend pre --no-landlock }
        foreach p [expr {$ll eq "" ? {} : [lsort -unique $rw]}] { lappend pre --rw $p }
        if {$ll ne "" && [dict get $E network] ne "yes"} { lappend pre --no-tcp }
        set cmd [list {*}$pre -- {*}$cmd]
    }

    dict set env HOME $home
    dict set env KIT_NAME [dict get $info name]
    dict set env KIT_VERSION [dict get $info version]
    dict set env KIT_TREE $app
    dict set env KIT_DATA $kitdata
    return [dict create bwrap $a cmd $cmd env $env unset [lsort -unique $unset] proxy $proxy proxysock $proxysock \
        perms $E landlock [expr {$ll ne ""}]]
}

# ---- launches the monitor can name -------------------------------------------------------------------
# $XDG_RUNTIME_DIR/kit/sandbox/<pid of kit run>/: "kit" (a Tcl dict: name, short, version) and
# "info" (bubblewrap's --info-fd JSON: child-pid, pid-namespace, ...).  Every process of the
# sandbox shares that pid namespace; the System monitor groups them under the kit by it.
proc ::kit::sandbox::recordDir {} {
    set rt [Runtime]
    if {$rt eq ""} { return "" }
    return [file join $rt kit sandbox]
}

# Drop the records of launches whose kit run is gone (killed before it could tidy up).
proc ::kit::sandbox::prune {} {
    set d [recordDir]
    if {$d eq ""} return
    foreach r [glob -nocomplain -directory $d -types d *] {
        set pid [file tail $r]
        if {[string is integer -strict $pid] && ![file exists /proc/$pid]} { catch {file delete -force $r} }
    }
}
