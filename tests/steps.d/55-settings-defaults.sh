#!/bin/sh
# Settings → Default apps (the backend, apps/settings/defaults.tcl) with no display, against a scratch tree of desktop
# entries, mimeapps.list and xdg-terminals.list files (tests/settings-defaults.tcl): the apps read, each row's
# candidates and default through the lookup order, the writes (every type, the rest of the file kept, atomic), the
# terminal list, Properties' own code (properties/facts.tcl) reading what is written, apps/term/bin/ribbon-terminal
# starting the chosen terminal (stub programs), and GLib's gio agreeing when it is installed. Then the launcher's
# syntax (sh -n) and shellcheck when there is one. Skips without tclsh8.6.
# NOT covered: a real terminal emulator started in a session (tests/term covers Ribbon Terminal itself); xdg-open.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip Settings → Default apps (no tclsh8.6)"; exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
st=0
mkdir -p "$T/tree"
if timeout -k 5 150 tclsh8.6 tests/settings-defaults.tcl "$D" "$T/tree" >"$T/out" 2>&1; then
	n=$(grep -c '^  ok ' "$T/out")
	grep '^  skip' "$T/out"
	echo "  ok   Settings → Default apps: the backend, Properties' reader, the terminal launcher and gio ($n checks)"
else
	cat "$T/out"
	echo "  FAIL Settings → Default apps: the backend"
	st=1
fi
launcher=$D/apps/term/bin/ribbon-terminal
if sh -n "$launcher" 2>"$T/shn"; then echo "  ok   ribbon-terminal parses (sh -n)"; else cat "$T/shn"; echo "  FAIL ribbon-terminal does not parse"; st=1; fi
[ -x "$launcher" ] && echo "  ok   ribbon-terminal is executable" || { echo "  FAIL ribbon-terminal is not executable"; st=1; }
if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck "$launcher" >"$T/sc" 2>&1; then echo "  ok   ribbon-terminal is shellcheck-clean"; else cat "$T/sc"; echo "  FAIL shellcheck ribbon-terminal"; st=1; fi
else
	echo "  skip shellcheck ribbon-terminal (no shellcheck)"
fi
if command -v dash >/dev/null 2>&1 && command -v busybox >/dev/null 2>&1; then
	# the same launcher under two more shells and busybox's awk and sed: one entry, one command
	mkdir -p "$T/b/bin" "$T/b/cfg" "$T/b/data/applications"
	printf '#!/bin/sh\necho "$0 $*" >>"$LOG"\n' >"$T/b/bin/otherterm"; chmod +x "$T/b/bin/otherterm"
	for a in awk sed tr cat; do ln -s "$(command -v busybox)" "$T/b/bin/$a"; done
	printf '[Desktop Entry]\nName=Other\nExec=otherterm --go "a b" %%U\nX-TerminalArgExec=-x\n' >"$T/b/data/applications/other.desktop"
	echo other.desktop >"$T/b/cfg/xdg-terminals.list"
	for shell in dash "busybox sh"; do
		: >"$T/b/log"
		env -i PATH="$T/b/bin:/usr/bin:/bin" HOME="$T/b" XDG_CONFIG_HOME="$T/b/cfg" XDG_CONFIG_DIRS="$T/b/none" XDG_DATA_HOME="$T/b/none" XDG_DATA_DIRS="$T/b/data" LOG="$T/b/log" $shell "$launcher" -e top -d 1
		if [ "$(cat "$T/b/log")" = "$T/b/bin/otherterm --go a b -x top -d 1" ]; then echo "  ok   ribbon-terminal under $shell with busybox awk, sed, tr: the chosen terminal runs the command"; else cat "$T/b/log"; echo "  FAIL ribbon-terminal under $shell"; st=1; fi
	done
fi
exit $st
