#!/bin/sh
# labwc020.sh - the test halves that need labwc 0.8 or later (0.20.x on Ribbon's base), in CI
# (build/ci/labwc020-tests.yml). The host's labwc on the runner (Ubuntu 24.04) is 0.7.1, as in the development
# container, so these checks run against a ROOT: a directory of prebuilt distribution packages (Void's, the base of
# docs/DECISIONS-DELEGATED.md 5) that the tests enter with chroot, the way tests/alttab-native/run.sh,
# tests/hud-native/run.sh, tests/term/run.sh and tests/steps.d/65-settings-input-live.sh already take one. Nothing is
# built from source; the test helpers are built with the host's toolchain and run in the root against its libraries.
#
#   sudo build/ci/labwc020.sh deps              the runner's packages (the host half of the checks)
#   sudo build/ci/labwc020.sh root DIR          make DIR a root of prebuilt packages (Void's own container image and its
#                                               signing keys, as the image job; xbps checks every package's signature);
#                                               DIR.packages lists what went in
#   build/ci/labwc020.sh check-root DIR         DIR has labwc >= 0.8, foot >= 1.20 and every program the checks run in
#                                               it; prints the versions (chroot: root only)
#   sudo build/ci/labwc020.sh run DIR RESULTS   check-root, then every check below against DIR; RESULTS gets one log per
#                                               check, labwc020-summary.txt (RESULT lines) and labwc020-notes.txt
#                                               (the measurements and notes the checks print)
#   build/ci/labwc020.sh verdict NAME STATUS LOG   the RESULT line for one check's exit STATUS and LOG (see below)
#   build/ci/labwc020.sh randr-keys [ROOT]      wlr-randr --json of ROOT's labwc (headless) has every key that
#                                               tests/fixtures/display-outputs.json (Settings → Display's model) uses
#   build/ci/labwc020.sh results [CI-CLONE] [DIR]  fetch the last run's results (branch ribbon-results-labwc020)
#
# A check against a root must neither skip nor fall back: a "skip" line, or a note that a labwc 0.7 fallback ran
# (FALLBACKS below), fails it, since the root is there exactly so that nothing is left out.
set -eu
cd "$(dirname "$0")/../.."
REPO=${RIBBON_LABWC_REPO:-https://repo-default.voidlinux.org/current}
IMAGE=${RIBBON_LABWC_IMAGE:-ghcr.io/void-linux/void-glibc-full:latest}
# what the checks run in the root (labwc's Xwayland for the X clients; fonts for Tk; xset and xkbcomp for the
# keyboard that X clients see; ffmpeg6, as ribbon-desktop has it, for the HUD's game art)
ROOT_PKGS="base-minimal bash coreutils findutils grep sed gawk procps-ng util-linux labwc wlroots0.20
xorg-server-xwayland foot grim wlr-randr tcl tk xset xkbcomp xkeyboard-config fontconfig dejavu-fonts-ttf cairo wayland libxkbcommon ffmpeg6"
# the programs check-root wants in the root
ROOT_TOOLS="sh sleep grep sed tail labwc Xwayland foot footclient grim wlr-randr tclsh8.6 wish8.6 xset xkbcomp ffmpeg"
# the runner's half: building the helpers (ribbon-shell-watch, ribbon-hud-surface, the virtual keyboard and pointer,
# rbnalpha) and what the step scripts look for on the host
HOST_PKGS="build-essential pkg-config wayland-protocols libwayland-dev libwayland-bin libxkbcommon-dev libcairo2-dev
tcl8.6 tk8.6 tk8.6-dev imagemagick grim xvfb xauth x11-xserver-utils x11-xkb-utils python3"
# name|command: the five test halves (ROOT is the root), and the U11 key check
CHECKS='alttab-native|ALTTAB_ROOT="$ROOT" sh tests/steps.d/80-alttab-native.sh
alttab-profile|PROFILE=5 sh tests/alttab-native/run.sh "$ROOT"
settings-input-live|TERM_ROOT="$ROOT" sh tests/steps.d/65-settings-input-live.sh
term|TERM_ROOT="$ROOT" sh tests/steps.d/65-term.sh
hud-surface|HUD_ROOT="$ROOT" sh tests/steps.d/57-hud-surface.sh
randr-keys|sh build/ci/labwc020.sh randr-keys "$ROOT"'
# notes that mean a check took its labwc 0.7 / old-foot path instead of the real one
FALLBACKS='has no ext-image-copy-capture
has no ForEach
has no \[desktop-notifications\]'
# notes that mean a check left a part out (a helper that did not build, no Xvfb on the host, a key the test had to
# make up for by hand)
LEFTOUT='skipped
does not build here
not checked
did not reach'

# ver_ge A B: version A >= B (dotted numbers)
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

verdict() { # NAME STATUS LOG
	n=$1; st=$2; log=$3
	nok=$(grep -c '^ *ok ' "$log" || :); nfail=$(grep -c '^ *FAIL' "$log" || :)
	skips=$(grep -E '^ *skip' "$log" | head -n3 | sed 's/^ *skip *//' | tr '\n' ';' | sed 's/;$//; s/;/; /g')
	fb=$(printf '%s\n' "$FALLBACKS" | while IFS= read -r p; do grep -E '^ *note' "$log" | grep -E -- "$p" | head -n1; done | sed 's/^ *note *//' | tr '\n' ';' | sed 's/;$//')
	lo=$(printf '%s\n' "$LEFTOUT" | while IFS= read -r p; do grep -E '^ *note' "$log" | grep -E -- "$p" | head -n1; done | sed 's/^ *note *//' | tr '\n' ';' | sed 's/;$//')
	# the timing run prints no ok lines: it needs cold and warm opens that measured something
	ncold=$(grep -cE '^  cold: .*=' "$log" || :); nwarm=$(grep -cE '^  warm: .*=' "$log" || :)
	if [ "$st" != 0 ] || [ "$nfail" -gt 0 ]; then echo "RESULT $n: FAILED (exit $st; $nok ok, $nfail FAIL)"
	elif [ -n "$skips" ]; then echo "RESULT $n: FAILED (skipped under the root: $skips)"
	elif [ -n "$fb" ]; then echo "RESULT $n: FAILED (the labwc 0.7 fallback ran under the root: $fb)"
	elif [ -n "$lo" ]; then echo "RESULT $n: FAILED (a part was left out under the root: $lo)"
	elif [ "$n" = alttab-profile ]; then
		if [ "$ncold" -gt 0 ] && [ "$nwarm" -gt 0 ]; then echo "RESULT $n: ok ($ncold cold, $nwarm warm opens timed)"
		else echo "RESULT $n: FAILED (no timing measured: $ncold cold, $nwarm warm)"; fi
	elif [ "$nok" -eq 0 ]; then echo "RESULT $n: FAILED (no check ran)"
	else echo "RESULT $n: ok ($nok ok)"; fi
}

check_root() { # DIR
	r=$1; bad=0
	[ -d "$r" ] || { echo "check-root: $r is not a directory" >&2; return 1; }
	[ "$(id -u)" = 0 ] || { echo "check-root: needs root (chroot)" >&2; return 1; }
	# (the root's own PATH, whatever the caller's is)
	CH=$(PATH=$PATH:/usr/sbin:/sbin command -v chroot) || { echo "check-root: no chroot" >&2; return 1; }
	cr() { PATH=/usr/bin:/bin:/usr/sbin:/sbin "$CH" "$r" "$@"; }
	miss=
	for t in $ROOT_TOOLS; do cr /bin/sh -c "command -v $t" >/dev/null 2>&1 || miss="$miss $t"; done
	[ -z "$miss" ] || { echo "check-root: $r lacks:$miss" >&2; bad=1; }
	lv=$(cr labwc -v 2>/dev/null | sed -n 's/^labwc \([0-9][0-9.]*\).*/\1/p' | head -n1)
	fv=$(cr foot --version 2>/dev/null | sed -n 's/^foot version: \([0-9][0-9.]*\).*/\1/p' | head -n1)
	if [ -z "$lv" ]; then echo "check-root: labwc -v says nothing in $r" >&2; bad=1
	elif ! ver_ge "$lv" 0.8; then echo "check-root: labwc $lv in $r; the checks need 0.8 or later" >&2; bad=1; fi
	if [ -z "$fv" ]; then echo "check-root: foot --version says nothing in $r" >&2; bad=1
	elif ! ver_ge "$fv" 1.20; then echo "check-root: foot $fv in $r; the notification mark needs 1.20 or later" >&2; bad=1; fi
	tk=$(echo 'puts [info patchlevel]' | cr tclsh8.6 2>/dev/null || :)
	echo "root $r: labwc ${lv:-?}, foot ${fv:-?}, Tcl ${tk:-?}"
	return $bad
}

randr_keys() { # [ROOT]
	r=${1:-}
	command -v python3 >/dev/null 2>&1 || { echo "  FAIL randr-keys: no python3"; return 1; }
	Rr() { if [ -n "$r" ]; then chroot "$r" "$@"; else "$@"; fi; }
	# (in the root its own PATH; on the host the caller's)
	P=$PATH; [ -z "$r" ] || P=/usr/bin:/bin
	t0=${TMPDIR:-/tmp}/rkeys.$$; t=$t0
	if [ -n "$r" ]; then t0=$r/tmp/rkeys.$$; t=/tmp/rkeys.$$; fi
	mkdir -p "$t0/rt" "$t0/cfg/labwc"; chmod 700 "$t0/rt"
	echo '<labwc_config><core><decoration>server</decoration></core></labwc_config>' > "$t0/cfg/labwc/rc.xml"
	echo 'echo "$WAYLAND_DISPLAY" > "$XDG_RUNTIME_DIR/wl"' > "$t0/cfg/labwc/autostart"
	# (started directly, not through Rr: chroot and env exec labwc, so $! is labwc itself and the kill below stops it)
	set -- env -i PATH="$P" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
		XDG_RUNTIME_DIR="$t/rt" HOME="$t" labwc -C "$t/cfg/labwc"
	if [ -n "$r" ]; then chroot "$r" "$@" >"$t0/labwc.log" 2>&1 & else "$@" >"$t0/labwc.log" 2>&1 & fi
	lp=$!
	i=0; while [ ! -s "$t0/rt/wl" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
	st=0
	wl() { Rr env -i PATH="$P" XDG_RUNTIME_DIR="$t/rt" WAYLAND_DISPLAY="$(cat "$t0/rt/wl")" timeout 10 wlr-randr "$@"; }
	if [ ! -s "$t0/rt/wl" ]; then
		tail -n 20 "$t0/labwc.log" | sed 's/^/       /'; echo "  FAIL randr-keys: labwc did not start"; st=1
	elif ! wl --json > "$t0/out.json" 2>"$t0/err"; then
		sed 's/^/       /' "$t0/err"; echo "  FAIL randr-keys: wlr-randr --json failed (wlr-randr $(wl --version 2>&1 | head -n1))"; st=1
	else
		echo "  note wlr-randr $(wl --version 2>&1 | head -n1); $(Rr labwc -v 2>/dev/null | head -n1)"
		python3 - tests/fixtures/display-outputs.json "$t0/out.json" <<'PY' || st=1
import json, sys
def keys(v, p=""):
    out = set()
    if isinstance(v, dict):
        for k, x in v.items():
            out.add(p + k); out |= keys(x, p + k + ".")
    elif isinstance(v, list):
        for x in v:
            out |= keys(x, p + "[].")
    return out
want = keys(json.load(open(sys.argv[1])))
got_doc = json.load(open(sys.argv[2]))
got = keys(got_doc)
if not got_doc:
    print("  FAIL randr-keys: wlr-randr listed no output"); sys.exit(1)
miss = sorted(want - got)
extra = sorted(got - want)
if extra:
    print("  note keys wlr-randr has that the fixture does not: " + " ".join(extra))
if miss:
    print("  FAIL randr-keys: keys of tests/fixtures/display-outputs.json that wlr-randr --json does not have: " + " ".join(miss)); sys.exit(1)
print("  ok   randr-keys: every key of tests/fixtures/display-outputs.json is in wlr-randr --json (%d keys)" % len(want))
PY
	fi
	kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null || :
	rm -rf "$t0"
	return $st
}

case ${1:-} in
deps)
	apt-get update -qq
	# shellcheck disable=SC2086
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $HOST_PKGS
	;;
root)
	r=${2:?usage: labwc020.sh root DIR}
	mkdir -p "$r"; r=$(cd "$r" && pwd)
	command -v docker >/dev/null 2>&1 || { echo "labwc020.sh: docker is needed to make the root" >&2; exit 1; }
	# Void's own xbps, keys and repository; -r: everything goes into the mounted directory. The keys are the image's
	# (the same trust as the image job's packages); xbps refuses a package whose signature does not check.
	# shellcheck disable=SC2086
	docker run --rm -v "$r:/target" -e PKGS="$(printf "%s " $ROOT_PKGS)" -e REPO="$REPO" "$IMAGE" sh -euc '
		xbps-install -Syu xbps >&2
		mkdir -p /target/var/db/xbps/keys
		cp -a /var/db/xbps/keys/. /target/var/db/xbps/keys/
		XBPS_ARCH=x86_64 xbps-install -S -y -r /target -R "$REPO" $PKGS >&2
		xbps-query -r /target -l' > "$r.packages"
	mkdir -p "$r/tmp"; chmod 1777 "$r/tmp"
	grep -E ' (labwc|wlroots0\.20|foot|tk|xorg-server-xwayland)-[0-9]' "$r.packages" | awk '{ print $2 }'
	;;
check-root) check_root "${2:?usage: labwc020.sh check-root DIR}" ;;
verdict) verdict "${2:?usage: labwc020.sh verdict NAME STATUS LOG}" "${3:?}" "${4:?}" ;;
randr-keys) randr_keys "${2:-}" ;;
run)
	ROOT=${2:?usage: labwc020.sh run DIR RESULTS}; R=${3:?usage: labwc020.sh run DIR RESULTS}
	ROOT=$(cd "$ROOT" && pwd); mkdir -p "$R"; R=$(cd "$R" && pwd)
	sum=$R/labwc020-summary.txt; : > "$sum"
	if ! check_root "$ROOT" > "$R/root.txt" 2>&1; then
		cat "$R/root.txt"; echo "RESULT labwc020-root: FAILED ($(tr '\n' ' ' < "$R/root.txt"))" | tee -a "$sum"; exit 1
	fi
	echo "RESULT labwc020-root: ok ($(cat "$R/root.txt"))" | tee -a "$sum"
	: > "$R/labwc020-notes.txt"
	printf '%s\n' "$CHECKS" | while IFS='|' read -r name cmd; do
		echo "== $name: $cmd"
		st=0
		# (the command is one of the fixed lines above; ROOT is expanded inside it)
		ROOT=$ROOT timeout -k 30 900 sh -c "$cmd" < /dev/null > "$R/$name.log" 2>&1 || st=$?
		tail -n 40 "$R/$name.log"
		{ echo "== $name"; grep -E '^ *(note|skip)|^  (cold|warm):' "$R/$name.log" || :; } >> "$R/labwc020-notes.txt"
		verdict "$name" "$st" "$R/$name.log" | tee -a "$sum"
	done
	cat "$sum"
	! grep -q '^RESULT [a-z0-9-]*: FAILED' "$sum"
	;;
results)
	CI=${2:-../ci}; OUT=${3:-out/ci-results-labwc020}
	git -C "$CI" fetch -q --depth 1 origin "+ribbon-results-labwc020:refs/remotes/origin/ribbon-results-labwc020"
	rm -rf "$OUT"; mkdir -p "$OUT"
	git -C "$CI" archive origin/ribbon-results-labwc020 | tar -x -C "$OUT"
	cat "$OUT/summary.txt" 2>/dev/null || ls "$OUT"
	;;
*)
	sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
