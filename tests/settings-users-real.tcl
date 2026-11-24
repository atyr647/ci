# settings-users-real.tcl - users.tcl changing YOUR OWN password through the real passwd(1): run as an ordinary
# account (tests/settings-users-real.sh makes one in a private /etc) with its current password and a new one.
#   tclsh8.6 tests/settings-users-real.tcl FILES-DIR CURRENT NEW
lassign $argv D cur new
source -encoding utf-8 $D/apps/settings/users.tcl
set fails 0
proc check {what ok} { global fails; if {[uplevel 1 [list expr $ok]]} { puts "  ok   $what" } else { puts "  FAIL $what"; incr fails } }
proc done {status msg} { set ::got [list $status $msg] }
proc settle {} { set t [after 30000 { set ::got {timeout {}} }]; set ::got {}; while {$::got eq {}} { vwait ::got }; after cancel $t }
users::refresh
set me [dict get [users::model] me]
check "the model knows who you are ($me), from the kernel's uid and the real /etc/passwd" {$me ne "" && [dict get [users::user $me] you]}
users::set_password $me $new "not-the-password" done; settle
check "passwd(1) with a wrong current password: [lindex $got 1]" {$got eq {failed {The current password is not right}}}
users::set_password $me "abc" $cur done; settle
check "passwd(1) refusing a new password, in PAM's words: [lindex $got 1]" {[lindex $got 0] eq "failed" && [lindex $got 1] ni {{} {The password was not changed} {The current password is not right}}}
users::set_password $me $new $cur done; settle
check "passwd(1) with the right current password changes it" {$got eq {ok {}}}
exit [expr {$fails > 0}]
