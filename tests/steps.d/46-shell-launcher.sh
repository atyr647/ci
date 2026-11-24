#!/bin/sh
# The launcher's flows (tests/shell-launcher.tcl, a RIBBON_SHELL_TEST hook under xvfb): typing and the ranking,
# the .desktop rules, launching through apps::run (stand-ins on PATH log what they were started with), Properties,
# the modes and the mode menu, Files mode (index, completion, opening in Ribbon Files or the chosen folder app)
# and Web mode. The apps are fixture .desktop files in a temp XDG_DATA_HOME and XDG_DATA_DIRS. Skips without
# wish8.6 / xvfb-run.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
	echo "  skip the launcher's flows (no wish8.6 / xvfb-run)"; exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/Documents" "$T/home/.secret" "$T/data/applications" "$T/sys/applications" "$T/bin" "$T/state/ribbon" "$T/rt" "$T/cfg"
chmod 700 "$T/rt"
: > "$T/home/Documents/report-2026.txt"
: > "$T/home/.secret/report-hidden.txt"
echo "strawberry 5" > "$T/state/ribbon/launcher-usage"

# desk ID NAME EXEC [KEY=VALUE...]: a .desktop file in the data home
desk() {
	f=$T/data/applications/$1.desktop; shift
	{ echo '[Desktop Entry]'; echo 'Type=Application'; echo "Name=$1"; echo "Exec=$2"; shift 2
	  for kv in "$@"; do echo "$kv"; done; } > "$f"
}
desk steam Steam 'steam -silent %U'
desk rsi 'Star Citizen' 'rsi-launcher --run %f'
desk strawberry Strawberry 'strawberry %U'
desk bigsteam 'Big Steam' bigsteam
desk mist Mist mist 'OnlyShowIn=Ribbon;'
desk phototool 'Photo Tool' phototool 'GenericName=Stills editor'
desk tuner 'Sound Tuner' tuner
desk htop htop htop 'Terminal=true'
desk stash1 'Stash NoDisplay' stash 'NoDisplay=true'
desk stash2 'Stash Hidden' stash 'Hidden=true'
desk stash3 'Stash KDE' stash 'OnlyShowIn=KDE;'
desk stuff 'Stuff link' stuff
sed -i 's/^Type=Application$/Type=Link/' "$T/data/applications/stuff.desktop"
# the same id in the data dirs: the data home's comes first
printf '[Desktop Entry]\nType=Application\nName=Old Steam\nExec=oldsteam\n' > "$T/sys/applications/steam.desktop"

# the stand-ins: each logs its name and arguments
for p in steam rsi-launcher strawberry ribbon-terminal ribbon-properties xdg-open; do
	printf '#!/bin/sh\necho "${0##*/} $*" >> "%s"\n' "$T/launch.log" > "$T/bin/$p"; chmod +x "$T/bin/$p"
done
: > "$T/launch.log"

if timeout -k 5 120 env PATH="$T/bin:$PATH" HOME="$T/home" XDG_DATA_HOME="$T/data" XDG_DATA_DIRS="$T/sys" XDG_STATE_HOME="$T/state" \
	XDG_CONFIG_HOME="$T/cfg" XDG_CACHE_HOME="$T/cache" XDG_RUNTIME_DIR="$T/rt" XDG_CURRENT_DESKTOP=Ribbon:wlroots \
	DBUS_SESSION_BUS_ADDRESS="unix:path=$T/none" DBUS_SYSTEM_BUS_ADDRESS="unix:path=$T/none" LAUNCH_LOG="$T/launch.log" \
	RIBBON_SHELL_TEST=tests/shell-launcher.tcl xvfb-run -a -s "-screen 0 1440x900x24" \
	wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell >"$T/out" 2>&1; then
	grep -E '^  (ok|FAIL)' "$T/out"
	if grep -q '^  FAIL' "$T/out"; then echo "the launcher's flows: checks failed"; exit 1; fi
	echo "the launcher's flows: all checks passed"
else
	sed 's/^/       /' "$T/out" | tail -40
	echo "  FAIL the launcher's flows (tests/shell-launcher.tcl)"; exit 1
fi
