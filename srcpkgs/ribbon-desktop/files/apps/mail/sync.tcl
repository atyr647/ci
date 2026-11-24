# sync.tcl - keeps one account's mail on this computer in step with its IMAP server, and sends through its SMTP
# server. Event-driven: one IMAP session per account runs a queue of jobs (sync every folder, sync one folder, push
# local flag changes, save a sent message to Sent), then waits in IDLE on the Inbox (RFC 2177) or, when the server
# has no IDLE, until the next poll. Every folder is checked again every -poll milliseconds.
#
#   mail::sync::start ACCT OPTS      start (or restart) the account. OPTS:
#        -imap {-host H -port N -security tls|starttls|none -user U ?-cafile F?}
#        -smtp {-host H -port N -security tls|starttls|none -user U ?-cafile F?}
#        -password CMD     called as "CMD ACCT" for the password at each login (the Secret Service lookup lives
#                          with the caller; the password is never kept here)
#        -store CMD        the local store, called as "CMD METHOD ACCT ..." (below)
#        -status CMD       called as "CMD ACCT STATUS" whenever the status changes (mail::sync::status)
#        -poll MS (300000)  -idlerestart MS (600000; RFC 2177 asks for less than 29 minutes, and NAT routers drop
#        quiet connections sooner)  -retry {MS ...} (waits before reconnecting: 15 s, 1, 2, 5, 15 min, then 15 min)
#   mail::sync::stop ACCT            log out and stop
#   mail::sync::check ACCT           check every folder now (a stopped account after a login error is started again)
#   mail::sync::push ACCT FOLDER     the store has local flag changes for FOLDER: send them
#   mail::sync::send ACCT FROM RCPTS BYTES CMD   SMTP; CMD gets "ok" once the server took the message, or "error
#                          KIND MESSAGE". Then a copy with \Seen is saved to the account's Sent folder (made when
#                          there is none; not on Gmail, which saves its own) and fetched into the store like any
#                          other message. A failed save shows in the status as kind "save".
#   mail::sync::move ACCT FOLDER UID DEST   move the message UID of FOLDER to the server folder DEST ("" deletes it):
#                          a queued job (kept by the store until done, so it survives a quit). UID MOVE when the
#                          server has MOVE (RFC 6851); else UID COPY, \Deleted and UID EXPUNGE with UIDPLUS (RFC 4315);
#                          else UID COPY and \Deleted (a plain EXPUNGE would also remove what another client marked).
#                          A delete is \Deleted and UID EXPUNGE (EXPUNGE without UIDPLUS: it is only asked for in
#                          Trash). A refused move shows in the status as kind "move".
#   mail::sync::status ACCT          {state S folder F checked SECONDS kind K message M retry SECONDS}
#        state: connecting, syncing, idle (IDLE on the Inbox), waiting (polling), offline (a retry is due), error
#        (needs the user: login refused, certificate not trusted), stopped. checked: when every folder was last
#        checked ("" before the first). kind/message: the last error.
#
# The store (W2 mail store's API; FOLDER is the server's name for it, as LIST gave it):
#   folders ACCT                          the folders the store holds for ACCT
#   folder ACCT FOLDER DISPLAY ROLE DELIM  the server has FOLDER (DISPLAY is its name as text; ROLE is inbox, sent,
#                                         drafts, trash, junk, archive, all, flagged or "")
#   drop ACCT FOLDER                      the server no longer has FOLDER
#   state ACCT FOLDER                     what setstate kept: {uidvalidity N uidnext N highestmodseq N} or {}
#   setstate ACCT FOLDER DICT
#   reset ACCT FOLDER                     UIDVALIDITY changed: the store's UIDs for FOLDER mean nothing now
#   uids ACCT FOLDER                      {UID FLAGS ...} for the messages it holds from the server
#   deliver ACCT FOLDER UID FLAGS DATE BYTES   a message from the server (DATE: INTERNALDATE as clock seconds)
#   flags ACCT FOLDER UID FLAGS           the server's flags for a message changed
#   expunge ACCT FOLDER UID               the message is gone from the server
#   pending ACCT FOLDER                   local flag changes not yet on the server: {{UID ADD REMOVE} ...}
#   pushed ACCT FOLDER UID                that change is on the server now
#   outbox ACCT BYTES                     (optional) keep a copy of a message just sent in the local Sent: an id
#   outboxed ACCT                         (optional) {ID BYTES ...}: those copies the server has not got yet
#   saved ACCT ID                         (optional) the server has that copy: the local one goes
#   move ACCT FOLDER UID DEST             (optional) remember a move asked for: {uidvalidity N} of FOLDER then
#   moves ACCT                            (optional) {{FOLDER UID DEST UIDVALIDITY} ...}: the moves not done yet
#   moved ACCT FOLDER UID RESULT          (optional) that move is over. RESULT: {status ok|error dest DEST ?destuid N?}
#
# Flags are IMAP's: \Seen \Answered \Flagged \Deleted \Draft and keywords ($Forwarded, labels).

source [file join [file dirname [info script]] imap.tcl]
source [file join [file dirname [info script]] smtp.tcl]

namespace eval ::mail::sync {
	variable A                ;# array: handle -> account dict. Each start makes a new handle ("ACCT#N"), so that
	array set A {}            ;# callbacks of a stopped run never act on a later one
	variable cur              ;# array: ACCT -> its handle
	array set cur {}
	variable gen 0
	variable batch 25         ;# messages per UID FETCH of new mail
}

proc ::mail::sync::H {name} {
	variable cur
	expr {[info exists cur($name)] ? $cur($name) : ""}
}

proc ::mail::sync::start {name opts} {
	variable A
	variable cur
	variable gen
	if {[H $name] ne ""} { stop $name }
	set acct $name#[incr gen]
	set cur($name) $acct
	set o [dict merge {-imap {} -smtp {} -password "" -store "" -status "" -poll 300000 -idlerestart 600000
		-retry {15000 60000 120000 300000 900000}} $opts]
	set A($acct) [dict create acct $name opts $o sid "" jobs {} job "" folders {} inbox INBOX selected "" \
		status [dict create state connecting folder "" checked "" kind "" message "" retry ""] \
		tries 0 timers {} run "" gmail 0 stopped 0 wait 0 noidle 0]
	Queue $acct all
	# moves and deletes asked for before Mail last quit
	if {![catch {Store $acct moves} waiting]} {
		foreach mv $waiting { Queue $acct [list move {*}$mv] }
	}
	# copies of sent mail the server did not get before Mail last quit
	if {![catch {Store $acct outboxed} waiting]} {
		foreach {id bytes} $waiting { SaveCopy $acct $bytes $id }
	}
	Poll $acct
	Kick $acct
}

proc ::mail::sync::stop {name} {
	variable A
	variable cur
	set acct [H $name]
	unset -nocomplain cur($name)
	if {![info exists A($acct)]} return
	foreach t [dict get $A($acct) timers] { after cancel $t }
	after cancel [dict get $A($acct) run]
	set sid [dict get $A($acct) sid]
	set cbs [Waiting $acct]
	unset A($acct)
	if {$sid ni {"" connecting}} {
		if {[mail::imap::idling $sid]} { mail::imap::done $sid }
		if {[mail::imap::alive $sid]} { mail::imap::logout $sid ::mail::sync::Ignore } else { mail::imap::close $sid }
	}
	foreach cb $cbs { catch {{*}$cb error stopped "the account was stopped"} }
}
proc ::mail::sync::Ignore {args} {}

# a callback from a session that has ended (Lost has queued its job again): it stops there
proc ::mail::sync::Gone {acct} {
	variable A
	expr {![info exists A($acct)] || [dict get $A($acct) sid] eq "" || ![mail::imap::alive [dict get $A($acct) sid]]}
}

# callbacks of jobs that will not run now
proc ::mail::sync::Waiting {acct} {
	variable A
	set out {}
	foreach j [concat [list [dict get $A($acct) job]] [dict get $A($acct) jobs]] {
		if {[lindex $j 0] eq "append" && [lindex $j 4] ne ""} { lappend out [lindex $j 4] }
	}
	return $out
}

proc ::mail::sync::Opt {acct k} {
	variable A
	dict get $A($acct) opts $k
}

proc ::mail::sync::status {name} {
	variable A
	set acct [H $name]
	if {![info exists A($acct)]} { return [dict create state stopped folder "" checked "" kind "" message "" retry ""] }
	dict get $A($acct) status
}
proc ::mail::sync::Status {acct args} {
	variable A
	if {![info exists A($acct)]} return
	set old [dict get $A($acct) status]
	set new [dict merge $old $args]
	dict set A($acct) status $new
	set cmd [Opt $acct -status]
	if {$new ne $old && $cmd ne ""} { {*}$cmd [dict get $A($acct) acct] $new }
}

proc ::mail::sync::Store {acct method args} {
	variable A
	{*}[Opt $acct -store] $method [dict get $A($acct) acct] {*}$args
}

# ---- the job queue ----------------------------------------------------------------------------------------------
# jobs: all | {folder NAME} | {push NAME} | {append BOX FLAGS BYTES CMD}; a job already waiting is not added twice
proc ::mail::sync::Queue {acct job} {
	variable A
	set jobs [dict get $A($acct) jobs]
	if {[lindex $job 0] ne "append" && $job in $jobs} return
	if {$job eq "all"} {
		# one full check covers every single-folder job waiting
		set jobs [lmap j $jobs { if {[lindex $j 0] eq "folder"} continue; set j }]
	} elseif {[lindex $job 0] eq "folder" && "all" in $jobs} {
		return
	}
	lappend jobs $job
	dict set A($acct) jobs $jobs
}

proc ::mail::sync::check {name} {
	variable A
	set acct [H $name]
	if {![info exists A($acct)]} return
	if {[dict get $A($acct) stopped]} {
		dict set A($acct) stopped 0
		dict set A($acct) tries 0
	}
	# a check asked for now does not wait out a retry
	dict set A($acct) wait 0
	Queue $acct all
	Kick $acct
}
proc ::mail::sync::push {name folder} {
	variable A
	set acct [H $name]
	if {![info exists A($acct)]} return
	Queue $acct [list push $folder]
	Kick $acct
}

proc ::mail::sync::move {name folder uid dest} {
	variable A
	set acct [H $name]
	if {![info exists A($acct)] || ![string is digit -strict $uid]} return
	set v ""
	if {![catch {Store $acct move $folder $uid $dest} r] && [dict exists $r uidvalidity]} { set v [dict get $r uidvalidity] }
	Queue $acct [list move $folder $uid $dest $v]
	Kick $acct
}

proc ::mail::sync::Kick {acct} {
	variable A
	if {![info exists A($acct)] || [dict get $A($acct) run] ne ""} return
	dict set A($acct) run [after 0 [list ::mail::sync::Run $acct]]
}

proc ::mail::sync::Run {acct} {
	variable A
	if {![info exists A($acct)]} return
	dict set A($acct) run ""
	if {[dict get $A($acct) stopped] || [dict get $A($acct) job] ne ""} return
	set sid [dict get $A($acct) sid]
	if {$sid eq ""} {
		if {![dict get $A($acct) wait]} { Connect $acct }
		return
	}
	if {![mail::imap::alive $sid]} return
	if {[mail::imap::idling $sid] || [dict exists $A($acct) idling]} {
		# IDLE ends first; its callback runs the queue
		if {[llength [dict get $A($acct) jobs]]} { mail::imap::done $sid }
		return
	}
	set jobs [dict get $A($acct) jobs]
	if {![llength $jobs]} { Rest $acct; return }
	set job [lindex $jobs 0]
	dict set A($acct) jobs [lrange $jobs 1 end]
	dict set A($acct) job $job
	switch -- [lindex $job 0] {
		all { Status $acct state syncing; FolderList $acct }
		folder { Status $acct state syncing; SyncFolder $acct [lindex $job 1] [list ::mail::sync::JobDone $acct] }
		push { Status $acct state syncing; SyncFolder $acct [lindex $job 1] [list ::mail::sync::JobDone $acct] }
		append { Append $acct {*}[lrange $job 1 end] }
		move { Status $acct state syncing; Move $acct {*}[lrange $job 1 end] }
	}
}
proc ::mail::sync::JobDone {acct args} {
	variable A
	if {[Gone $acct]} return
	dict set A($acct) job ""
	Kick $acct
}

# nothing to do: IDLE on the Inbox, or wait for the next poll
proc ::mail::sync::Rest {acct} {
	variable A
	set sid [dict get $A($acct) sid]
	set inbox [dict get $A($acct) inbox]
	if {![mail::imap::has $sid IDLE] || [dict get $A($acct) noidle]} {
		# no IDLE (or the Inbox would not open): the next poll checks again
		Status $acct state waiting folder ""
		return
	}
	if {[dict get $A($acct) selected] ne $inbox} {
		# the Inbox is synced (and so selected) before IDLE
		Queue $acct [list folder $inbox]
		Kick $acct
		return
	}
	dict set A($acct) idling 1
	Status $acct state idle folder ""
	Timer $acct idle [Opt $acct -idlerestart] [list ::mail::sync::IdleRestart $acct]
	mail::imap::idle $sid [list ::mail::sync::IdleEnded $acct]
}
proc ::mail::sync::IdleRestart {acct} {
	variable A
	if {![info exists A($acct)]} return
	set sid [dict get $A($acct) sid]
	if {$sid ne "" && [mail::imap::idling $sid]} { mail::imap::done $sid }
}
proc ::mail::sync::IdleEnded {acct status args} {
	variable A
	if {![info exists A($acct)]} return
	dict unset A($acct) idling
	Kick $acct
}

# a named timer per account: setting it again replaces it
proc ::mail::sync::Timer {acct name ms cmd} {
	variable A
	set t [dict get $A($acct) timers]
	if {[dict exists $t $name]} { after cancel [dict get $t $name] }
	dict set t $name [after $ms $cmd]
	dict set A($acct) timers $t
}
proc ::mail::sync::Poll {acct} {
	Timer $acct poll [Opt $acct -poll] [list ::mail::sync::Polled $acct]
}
proc ::mail::sync::Polled {acct} {
	variable A
	if {![info exists A($acct)]} return
	Poll $acct
	if {[dict get $A($acct) stopped]} return
	Queue $acct all
	Kick $acct
}

# ---- the session ------------------------------------------------------------------------------------------------
proc ::mail::sync::Connect {acct} {
	variable A
	set o [Opt $acct -imap]
	set pw ""
	set pcmd [Opt $acct -password]
	# the lookup may wait in the event loop (the Secret Service, its unlock prompt): no second Connect meanwhile
	dict set A($acct) sid connecting
	if {$pcmd ne "" && [catch {{*}$pcmd [dict get $A($acct) acct]} pw]} {
		if {![info exists A($acct)]} return
		dict set A($acct) sid ""
		Status $acct state error kind auth message "the password could not be read: $pw"
		dict set A($acct) stopped 1
		return
	}
	# stopped while the password was looked up
	if {![info exists A($acct)]} return
	Status $acct state connecting kind "" message "" retry ""
	set sid [mail::imap::open [dict merge $o [list -password $pw -onevent [list ::mail::sync::Event $acct] \
		-onclose [list ::mail::sync::Lost $acct]]] [list ::mail::sync::Opened $acct]]
	if {[info exists A($acct)] && [dict get $A($acct) sid] eq "connecting"} { dict set A($acct) sid $sid }
}
proc ::mail::sync::Opened {acct status args} {
	variable A
	if {![info exists A($acct)]} {
		if {$status eq "ok"} { mail::imap::close [lindex $args 0] }
		return
	}
	if {$status ne "ok"} {
		dict set A($acct) sid ""
		Failed $acct {*}$args
		return
	}
	set sid [lindex $args 0]
	dict set A($acct) sid $sid
	dict set A($acct) tries 0
	dict set A($acct) selected ""
	dict set A($acct) gmail [mail::imap::has $sid X-GM-EXT-1]
	dict set A($acct) noidle 0
	Kick $acct
}
# the session ended under a job
proc ::mail::sync::Lost {acct kind msg} {
	variable A
	if {![info exists A($acct)]} return
	dict set A($acct) sid ""
	dict unset A($acct) idling
	set job [dict get $A($acct) job]
	dict set A($acct) job ""
	# the job that was running runs again on the next session
	if {$job ne ""} {
		dict set A($acct) jobs [linsert [dict get $A($acct) jobs] 0 $job]
	}
	Failed $acct $kind $msg
}
proc ::mail::sync::Failed {acct kind msg} {
	variable A
	if {$kind in {auth tls insecure}} {
		# the user has to change something: no retry until mail::sync::check
		dict set A($acct) stopped 1
		Status $acct state error kind $kind message $msg retry ""
		return
	}
	set retry [Opt $acct -retry]
	set n [dict get $A($acct) tries]
	set ms [lindex $retry [expr {min($n, [llength $retry] - 1)}]]
	dict incr A($acct) tries
	dict set A($acct) wait 1
	Status $acct state offline kind $kind message $msg retry [expr {[clock seconds] + $ms / 1000}]
	Timer $acct retry $ms [list ::mail::sync::Retry $acct]
}
proc ::mail::sync::Retry {acct} {
	variable A
	if {![info exists A($acct)]} return
	dict set A($acct) wait 0
	Kick $acct
}

# news from the server, unasked
proc ::mail::sync::Event {acct ev} {
	variable A
	if {![info exists A($acct)]} return
	set box [dict get $A($acct) selected]
	if {$box eq "" || [dict get $ev type] ni {exists expunge fetch}} return
	Queue $acct [list folder $box]
	Kick $acct
}

# ---- every folder -------------------------------------------------------------------------------------------------
proc ::mail::sync::FolderList {acct} {
	variable A
	mail::imap::mailboxes [dict get $A($acct) sid] [list ::mail::sync::Listed $acct]
}
proc ::mail::sync::Role {name flags {delim ""}} {
	foreach f $flags {
		switch -nocase -- $f {
			\\Sent { return sent }
			\\Drafts { return drafts }
			\\Trash { return trash }
			\\Junk { return junk }
			\\Archive { return archive }
			\\All { return all }
			\\Flagged { return flagged }
		}
	}
	if {[string toupper $name] eq "INBOX"} { return inbox }
	# servers that keep every folder under the Inbox (Courier, cPanel hosting: "INBOX.Sent")
	if {$delim ne "" && [string equal -nocase -length 6 $name INBOX$delim] && [string length $delim] == 1} {
		set name [string range $name 6 end]
	}
	# servers without SPECIAL-USE (RFC 6154): the usual names
	switch -nocase -- $name {
		Sent - "Sent Items" - "Sent Messages" - "Sent Mail" { return sent }
		Drafts - Draft { return drafts }
		Trash - "Deleted Items" - "Deleted Messages" - Deleted { return trash }
		Junk - Spam - "Junk E-mail" - "Junk Email" - "Bulk Mail" { return junk }
		Archive - Archives { return archive }
	}
	return ""
}
proc ::mail::sync::Listed {acct status args} {
	variable A
	if {[Gone $acct]} return
	if {$status ne "ok"} { JobDone $acct; return }
	set folders {}
	set inbox INBOX
	foreach m [lindex $args 0] {
		set flags [dict get $m flags]
		set skip 0
		foreach f $flags { if {[string tolower $f] in {\\noselect \\nonexistent}} { set skip 1 } }
		if {$skip} continue
		set name [dict get $m name]
		set role [Role $name $flags [dict get $m delim]]
		# with a non-ASCII name the special-use flag is all that tells the role
		if {$role eq "inbox"} { set inbox $name }
		lappend folders [dict create name $name role $role delim [dict get $m delim]]
	}
	set old [Store $acct folders]
	set names [lmap f $folders {dict get $f name}]
	foreach n $old { if {$n ni $names} { Store $acct drop $n } }
	# a folder the store will not take is left out; the rest of the account still syncs
	set folders [lmap f $folders {
		if {[catch {Store $acct folder [dict get $f name] [mail::imap::utf7_decode [dict get $f name]] [dict get $f role] \
			[dict get $f delim]}]} continue
		set f
	}]
	set names [lmap f $folders {dict get $f name}]
	dict set A($acct) folders $folders
	dict set A($acct) inbox $inbox
	# the Inbox last, so that IDLE needs no other SELECT
	set order [concat [lsearch -all -inline -not -exact $names $inbox] [list $inbox]]
	if {$inbox ni $names} { set order [lrange $order 0 end-1] }
	SyncAll $acct $order
}
proc ::mail::sync::SyncAll {acct order} {
	variable A
	if {[Gone $acct]} return
	if {![llength $order]} {
		Status $acct checked [clock seconds] folder ""
		JobDone $acct
		return
	}
	SyncFolder $acct [lindex $order 0] [list ::mail::sync::SyncAllNext $acct [lrange $order 1 end]]
}
proc ::mail::sync::SyncAllNext {acct order args} { SyncAll $acct $order }

# ---- one folder: SELECT, push local flags, expunges and flags, new mail ------------------------------------------
proc ::mail::sync::SyncFolder {acct box done} {
	variable A
	Status $acct folder [mail::imap::utf7_decode $box]
	set sid [dict get $A($acct) sid]
	mail::imap::select $sid $box [list ::mail::sync::Selected $acct $box $done]
}
proc ::mail::sync::Selected {acct box done status args} {
	variable A
	if {[Gone $acct]} return
	if {$status ne "ok"} {
		# a folder deleted since LIST, or one that cannot be opened: skip it (a lost session is handled by Lost)
		dict set A($acct) selected ""
		if {$box eq [dict get $A($acct) inbox]} { dict set A($acct) noidle 1 }
		{*}$done error {*}$args
		return
	}
	dict set A($acct) selected $box
	set info [lindex $args 0]
	set st [Store $acct state $box]
	if {[dict exists $st uidvalidity] && [dict get $st uidvalidity] ne "" &&
		[dict get $st uidvalidity] ne [dict get $info uidvalidity]} {
		Store $acct reset $box
		set st {}
	}
	set f [dict create box $box info $info st $st done $done]
	if {[dict get $info readonly]} {
		Known $acct $f
	} else {
		Push $acct $f [Store $acct pending $box]
	}
}

proc ::mail::sync::Push {acct f todo} {
	variable A
	if {[Gone $acct]} return
	if {![llength $todo]} { Known $acct $f; return }
	lassign [lindex $todo 0] uid add remove
	set rest [lrange $todo 1 end]
	set sid [dict get $A($acct) sid]
	set steps {}
	if {[llength $add]} { lappend steps [list +FLAGS.SILENT $add] }
	if {[llength $remove]} { lappend steps [list -FLAGS.SILENT $remove] }
	PushSteps $acct $f $uid $steps $rest
}
proc ::mail::sync::PushSteps {acct f uid steps rest {status ok} args} {
	variable A
	# a lost session leaves the change pending for the next one
	if {[Gone $acct]} return
	if {$status ne "ok"} {
		# the server refused the change (a flag it does not keep): the server's flags win at the flag sync below
		Store $acct pushed [dict get $f box] $uid
		Push $acct $f $rest
		return
	}
	if {![llength $steps]} {
		Store $acct pushed [dict get $f box] $uid
		Push $acct $f $rest
		return
	}
	lassign [lindex $steps 0] op flags
	mail::imap::uid_store [dict get $A($acct) sid] $uid $op $flags \
		[list ::mail::sync::PushSteps $acct $f $uid [lrange $steps 1 end] $rest]
}

# the messages the store holds: which are gone, whose flags changed
proc ::mail::sync::Known {acct f} {
	variable A
	set known [Store $acct uids [dict get $f box]]
	dict set f known $known
	if {![dict size $known]} { New $acct $f; return }
	set last [tcl::mathfunc::max {*}[dict keys $known]]
	dict set f last $last
	mail::imap::uid_search [dict get $A($acct) sid] "UID 1:$last" [list ::mail::sync::Present $acct $f]
}
proc ::mail::sync::Present {acct f status args} {
	variable A
	if {[Gone $acct]} return
	if {$status ne "ok"} { {*}[dict get $f done] error {*}$args; return }
	set present [lindex $args 0]
	set box [dict get $f box]
	set have [dict create]
	foreach u $present { dict set have $u 1 }
	foreach u [dict keys [dict get $f known]] {
		if {![dict exists $have $u]} {
			Store $acct expunge $box $u
			dict unset f known $u
		}
	}
	if {![dict size [dict get $f known]]} { New $acct $f; return }
	# with CONDSTORE only the flags changed since the last sync come back
	set sid [dict get $A($acct) sid]
	set mod ""
	set st [dict get $f st]
	set hm [dict get $f info highestmodseq]
	if {[mail::imap::has $sid CONDSTORE] && [dict exists $st highestmodseq] && [dict get $st highestmodseq] ne "" && $hm ne ""} {
		if {[dict get $st highestmodseq] eq $hm} { New $acct $f; return }
		set mod "CHANGEDSINCE [dict get $st highestmodseq]"
	}
	set var ::mail::sync::flags[incr ::mail::sync::seq]
	set $var {}
	mail::imap::uid_fetch $sid "1:[dict get $f last]" "UID FLAGS" [list ::mail::sync::FlagsDone $acct $f $var] \
		[list ::mail::sync::FlagSeen $var] $mod
}
proc ::mail::sync::FlagSeen {var d} {
	upvar #0 $var acc
	lappend acc [dict get $d UID] [expr {[dict exists $d FLAGS] ? [dict get $d FLAGS] : {}}]
}
proc ::mail::sync::FlagsDone {acct f var status args} {
	variable A
	upvar #0 $var acc
	set seen $acc
	unset acc
	if {[Gone $acct]} return
	if {$status ne "ok"} { {*}[dict get $f done] error {*}$args; return }
	set box [dict get $f box]
	set known [dict get $f known]
	set waiting {}
	foreach p [Store $acct pending $box] { lappend waiting [lindex $p 0] }
	foreach {u flags} $seen {
		if {![dict exists $known $u] || $u in $waiting} continue
		if {[Same [dict get $known $u] $flags]} continue
		Store $acct flags $box $u $flags
	}
	New $acct $f
}
proc ::mail::sync::Same {a b} {
	expr {[lsort -unique [string tolower $a]] eq [lsort -unique [string tolower $b]]}
}

# new mail: the UIDs above the last one held, fetched in batches; the state is saved after each batch so that an
# interrupted first sync goes on where it stopped
proc ::mail::sync::New {acct f} {
	variable A
	set info [dict get $f info]
	set last [expr {[dict exists $f last] ? [dict get $f last] : 0}]
	set st [dict get $f st]
	if {[dict exists $st uidnext] && [dict get $st uidnext] ne "" && [dict get $st uidnext] - 1 > $last} {
		set last [expr {[dict get $st uidnext] - 1}]
	}
	dict set f from $last
	if {[dict get $info exists] == 0 ||
		([dict get $info uidnext] ne "" && [dict get $info uidnext] <= $last + 1)} {
		Finish $acct $f $last
		return
	}
	mail::imap::uid_search [dict get $A($acct) sid] "UID [expr {$last + 1}]:*" [list ::mail::sync::NewFound $acct $f]
}
proc ::mail::sync::NewFound {acct f status args} {
	if {[Gone $acct]} return
	if {$status ne "ok"} { {*}[dict get $f done] error {*}$args; return }
	set from [dict get $f from]
	# "N:*" also matches the highest UID when that is below N (RFC 3501 6.4.8)
	set uids [lmap u [lindex $args 0] { if {$u <= $from} continue; set u }]
	Fetch $acct $f $uids $from
}
proc ::mail::sync::Fetch {acct f uids top} {
	variable A
	variable batch
	if {[Gone $acct]} return
	if {![llength $uids]} { Finish $acct $f $top; return }
	set now [lrange $uids 0 [expr {$batch - 1}]]
	set rest [lrange $uids $batch end]
	mail::imap::uid_fetch [dict get $A($acct) sid] [join $now ,] "UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK\[\]" \
		[list ::mail::sync::Fetched $acct $f $rest [lindex $now end]] [list ::mail::sync::Arrived $acct [dict get $f box]]
}
proc ::mail::sync::Arrived {acct box d} {
	if {![info exists ::mail::sync::A($acct)] || ![dict exists $d BODY\[\]]} return
	set date ""
	if {[dict exists $d INTERNALDATE]} {
		catch {set date [clock scan [dict get $d INTERNALDATE] -format {%d-%b-%Y %H:%M:%S %z}]}
	}
	Store $acct deliver $box [dict get $d UID] [expr {[dict exists $d FLAGS] ? [dict get $d FLAGS] : {}}] $date [dict get $d BODY\[\]]
}
proc ::mail::sync::Fetched {acct f rest top status args} {
	variable A
	if {[Gone $acct]} return
	if {$status ne "ok"} { {*}[dict get $f done] error {*}$args; return }
	set st [Store $acct state [dict get $f box]]
	dict set st uidvalidity [dict get $f info uidvalidity]
	dict set st uidnext [expr {$top + 1}]
	Store $acct setstate [dict get $f box] $st
	Fetch $acct $f $rest $top
}
proc ::mail::sync::Finish {acct f top} {
	set info [dict get $f info]
	set st [dict create uidvalidity [dict get $info uidvalidity] \
		uidnext [expr {[dict get $info uidnext] ne "" ? max([dict get $info uidnext], $top + 1) : $top + 1}] \
		highestmodseq [dict get $info highestmodseq]]
	Store $acct setstate [dict get $f box] $st
	{*}[dict get $f done] ok
}

# ---- moves and deletes ------------------------------------------------------------------------------------------
proc ::mail::sync::Move {acct box uid dest v} {
	variable A
	Status $acct folder [mail::imap::utf7_decode $box]
	mail::imap::select [dict get $A($acct) sid] $box [list ::mail::sync::MoveSelected $acct $box $uid $dest $v]
}
proc ::mail::sync::MoveSelected {acct box uid dest v status args} {
	variable A
	if {[Gone $acct]} return
	if {$status ne "ok"} {
		dict set A($acct) selected ""
		MoveOver $acct $box $uid $dest error [lindex $args end]
		return
	}
	dict set A($acct) selected $box
	set info [lindex $args 0]
	# the folder's UIDs were renumbered since: UID means another message now (or none); the sync fetches it anew
	if {$v ne "" && [dict get $info uidvalidity] ne $v} {
		MoveOver $acct $box $uid $dest error "the folder changed on the server"
		return
	}
	if {[dict get $info readonly]} {
		MoveOver $acct $box $uid $dest error "the folder is read-only"
		return
	}
	set sid [dict get $A($acct) sid]
	set next [list ::mail::sync::MoveStep $acct $box $uid $dest]
	if {$dest eq ""} {
		mail::imap::uid_store $sid $uid +FLAGS.SILENT [list \\Deleted] [list {*}$next expunge {}]
	} elseif {[mail::imap::has $sid MOVE]} {
		mail::imap::uid_move $sid $uid $dest [list {*}$next done {}]
	} else {
		mail::imap::uid_copy $sid $uid $dest [list {*}$next deleted {}]
	}
}
# the steps after the first: STEP names what comes next; R is what the copy or move told (COPYUID)
proc ::mail::sync::MoveStep {acct box uid dest step r status args} {
	variable A
	if {[Gone $acct]} return
	if {$status ne "ok"} {
		MoveOver $acct $box $uid $dest error [lindex $args end] $r
		return
	}
	if {$r eq "" && $step in {deleted done}} { set r [lindex $args 0] }
	set sid [dict get $A($acct) sid]
	set next [list ::mail::sync::MoveStep $acct $box $uid $dest]
	switch -- $step {
		deleted { mail::imap::uid_store $sid $uid +FLAGS.SILENT [list \\Deleted] [list {*}$next expunge $r] }
		expunge {
			if {[mail::imap::has $sid UIDPLUS]} {
				mail::imap::uid_expunge $sid $uid [list {*}$next done $r]
			} elseif {$dest eq ""} {
				# a delete is only asked for in Trash, where every message marked \Deleted is meant to go
				mail::imap::expunge $sid [list {*}$next done $r]
			} else {
				MoveOver $acct $box $uid $dest ok "" $r
			}
		}
		done { MoveOver $acct $box $uid $dest ok "" $r }
	}
}
proc ::mail::sync::MoveOver {acct box uid dest status msg {r ""}} {
	set res [dict create status $status dest $dest]
	if {[dict exists $r src] && [dict exists $r dst]} {
		set i [lsearch -exact [dict get $r src] $uid]
		if {$i >= 0 && $i < [llength [dict get $r dst]]} { dict set res destuid [lindex [dict get $r dst] $i] }
	}
	catch {Store $acct moved $box $uid $res}
	if {$status ne "ok"} {
		Status $acct kind move message "a message could not be moved on the server: $msg"
	} elseif {$dest ne ""} {
		# the message in its new folder: fetched (or matched with the copy moved here) at once
		Queue $acct [list folder $dest]
	}
	JobDone $acct
}

# ---- sending ---------------------------------------------------------------------------------------------------------
proc ::mail::sync::send {name from rcpts bytes cmd} {
	variable A
	set acct [H $name]
	if {![info exists A($acct)]} { after 0 [list {*}$cmd error stopped "the account is not started"]; return }
	set pw ""
	set pcmd [Opt $acct -password]
	if {$pcmd ne "" && [catch {{*}$pcmd [dict get $A($acct) acct]} pw]} {
		after 0 [list {*}$cmd error auth "the password could not be read: $pw"]
		return
	}
	if {![info exists A($acct)]} { after 0 [list {*}$cmd error stopped "the account was stopped"]; return }
	mail::smtp::send [dict merge [Opt $acct -smtp] [list -password $pw]] $from $rcpts $bytes \
		[list ::mail::sync::Sent $acct $bytes $cmd]
}
proc ::mail::sync::Sent {acct bytes cmd status args} {
	variable A
	if {$status ne "ok"} { {*}$cmd error {*}$args; return }
	# the copy is in the store's Sent at once (and stays there if Mail quits before the server has it), until the
	# server's copy replaces it
	set id ""
	if {[info exists A($acct)]} { catch {set id [Store $acct outbox $bytes]} }
	{*}$cmd ok
	if {![info exists A($acct)]} return
	SaveCopy $acct $bytes $id
	Kick $acct
}
# IMAP takes a message with CRLF line ends only (RFC 3501 6.3.11); the copy keeps its Bcc header
proc ::mail::sync::SaveCopy {acct bytes id} {
	Queue $acct [list append "" [list \\Seen] [string map {\n \r\n} [string map {\r\n \n \r \n} $bytes]] \
		[expr {$id eq "" ? "" : [list ::mail::sync::Saved $acct $id]}]]
}
# the server has the copy (or files its own, Gmail): the store's local one goes
proc ::mail::sync::Saved {acct id status args} {
	if {$status eq "ok" && [info exists ::mail::sync::A($acct)]} { catch {Store $acct saved $id} }
}
proc ::mail::sync::Append {acct box flags bytes cb} {
	variable A
	set sid [dict get $A($acct) sid]
	if {$box eq ""} {
		set sent ""
		foreach f [dict get $A($acct) folders] { if {[dict get $f role] eq "sent"} { set sent [dict get $f name]; break } }
		if {[dict get $A($acct) gmail]} {
			# Gmail files what it sends in Sent by itself; a copy would be a second one
			if {$sent ne ""} { Queue $acct [list folder $sent] }
			if {$cb ne ""} { catch {{*}$cb ok} }
			JobDone $acct
			return
		}
		if {$sent eq ""} {
			mail::imap::create $sid Sent [list ::mail::sync::Created $acct $flags $bytes $cb]
			return
		}
		set box $sent
	}
	mail::imap::append_msg $sid $box $flags $bytes [list ::mail::sync::Appended $acct $box $cb]
}
proc ::mail::sync::Created {acct flags bytes cb status args} {
	variable A
	if {[Gone $acct]} return
	# made now (or made by someone else meanwhile): the next LIST gives its role by name
	dict lappend A($acct) folders [dict create name Sent role sent delim /]
	Store $acct folder Sent Sent sent /
	mail::imap::append_msg [dict get $A($acct) sid] Sent $flags $bytes [list ::mail::sync::Appended $acct Sent $cb]
}
proc ::mail::sync::Appended {acct box cb status args} {
	variable A
	# a lost session: the append job is queued again by Lost
	if {[Gone $acct]} return
	if {$status ne "ok"} {
		Status $acct kind save message "the message was sent but not saved to Sent: [lindex $args end]"
	} else {
		Queue $acct [list folder $box]
	}
	if {$cb ne ""} { catch {{*}$cb $status {*}$args} }
	JobDone $acct
}
