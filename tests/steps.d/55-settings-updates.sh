#!/bin/sh
# Settings → Updates (U12): the page's states and its flow against the stand-in kit (tests/settings-updates-kit.tcl),
# under xvfb: the waiting list and history from kit's --tcl answers, the Rewind sheet, the dropdown, and the flow
# (switches written through kit-updater --set, kit rewind --tcl --yes, kit check --tcl --yes), and the system's packages
# beside the kits (system: the real ribbon-update on the stand-in package seam tests/fixtures/updates-seam and its
# stand-in pkexec). Skips without wish8.6/xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip Settings → Updates (needs wish8.6 and xvfb-run)"; exit 0
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
D=$PWD/srcpkgs/ribbon-desktop/files
fails=0
for st in main rewind dropdown flow system; do
	h=$T/$st; mkdir -p "$h/home" "$h/cfg" "$h/cache" "$h/seam" "$h/run" "$h/modules"
	set -- RIBBON_UPDATE=    # no ribbon-update: kit's rows only, whatever this host has installed
	if [ "$st" = system ]; then
		printf 'linux6.18|6.18.58|6.18.60|14000000|update|restart\n' > "$h/seam/plan"
		printf 'linux6.18 6.18.58_1\n' > "$h/seam/installed"; : > "$h/seam/log"
		set -- RIBBON_UPDATE="bash $PWD/srcpkgs/ribbon-tools/files/bin/ribbon-update" RIBBON_UPDATE_PKEXEC="$PWD/tests/fixtures/updates-seam/bin/pkexec" \
			RIBBON_LIB="$PWD/tests/fixtures/updates-seam" RIBBON_REAL_LIB="$PWD/srcpkgs/ribbon-tools/files/lib" RIBBON_SEAM_STUB="$h/seam" \
			RIBBON_RUN="$h/run" RIBBON_MODULES="$h/modules" SETTINGS_UPDATES_STUB_LOG="$h/seam/log"
	fi
	if timeout -k 5 120 env HOME="$h/home" XDG_CONFIG_HOME="$h/cfg" XDG_CACHE_HOME="$h/cache" "$@" \
		RIBBON_KIT="tclsh8.6 $PWD/tests/settings-updates-kit.tcl" \
		RIBBON_KIT_UPDATER="tclsh8.6 $PWD/tests/settings-updates-kit.tcl" \
		RIBBON_SETTINGS_SCENE="$PWD/tests/settings-updates-scene.tcl" RIBBON_UPDATES_STATE=$st \
		RIBBON_UPDATES_RESULT="$h/result.txt" \
		xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 "$D/apps/settings/main.tcl" >"$h/out.txt" 2>&1; then
		echo "  ok   Settings → Updates: $st"
	else
		echo "  FAIL Settings → Updates: $st"; sed 's/^/       /' "$h/out.txt" "$h/result.txt" 2>/dev/null; fails=$((fails + 1))
	fi
done
[ "$fails" -eq 0 ] || exit 1
