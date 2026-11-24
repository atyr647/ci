#!/bin/sh
# Alt+Tab data and grid (U17): the grid for 1..40 apps and the grouping from a scripted watch stream
# (tests/shell-alttab.tcl, no display); ribbon-shell-watch builds with -Werror; the switcher scene draws
# each board state headless (tests/shell-alttab-scene.tcl: apps, many, scrolled, stack, close, quit, game). Skips what the container lacks.
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
if command -v tclsh >/dev/null 2>&1; then
	if tclsh tests/shell-alttab.tcl >/tmp/alttab-$$.out 2>&1; then
		echo "  ok   switcher grid and app list (tests/shell-alttab.tcl)"
	else
		sed 's/^/       /' /tmp/alttab-$$.out; echo "  FAIL switcher grid and app list"; fails=1
	fi
	rm -f /tmp/alttab-$$.out
else
	echo "  skip switcher grid (no tclsh)"
fi
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists wayland-client xkbcommon wayland-protocols && command -v wayland-scanner >/dev/null 2>&1; then
	T=$(mktemp -d)
	if make -s -C srcpkgs/ribbon-desktop/files/shell-watch O="$T" CFLAGS="-O2 -Wall -Wextra -Werror" >"$T/out" 2>&1; then
		echo "  ok   ribbon-shell-watch and ribbon-shell-switch build with -Werror"
	else
		sed 's/^/       /' "$T/out"; echo "  FAIL shell-watch does not build with -Werror"; fails=1
	fi
	rm -rf "$T"
else
	echo "  skip shell-watch build (no wayland-client / xkbcommon / wayland-protocols / wayland-scanner)"
fi
if command -v wish8.6 >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1; then
	D=$PWD/srcpkgs/ribbon-desktop/files
	T=$(mktemp -d)
	mkdir -p "$T/config/ribbon" "$T/home"
	cp "$D/themes/palettes/ribbon.conf" "$T/config/ribbon/palette.conf"
	cp -r "$D/shell" "$T/shell"; cp -r "$D/rbnalpha" "$T/rbnalpha"
	for b in apps many scrolled stack close quit game; do
		mkdir -p "$T/$b/run" "$T/$b/state" "$T/$b/cache"
		if HOME=$T/home XDG_CONFIG_HOME=$T/config XDG_CACHE_HOME=$T/$b/cache XDG_STATE_HOME=$T/$b/state \
			XDG_RUNTIME_DIR=$T/$b/run ALTTAB_BOARD=$b ALTTAB_OUT=$T/$b.png \
			RIBBON_SHELL_TEST=tests/shell-alttab-scene.tcl \
			timeout -k 5 60 xvfb-run -a -s "-screen 0 1440x900x24" \
			wish8.6 -encoding utf-8 "$T/shell/main.tcl" -name ribbon-shell >"$T/$b.log" 2>&1 \
			&& [ -s "$T/$b.png" ]; then
			echo "  ok   switcher board $b draws headless"
			[ -n "${ALTTAB_SHOTS:-}" ] && cp "$T/$b.png" "$ALTTAB_SHOTS/alttab-$b.png"
		else
			sed 's/^/       /' "$T/$b.log" | tail -5; echo "  FAIL switcher board $b"; fails=1
		fi
	done
	rm -rf "$T"
else
	echo "  skip switcher scene (no wish8.6 / xvfb-run)"
fi
exit $fails
