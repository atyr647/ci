#!/bin/sh
# Tcl and Tk by their version-neutral names (docs/STACK.md §4, T0; audit 207 and 85): what Ribbon ships starts
# tclsh and wish, never tclsh8.6 or wish8.6, so it runs on a base that installs only the unversioned names (Void's
# tcl and tk packages make both) and moves to Tcl/Tk 9 without edits; Tcl and Tk are required as 8.6- (8.6 or later,
# 9 included); rbnalpha builds against whichever Tk the system has.
#   1. no tclsh8.6, wish8.6 or "package require Tk 8.6" (without its "-") anywhere under srcpkgs
#   2. a base with only tclsh and wish (this host's binaries under those names, every versioned name gone from PATH):
#      every launcher that execs wish or tclsh runs, the #!/usr/bin/env tclsh scripts run
#   3. the Tcl programs that start another tclsh or wish (the FileChooser portal, the Catalogue, Properties,
#      Settings' Identify) pick tclsh and wish, else the names of their own Tcl's version (tests/tcl-names.tcl);
#      the System monitor takes a versioned interpreter for a wrapper
#   4. rbnalpha's Makefile: the system's tkConfig.sh first, else the newest versioned one, with the Tcl of its version;
#      a Tk and a Tcl of two versions are refused; it builds here with -Werror
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
D=srcpkgs/ribbon-desktop/files

# ---- 1. the names in the tree
hits=$(grep -rnE '\b(tclsh|wish)8\.[0-9]' srcpkgs)
[ -z "$hits" ] && ok "nothing under srcpkgs names tclsh8.x or wish8.x" ||
	{ echo "$hits" | sed 's/^/       /'; fail "srcpkgs names a versioned tclsh or wish ($(echo "$hits" | wc -l) lines)"; }
hits=$(grep -rnE 'package (require|present) +(-exact +)?(Tcl|Tk) +[0-9][0-9.]*([^-0-9.]|$)' srcpkgs)
[ -z "$hits" ] && ok "every Tcl and Tk requirement takes 9 too (8.6-)" ||
	{ echo "$hits" | sed 's/^/       /'; fail "a Tcl or Tk requirement refuses Tcl/Tk 9"; }

# ---- 2. a base with only the unversioned names
real_tclsh=$(command -v tclsh || command -v tclsh8.6)
real_wish=$(command -v wish || command -v wish8.6)
if [ -z "$real_tclsh" ] || [ -z "$real_wish" ]; then
	echo "  skip the unversioned base (no tclsh / wish here)"
	exit $((fails > 0))
fi
real_tclsh=$(readlink -f "$real_tclsh"); real_wish=$(readlink -f "$real_wish")
ver=$(echo 'puts [info tclversion]' | "$real_tclsh")
# only: every program of this host's PATH but the Tcl and Tk interpreters, then tclsh and wish
mkdir -p "$T/only"
oldifs=$IFS; IFS=:
for dir in $PATH; do
	[ -d "$dir" ] || continue
	for p in "$dir"/*; do
		n=${p##*/}
		case $n in tclsh* | wish*) continue ;; esac
		[ -x "$p" ] && [ ! -e "$T/only/$n" ] && ln -s "$p" "$T/only/$n"
	done
done
IFS=$oldifs
ln -s "$real_tclsh" "$T/only/tclsh"; ln -s "$real_wish" "$T/only/wish"
if PATH=$T/only sh -c 'command -v tclsh8.6 || command -v wish8.6 || command -v "tclsh'"$ver"'"' >/dev/null 2>&1; then
	fail "the unversioned base still has a versioned name"
fi

# the launchers: every script whose program line is "exec wish ..." or "exec tclsh ...", run against stand-ins that
# record what they were given (the real programs are /usr/lib/ribbon/..., not in this tree)
mkdir -p "$T/stub" "$T/home"
for p in tclsh wish; do printf '#!/bin/sh\necho "%s $*" >> "%s/ran"\n' "$p" "$T" > "$T/stub/$p"; chmod +x "$T/stub/$p"; done
n=0; bad=
for f in $(grep -rlE '^[[:space:]]*exec (wish|tclsh) ' srcpkgs | LC_ALL=C sort); do
	head -n 1 "$f" | grep -q '^#!/bin/sh' || continue
	want=$(sed -n -E 's/^[[:space:]]*exec ((wish|tclsh)( -encoding utf-8)? [^ ]+).*/\1/p' "$f" | head -n 1)
	: > "$T/ran"
	HOME=$T/home XDG_RUNTIME_DIR=$T PATH=$T/stub:$T/only timeout 10 sh "$f" >/dev/null 2>&1 </dev/null
	if grep -qF -- "$want" "$T/ran"; then n=$((n + 1)); else bad="$bad ${f#srcpkgs/}"; fi
done
[ -z "$bad" ] && [ "$n" -ge 15 ] && ok "$n launchers start their program with only tclsh and wish on PATH" ||
	fail "launchers that did not run on tclsh/wish ($n ran):$bad"
# the HUD's control starts its daemon on wish (setsid wish ..., not an exec)
: > "$T/ran"
HOME=$T/home XDG_RUNTIME_DIR=$T RIBBON_HUD_DIR=/opt/hud PATH=$T/stub:$T/only timeout 15 sh "$D/apps/hud/bin/ribbon-hud" start >/dev/null 2>&1
grep -q '^wish -encoding utf-8 /opt/hud/main.tcl -name ribbon-hud --auto' "$T/ran" && ok "ribbon-hud starts its daemon on wish" ||
	fail "ribbon-hud's daemon: $(cat "$T/ran")"
# the greeter, in labwc: wish runs main.tcl (a stand-in labwc takes the --exit)
printf '#!/bin/sh\necho "labwc $*" >> "%s/ran"\n' "$T" > "$T/stub/labwc"; chmod +x "$T/stub/labwc"
: > "$T/ran"
RIBBON_GREETER_MAIN=/opt/g/main.tcl PATH=$T/stub:$T/only timeout 10 sh "$D/greeter/ribbon-greeter" --in-labwc >/dev/null 2>&1
[ "$(cat "$T/ran")" = "wish -encoding utf-8 /opt/g/main.tcl -name ribbon-greeter
labwc --exit" ] && ok "ribbon-greeter runs the login screen on wish" || fail "ribbon-greeter: $(cat "$T/ran")"

# the #! scripts run by env on the unversioned base
if PATH=$T/only "$D/bin/ribbon-wallpaper" "$D/themes/palettes/ribbon.conf" 64x36 2>"$T/err" | grep -q '<svg'; then
	ok "ribbon-wallpaper (#!/usr/bin/env tclsh) runs"
else fail "ribbon-wallpaper: $(cat "$T/err")"; fi
if PATH=$T/only srcpkgs/ribbon-kit/files/bin/kit help 2>"$T/err" | grep -q 'kit grab'; then ok "kit (#!/usr/bin/env tclsh) runs"
else fail "kit help: $(cat "$T/err")"; fi
if PATH=$T/only timeout 60 srcpkgs/ribbon-installer/files/bin/ribbon-install-probe --only machine 2>"$T/err" | grep -q '^machine '; then
	ok "ribbon-install-probe (#!/usr/bin/env tclsh) runs"
else fail "ribbon-install-probe: $(cat "$T/err")"; fi
# ribbon-theme makes each theme's wallpaper with tclsh
mkdir -p "$T/theme"
if PATH=$T/only bash "$D/bin/ribbon-theme" render-from "$D/themes" ribbon "$T/theme/ribbon" >"$T/err" 2>&1 &&
	grep -q '<svg' "$T/theme/ribbon/wallpaper.svg" 2>/dev/null; then
	ok "ribbon-theme makes the wallpaper with tclsh"
else sed 's/^/       /' "$T/err" | tail -n 5; fail "ribbon-theme render-from on the unversioned base"; fi
# the services name /usr/bin/tclsh and /usr/bin/wish
svc=$(grep -hE '^(command|Exec) *=' srcpkgs/ribbon-dinit/files/user-services/ribbon-hud srcpkgs/ribbon-dinit/files/user-services/ribbon-power-idle \
	"$D/dbus-services/org.freedesktop.ScreenSaver.service" "$D/dbus-services/org.freedesktop.impl.portal.desktop.ribbon.service" |
	sed -E 's/^[A-Za-z]+ *= *//' | awk '{ print $1 }' | sort -u | tr '\n' ' ')
[ "$svc" = "/usr/bin/tclsh /usr/bin/wish " ] && ok "the dinit and D-Bus services run /usr/bin/tclsh and /usr/bin/wish" ||
	fail "the services run: $svc"

# ---- 3. the Tcl programs that start another tclsh or wish
mkdir -p "$T/v" "$T/w1" "$T/w2" "$T/w3"
cp -r "$T/only/." "$T/v/"; rm -f "$T/v/tclsh" "$T/v/wish"
ln -s "$real_tclsh" "$T/v/tclsh$ver"; ln -s "$real_wish" "$T/v/wish$ver"
for c in plain:only:w1 versioned:v:w2 monitor:only:w3; do
	IFS=: read -r name bin w <<EOF
$c
EOF
	HOME=$T/home PATH=$T/$bin "$real_tclsh" tests/tcl-names.tcl "$PWD/$D" "$name" "$T/$w" > "$T/$name.out" 2>&1
	cat "$T/$name.out"
	n=$(grep -c '^  FAIL' "$T/$name.out"); fails=$((fails + n))
	grep -q '^  ok' "$T/$name.out" || fail "tests/tcl-names.tcl $name did not run"
done

# ---- 4. rbnalpha's Makefile
R=$D/rbnalpha
tkc=$(make -s -C "$R" -p -n 2>/dev/null | sed -n 's/^TK_CONFIG := //p')
tcc=$(make -s -C "$R" -p -n 2>/dev/null | sed -n 's/^TCL_CONFIG := //p')
if [ -z "$tkc" ] || [ ! -f "$tkc" ] || [ ! -f "$tcc" ]; then
	echo "  skip rbnalpha's Makefile (no tkConfig.sh / tclConfig.sh here)"
else
	# made-up configs: DIR/tk8.6, DIR/tk9.0, DIR/tk9.1 (and the Tcls of 8.6 and 9.0), all this host's files but each with
	# its own version
	mk() { # KIND VERSION DIR
		mkdir -p "$3"
		if [ "$1" = tk ]; then src=$tkc; var=TK_VERSION; else src=$tcc; var=TCL_VERSION; fi
		{ echo ". $src"; echo "$var='$2'"; } > "$3/$1Config.sh"
	}
	C=$T/cfg
	mk tk 8.6 "$C/lib/tk8.6"; mk tk 9.0 "$C/lib/tk9.0"; mk tk 9.1 "$C/lib64/tk9.1"
	mk tcl 8.6 "$C/lib/tcl8.6"; mk tcl 9.0 "$C/lib/tcl9.0"; mk tcl 9.1 "$C/lib/tcl9.1"
	pick() { make -s -C "$R" -p -n CONFIG_DIRS="$*" 2>/dev/null | sed -n -E 's/^(TK|TCL)_CONFIG := //p' | tr '\n' ' '; }
	got=$(pick "$C/lib $C/lib64")
	[ "$got" = "$C/lib/tcl9.1/tclConfig.sh $C/lib64/tk9.1/tkConfig.sh " ] && ok "rbnalpha takes the newest Tk (9.1) and its Tcl" ||
		fail "rbnalpha with 8.6, 9.0 and 9.1 took: $got"
	got=$(pick "$C/lib")
	[ "$got" = "$C/lib/tcl9.0/tclConfig.sh $C/lib/tk9.0/tkConfig.sh " ] && ok "rbnalpha: 9.0 before 8.6" || fail "rbnalpha with 8.6 and 9.0 took: $got"
	mk tk 8.6 "$C/sys"; mk tcl 9.0 "$C/sys"; mk tcl 8.6 "$C/sys/tcl8.6"
	got=$(pick "$C/sys $C/lib")
	[ "$got" = "$C/sys/tcl8.6/tclConfig.sh $C/sys/tkConfig.sh " ] &&
		ok "the system's own tkConfig.sh wins, with the Tcl of its version (not the system's 9.0)" || fail "rbnalpha with a system Tk 8.6 took: $got"
	if make -s -B -C "$R" O="$T" TK_CONFIG="$C/lib/tk9.0/tkConfig.sh" TCL_CONFIG="$C/lib/tcl8.6/tclConfig.sh" >"$T/mk" 2>&1; then
		fail "rbnalpha built Tk 9.0 against Tcl 8.6"
	else grep -q 'Tk 9.0 .* needs Tcl 9.0' "$T/mk" && ok "rbnalpha refuses Tk 9.0 with Tcl 8.6" || fail "rbnalpha's refusal: $(cat "$T/mk")"; fi
	if make -s -B -C "$R" O="$T" CFLAGS="-O2 -Werror" >"$T/mk" 2>&1 && [ -f "$T/librbnalpha.so" ]; then
		ok "rbnalpha builds with -Werror against this host's Tk $(. "$tkc" && echo "$TK_VERSION")"
	else sed 's/^/       /' "$T/mk"; fail "rbnalpha does not build"; fi
fi

[ $fails = 0 ] || { echo "  $fails failed"; exit 1; }
