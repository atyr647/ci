#!/bin/sh
# The standalone file window (properties/win2.tcl): a photo, a text file, a folder, a selection of
# three files and the edit view are each drawn headless in Graphite, Fjord and Moss
# (tests/win2-scene.tcl through the Properties app); screenshots of the photo and its edit view in
# Graphite are kept in $WIN2_SHOTS when that is set. Then the window as it runs (tests/win2-live.sh):
# where it opens, one window per file over its socket, and its watch (ribbon-fswatch, then the poll).
# Skips without wish8.6, xvfb-run or convert.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1 || ! command -v convert >/dev/null 2>&1; then
	echo "  skip win2 (no wish8.6 / xvfb-run / convert)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
mkdir -p "$T/folder" "$T/home"
convert -size 300x200 gradient:orange-navy "$T/photo.png"
printf 'puts "hello"\nset x 1\n' > "$T/notes.tcl"
echo 'x' > "$T/folder/one.txt"
cp "$T/photo.png" "$T/second.png"
# the states: one file, a folder, a text file, several files (a selection), and the edit view
for scheme in graphite fjord moss; do
	for item in photo.png notes.tcl folder "photo.png|second.png|notes.tcl" edit:photo.png; do
		case $item in
			edit:*) path="${item#edit:}"; path="$T/$path"; edit=1 ;;
			*'|'*) path=""; for p in $(echo "$item" | tr '|' ' '); do path="${path:+$path|}$T/$p"; done; edit=0 ;;
			*) path="$T/$item"; edit=0 ;;
		esac
		name=$(echo "$item" | tr '|:' '__')
		out=""
		[ "$scheme" = graphite ] && [ "$item" = photo.png ] && out="${WIN2_SHOTS:-$T}/win2-$scheme-photo.png"
		[ "$scheme" = graphite ] && [ "$item" = "edit:photo.png" ] && out="${WIN2_SHOTS:-$T}/win2-$scheme-edit.png"
		[ -n "$out" ] && mkdir -p "$(dirname "$out")"
		if env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_DATA_HOME="$T/home/.local/share" XDG_CACHE_HOME="$T/cache" KIT_LIB=/nonexistent \
			RIBBON_PROPERTIES_SCENE=tests/win2-scene.tcl RIBBON_WIN2_PATH="$path" RIBBON_WIN2_EDIT="$edit" ${out:+RIBBON_PROPERTIES_SHOT="$out"} \
			timeout 60 xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/properties/main.tcl" >"$T/$scheme-$name.log" 2>&1 \
			&& grep -q '  ok   win2 drawn' "$T/$scheme-$name.log"; then
			echo "  ok   $scheme: $item drawn in the standalone window"
		else
			echo "  FAIL $scheme: $item"; sed 's/^/       /' "$T/$scheme-$name.log"; fails=$((fails + 1))
		fi
	done
done
# the window as it runs: unix_extra for its socket (built when missing), ribbon-fswatch for its watch
ux=
if ! echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	if [ -e /usr/include/tcl.h ] || [ -e /usr/include/tcl8.6/tcl.h ]; then
		mkdir -p "$T/ux"
		if make -s -C srcpkgs/tcl-unix-extra/files O="$T/ux" >"$T/make.log" 2>&1; then ux=$T/ux
		else echo "  FAIL unix_extra does not build"; sed 's/^/       /' "$T/make.log"; fails=$((fails + 1)); fi
	fi
fi
if [ -n "$ux" ] || echo 'exit [catch {package require unix_extra 0.3}]' | tclsh8.6 2>/dev/null; then
	mkdir -p "$T/fsw"
	if command -v cc >/dev/null 2>&1 && cc -O2 -o "$T/fsw/ribbon-fswatch" "$D/fswatch/ribbon-fswatch.c" 2>"$T/cc.log"; then
		runs="$T/fsw "
	else
		echo "  (ribbon-fswatch not built: the watch is checked with the poll only)"; runs=""
	fi
	for fsw in $runs ""; do
		rm -rf "$T/live"
		if env TCLLIBPATH="${ux:+$ux }${TCLLIBPATH:-}" timeout 300 xvfb-run -a -s "-screen 0 1440x900x24" sh tests/win2-live.sh "$T/live" "$fsw" >"$T/live.log" 2>&1; then
			grep '^  ok' "$T/live.log"
		else
			grep -v '^  ok' "$T/live.log" | sed 's/^/       /'; grep '^  FAIL' "$T/live.log"; fails=$((fails + 1))
		fi
	done
else
	echo "  skip the running window (no unix_extra, no Tcl headers to build it)"
fi

[ $fails -eq 0 ] && echo "win2: all checks passed" || echo "win2: $fails checks failed"
[ $fails -eq 0 ]
