#!/bin/sh
# runit's finish and check scripts under dinit (srcpkgs/ribbon-dinit/files/sv-exec and sv): ./finish runs when ./run ends,
# with runit's arguments (exit code or -1, then 0 or the signal number), after dinit's stop signal has been passed to
# the daemon; a service without ./finish is still exec'd (no extra process); `sv check` runs ./check and waits -w seconds.
# Fixture services in a temporary RIBBON_SV_DIR; dinitctl is a stand-in.
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
SVEXEC=$PWD/srcpkgs/ribbon-dinit/files/sv-exec
SV=$PWD/srcpkgs/ribbon-dinit/files/sv
export RIBBON_SV_DIR=$T/sv
mkdir -p "$T/sv/withfin" "$T/sv/plain" "$T/sv/exits" "$T/sv/chk" "$T/bin"

# a daemon that runs until it is stopped, and a finish that writes its arguments
printf '#!/bin/sh\necho "$$" > "%s/daemon.pid"\nexec sleep 60\n' "$T" > "$T/sv/withfin/run"
printf '#!/bin/sh\necho "finish $*" >> "%s/finish.log"\n' "$T" > "$T/sv/withfin/finish"
printf '#!/bin/sh\necho "$$" > "%s/plain.pid"\nexec sleep 60\n' "$T" > "$T/sv/plain/run"
printf '#!/bin/sh\nexit 3\n' > "$T/sv/exits/run"
printf '#!/bin/sh\necho "finish $*" >> "%s/finish.log"\n' "$T" > "$T/sv/exits/finish"
chmod +x "$T"/sv/*/run "$T"/sv/*/finish

# 1. dinit's stop signal reaches the daemon, then finish runs with -1 and the signal number
sh "$SVEXEC" withfin & sup=$!
i=0; while [ ! -s "$T/daemon.pid" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
dpid=$(cat "$T/daemon.pid")
if [ "$dpid" != "$sup" ]; then ok "with a finish, ./run is a child of sv-exec (dinit supervises sv-exec, which passes signals on)"; else bad "run was exec'd although there is a finish"; fi
kill -TERM "$sup"
wait "$sup"; rc=$?
if ! kill -0 "$dpid" 2>/dev/null; then ok "dinit's stop (TERM to sv-exec) stopped the daemon too"; else bad "the daemon survived the stop"; kill "$dpid" 2>/dev/null; fi
if [ "$(cat "$T/finish.log" 2>/dev/null)" = "finish -1 15" ]; then ok "finish ran once, after it, with -1 (killed by a signal) and 15 (TERM)"; else bad "finish log: $(cat "$T/finish.log" 2>&1)"; fi
[ $rc = 143 ] && ok "sv-exec ends with the daemon's own status (143)" || bad "exit status $rc"

# 2. a daemon that exits by itself: finish gets its exit code and 0
: > "$T/finish.log"
sh "$SVEXEC" exits; rc=$?
if [ "$(cat "$T/finish.log")" = "finish 3 0" ] && [ $rc = 3 ]; then ok "a daemon that exits 3: finish 3 0, and sv-exec exits 3 (dinit sees the failure and restarts by its own policy)"; else bad "exit case: rc=$rc $(cat "$T/finish.log")"; fi

# 3. no finish: run is exec'd, nothing in between
sh "$SVEXEC" plain & sup=$!
i=0; while [ ! -s "$T/plain.pid" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if [ "$(cat "$T/plain.pid")" = "$sup" ]; then ok "without a finish nothing changes: ./run replaces sv-exec (the daemon is what dinit supervises)"; else bad "plain service not exec'd: $(cat "$T/plain.pid") vs $sup"; fi
kill "$sup" 2>/dev/null; wait "$sup" 2>/dev/null

# 4. sv check: up, and ./check says ready
cat > "$T/bin/dinitctl" <<'SH'
#!/bin/sh
# dinitctl is-started NAME: started when $T/up/NAME exists
[ "$1" = is-started ] && [ -e "$UPDIR/$2" ]
SH
chmod +x "$T/bin/dinitctl"
export UPDIR=$T/up; mkdir -p "$UPDIR"
sv() { PATH=$T/bin:$PATH sh "$SV" "$@"; }
printf '#!/bin/sh\n[ -e "%s/ready" ]\n' "$T" > "$T/sv/chk/check"; chmod +x "$T/sv/chk/check"
sv check chk; [ $? != 0 ] && ok "sv check: a service that is not up fails (no wait with -w 0)" || bad "check on a stopped service"
touch "$UPDIR/chk"
sv -w 0 check chk; [ $? != 0 ] && ok "up, but its ./check says not ready yet: sv check fails" || bad "check ignored ./check"
touch "$T/ready"
sv -w 0 check chk && ok "up and ./check exits 0: sv check succeeds" || bad "check with a ready service"
rm -f "$T/ready"
( sleep 2; touch "$T/ready" ) &
start=$(date +%s)
sv -w 6 check chk; rc=$?
end=$(date +%s)
if [ $rc = 0 ] && [ $((end - start)) -ge 1 ] && [ $((end - start)) -le 5 ]; then ok "-w 6 waits for ./check to turn ready (took $((end - start)) s)"; else bad "wait: rc=$rc after $((end - start)) s"; fi
touch "$UPDIR/plain"
sv -w 0 check plain && ok "a service with no ./check is ready once it is up" || bad "check without ./check"
sv -w 0 status chk && ok "sv status is still just 'is it started'" || bad "status"
exit $fail
