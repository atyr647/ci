# polkit-helper.tcl - a stand-in for polkit-agent-helper-1 (tests/steps.d/70-polkit.sh). The real one is
# setuid root and needs PAM, neither of which can run here; this speaks the same pipe protocol:
#   argv: USER                  (the cookie is NOT in argv: it is the first line on stdin)
#   stdout: PAM_PROMPT_ECHO_OFF|PAM_PROMPT_ECHO_ON|PAM_ERROR_MSG|PAM_TEXT_INFO text, then SUCCESS or FAILURE
#   stdin: one line per prompt
# On success it tells polkitd (the real one does so as root): AuthenticationAgentResponse2.
# $POLKIT_FIX/pam.txt holds "USER PASSWORD UID" lines. $POLKIT_FIX/helper.log gets argv, the whole
# environment and the cookie (so the tests can prove nothing secret is in them) but never the answer.
# Users with special names: talky (info, error and an echoed token before the password), dies (exits
# after the prompt), hang (never answers EOF: only a signal ends it).
set dir $env(POLKIT_FIX)
set user [lindex $argv 0]
fconfigure stdout -buffering line
fconfigure stdin -buffering line
set cookie [gets stdin]
set log [open $dir/helper.log a]
puts $log "helper pid [pid] argv [list $argv] argc [llength $argv]"
puts $log "cookie $cookie"
foreach k [lsort [array names env]] { puts $log "env $k=$env($k)" }
flush $log

set pw ""; set uid 0
set f [open $dir/pam.txt]
foreach l [split [read $f] \n] { if {[lindex $l 0] eq $user} { set pw [lindex $l 1]; set uid [lindex $l 2] } }
close $f

if {$user eq "talky"} {
	puts "PAM_TEXT_INFO Touch the key"
	puts "PAM_ERROR_MSG Token expired, retrying"
	puts "PAM_PROMPT_ECHO_ON Token: "
	gets stdin tok
	unset tok
}
puts "PAM_PROMPT_ECHO_OFF Password: "
if {$user eq "dies"} { puts $log "exiting after the prompt"; close $log; exit 3 }
if {$user eq "hang"} { vwait forever }
if {[gets stdin got] < 0} { puts $log "eof on stdin"; close $log; exit 2 }
set ok [expr {$pw ne "" && $got eq $pw}]
unset got
if {$ok} {
	# the real helper does this as root, before it prints SUCCESS
	package require ribbon::dbus
	set bus [ribbon::dbus::connect system]
	$bus call org.freedesktop.PolicyKit1 /org/freedesktop/PolicyKit1/Authority org.freedesktop.PolicyKit1.Authority \
		AuthenticationAgentResponse2 "us(sa{sv})" $uid $cookie [list unix-user [list uid [list u $uid]]]
	puts $log "response sent"
	close $log
	puts SUCCESS
	exit 0
}
puts $log "wrong password"
close $log
puts FAILURE
exit 1
