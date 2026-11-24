#!/bin/sh
# Settings → Users, the page (page-users.tcl) under xvfb with users.tcl's model and changes stood in for
# (tests/settings-users-scene.tcl): the page in its board's state and each of its three sheets (Add, Password, Remove)
# filled in by typing, each compared with its board's crop in tests/fixtures/settings-pages (the page right of the
# rail; both blurred, RMSE), and every control pressed as a click or a key, checking the call it makes, what a refusal
# or a dismissed prompt leaves, and that a typed password is drawn nowhere and kept nowhere. A last run stands in for
# nothing in users.tcl: the page's clicks and typing reach a stand-in pkexec and passwd (the password on their standard
# input, in no argument and no environment) over a fixture root. The logic behind the page
# has its own steps (55-settings-users.sh, 56-settings-users-helper.sh, 56-settings-users-real.sh).
# Skips without wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the Users page (no wish8.6 / xvfb-run)"; exit 0
fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	[ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ] || { echo "  skip the Users page (no unix_extra, no Tcl headers to build it)"; exit 0; }
	mkdir -p "$T/ux"
	make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1 || { cat "$T/make.log"; echo "  FAIL unix_extra does not build"; exit 1; }
	ux=$T/ux
fi
D=$PWD/srcpkgs/ribbon-desktop/files
TCLLIBPATH="${ux:+$ux }$D${TCLLIBPATH:+ $TCLLIBPATH}"; export TCLLIBPATH
mkdir -p "$T/home/.config/ribbon" "$T/root/etc/pam.d" "$T/log"; cp "$D/themes/palettes/ribbon.conf" "$T/home/.config/ribbon/palette.conf"
# the fixture root and the stand-ins the scene "real" uses (the other scenes stand in for users.tcl's changes themselves)
printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' 'daemon:x:1:1:daemon:/:/usr/sbin/nologin' 'adam:x:1000:1000:Adam:/home/adam:/bin/sh' \
	'mira:x:1001:1001:Mira:/home/mira:/bin/sh' 'guest:x:1002:1002:Guest:/home/guest:/bin/sh' >"$T/root/etc/passwd"
printf '%s\n' 'root:x:0:' 'wheel:x:10:adam' 'adam:x:1000:' 'mira:x:1001:' 'guest:x:1002:' >"$T/root/etc/group"
printf '%s\n' 'auth sufficient pam_succeed_if.so user ingroup nopasswdlogin' 'auth include system-login' >"$T/root/etc/pam.d/greetd"
cat >"$T/pkexec" <<'STUB'
#!/bin/sh
# a stand-in pkexec: records its arguments, standard input and environment; exits as $RIBBON_USERS_LOG/exit says ("CODE MESSAGE")
printf '%s\n' "$*" >>"$RIBBON_USERS_LOG/argv"
cat >>"$RIBBON_USERS_LOG/stdin"
env >>"$RIBBON_USERS_LOG/env"
code=0; msg=
[ -s "$RIBBON_USERS_LOG/exit" ] && read -r code msg <"$RIBBON_USERS_LOG/exit"
[ -n "$msg" ] && printf '%s\n' "$msg" >&2
exit "$code"
STUB
cat >"$T/passwd" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$RIBBON_USERS_LOG/passwd.argv"
cat >>"$RIBBON_USERS_LOG/passwd.stdin"
STUB
chmod 755 "$T/pkexec" "$T/passwd"
: >"$T/log/argv"; : >"$T/log/stdin"; : >"$T/log/env"; : >"$T/log/passwd.argv"; : >"$T/log/passwd.stdin"
fails=0
page() { # NAME RIBBON_SCENE
	name=$1
	if env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/cache" RIBBON_USERS_ROOT="$T/root" \
		RIBBON_USERS_TEST=1 RIBBON_USERS_UID=1000 RIBBON_USERS_PKEXEC="$T/pkexec" RIBBON_USERS_PASSWD="$T/passwd" RIBBON_USERS_LOG="$T/log" \
		RIBBON_SETTINGS_SCENE="$PWD/tests/settings-users-scene.tcl" RIBBON_USERS_SHOT="$T/$name.png" RIBBON_USERS_RESULT="$T/$name.res" RIBBON_SCENE="$2" \
		timeout -k 5 150 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$T/out" 2>&1; then
		sed 's/^/  /' "$T/$name.res"
	else
		[ -f "$T/$name.res" ] && sed 's/^/  /' "$T/$name.res"; sed 's/^/       /' "$T/out"; echo "  FAIL the $name page"; fails=$((fails + 1))
	fi
	[ "$2" = real ] && return
	[ -n "${RIBBON_KEEP_SHOTS:-}" ] && [ -s "$T/$name.png" ] && cp "$T/$name.png" "$RIBBON_KEEP_SHOTS/$name.png"
	if command -v convert >/dev/null 2>&1 && command -v compare >/dev/null 2>&1 && [ -s "$T/$name.png" ]; then
		convert "$T/$name.png" -crop 870x720+400+104 +repage -blur 0x2 "$T/a.png"; convert "tests/fixtures/settings-pages/$name.png" -blur 0x2 "$T/b.png"
		r=$(compare -metric RMSE "$T/a.png" "$T/b.png" null: 2>&1 | sed -n 's/.*(\([0-9.e-]*\)).*/\1/p')
		if awk "BEGIN { exit !(${r:-1} < 0.05) }"; then echo "  ok   $name matches the board (blurred RMSE $r)"; else echo "  FAIL $name against the board: RMSE ${r:-?}"; fails=$((fails + 1)); fi
	fi
}
page users main
page users-add add
page users-password password
page users-remove remove
page users-real real
if [ $fails -eq 0 ]; then echo "Users page: all checks passed"; else echo "Users page: $fails failed"; exit 1; fi
