#!/bin/sh
# The session's small scripts, run unmodified against stand-ins: ribbon-firstrun (the theme on a first login, the
# welcome flag, idempotence, the live ISO), ribbon-conky (its layouts, switching, a bad name, your own file first,
# off), the
# boot service ribbon-power-limit (its command is the installed helper's apply, which puts the saved charge limit
# back on a fixture root) and greetd/greetd-launch (its config fallback and the old gtkgreet config rewritten).
# The scripts read fixed system paths (/etc, /sys, /run, /usr/share/ribbon, /usr/bin/greetd): each run that needs
# them is in a private mount namespace (unshare -m as root, -rm otherwise) that lays the fixtures over those paths,
# so nothing on the host changes. Skips what needs a namespace when there is none.
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
F=$ROOT/srcpkgs/ribbon-desktop/files
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
if [ "$(id -u)" = 0 ]; then NS="unshare -m"; else NS="unshare -rm"; fi
# shellcheck disable=SC2086
if $NS sh -c "mount -t tmpfs t $T" 2>/dev/null; then HAVE_NS=1; else HAVE_NS=; echo "  (no mount namespace here: the checks on fixed paths are skipped)"; fi
# ns SCRIPT: runs the sh SCRIPT in a private mount namespace, with the environment of the caller
# shellcheck disable=SC2086
ns() { $NS sh -c "$1"; }

# stand-ins on PATH: each logs its name and arguments to $T/log
B=$T/bin; mkdir -p "$B"
stub() { printf '#!/bin/sh\necho "${0##*/}${*:+ $*}" >> %s/log\n%s\n' "$T" "${2:-}" > "$B/$1"; chmod +x "$B/$1"; }
log() { cat "$T/log" 2>/dev/null; }

# ---- ribbon-firstrun
stub xdg-user-dirs-update
# ribbon-theme apply writes the theme as the real one does (theme.conf), so the next login migrates instead
stub ribbon-theme 'case $1 in apply) mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/ribbon"; echo "SCHEME=$2" > "${XDG_CONFIG_HOME:-$HOME/.config}/ribbon/theme.conf" ;; esac'
H=$T/fr; mkdir -p "$H"
firstrun() { : > "$T/log"; env -i PATH="$B:/usr/bin:/bin" HOME="$H" sh "$F/bin/ribbon-firstrun"; }
if firstrun && [ "$(log)" = "xdg-user-dirs-update
ribbon-theme apply ribbon --quiet --no-reload --no-login" ]; then
	ok "firstrun: a first login makes the user folders and applies the default scheme for you only (--no-login)"
else bad "firstrun first login: $(log | tr '\n' ';')"; fi
[ -f "$H/.config/ribbon/welcome-pending" ] && ok "firstrun: the welcome is flagged for a first login" || bad "firstrun: no welcome-pending"
if firstrun && [ "$(log | tail -n1)" = "ribbon-theme migrate" ] && [ "$(cat "$H/.config/ribbon/theme.conf")" = "SCHEME=ribbon" ]; then
	ok "firstrun: the next login only migrates the scheme (yours is not applied again)"
else bad "firstrun second login: $(log | tr '\n' ';')"; fi
rm -f "$H/.config/ribbon/welcome-pending"; : > "$H/.config/ribbon/welcome-done"
firstrun; [ ! -e "$H/.config/ribbon/welcome-pending" ] && ok "firstrun: after the welcome is done it is not flagged again" || bad "firstrun: welcome flagged again after welcome-done"
H=$T/fr2; mkdir -p "$H"
stub ribbon-theme 'exit 1'
firstrun && ok "firstrun: a failing ribbon-theme does not fail the login (exit 0)" || bad "firstrun: exit status $? with a failing ribbon-theme"
H=$T/fr3; mkdir -p "$H"
rm -f "$B/xdg-user-dirs-update"
if env -i PATH="$B:/usr/bin:/bin" HOME="$H" XDG_CONFIG_HOME="$H/cfg" sh "$F/bin/ribbon-firstrun" && [ -f "$H/cfg/ribbon/welcome-pending" ]; then
	ok "firstrun: XDG_CONFIG_HOME is followed, and no xdg-user-dirs-update is no error"
else bad "firstrun with XDG_CONFIG_HOME"; fi
if [ -n "$HAVE_NS" ]; then
	H=$T/fr4; mkdir -p "$H" "$T/etc/ribbon"; : > "$T/etc/ribbon/live"
	ns "mount -t overlay overlay -o lowerdir=$T/etc:/etc /etc && env -i PATH=$B:/usr/bin:/bin HOME=$H sh $F/bin/ribbon-firstrun"
	[ ! -e "$H/.config/ribbon/welcome-pending" ] && ok "firstrun: the live ISO (/etc/ribbon/live) gets no welcome" || bad "firstrun: welcome flagged on the live ISO"
	rm -rf "${T:?}/etc"
fi

# ---- ribbon-conky
if [ -n "$HAVE_NS" ]; then
	mkdir -p "$T/usr/share/ribbon/conky/layouts" "$T/usr/share/ribbon/conky/lua"
	cp "$F"/conky/layouts/*.conf "$T/usr/share/ribbon/conky/layouts/"; cp "$F/conky/lua/ribbon.lua" "$T/usr/share/ribbon/conky/lua/"
	stub pkill
	stub conky 'echo "W=$RIBBON_SCREEN_W" >> '"$T"'/log'
	stub wlr-randr 'printf "HEADLESS-1 \"Headless output 1\"\n  Modes:\n    1920x1080 px, 60.000000 Hz (preferred)\n    2560x1440 px, 59.951000 Hz (current)\n"'
	H=$T/ck; mkdir -p "$H"
	# the user ribbon-conky stops conky for: you, as seen inside the namespace (unshare -r maps you to 0 there)
	NSUID=$(ns 'id -u')
	conky() { : > "$T/log"; ns "mount -t overlay overlay -o lowerdir=$T/usr/share:/usr/share /usr/share && env -i PATH=$B:/usr/bin:/bin HOME=$H sh $F/bin/ribbon-conky $*" > "$T/ck.out" 2>&1; }
	# conky runs detached (setsid): wait for its line, at most 5 s
	waitconky() { i=0; while [ $i -lt 50 ] && ! grep -q '^W=' "$T/log" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done; }
	conky layouts
	[ "$(tr '\n' ' ' < "$T/ck.out")" = "calendar card clock gaming graphs strip " ] && ok "conky: six layouts listed (calendar card clock gaming graphs strip)" || bad "conky layouts: $(cat "$T/ck.out")"
	conky; waitconky
	if log | grep -qx "conky -c /usr/share/ribbon/conky/layouts/card.conf" && log | grep -qx "W=2560" && log | grep -qx "pkill -x -u $NSUID conky"; then
		ok "conky: with no choice it starts the card layout, the current mode's width (2560) passed, the old one stopped"
	else bad "conky default start: $(log | tr '\n' ';')"; fi
	conky layout gaming; waitconky
	if [ "$(cat "$H/.config/ribbon/conky.conf")" = "LAYOUT=gaming" ] && log | grep -qx "conky -c /usr/share/ribbon/conky/layouts/gaming.conf"; then
		ok "conky: layout gaming is kept in ~/.config/ribbon/conky.conf and started"
	else bad "conky layout gaming: $(log | tr '\n' ';') conf $(cat "$H/.config/ribbon/conky.conf" 2>/dev/null)"; fi
	conky; waitconky
	log | grep -qx "conky -c /usr/share/ribbon/conky/layouts/gaming.conf" && ok "conky: the next start keeps the chosen layout" || bad "conky restart: $(log | tr '\n' ';')"
	if conky layout nope; then bad "conky: layout nope succeeded"
	else
		[ "$(cat "$H/.config/ribbon/conky.conf")" = "LAYOUT=gaming" ] && grep -q "no layout 'nope'" "$T/ck.out" && ! log | grep -q '^conky ' \
			&& ok "conky: an unknown layout is refused (exit 2, the choice kept, nothing started)" || bad "conky layout nope: $(cat "$T/ck.out")"
	fi
	echo "LAYOUT=gone" > "$H/.config/ribbon/conky.conf"
	conky; waitconky
	log | grep -qx "conky -c /usr/share/ribbon/conky/layouts/card.conf" && ok "conky: a layout that is no longer shipped falls back to card" || bad "conky fallback: $(log | tr '\n' ';')"
	mkdir -p "$H/.config/conky"; echo 'conky.config = {}' > "$H/.config/conky/ribbon.conf"
	conky; waitconky
	log | grep -qx "conky -c $H/.config/conky/ribbon.conf" && ok "conky: your own ~/.config/conky/ribbon.conf wins" || bad "conky own file: $(log | tr '\n' ';')"
	conky off
	log | grep -qx "pkill -x -u $NSUID conky" && ! log | grep -q '^conky ' && ok "conky: off stops it and starts nothing" || bad "conky off: $(log | tr '\n' ';')"
fi
# the layouts are Lua (conky 1.10+) and draw with the installed ribbon.lua
if command -v luac >/dev/null 2>&1; then
	n=0; for f in "$F"/conky/layouts/*.conf; do luac -p "$f" 2>"$T/luac.err" || { bad "conky layout $(basename "$f") does not parse: $(cat "$T/luac.err")"; continue; }; n=$((n + 1)); done
	[ $n -eq 6 ] && ok "conky: the six layouts parse as Lua"
fi
miss=$(grep -L "lua_load = '/usr/share/ribbon/conky/lua/ribbon.lua'" "$F"/conky/layouts/*.conf)
[ -z "$miss" ] && grep -q 'usr/share/ribbon/conky/lua' srcpkgs/ribbon-desktop/template \
	&& ok "conky: each layout loads ribbon.lua from where the package installs it" || bad "conky: layouts not loading the installed ribbon.lua: $miss"

# ---- ribbon-power-limit: the boot service runs the installed helper's apply
SV=$F/services/ribbon-power-limit
cmd=$(sed -n 's/^command *= *//p' "$SV")
if [ "$cmd" = "/usr/bin/ribbon-power-helper apply" ] && grep -qx 'type = scripted' "$SV" && [ -x "$F/apps/settings/bin/ribbon-power-helper" ] \
	&& grep -q '"${FILESDIR}"/apps/\*/' srcpkgs/ribbon-desktop/template && grep -q 'ribbon-power-limit' srcpkgs/ribbon-tools/files/bin/postinstall; then
	ok "power-limit: a scripted boot service running /usr/bin/ribbon-power-helper apply (apps/settings/bin, enabled by postinstall)"
else bad "power-limit: command '$cmd'"; fi
if command -v tclsh8.6 >/dev/null 2>&1; then
	P=$T/proot; mkdir -p "$P/etc/ribbon" "$P/sys/class/power_supply/BAT0"
	echo Battery > "$P/sys/class/power_supply/BAT0/type"; echo 100 > "$P/sys/class/power_supply/BAT0/charge_control_end_threshold"
	printf 'CHARGE_LIMIT=80\n' > "$P/etc/ribbon/power-helper.conf"
	set -- $cmd; shift
	if env RIBBON_POWER_TEST=1 RIBBON_POWER_ROOT="$P" tclsh8.6 "$F/apps/settings/bin/ribbon-power-helper" "$@" >"$T/pl.out" 2>&1 \
		&& [ "$(cat "$P/sys/class/power_supply/BAT0/charge_control_end_threshold")" = 80 ]; then
		ok "power-limit: the service's command puts the saved limit (80) back on the battery"
	else bad "power-limit apply: $(cat "$T/pl.out") threshold $(cat "$P/sys/class/power_supply/BAT0/charge_control_end_threshold")"; fi
fi

# ---- greetd-launch
if [ -n "$HAVE_NS" ]; then
	mkdir -p "$T/gb" "$T/gs/ribbon/greetd" "$T/ge/greetd"
	printf '#!/bin/sh\necho "greetd $*"\n[ "$1" = --config ] && cat "$2"\n' > "$T/gb/greetd"; chmod +x "$T/gb/greetd"
	cp "$F/greetd/config.toml" "$T/gs/ribbon/greetd/config.toml"
	greet() { ns "mount -t overlay overlay -o lowerdir=$T/gb:/usr/bin /usr/bin && mount -t overlay overlay -o lowerdir=$T/gs:/usr/share /usr/share \
		&& mount -t overlay overlay -o lowerdir=$T/ge:/etc /etc && mount -t tmpfs run /run && sh $F/greetd/greetd-launch" > "$T/g.out" 2>&1; }
	greet
	head -n1 "$T/g.out" | grep -qx "greetd --config /usr/share/ribbon/greetd/config.toml" && ok "greetd-launch: without /etc/greetd/ribbon.toml, Ribbon's config" || bad "greetd-launch default: $(head -n3 "$T/g.out")"
	grep -q 'ribbon-greeter' "$F/greetd/config.toml" && ok "greetd-launch: Ribbon's config starts ribbon-greeter" || bad "greetd config.toml does not start ribbon-greeter"
	printf '[terminal]\nvt = 7\n[default_session]\ncommand = "ribbon-greeter"\nuser = "_greeter"\n' > "$T/ge/greetd/ribbon.toml"
	greet
	head -n1 "$T/g.out" | grep -qx "greetd --config /etc/greetd/ribbon.toml" && ok "greetd-launch: an admin's /etc/greetd/ribbon.toml wins" || bad "greetd-launch /etc: $(head -n3 "$T/g.out")"
	printf '[default_session]\ncommand = "cage -s -- gtkgreet -l"\nuser = "_greeter"\n[initial_session]\ncommand = "ribbon-session"\nuser = "me"\n' > "$T/ge/greetd/ribbon.toml"
	greet
	if head -n1 "$T/g.out" | grep -qx "greetd --config /run/ribbon/greetd.toml" && grep -qx 'command = "ribbon-greeter"' "$T/g.out" \
		&& ! grep -q gtkgreet "$T/g.out" && grep -qx 'command = "ribbon-session"' "$T/g.out" && grep -q gtkgreet "$T/ge/greetd/ribbon.toml"; then
		ok "greetd-launch: an old gtkgreet config runs with ribbon-greeter from /run (the autologin kept, /etc untouched)"
	else bad "greetd-launch gtkgreet: $(cat "$T/g.out" | tr '\n' ';')"; fi
fi

# ribbon-session exports the locale: /etc/locale.conf, then the account's (Settings → Language and region)
mkdir -p "$T/ls/bin" "$T/ls/home/.config"
printf '#!/bin/sh\nenv | grep -E "^(LANG|LC_[A-Z]+)=" | sort\n' > "$T/ls/bin/labwc"; chmod +x "$T/ls/bin/labwc"
printf 'LANG="en_US.UTF-8"\nLC_TIME=en_US.UTF-8\nLC_COLLATE=C\nKEYMAP=us\n' > "$T/ls/system"
sess() { env -i PATH="$T/ls/bin:/usr/bin:/bin" HOME="$T/ls/home" XDG_STATE_HOME="$T/ls/state" DBUS_SESSION_BUS_ADDRESS=x \
	RIBBON_LOCALE_CONF="$T/ls/system" sh "$F/bin/ribbon-session" 2>/dev/null | tr '\n' ' '; }
out=$(sess)
[ "$out" = "LANG=en_US.UTF-8 LC_COLLATE=C LC_TIME=en_US.UTF-8 " ] && ok "ribbon-session: the system's locale.conf (quotes stripped, not other keys)" ||
	bad "ribbon-session's locale from /etc/locale.conf: $out"
printf 'LANG=de_DE.UTF-8\nLC_PAPER="en_GB.UTF-8"\n' > "$T/ls/home/.config/locale.conf"
out=$(sess)
[ "$out" = "LANG=de_DE.UTF-8 LC_COLLATE=C LC_PAPER=en_GB.UTF-8 " ] &&
	ok "ribbon-session: the account's locale.conf wins; the system's formats give way, LC_COLLATE stays" || bad "ribbon-session's locale with the account's file: $out"
printf 'LC_TIME=en_GB.UTF-8\n' > "$T/ls/home/.config/locale.conf"
out=$(sess)
[ "$out" = "LANG=en_US.UTF-8 LC_COLLATE=C LC_TIME=en_GB.UTF-8 " ] && ok "ribbon-session: an account file without LANG overrides only what it names" ||
	bad "ribbon-session's locale with an account LC_TIME only: $out"

[ $fails -eq 0 ] && echo "session scripts: all checks passed" || echo "session scripts: $fails checks failed"
[ $fails -eq 0 ]
