# system.tcl's kernels beside the running one (KernelVersions, KernelsBeside): after a system change the kernels the
# /usr view shows that it did not before are handed to kernel-boot-files (a stand-in logs its words); a kernel it
# cannot finish is said and does not stop the change; a missing command is said too. No Mk4tcl, root or mounts.
set top [file dirname [file dirname [file normalize [info script]]]]
set work [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] kit-kernels-[pid]]
file mkdir $work/home $work/usr/lib/modules
set ::env(HOME) $work/home
source -encoding utf-8 $top/srcpkgs/ribbon-kit/files/lib/core.tcl
::kit::init
::kit::need system
set ::kit::P(root) $work   ;# the system scope sets it (target reads it)
set ::env(KIT_USR) $work/usr
set said {}
proc ::kit::note {m} { lappend ::said $m }
set fails 0
proc ok {what cond {detail ""}} { global fails; if {[uplevel 1 [list expr $cond]]} { puts "  ok   $what" } else { puts "  FAIL $what $detail"; incr fails } }
proc kernel {v {image 1}} { global work; file mkdir $work/usr/lib/modules/$v; if {$image} { set f [open $work/usr/lib/modules/$v/vmlinuz w]; puts $f k; close $f } }
proc stub {body} { global work; set f $work/kbf; set fh [open $f w]; puts $fh "#!/bin/sh\n$body"; close $fh; file attributes $f -permissions 0755; set ::env(KIT_KERNEL_BOOT_FILES) $f; file delete $work/log }
proc logged {} { global work; if {[catch {set fh [open $work/log]}]} { return {} }; set d [string trim [read $fh]]; close $fh; return [split $d \n] }

kernel 6.18.60_1; kernel 6.12.1_1 0; file mkdir $work/usr/lib/modules/extra-dir
ok "KernelVersions: the directories with a vmlinuz, sorted (a modules directory with no image is no kernel)" {[::kit::system::KernelVersions] eq {6.18.60_1}} [::kit::system::KernelVersions]
set before [::kit::system::KernelVersions]
kernel 6.18.70-ribbon_1
stub "echo \"\$*\" >> $work/log"
::kit::system::KernelsBeside $before
ok "a kernel that is new in the view: kernel-boot-files install VERSION, once, for it only" {[logged] eq {{install 6.18.70-ribbon_1}}} [logged]
ok "  and it is said that it starts at the next restart" {[string match "*6.18.70-ribbon_1 is on the boot menu*restart*" [lindex $said end]]} $said
set said {}
stub "echo \"\$*\" >> $work/log"
::kit::system::KernelsBeside [::kit::system::KernelVersions]
ok "no new kernel: nothing is run, nothing said" {[logged] eq {} && $said eq {}}
kernel 6.18.71-ribbon_1; kernel 6.19.0-ribbon_1
stub "echo \"\$*\" >> $work/log"
::kit::system::KernelsBeside [list 6.18.60_1 6.18.70-ribbon_1]
ok "two new kernels: both, in order" {[logged] eq {{install 6.18.71-ribbon_1} {install 6.19.0-ribbon_1}}} [logged]
set said {}
stub "echo 'the initramfs for 6.18.71-ribbon_1 could not be built' >&2; exit 1"
::kit::system::KernelsBeside [list 6.18.60_1 6.18.70-ribbon_1 6.19.0-ribbon_1]
ok "kernel-boot-files failing: said with its words, and nothing raised (the change stands)" {[llength $said] == 1 && [string match "*6.18.71-ribbon_1 could not be made bootable: the initramfs for 6.18.71-ribbon_1 could not be built*" [lindex $said 0]]} $said
set said {}
set ::env(KIT_KERNEL_BOOT_FILES) $work/nothing-here
::kit::system::KernelsBeside {}
ok "the command missing: each kernel's absence from the menu is said, with what to run" {[llength $said] == 4 && [string match "*is installed, but*missing*ribbon boot update*" [lindex $said 0]]} $said
ok "afterSwitch calls both (KernelVersions before the view changes, KernelsBeside after)" {[string match {*set kernelsBefore \[KernelVersions\]*mount::activate*KernelsBeside $kernelsBefore*} [string map {"\n" " "} [info body ::kit::system::afterSwitch]]]}
file delete -force $work
if {$fails} { exit 1 }
puts "all kit-system kernel checks passed"
