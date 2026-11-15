#!/bin/sh
# The whole Ribbon session under labwc: make install into a temp root, then that installed tree laid over /usr in a
# private mount namespace (overlayfs, as 90-install.sh step 5 does; the host's own /etc/xdg/labwc hidden) and the real
# /usr/bin/ribbon-session run there with labwc's headless backend. It runs ribbon-firstrun and ribbon-input, then
# labwc with Ribbon's config layers and its real autostart, which hands its environment to the user dinit and starts
# each service through it. dinitctl is a stand-in that does what the user dinit does for those calls (setenv keeps
# the activation environment; start runs the service's command from /usr/lib/dinit.d/user with it, its output kept)
# and kanshi a stand-in that stays up; the session and system buses are private, with a polkitd stand-in
# (tests/fixtures/polkitd.tcl) on the system bus. Checked: the session's environment, every service asked of dinit
# and running (the HUD's daemon up, or gone with status 0 when nothing asks for it: --auto), Settings → Keyboard's
# input.conf turned into labwc's input layer and the layout the session's programs get, the
# shell's bars and the wallpaper on screen, org.freedesktop.Notifications owned on the session bus, the polkit agent
# registered, the first-login welcome up, and no error or traceback in any service's output or the shell's log
# (labwc 0.7.1's complaints about the 0.20 options in rc.xml aside). Then the same without dinit: the autostart's
# own keep loop starts the services (their output is not kept there). Skips what this host cannot do.
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
for t in cc make tclsh8.6 wish8.6 labwc Xwayland grim xwininfo dbus-daemon dbus-send; do
	command -v $t >/dev/null 2>&1 || { echo "  skip the session under labwc (no $t)"; exit 0; }
done
# not root: a user namespace for the mounts (-r), then back to our own uid for the session (DROP), so that what it
# tells the buses and Xwayland (EXTERNAL's uid, the socket directory's owner) is what the kernel says of it
if [ "$(id -u)" = 0 ]; then NS="unshare -m" DROP=; else NS="unshare -rm" DROP="unshare --map-user=$(id -u) --map-group=$(id -g)"; fi
T=$(mktemp -d)
MARK=ribbon-session-test-$$
BUSES=
# every process of the run carries RIBBON_TEST_MARK in its environment: found (and ended) by it, nothing else
ours() { for e in /proc/[0-9]*/environ; do grep -qz "^RIBBON_TEST_MARK=$MARK\$" "$e" 2>/dev/null && { p=${e#/proc/}; echo "${p%/environ}"; }; done; }
stop_all() { for p in $(ours); do kill "$p" 2>/dev/null; done; k=0; while [ -n "$(ours)" ] && [ $k -lt 40 ]; do sleep 0.1; k=$((k + 1)); done; for p in $(ours); do kill -9 "$p" 2>/dev/null; done; }
cleanup() { stop_all; for p in $BUSES; do kill "$p" 2>/dev/null; done; [ -n "${SESSION_KEEP:-}" ] && echo "kept $T" || rm -rf "$T"; }
trap cleanup EXIT
fails=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
# poll SECONDS COMMAND...: until COMMAND succeeds, at most SECONDS
poll() { _l=$(($1 * 10)); shift; _i=0; while ! "$@"; do [ $_i -ge $_l ] && return 1; sleep 0.1; _i=$((_i + 1)); done; }

# ---- the installed tree
# (SESSION_ROOT=DIR: an installed tree made before, instead of building one)
R=${SESSION_ROOT:-$T/root}
mkdir -p "$T/dist"
if [ -z "${SESSION_ROOT:-}" ]; then
	{ make -s build O="$T/build" DISTDIR="$T/dist" && make -s install O="$T/build" DISTDIR="$T/dist" DESTDIR="$R" PREFIX=/usr; } >"$T/build.log" 2>&1 ||
		{ sed 's/^/       /' "$T/build.log" | tail -20; echo "  FAIL make build / make install"; exit 1; }
fi
# shellcheck disable=SC2086
$NS sh -c "mount -t overlay overlay -o lowerdir=$R/usr/lib:/usr/lib /usr/lib && test -d /usr/lib/ribbon/shell" 2>/dev/null ||
	{ echo "  skip the session under labwc (no mount namespace with overlayfs here)"; exit 0; }

# ---- stand-ins, laid over the installed tree
mkdir -p "$T/top/usr/bin" "$T/dsvc"
cat > "$T/top/usr/bin/dinitctl" <<EOF
#!/bin/sh
# dinitctl stand-in: the user dinit's setenv and start, as the session's autostart uses them
L=$T/dsvc
[ "\${1:-}" = --user ] || exit 1; shift
case \${1:-} in
setenv) shift; echo "setenv \$*" >> \$L/log; for kv in "\$@"; do printf '%s\n' "\$kv" >> \$L/env; done ;;
start)
	n=\$2; f=/usr/lib/dinit.d/user/\$n
	[ -r "\$f" ] || { echo "start \$n: no such service" >> \$L/log; exit 1; }
	cmd=\$(sed -n 's/^command *= *//p' "\$f")
	echo "start \$n \$cmd" >> \$L/log
	# the command, with only the environment setenv gave (dinit's activation environment); its end is logged
	ENVF=\$L/env CMD=\$cmd N=\$n LOG=\$L/log setsid sh -c 'set --; while IFS= read -r kv; do set -- "\$@" "\$kv"; done < "\$ENVF"
		env -i "\$@" sh -c "exec \$CMD"; echo "exit \$N \$?" >> "\$LOG"' >"\$L/\$n.out" 2>&1 </dev/null &
	;;
*) exit 1 ;;
esac
EOF
printf '#!/bin/sh\necho "kanshi $*" >> %s/kanshi.log\nexec tail -f /dev/null\n' "$T" > "$T/top/usr/bin/kanshi"
chmod +x "$T/top/usr/bin/dinitctl" "$T/top/usr/bin/kanshi"

# ---- private buses: the session's, and a system bus with the polkitd stand-in
cat > "$T/bus.conf" <<XML
<busconfig><type>session</type><listen>unix:dir=$T</listen><auth>EXTERNAL</auth>
<policy context="default"><allow send_destination="*"/><allow own="*"/><allow receive_sender="*"/><allow eavesdrop="true"/></policy></busconfig>
XML
bus() { timeout 300 dbus-daemon --nofork --nopidfile --config-file="$T/bus.conf" --print-address=3 3>"$T/$1.addr" 2>>"$T/daemon.log" &
	BUSES="$BUSES $!"; poll 10 test -s "$T/$1.addr" || { cat "$T/daemon.log"; echo "  FAIL dbus-daemon ($1)"; exit 1; }; }
bus session; bus system
SBUS=$(cat "$T/session.addr"); YBUS=$(cat "$T/system.addr")

# ---- one session: phase NAME DINIT(1|0)
phase() {
	P=$T/$1; rm -rf "$P"; mkdir -p "$P/home/.config/ribbon" "$P/rt" "$P/cache"; chmod 700 "$P/rt"
	# Settings → Keyboard chose a German layout: ribbon-input generates labwc's input layer from it at login
	printf 'LAYOUT=de\n' > "$P/home/.config/ribbon/input.conf"
	rm -f "$T/dsvc/log" "$T/dsvc/env" "$T/dsvc"/*.out "$T/kanshi.log" "$T/polkitd.out"
	if [ "$2" = 1 ]; then top=$T/top/usr/bin; else mkdir -p "$T/nodinit"; cp "$T/top/usr/bin/kanshi" "$T/nodinit/"; top=$T/nodinit; fi
	cat > "$P/ns.sh" <<EOF
set -e
mount -t overlay overlay -o lowerdir=$top:$R/usr/bin:/usr/bin /usr/bin
mount -t overlay overlay -o lowerdir=$R/usr/lib:/usr/lib /usr/lib
mount -t overlay overlay -o lowerdir=$R/usr/share:/usr/share /usr/share
mount -t tmpfs tmpfs /etc/xdg/labwc
# Xwayland's socket directory, our own (the host's is root's, which a user namespace sees as nobody's)
mkdir -p /tmp/.X11-unix; mount -t tmpfs -o mode=1777 tmpfs /tmp/.X11-unix
exec $DROP sh $P/login.sh
EOF
	cat > "$P/login.sh" <<EOF
unset TCLLIBPATH WAYLAND_DISPLAY DISPLAY XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_DIRS XDG_CONFIG_DIRS XDG_CURRENT_DESKTOP
export PATH=/usr/bin:/bin HOME=$P/home XDG_RUNTIME_DIR=$P/rt XDG_CACHE_HOME=$P/cache
# the login gives the session its id (pam_elogind); the polkit agent registers for it
export DBUS_SESSION_BUS_ADDRESS=$SBUS DBUS_SYSTEM_BUS_ADDRESS=$YBUS RIBBON_TEST_MARK=$MARK XDG_SESSION_ID=1
export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1
tail -f /dev/null | tclsh8.6 $REPO/tests/fixtures/polkitd.tcl > $T/polkitd.out 2>&1 &
exec timeout 300 /usr/bin/ribbon-session
EOF
	# a login's environment, not this script's: only what ns.sh sets
	env -i PATH=/usr/bin:/bin $NS sh "$P/ns.sh" >"$P/session.out" 2>&1 &
	# the processes of this run, by command line
	cmdlines() { for p in $(ours); do tr '\0' ' ' 2>/dev/null < /proc/$p/cmdline; echo; done 2>/dev/null; }
	running() { cmdlines | grep -q -- "$1"; }
	allup() { for c in "ribbon/shell/main.tcl -name ribbon-shell" "ribbon-wall" "ribbon/polkit/" "settings/power-idle.tcl" "welcome/main.tcl"; do running "$c" || return 1; done; }
	poll 40 allup
	cmdlines > "$P/procs"
	# labwc is what everything else runs in: without it, its output is the one cause to show
	if ! grep -q -- '^labwc ' "$P/procs"; then
		# its errors (its complaints about rc.xml's newer options aside), or the end of the output if it gave none
		why=$(grep -E '\[ERROR\]|^Error|cannot|failed' "$P/session.out" | grep -vE '\[\.\./src/(common/parse-bool|config/rcxml)\.c' | tail -n 8)
		bad "$1: labwc did not start:"; { [ -n "$why" ] && echo "$why" || tail -n 12 "$P/session.out"; } | sed 's/^/       /'
		stop_all; return
	fi
	for c in "labwc --merge-config|labwc" "ribbon/shell/main.tcl -name ribbon-shell|the shell" "ribbon-wall |the wallpaper (ribbon-wall)" \
		"ribbon/polkit/|the polkit agent" "settings/power-idle.tcl|the idle timers (power-idle.tcl)" "welcome/main.tcl|the first-login welcome"; do
		pat=${c%%|*} what=${c#*|}
		grep -q -- "$pat" "$P/procs" && ok "$1: $what is running" || bad "$1: $what is not running"
	done
	[ -s "$T/kanshi.log" ] && ok "$1: kanshi was started" || bad "$1: kanshi was not started"
	pid=$(for p in $(ours); do tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q '^labwc ' && echo "$p"; done | head -n1)
	env_of() { [ -r /proc/"$1"/environ ] && tr '\0' '\n' < /proc/"$1"/environ; }
	if [ -n "$pid" ]; then
		env_of "$pid" > "$P/labwc.env"
		grep -qx 'XDG_CURRENT_DESKTOP=Ribbon:wlroots' "$P/labwc.env" && grep -qx 'XDG_SESSION_TYPE=wayland' "$P/labwc.env" &&
			grep -qx "XDG_CONFIG_DIRS=$P/home/.local/state/ribbon/xdg:$P/home/.local/state/ribbon/xdg-display:$P/home/.local/state/ribbon/xdg-input:/usr/share/ribbon/xdg:/etc/xdg" "$P/labwc.env" &&
			ok "$1: labwc runs with Ribbon's desktop name and config layers (--merge-config)" || bad "$1: labwc's environment: $(grep -E '^XDG_(CURRENT|SESSION_TYPE|CONFIG_DIRS)' "$P/labwc.env" | tr '\n' ' ')"
	fi
	[ -f "$P/home/.config/ribbon/theme.conf" ] && [ -f "$P/home/.config/ribbon/welcome-pending" ] &&
		ok "$1: ribbon-firstrun ran (the default scheme applied, the welcome flagged)" || bad "$1: ribbon-firstrun did not run: $(ls "$P/home/.config/ribbon" 2>/dev/null | tr '\n' ' ')"

	# the X display the session's programs were given, from the shell's environment
	sp=$(for p in $(ours); do tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q 'shell/main.tcl' && echo "$p"; done | head -n1)
	DISP=$(env_of "${sp:-0}" | sed -n 's/^DISPLAY=//p'); WL=$(env_of "${sp:-0}" | sed -n 's/^WAYLAND_DISPLAY=//p')
	[ -f "$P/home/.local/state/ribbon/xdg-input/labwc/rc.xml" ] && env_of "${sp:-0}" | grep -qx 'XKB_DEFAULT_LAYOUT=de' &&
		ok "$1: ribbon-input wrote labwc's input layer from input.conf, and the session's programs have its layout (XKB_DEFAULT_LAYOUT=de)" ||
		bad "$1: the input layer: $(ls "$P/home/.local/state/ribbon/xdg-input/labwc" 2>/dev/null | tr '\n' ' ') the shell's $(env_of "${sp:-0}" | grep XKB_DEFAULT_LAYOUT)"
	bars() { DISPLAY=$DISP xwininfo -root -tree 2>/dev/null | grep '"RibbonShellBar")' | grep -qv ' 1x1+'; }
	if [ -n "$DISP" ] && poll 20 bars; then ok "$1: the shell's bars are mapped on XWayland ($DISP)"; else bad "$1: no shell bar window"; fi
	welcome() { DISPLAY=$DISP xwininfo -root -tree 2>/dev/null | grep -q '"RibbonWelcome")'; }
	poll 10 welcome && ok "$1: the welcome's window is up" || bad "$1: no welcome window"
	# on screen: the left bar's band holds the bar (its text and edges: a spread of grey levels), the middle the wallpaper
	band() { XDG_RUNTIME_DIR=$P/rt WAYLAND_DISPLAY=$WL grim -t ppm "$P/shot.ppm" 2>/dev/null && tclsh8.6 tests/ppm-band.tcl "$P/shot.ppm" 20 12 400 42; }
	drawn() { b=$(band); [ -n "$b" ] && awk "BEGIN{exit !($b > 8)}"; }
	poll 20 drawn && ok "$1: the bars are on screen (grim: the left bar's band)" || bad "$1: the bars are not on screen (band spread ${b:-?})"
	mid=$(tclsh8.6 tests/ppm-band.tcl "$P/shot.ppm" 600 400 900 600 2>/dev/null)
	grep -q 'ribbon-wall' "$P/procs" && [ -n "$mid" ] && ok "$1: the wallpaper is drawn under them (spread $mid in the middle)" || bad "$1: no wallpaper"
	owner() { dbus-send --bus="$SBUS" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner string:org.freedesktop.Notifications >/dev/null 2>&1; }
	poll 20 owner && ok "$1: org.freedesktop.Notifications is owned on the session bus (the shell's server)" || bad "$1: no notification server on the session bus"
	registered() { grep -q '^registered ' "$T/polkitd.out" 2>/dev/null; }
	poll 20 registered && ok "$1: the polkit agent registered with polkitd" || bad "$1: the polkit agent did not register: $(tail -n2 "$T/polkitd.out" 2>/dev/null)"

	if [ "$2" = 1 ] && [ ! -s "$T/dsvc/log" ]; then
		bad "dinit: the autostart never called dinitctl"
		outs=
	elif [ "$2" = 1 ]; then
		L=$T/dsvc/log
		grep '^setenv ' "$L" | grep -q 'WAYLAND_DISPLAY=' && grep '^setenv ' "$L" | grep -q 'DISPLAY=:' && grep '^setenv ' "$L" | grep -q 'XDG_CURRENT_DESKTOP=Ribbon:wlroots' &&
			ok "dinit: the autostart gave the user dinit the session's environment (WAYLAND_DISPLAY, DISPLAY, XDG_CURRENT_DESKTOP)" || bad "dinit: setenv: $(grep '^setenv' "$L" | cut -c1-200)"
		for s in ribbon-wall ribbon-shell ribbon-polkit ribbon-hud kanshi ribbon-power-idle; do
			grep -q "^start $s /" "$L" && ok "dinit: $s was started as a user service" || bad "dinit: $s was not started through dinit"
		done
		# the HUD's daemon (--auto) stays while Show when a game starts is on somewhere (the default), or leaves with status 0
		if grep -q '^exit ribbon-hud ' "$L"; then
			grep -q '^exit ribbon-hud 0$' "$L" && ok "dinit: the HUD's daemon left with status 0 (nothing asks for it)" || bad "dinit: the HUD's daemon: $(grep '^exit ribbon-hud' "$L"; tail -n3 "$T/dsvc/ribbon-hud.out")"
		else
			grep -q 'hud/main.tcl -name ribbon-hud --auto' "$P/procs" && ok "dinit: the HUD's daemon is up (--auto, Show when a game starts is on by default)" || bad "dinit: the HUD's daemon neither runs nor left"
		fi
		for s in ribbon-wall ribbon-shell ribbon-polkit ribbon-hud kanshi ribbon-power-idle; do
			[ $s = ribbon-hud ] && grep -q '^exit ribbon-hud 0$' "$L" && continue
			grep -q "^exit $s " "$L" && bad "dinit: $s ended: $(grep "^exit $s " "$L"; tail -n3 "$T/dsvc/$s.out")"
		done
		outs=$T/dsvc
	else
		[ ! -e "$T/dsvc/log" ] && ok "keep: without dinit the autostart starts the services itself" || bad "keep: dinitctl was called"
		# the HUD's daemon too (--auto stays up while Show when a game starts is on, the default)
		grep -q 'hud/main.tcl -name ribbon-hud --auto' "$P/procs" && ok "keep: the HUD's daemon is up (--auto)" || bad "keep: the HUD's daemon is not running"
		outs=
	fi
	# no error or traceback anywhere
	err=$({ [ -z "$outs" ] || cat "$outs"/*.out; cat "$P/session.out" "$P/home/.local/state/ribbon/shell.log"; } 2>/dev/null |
		grep -iE "error|traceback|while executing|can't find package|couldn't (read|load)|invalid command name|no such file" |
		grep -vE 'Errors from xkbcomp|xkbcomp|XKB|\[ERROR\] \[xwayland/xwm.c|Failed to set fd limit|MESA: error: ZINK|Failed to initialize glamor' |
		grep -vE '\[ERROR\] \[\.\./src/(common/parse-bool|config/rcxml)\.c' | head -n5)
	[ -z "$err" ] && ok "$1: no error or traceback in the services' output, the session's or the shell's log" || { bad "$1: errors:"; echo "$err" | sed 's/^/       /'; }
	stop_all
}
for ph in ${SESSION_PHASES:-dinit keep}; do
	case $ph in dinit) phase dinit 1 ;; keep) phase keep 0 ;; esac
done

[ $fails -eq 0 ] && echo "the session under labwc: all checks passed" || echo "the session under labwc: $fails checks failed"
[ $fails -eq 0 ]
