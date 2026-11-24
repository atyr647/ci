#!/bin/sh
# The hardware clock's mode at boot and shutdown (srcpkgs/ribbon-dinit/files/boot.sh, shutdown-hook): rc.conf's
# HARDWARECLOCK (Void's) wins; without it /etc/adjtime's third line (UTC or LOCAL, hwclock's own file on any base) sets
# it, so an install next to Windows (ribbon-install writes LOCAL there) keeps the clock in local time. The snippet is
# the same in both files; it is cut out between its markers and run on its own against fixture files.
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
D=srcpkgs/ribbon-dinit/files
for f in boot.sh shutdown-hook; do
	sed -n '/^# --- rtc mode ---$/,/^# --- end rtc mode ---$/p' "$D/$f" > "$T/$f.snip"
	[ -s "$T/$f.snip" ] && ok "$f has the rtc-mode snippet" || bad "$f has no rtc-mode snippet"
done
cmp -s "$T/boot.sh.snip" "$T/shutdown-hook.snip" && ok "the two files carry the same snippet" || bad "boot.sh and shutdown-hook differ"
mode() { # ADJTIME-CONTENT [HARDWARECLOCK] -> the HARDWARECLOCK after the snippet
	if [ "$1" = NOFILE ]; then rm -f "$T/adjtime"; else printf '%b' "$1" > "$T/adjtime"; fi
	( HARDWARECLOCK=${2:-}; RIBBON_ADJTIME=$T/adjtime; . "$T/boot.sh.snip"; printf '%s' "$HARDWARECLOCK" )
}
[ "$(mode '0.0 0 0.0\n0\nLOCAL\n')" = localtime ] && ok "adjtime LOCAL: the clock is local time" || bad "LOCAL"
[ "$(mode '0.0 0 0.0\n0\nUTC\n')" = UTC ] && ok "adjtime UTC: UTC" || bad "UTC"
[ "$(mode '0.0 0 0.0\r\n0\r\nLOCAL\r\n')" = localtime ] && ok "CR LF line ends are no matter" || bad "CRLF"
[ "$(mode '0.0 0 0.0\n0\nLOCAL\n' UTC)" = UTC ] && ok "rc.conf's HARDWARECLOCK (Void's place) wins over adjtime" || bad "rc.conf wins"
[ -z "$(mode NOFILE)" ] && ok "no adjtime: nothing set (the kernel's UTC stands)" || bad "no file"
[ -z "$(mode '0.0 0 0.0\n0\n')" ] && ok "an adjtime with no third line: nothing set" || bad "short file"
[ -z "$(mode '0.0 0 0.0\n0\nGARBAGE\n')" ] && ok "an adjtime with another word there: nothing set" || bad "garbage"
# what hwclock is then asked: the lower-cased value as its flag (--localtime, --utc), as before
for f in boot.sh shutdown-hook; do
	grep -q 'tr .A-Z. .a-z.' "$D/$f" && ok "$f passes the value to hwclock as --localtime or --utc" || bad "$f's hwclock call changed"
done
# the installer writes LOCAL for Windows, and only then
grep -q "printf '0.0 0 0.0.n0.nLOCAL.n' > \"\$TARGET/etc/adjtime\"" srcpkgs/ribbon-installer/files/bin/ribbon-install &&
	grep -q 'MODE" = alongside \] || \[ -n "\$WINDOWS_ESP"' srcpkgs/ribbon-installer/files/bin/ribbon-install &&
	ok "ribbon-install writes adjtime LOCAL for an install alongside Windows or with Windows' boot manager on another disk" ||
	bad "ribbon-install's adjtime step is missing"
sh -n "$D/boot.sh" && sh -n "$D/shutdown-hook" && ok "both scripts still parse" || bad "syntax"
exit $fail
