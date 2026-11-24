#!/bin/sh
# The nftables service (srcpkgs/ribbon-dinit/files/services/nftables) and its loader (files/firewall-load): the firewall is
# ordered before the network and the login screen, stopping it removes only Ribbon's table, and a /etc/nftables.conf that does
# not load never leaves the machine without a firewall (Ribbon's own ruleset, then a minimal one; the service fails so that
# it shows). Review findings of 17 Nov. nft is a stand-in that logs and fails for the files named in $FAILS.
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
SVC=srcpkgs/ribbon-dinit/files/services/nftables
LOADER=srcpkgs/ribbon-dinit/files/firewall-load

grep -qx 'before: NetworkManager' "$SVC" && grep -qx 'before: loginready' "$SVC" && ok "the firewall starts before NetworkManager and before the login screen is ready" || bad "no ordering before the network: $(grep -n before "$SVC")"
grep -qx 'stop-command = /usr/sbin/nft delete table inet ribbon' "$SVC" && ! grep -v '^#' "$SVC" | grep -q 'flush ruleset' && ok "stopping removes Ribbon's table only (other software's tables stay)" || bad "stop-command: $(grep stop "$SVC")"
grep -qx 'command = /usr/lib/ribbon/firewall-load' "$SVC" && ok "the service runs the loader" || bad "service command"
python3 tests/lint-dinit.py --known runit-compat --known NetworkManager --known greetd srcpkgs/ribbon-dinit/files/services >"$T/lint" 2>&1 && ok "the dinit services still lint" || { cat "$T/lint"; bad "dinit lint"; }
grep -q 'file 755 usr/lib/ribbon @files/firewall-load' build/install/manifests/ribbon-dinit.manifest && grep -q 'firewall-load" 755 usr/lib/ribbon' srcpkgs/ribbon-dinit/template && ok "the loader is installed (template and manifest)" || bad "loader not installed"

cat > "$T/nft" <<'SH'
#!/bin/sh
# nft -f FILE | nft -f - : logs the file (or the stdin's first words) and fails for a file named in $FAILS
f=$2
if [ "$f" = - ]; then echo "nft stdin: $(cat | tr -s '\n\t ' ' ' | cut -c1-600)" >> "$LOG"; exit "${STDIN_RC:-0}"; fi
echo "nft $f" >> "$LOG"
case " $FAILS " in *" $f "*) echo "$f:3:1: Error: syntax error" >&2; exit 1 ;; esac
exit 0
SH
chmod +x "$T/nft"
echo "table inet ribbon {}" > "$T/default.conf"; echo "garbage" > "$T/etc.conf"
export LOG=$T/log
run() { : > "$LOG"; : > "$T/kmsg"; RIBBON_NFT=$T/nft RIBBON_NFT_CONF=$T/etc.conf RIBBON_NFT_DEFAULT=$T/default.conf RIBBON_KMSG=$T/kmsg sh "$LOADER" 2>"$T/err"; }

FAILS='' run; rc=$?
[ $rc = 0 ] && [ "$(cat "$LOG")" = "nft $T/etc.conf" ] && ok "the configured file loads: exit 0, nothing else loaded" || bad "good conf: rc=$rc $(cat "$LOG")"
FAILS="$T/etc.conf" run; rc=$?
if [ $rc = 1 ] && grep -qx "nft $T/default.conf" "$LOG" && grep -q 'did not load' "$T/kmsg" && grep -q "Ribbon's own ruleset" "$T/kmsg"; then
	ok "a configured file that does not load: Ribbon's own ruleset goes in, the service fails (exit 1), the reason is in the kernel log"
else bad "bad conf: rc=$rc $(cat "$LOG" "$T/kmsg")"; fi
FAILS="$T/etc.conf $T/default.conf" run; rc=$?
if [ $rc = 1 ] && grep -q '^nft stdin: .*policy drop' "$LOG"; then
	ok "neither loads: a minimal inbound-drop ruleset is loaded from the loader itself (never no firewall), exit 1"
else bad "both bad: rc=$rc $(cat "$LOG")"; fi
grep -q 'ct state established,related accept' "$LOG" && grep -q 'iif "lo" accept' "$LOG" && ok "  and it lets replies and loopback through (the machine stays usable)" || bad "minimal ruleset: $(cat "$LOG")"
: > "$LOG"; RIBBON_NFT=$T/nft RIBBON_NFT_CONF=$T/default.conf RIBBON_NFT_DEFAULT=$T/default.conf RIBBON_KMSG=$T/kmsg FAILS="$T/default.conf" STDIN_RC=0 sh "$LOADER" 2>/dev/null; rc=$?
grep -q '^nft stdin' "$LOG" && [ $rc = 1 ] && ok "when the configured file IS Ribbon's own and fails, it is not tried twice: the minimal one follows" || bad "same file twice: rc=$rc $(cat "$LOG")"
exit $fail
