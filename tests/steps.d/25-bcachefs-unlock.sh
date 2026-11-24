#!/bin/sh
# The initramfs hook that asks for an encrypted bcachefs root's passphrase
# (srcpkgs/ribbon-tools/files/dracut/90ribbon-bcachefs/ribbon-bcachefs-unlock.sh), run sourced, as dracut does, with stand-ins
# for getarg, modprobe, bcachefs and ask_for_password. `bcachefs unlock` reads its passphrase from standard input (read in
# bcachefs-tools' source: never /dev/tty), so the hook asks through dracut's ask_for_password where there is one (console or
# plymouth, the answer piped to the command), and falls back to running the command itself, three tries.
set -u
cd "$(dirname "$0")/../.." || exit 1
H=$PWD/srcpkgs/ribbon-tools/files/dracut/90ribbon-bcachefs/ribbon-bcachefs-unlock.sh
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
LOG=$T/log
# the hook runs in a function-less sh script with `return`: source it from a function, as dracut's hook runner does
run() { # ROOTFSTYPE ROOT ENCRYPTED(0|1) WITH_ASK(0|1) [UNLOCK_FAILS_N]
	: > "$LOG"
	(
		getarg() { case $1 in rootfstype=) echo "$ROOTFSTYPE" ;; root=) echo "$ROOT" ;; esac; }
		modprobe() { echo "modprobe $*" >> "$LOG"; }
		bcachefs() {
			echo "bcachefs $*" >> "$LOG"
			if [ "$1 $2" = "unlock -c" ]; then [ "$ENCRYPTED" = 1 ]; return; fi
			# a real unlock: fails the first $UNLOCK_FAILS times
			n=$(cat "$T/n" 2>/dev/null || echo 0); echo $((n + 1)) > "$T/n"
			[ "$n" -ge "${UNLOCK_FAILS:-0}" ]
		}
		[ "$WITH_ASK" = 1 ] && ask_for_password() { echo "ask_for_password $*" >> "$LOG"; }
		hook() { . "$H"; }
		hook
	)
}
rm -f "$T/n"
ROOTFSTYPE=ext4 ROOT=/dev/sda2 ENCRYPTED=1 WITH_ASK=1 run
[ ! -s "$LOG" ] && ok "another root filesystem: nothing is loaded, checked or asked" || bad "ext4: $(cat "$LOG")"

ROOTFSTYPE=bcachefs ROOT=UUID=1234-abcd ENCRYPTED=0 WITH_ASK=1 run
if grep -q 'modprobe -q bcachefs' "$LOG" && grep -q 'unlock -c /dev/disk/by-uuid/1234-abcd' "$LOG" && ! grep -q 'ask_for_password' "$LOG"; then
	ok "an unencrypted bcachefs root: the module is loaded, the device checked (by its UUID path), nobody asked"
else bad "unencrypted: $(cat "$LOG")"; fi

ROOTFSTYPE=bcachefs ROOT=UUID=1234-abcd ENCRYPTED=1 WITH_ASK=1 run
want="ask_for_password --cmd bcachefs unlock -k session /dev/disk/by-uuid/1234-abcd --prompt Passphrase for /dev/disk/by-uuid/1234-abcd --tries 3 --tty-echo-off"
if grep -qxF "$want" "$LOG" && [ "$(grep -c '^bcachefs unlock -k' "$LOG")" = 0 ]; then
	ok "an encrypted root with dracut's ask_for_password: it asks (console or splash), 3 tries, the answer goes to bcachefs' standard input; the hook does not run unlock itself"
else bad "encrypted with ask: $(cat "$LOG")"; fi

rm -f "$T/n"
ROOTFSTYPE=bcachefs ROOT=/dev/nvme0n1p2 ENCRYPTED=1 WITH_ASK=0 UNLOCK_FAILS=1 run
if [ "$(grep -c '^bcachefs unlock -k session /dev/nvme0n1p2' "$LOG")" = 2 ]; then
	ok "no ask_for_password: the command itself, a plain device path as given, stopping at the first success (2 tries here)"
else bad "fallback: $(cat "$LOG")"; fi
rm -f "$T/n"
ROOTFSTYPE=bcachefs ROOT=/dev/nvme0n1p2 ENCRYPTED=1 WITH_ASK=0 UNLOCK_FAILS=9 run
[ "$(grep -c '^bcachefs unlock -k session' "$LOG")" = 3 ] && ok "  three tries at most, then the boot goes on to fail with its own message" || bad "tries: $(cat "$LOG")"
sh -n "$H" && ok "the hook parses as POSIX sh" || bad "syntax"
exit $fail
