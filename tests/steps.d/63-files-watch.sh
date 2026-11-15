#!/bin/sh
# Ribbon Files' folder watch (ribbon-fswatch, shell/files.tcl) and the background copy's status and
# clean-up (tests/files-watch.tcl): the real helper built here with -Werror, then the fallbacks: a helper
# that refuses every folder, one that exits, and no helper (the windows poll). Runs the shell under
# xvfb with HOME in a temp folder. Without wish8.6, xvfb-run or cc the step skips.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v wish8.6 >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1 || ! command -v cc >/dev/null 2>&1; then
	echo "  skip files watch (no wish8.6 / xvfb-run / cc)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/refuse" "$T/dies"
if ! cc -O2 -Wall -Wextra -Werror -o "$T/bin/ribbon-fswatch" srcpkgs/ribbon-desktop/files/fswatch/ribbon-fswatch.c; then
	echo "files watch: ribbon-fswatch does not build"
	exit 1
fi
cat >"$T/refuse/ribbon-fswatch" <<'SH'
#!/bin/sh
while IFS= read -r line; do
	case $line in watch\ *) printf 'refused\t%s\n' "${line#watch }" ;; esac
done
SH
printf '#!/bin/sh\nexit 0\n' >"$T/dies/ribbon-fswatch"
chmod +x "$T/refuse/ribbon-fswatch" "$T/dies/ribbon-fswatch"

fail=0
run_mode() {  # MODE PATH-PREFIX
	m=$1; dir=$2
	h="$T/home-$m"; mkdir -p "$h/config" "$h/state" "$h/cache" "$h/run"
	if env HOME="$h" XDG_CONFIG_HOME="$h/config" XDG_STATE_HOME="$h/state" XDG_CACHE_HOME="$h/cache" XDG_RUNTIME_DIR="$h/run" \
		PATH="${dir:+$dir:}$PATH" RIBBON_FILES_WATCH_MODE=$m RIBBON_SHELL_TEST=tests/files-watch.tcl timeout -k 5 300 \
		xvfb-run -a -s "-screen 0 1440x900x24" wish8.6 -encoding utf-8 srcpkgs/ribbon-desktop/files/shell/main.tcl -name ribbon-shell >"$T/out-$m" 2>&1 \
		&& grep -q 'files-watch: all checks passed' "$T/out-$m"
	then
		grep '  ok ' "$T/out-$m" | sed 's/^/  /'
		echo "files watch ($m): all checks passed"
	else
		sed 's/^/       /' "$T/out-$m"
		echo "files watch ($m): checks failed"
		fail=1
	fi
}
run_mode real "$T/bin"
run_mode refuse "$T/refuse"
run_mode dies "$T/dies"
if command -v ribbon-fswatch >/dev/null 2>&1; then
	echo "  skip files watch (none): a ribbon-fswatch is installed on PATH"
else
	run_mode none ""
fi
exit $fail
