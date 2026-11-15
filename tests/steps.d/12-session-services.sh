#!/bin/sh
# The session's services and the system services Ribbon ships (audit 75, 202, 97, 172, 274):
#   1. every dinit description in the tree passes tests/lint-dinit.py with no --known names; the seven system daemons
#      (NetworkManager, bluetoothd, polkitd, chronyd, power-profiles-daemon, cronie, nftables) have one; each session
#      program labwc's autostart starts is a user service with the shell's restart policy (a restart 2 s after a crash,
#      at most 5 starts in 60 s) and the same command as the autostart's fallback;
#   2. the autostart with a stand-in dinitctl: the session's variables (DISPLAY and XDG_SESSION_ID among them) go to
#      the user dinit, every program is started through `dinitctl --user start`, a service dinit will not start falls
#      back to the program itself, and conky is not started;
#   3. the autostart without dinit (stand-in programs, a stand-in Wayland socket): each program starts; SIGSEGV brings
#      it back within a few seconds; a clean exit is not restarted; a crash loop stops after 5 starts; after the
#      session's socket is gone nothing is restarted;
#   4. the same under headless labwc (when it is installed): the autostart's programs come up with DISPLAY and
#      WAYLAND_DISPLAY, a SIGSEGV'd one comes back, and when labwc exits a crash is not restarted;
#   5. build/install/install.sh's pam line puts greetd's "Log in without a password" rule ahead of the password check
#      of a Void/Arch-like and a Debian-like /etc/pam.d/greetd (Settings' users::pam_nopass then sees it), only once,
#      and uninstall takes it out again; its account line makes _greeter (home /var/lib/greetd, nologin, its own group)
#      in a staged /etc and adds it to video and input where those groups exist; the real manifest is held to the
#      template's system_accounts.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
note() { echo "  note $*"; }
T=$(mktemp -d)
cleanup() {
	# only what this step started: the autostart's loops (their command line names this step's folder) and the
	# stand-ins (their pids are listed)
	pkill -f "$T/" 2>/dev/null
	[ -f "$T/pids" ] && xargs kill -9 < "$T/pids" 2>/dev/null
	[ -n "${LABWC:-}" ] && kill "$LABWC" 2>/dev/null
	rm -rf "$T"
}
trap cleanup EXIT
AUTOSTART=srcpkgs/ribbon-desktop/files/xdg/labwc/autostart
SYS=srcpkgs/ribbon-dinit/files/services
USR=srcpkgs/ribbon-dinit/files/user-services
# wait_for SECONDS COMMAND...: poll until COMMAND succeeds
wait_for() {
	w=$1; shift
	i=0
	while [ "$i" -lt $((w * 10)) ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
	return 1
}

# ---- 1. the descriptions --------------------------------------------------------------------------------------
if out=$(python3 tests/lint-dinit.py "$SYS" srcpkgs/ribbon-tools/files/services srcpkgs/ribbon-desktop/files/services 2>&1) &&
	out2=$(python3 tests/lint-dinit.py "$USR" srcpkgs/ribbon-kit/files/services 2>&1); then
	ok "lint-dinit, no --known names: $out; $out2"
else
	echo "$out"; echo "${out2:-}"; fail "lint-dinit without --known names"
fi
for s in NetworkManager bluetoothd polkitd chronyd power-profiles-daemon cronie nftables; do
	f=$SYS/$s
	if [ -f "$f" ] && grep -q '^depends-on: system$' "$f" && grep -q '^command = /' "$f"; then
		ok "system service $s ($(sed -n 's/^command = //p' "$f"))"
	else
		fail "system service $s: missing, or no absolute command, or not after 'system'"
	fi
done
for s in NetworkManager bluetoothd polkitd power-profiles-daemon; do
	grep -q '^depends-on: dbus$' "$SYS/$s" 2>/dev/null || fail "$s does not depend on dbus (it is a system-bus service)"
done
grep -q '^stop-command = /usr/sbin/nft flush ruleset$' "$SYS/nftables" && ok "nftables: stopping it flushes the ruleset" ||
	fail "nftables has no flush stop-command"
for f in "$SYS"/* "$USR"/*; do
	v=$(sed -n 's/^restart *= *//p' "$f")
	case ${v:-none} in none | yes | true | no | false | on-failure) ;; *) fail "$f: restart = $v is not a dinit value" ;; esac
done
# autostart lines `service NAME CMD...` against the user services
svcs=$(sed -n 's/^service \([^ ]*\) .*/\1/p' "$AUTOSTART")
[ "$(echo "$svcs" | wc -w)" = 6 ] && ok "the autostart starts 6 session services: $(echo $svcs)" ||
	fail "the autostart starts $(echo "$svcs" | wc -w) services, not 6: $(echo $svcs)"
for s in $svcs; do
	f=$USR/$s
	[ -f "$f" ] || { fail "user service $s: no $f"; continue; }
	want=$(sed -n "s/^service $s //p" "$AUTOSTART")
	got=$(sed -n 's/^command = //p' "$f" | sed 's|^/usr/bin/||')
	[ "$got" = "$want" ] || fail "user service $s runs '$got', the autostart's fallback '$want'"
	r=$(sed -n 's/^restart *= *//p' "$f")
	if { [ "$r" = on-failure ] || [ "$r" = true ]; } && grep -q '^restart-delay = 2$' "$f" &&
		grep -q '^restart-limit-count = 5$' "$f" && grep -q '^restart-limit-interval = 60$' "$f"; then
		ok "user service $s: restarted ($r) after 2 s, at most 5 starts in 60 s"
	else
		fail "user service $s: not the shell's restart policy"
	fi
done
if grep -qi 'conky' "$AUTOSTART"; then fail "the autostart still starts conky"; else ok "the autostart does not start conky"; fi
grep -q 'cuts out' "$AUTOSTART" && fail "the autostart still says ribbon-wall cuts out the bars" || :

# ---- the stand-ins ----------------------------------------------------------------------------------------------
S=$T/stubs B=$T/tools
mkdir -p "$S" "$B" "$T/rt" "$T/home/.config" "$T/log"
chmod 700 "$T/rt"
for t in sh date sleep cat awk; do ln -s "$(command -v "$t")" "$B/$t"; done
# a session program: logs its start, its arguments and DISPLAY; with T/clean-NAME it exits 0, with T/crash-NAME 1;
# otherwise it stays (exec sleep, so a signal ends the very process the autostart started)
for p in ribbon-wall ribbon-shell ribbon-polkit wish kanshi tclsh ribbon-conky ribbon-welcome xrdb; do
	cat > "$S/$p" <<EOF
#!/bin/sh
echo "\$\$" >> "$T/pids"
echo "\$\$ \$* DISPLAY=\${DISPLAY:-} WAYLAND_DISPLAY=\${WAYLAND_DISPLAY:-}" >> "$T/log/$p"
[ -e "$T/clean-$p" ] && exit 0
[ -e "$T/crash-$p" ] && exit 1
exec sleep 600
EOF
	chmod +x "$S/$p"
done
printf '#!/bin/sh\nexit 0\n' > "$S/dbus-update-activation-environment"
chmod +x "$S/dbus-update-activation-environment"
starts() { [ -f "$T/log/$1" ] && wc -l < "$T/log/$1" | tr -d ' ' || echo 0; }
atleast() { [ "$(starts "$1")" -ge "$2" ]; }
lastpid() { tail -n1 "$T/log/$1" 2>/dev/null | cut -d' ' -f1; }
reset() { pkill -f "$T/" 2>/dev/null; [ -f "$T/pids" ] && xargs kill -9 < "$T/pids" 2>/dev/null; rm -f "$T/pids" "$T"/log/* "$T"/clean-* "$T"/crash-*; }
cp "$AUTOSTART" "$T/autostart"

# ---- 2. with a stand-in dinitctl --------------------------------------------------------------------------------
D=$T/dinit
mkdir -p "$D"
cat > "$D/dinitctl" <<EOF
#!/bin/sh
echo "\$*" >> "$T/log/dinitctl"
[ "\$1 \$2" = "--user setenv" ] && { shift 2; printf '%s\n' "\$@" > "$T/setenv.log"; }
[ "\$*" = "--user start ribbon-hud" ] && exit 1
exit 0
EOF
chmod +x "$D/dinitctl"
env -i PATH="$D:$S:$B" HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_RUNTIME_DIR="$T/rt" \
	WAYLAND_DISPLAY=wayland-T DISPLAY=:7 XDG_CURRENT_DESKTOP=Ribbon:wlroots XDG_SESSION_TYPE=wayland XDG_SESSION_ID=c4 \
	XDG_DATA_DIRS=/usr/share:/var/lib/flatpak/exports/share QT_QPA_PLATFORM='wayland;xcb' XCURSOR_THEME=Adwaita \
	MOZ_ENABLE_WAYLAND=1 RIBBON_T_SPACE='a b' sh "$T/autostart"
wait_for 5 test -s "$T/log/wish" || :
# everything ribbon-session and labwc's environment files export reaches the user dinit, as the programs started
# with & got it (the shell's launcher reads XDG_DATA_DIRS; the apps it starts inherit the rest)
miss=
for kv in WAYLAND_DISPLAY=wayland-T DISPLAY=:7 XDG_CURRENT_DESKTOP=Ribbon:wlroots XDG_SESSION_TYPE=wayland \
	XDG_SESSION_ID=c4 XDG_DATA_DIRS=/usr/share:/var/lib/flatpak/exports/share 'QT_QPA_PLATFORM=wayland;xcb' \
	XCURSOR_THEME=Adwaita MOZ_ENABLE_WAYLAND=1 'RIBBON_T_SPACE=a b' "HOME=$T/home"; do
	grep -qxF -- "$kv" "$T/setenv.log" 2>/dev/null || miss="$miss $kv"
done
[ -z "$miss" ] && ok "the session's environment goes to the user dinit ($(wc -l < "$T/setenv.log") variables)" ||
	fail "dinitctl setenv is missing:$miss"
grep -qE '^(PWD|SHLVL|OLDPWD|_)=' "$T/setenv.log" && fail "dinitctl setenv passes the autostart's own PWD/SHLVL" || :
miss=
for s in ribbon-wall ribbon-shell ribbon-polkit ribbon-hud kanshi ribbon-power-idle; do
	grep -qx -- "--user start $s" "$T/log/dinitctl" || miss="$miss $s"
done
[ -z "$miss" ] && ok "every session program is started with dinitctl --user start" || fail "not started through dinit:$miss"
ran=$(for f in "$T"/log/*; do case ${f##*/} in dinitctl | wish) ;; *) printf '%s ' "${f##*/}" ;; esac; done)
[ -z "$ran" ] && ok "under dinit no program is started by the autostart itself" || fail "under dinit the autostart also ran: $ran"
grep -q 'hud/main.tcl -name ribbon-hud --auto' "$T/log/wish" 2>/dev/null &&
	ok "a service dinit will not start (ribbon-hud) falls back to its program" || fail "ribbon-hud's fallback did not run"
reset

# ---- 3. without dinit ------------------------------------------------------------------------------------------
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/rt/wayland-T"
env -i PATH="$S:$B" HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_RUNTIME_DIR="$T/rt" \
	WAYLAND_DISPLAY=wayland-T DISPLAY=:7 sh "$T/autostart"
up() { for p in ribbon-wall ribbon-shell ribbon-polkit wish kanshi tclsh; do [ "$(starts "$p")" -ge 1 ] || return 1; done; }
if wait_for 5 up; then ok "without dinit the autostart starts all six programs"; else fail "without dinit not all started: $(ls "$T/log" | tr '\n' ' ')"; fi
[ "$(starts ribbon-conky)" = 0 ] && ok "conky is not started" || fail "conky was started"
grep -q 'hud/main.tcl -name ribbon-hud --auto' "$T/log/wish" && grep -q 'settings/power-idle.tcl' "$T/log/tclsh" ||
	fail "the HUD daemon or the idle daemon got other arguments"
touch "$T/clean-kanshi" "$T/crash-tclsh"
for p in ribbon-wall ribbon-shell ribbon-polkit wish kanshi tclsh; do kill -SEGV "$(lastpid "$p")"; done
again() { for p in ribbon-wall ribbon-shell ribbon-polkit wish; do [ "$(starts "$p")" -ge 2 ] || return 1; done; }
if wait_for 5 again; then ok "SIGSEGV: ribbon-wall, ribbon-shell, ribbon-polkit and the HUD daemon are back within 5 s"
else fail "SIGSEGV: not all back ($(for p in ribbon-wall ribbon-shell ribbon-polkit wish; do printf '%s=%s ' "$p" "$(starts "$p")"; done))"; fi
# the crash loop: the idle daemon fails on every start from now on: 5 starts in all, then no more
wait_for 15 atleast tclsh 5 || :
sleep 3
[ "$(starts tclsh)" = 5 ] && ok "a crash loop stops after 5 starts" || fail "crash loop: $(starts tclsh) starts"
# kanshi was restarted once after its SIGSEGV and then quit cleanly: not restarted again
[ "$(starts kanshi)" = 2 ] && ok "a clean exit (status 0) is not restarted" || fail "clean exit: kanshi started $(starts kanshi) times"
# the session ends (the Wayland socket goes): a crash is not restarted
rm -f "$T/rt/wayland-T"
n=$(starts ribbon-polkit)
kill -SEGV "$(lastpid ribbon-polkit)"
sleep 3
[ "$(starts ribbon-polkit)" = "$n" ] && ok "after the session's socket is gone a crash is not restarted" ||
	fail "ribbon-polkit was restarted after the session ended"
reset

# ---- 4. under headless labwc -------------------------------------------------------------------------------------
if command -v labwc >/dev/null 2>&1; then
	C=$T/labwc
	mkdir -p "$C" "$T/rt2"
	chmod 700 "$T/rt2"
	cp "$AUTOSTART" "$C/autostart"
	env -i PATH="$S:$B" HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_RUNTIME_DIR="$T/rt2" \
		WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1 \
		"$(command -v labwc)" -C "$C" > "$T/labwc.log" 2>&1 &
	LABWC=$!
	if wait_for 10 up; then
		ok "headless labwc: its autostart starts all six programs"
		grep -q 'DISPLAY=:[0-9]* WAYLAND_DISPLAY=wayland-[0-9]' "$T/log/ribbon-shell" &&
			ok "headless labwc: they get DISPLAY and WAYLAND_DISPLAY ($(head -n1 "$T/log/ribbon-shell" | cut -d' ' -f2-))" ||
			fail "headless labwc: no DISPLAY/WAYLAND_DISPLAY: $(head -n1 "$T/log/ribbon-shell")"
		kill -SEGV "$(lastpid ribbon-wall)"
		wait_for 5 atleast ribbon-wall 2 && ok "headless labwc: ribbon-wall is back after SIGSEGV" ||
			fail "headless labwc: ribbon-wall not restarted"
		kill "$LABWC"; wait "$LABWC" 2>/dev/null; LABWC=
		wait_for 5 sh -c 'for f in "$1"/wayland-*; do [ -S "$f" ] && exit 1; done; exit 0' _ "$T/rt2" || :
		n=$(starts ribbon-wall)
		kill -SEGV "$(lastpid ribbon-wall)"
		sleep 3
		[ "$(starts ribbon-wall)" = "$n" ] && ok "headless labwc: after labwc exits a crash is not restarted" ||
			fail "headless labwc: ribbon-wall restarted after labwc exited"
	else
		sed 's/^/       /' "$T/labwc.log" | tail -5
		fail "headless labwc: the autostart's programs did not start ($(ls "$T/log" | tr '\n' ' '))"
	fi
	[ -n "${LABWC:-}" ] && { kill "$LABWC" 2>/dev/null; wait "$LABWC" 2>/dev/null; LABWC=; }
	reset
else
	note "no labwc: the compositor run is skipped"
fi

# ---- 5. make install: greetd's PAM rule and the _greeter account --------------------------------------------------
FRAG=srcpkgs/ribbon-desktop/files/greetd/pam-nopasswdlogin
M=$T/manifests R=$T/root
mkdir -p "$M" "$R/etc/pam.d" "$R/usr/sbin"
cat > "$M/ribbon-desktop.manifest" <<'EOF'
account _greeter /var/lib/greetd video,input
state /var/lib/greetd 0750 _greeter _greeter
pam etc/pam.d/greetd @files/greetd/pam-nopasswdlogin
EOF
inst() { MANIFESTS=$M O=$T/o RECORD=$T/rec DESTDIR=$R sh build/install/install.sh "$@" ribbon-desktop 2>"$T/inst.err"; }
cat > "$R/etc/pam.d/greetd" <<'EOF'
#%PAM-1.0

auth       required     pam_securetty.so
auth       requisite    pam_nologin.so
auth       include      system-local-login
account    include      system-local-login
session    include      system-local-login
EOF
cp "$R/etc/pam.d/greetd" "$T/greetd.orig"
printf 'root:x:0:0::/root:/bin/sh\nalice:x:1000:1000::/home/alice:/bin/sh\nnobody:x:999:999::/:/sbin/nologin\n' > "$R/etc/passwd"
printf 'root:x:0:\nvideo:x:12:alice\ninput:x:998:\nalice:x:1000:\nnobody:x:999:\n' > "$R/etc/group"
printf 'root:*:19000::::::\nalice:x:19000::::::\n' > "$R/etc/shadow"
printf 'root:::\nvideo:!::alice\ninput:!::\n' > "$R/etc/gshadow"
: > "$R/usr/sbin/nologin"; chmod +x "$R/usr/sbin/nologin"
# the working copies of shadow's files are never readable by others (a cat stand-in sees each one's mode)
W=$T/wrap
mkdir -p "$W"
cat > "$W/cat" <<EOF
#!/bin/sh
for a; do case \$a in *.ribbon-new) stat -c '%a %n' "\$a" >> "$T/modes" ;; esac; done
exec $(command -v cat) "\$@"
EOF
chmod +x "$W/cat"
if (umask 022; PATH=$W:$PATH inst install >/dev/null); then ok "install.sh installs the account, state and pam lines"; else cat "$T/inst.err"; fail "install.sh install"; fi
if grep -q 'gshadow.ribbon-new' "$T/modes" 2>/dev/null && ! grep 'shadow.ribbon-new' "$T/modes" | grep -qv '^600 '; then
	ok "account: gshadow is rewritten through a copy only its owner can read"
else
	fail "account: gshadow's working copy is readable by others: $(grep shadow "$T/modes" 2>/dev/null | tr '\n' ' ')"
fi
order=$(grep -n '' "$R/etc/pam.d/greetd" | grep -E 'pam_nologin|nopasswdlogin|system-local-login' | head -3 | sed 's/:.*//' | tr '\n' ' ')
first=$(grep -n 'ingroup nopasswdlogin' "$R/etc/pam.d/greetd" | cut -d: -f1)
nl=$(grep -n 'pam_nologin' "$R/etc/pam.d/greetd" | cut -d: -f1)
inc=$(grep -n '^auth *include' "$R/etc/pam.d/greetd" | cut -d: -f1)
if [ -n "$first" ] && [ "$first" -gt "$nl" ] && [ "$first" -lt "$inc" ] &&
	grep -q '^auth       sufficient   pam_succeed_if.so user ingroup nopasswdlogin$' "$R/etc/pam.d/greetd"; then
	ok "pam: the nopasswdlogin rule sits after pam_nologin and ahead of the password stack (lines $order)"
else
	cat "$R/etc/pam.d/greetd"; fail "pam: rule order (lines $order)"
fi
pn=$(printf 'source srcpkgs/ribbon-desktop/files/apps/settings/users.tcl\nset f [open {%s}]; puts [users::pam_nopass [read $f]]\n' "$R/etc/pam.d/greetd" | tclsh 2>&1)
[ "$pn" = 1 ] && ok "Settings (users::pam_nopass) sees the rule" || fail "Settings does not see the rule: $pn"
inst install >/dev/null
[ "$(grep -c 'ingroup nopasswdlogin' "$R/etc/pam.d/greetd")" = 1 ] && ok "pam: a second install adds nothing" ||
	fail "pam: the rule is there $(grep -c 'ingroup nopasswdlogin' "$R/etc/pam.d/greetd") times"
# the account
pw=$(grep '^_greeter:' "$R/etc/passwd")
case $pw in
	_greeter:x:997:997:*:/var/lib/greetd:/usr/sbin/nologin) ok "account: $pw (the first free system id, its own group)" ;;
	*) fail "account: passwd line '$pw'" ;;
esac
grep -qx '_greeter:x:997:' "$R/etc/group" && grep -q '^_greeter:!:[0-9]*::::::$' "$R/etc/shadow" &&
	grep -qx '_greeter:!::' "$R/etc/gshadow" && ok "account: its group, shadow and gshadow lines" ||
	fail "account: group/shadow/gshadow lines missing"
grep -qx 'video:x:12:alice,_greeter' "$R/etc/group" && grep -qx 'input:x:998:_greeter' "$R/etc/group" &&
	grep -qx 'video:!::alice,_greeter' "$R/etc/gshadow" && ok "account: added to video and input, members kept" ||
	{ grep -E '^(video|input)' "$R/etc/group" "$R/etc/gshadow"; fail "account: video/input membership"; }
[ "$(grep -c '^_greeter:' "$R/etc/passwd")$(grep -o '_greeter' "$R/etc/group" | wc -l | tr -d ' ')" = 13 ] &&
	ok "account: a second install adds nothing" || fail "account: duplicated by a second install"
inst uninstall >/dev/null
if cmp -s "$R/etc/pam.d/greetd" "$T/greetd.orig"; then ok "uninstall gives /etc/pam.d/greetd back as it was"
else diff "$T/greetd.orig" "$R/etc/pam.d/greetd"; fail "uninstall left the PAM file changed"; fi
# a Debian-like file (@include), a base without the input group, and one without greetd
cat > "$R/etc/pam.d/greetd" <<'EOF'
#%PAM-1.0
auth       requisite    pam_nologin.so
@include common-auth
@include common-account
@include common-session
EOF
sed -i '/^input:/d' "$R/etc/group"
sed -i '/^_greeter:/d' "$R/etc/passwd" "$R/etc/group" "$R/etc/shadow" "$R/etc/gshadow"
sed -i 's/,_greeter$//' "$R/etc/group" "$R/etc/gshadow"
inst install >/dev/null
a=$(grep -n 'ingroup nopasswdlogin' "$R/etc/pam.d/greetd" | cut -d: -f1)
b=$(grep -n '^@include common-auth' "$R/etc/pam.d/greetd" | cut -d: -f1)
[ -n "$a" ] && [ "$a" -lt "$b" ] && ok "pam: ahead of a Debian-style @include common-auth" || { cat "$R/etc/pam.d/greetd"; fail "pam: @include order"; }
grep -q '_greeter' "$R/etc/group" && ! grep -q '^input' "$R/etc/group" && ok "account: a missing group (input) is skipped" ||
	fail "account: missing input group"
inst uninstall >/dev/null
rm -f "$R/etc/pam.d/greetd"
inst install >/dev/null
if [ ! -e "$R/etc/pam.d/greetd" ] && grep -q 'greetd is not installed' "$T/inst.err"; then
	ok "pam: a base without greetd's PAM file gets none, and the install says so"
else
	fail "pam: a PAM file was made where the base had none"
fi
inst uninstall >/dev/null
l=$(MANIFESTS=$M sh build/install/install.sh list ribbon-desktop | grep -E '^[up] ' | tr '\n' ';')
case $l in "u _greeter /var/lib/greetd video,input;p /etc/pam.d/greetd $ROOT/$FRAG;") ok "install.sh list shows them: $l" ;;
	*) fail "install.sh list: $l" ;; esac
# the real manifest, held to the template
RM=build/install/manifests/ribbon-desktop.manifest
acct=$(XBPS_CROSS_BASE='' bash -c '. "$1" >/dev/null 2>&1; echo "$system_accounts $_greeter_homedir $_greeter_pgroups"' _ srcpkgs/ribbon-desktop/template)
if grep -q '^account ' "$RM"; then
	ml=$(sed -n 's/^account //p' "$RM")
	[ "$ml" = "$acct" ] && ok "ribbon-desktop.manifest's account line is the template's system_accounts ($acct)" ||
		fail "manifest account '$ml', template '$acct'"
	al=$(grep -n '^account ' "$RM" | cut -d: -f1); sl=$(grep -n '^state .* _greeter ' "$RM" | cut -d: -f1)
	[ "$al" -lt "${sl:-99999}" ] || fail "the manifest's account line must come before the state line it owns"
	grep -qx 'pam etc/pam.d/greetd @files/greetd/pam-nopasswdlogin' "$RM" || fail "ribbon-desktop.manifest has no pam line"
else
	note "ribbon-desktop.manifest has no account/pam lines yet (INTEGRATION REQUEST W1-session): the template's is '$acct'"
fi

[ "$fails" -eq 0 ] || { echo "session services: $fails failure(s)"; exit 1; }
