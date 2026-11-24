#!/bin/sh
# win2-live.sh - the standalone file window as it runs (under one X display: xvfb-run sh this):
# where it opens (--beside a tile, --over the window that asked, the work area; stepping off
# another Properties window), one window per file over its socket, and the watch: chmod, rename
# and removal from outside, with ribbon-fswatch and without it (the poll).
#   sh tests/win2-live.sh WORKDIR FSWATCH-DIR   (FSWATCH-DIR holds ribbon-fswatch, or is empty)
# Needs unix_extra on TCLLIBPATH. Prints "  ok ..." / "  FAIL ..." lines.
set -u
cd "$(dirname "$0")/.." || exit 1
T=$1; FSW=$2
M=$PWD/srcpkgs/ribbon-desktop/files/properties/main.tcl
mkdir -p "$T/home" "$T/files"
# a short runtime dir: a socket's path has room for 107 bytes
R=$(mktemp -d /tmp/w2.XXXXXX) || exit 1
trap 'rm -rf "$R"' EXIT
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_DATA_HOME="$T/home/.local/share" XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$R" KIT_LIB=/nonexistent
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
printf 'one\n' > "$T/files/a.txt"; printf 'two\n' > "$T/files/b.txt"; printf 'three\n' > "$T/files/c.txt"
props() { WIN2_PROBE=$1; shift; env WIN2_PROBE="$WIN2_PROBE" RIBBON_PROPERTIES_PROBE="$PWD/tests/win2-probe.tcl" PATH="${FSW:+$FSW:}$PATH" timeout 40 wish8.6 -encoding utf-8 "$M" "$@"; }
# deadline wait for a condition (a shell command)
waitfor() { n=0; while ! eval "$1"; do n=$((n + 1)); [ $n -gt 100 ] && return 1; sleep 0.1; done; }

# ---- where it opens (a 1440 x 900 screen, the window 720 x 494)
place() {
	want=$1; shift
	got=$(props place "$@" 2>&1 | sed -n 's/^at //p')
	if [ "$got" = "$want" ]; then ok "opens at $want: $*"; else fail "opens at ${got:-nothing}, not $want: $*"; fi
}
place "388 278" --beside 222 288 150 150 "$T/files/a.txt"     # right of the tile, its top 10 above
place "464 290" --beside 1200 300 150 150 "$T/files/a.txt"    # no room on the right: left of the tile
place "8 225" --over 8 66 700 812 "$T/files/a.txt"            # centred on the window that asked, kept on screen
place "616 54" --beside 600 20 0 0 "$T/files/a.txt"           # beside the pointer, kept under the bar
place "360 226" "$T/files/a.txt"                              # centred in the work area

# ---- one window per file: asking again raises it (the socket), and a second window steps off it
props stay "$T/files/a.txt" > "$T/stay.log" 2>&1 &
pa=$!
if waitfor "grep -q '^serving .*sock' '$T/stay.log'"; then
	ok "the window answers on its socket ($(sed -n 's/^serving //p' "$T/stay.log" | sed "s|$R|\$XDG_RUNTIME_DIR|"))"
	place "388 254" "$T/files/b.txt"                          # on the first one's place: 28 down and right
	start=$(date +%s)
	if props place "$T/files/a.txt" > "$T/again.log" 2>&1 && ! grep -q '^at ' "$T/again.log"; then
		ok "asked again for the same file: the second start hands it over and exits ($(( $(date +%s) - start )) s)"
	else fail "asked again, a second window opened"; sed 's/^/       /' "$T/again.log"; fi
	wait $pa; cat "$T/stay.log" | grep '^  \(ok\|FAIL\)' || fail "the first window was not raised"
	grep -q '^  FAIL' "$T/stay.log" && fails=$((fails + 1))
	[ -e "$(sed -n 's/^serving //p' "$T/stay.log")" ] && fail "the socket is left behind" || ok "the socket goes with the window"
else
	fail "the window has no socket"; sed 's/^/       /' "$T/stay.log"; kill $pa 2>/dev/null
fi

# ---- the watch
lab=$([ -n "$FSW" ] && echo ribbon-fswatch || echo "the poll")
if props live "$T/files/c.txt" > "$T/live.log" 2>&1 && grep -q '^  removing' "$T/live.log"; then
	sed -n 's/^  ok /  ok /p' "$T/live.log" | sed "s/\$/ ($lab)/"
	ok "its file removed from outside: the window closes ($lab)"
else
	fail "the watch ($lab)"; sed 's/^/       /' "$T/live.log"
fi
printf 'four\n' > "$T/files/d.txt"; printf 'five\n' > "$T/files/e.txt"
if props pair "$T/files/d.txt" "$T/files/e.txt" > "$T/pair.log" 2>&1; then
	sed -n 's/^  ok /  ok /p' "$T/pair.log" | sed "s/\$/ ($lab)/"
else
	fail "two files, one renamed over the other ($lab)"; sed 's/^/       /' "$T/pair.log"
fi
exit $((fails > 0))
