#!/bin/sh
# Runs ribbon-sv2dinit against real Void runit services (tests/fixtures/sv)
# and checks the generated dinit services.
set -eu
cd "$(dirname "$0")/.."
GEN=srcpkgs/ribbon-dinit/files/ribbon-sv2dinit
SHARE=srcpkgs/ribbon-dinit/files
HAND=srcpkgs/ribbon-dinit/files/services
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT
fail=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi; }

# Ribbon now ships hand-written services for some of the fixture daemons (NetworkManager, bluetoothd,
# chronyd, cronie), which the generator rightly skips; the generation checks below run against the
# hand-written set without those, and the real set is checked for winning over the fixtures afterwards.
mkdir "$tmp/hand"
cp -R "$HAND"/. "$tmp/hand/"
for n in NetworkManager bluetoothd chronyd cronie; do rm -rf "${tmp:?}/hand/$n" "${tmp:?}/hand/$n.d"; done
sh "$GEN" --sv-dir tests/fixtures/sv --out "$tmp/out" --hand-dirs "$tmp/hand" --share "$SHARE" > "$tmp/log" 2>&1
cat "$tmp/log" | sed 's/^/     /'

check "NetworkManager generated"                "[ -f $tmp/out/NetworkManager ]"
check "NetworkManager depends on dbus"          "grep -qx 'depends-on: dbus' $tmp/out/NetworkManager"
check "NetworkManager runs the unmodified run script" "grep -q 'command = /usr/lib/ribbon/sv2dinit/sv-exec NetworkManager' $tmp/out/NetworkManager"
check "bluetoothd depends on dbus"              "grep -qx 'depends-on: dbus' $tmp/out/bluetoothd"
check "avahi-daemon depends on dbus (inside if)" "grep -qx 'depends-on: dbus' $tmp/out/avahi-daemon"
check "chronyd has no extra deps"               "[ \"\$(grep -c '^depends-on:' $tmp/out/chronyd 2>/dev/null)\" = 1 ]"
check "ufw (exec pause) accepted"               "[ -f $tmp/out/ufw ]"
check "ufw finish noted"                        "grep -q 'finish exists' $tmp/out/ufw"
check "dbus skipped (hand-written exists)"      "[ ! -f $tmp/out/dbus ]"
check "elogind skipped (hand-written exists)"   "[ ! -f $tmp/out/elogind ]"
check "backgrounding service refused"           "[ ! -f $tmp/out/libvirtd ] && grep -q 'refused   libvirtd' $tmp/log"
check "non-exec service refused"                "[ ! -f $tmp/out/badservice ] && grep -q 'refused   badservice' $tmp/log"
check "runit-compat service written"            "[ -f $tmp/out/runit-compat ] && [ -d $tmp/out/runit-compat.d ]"
check "logs go to /var/log/dinit"               "grep -q 'logfile = /var/log/dinit/cronie.log' $tmp/out/cronie"

# Re-running replaces only generated files and keeps foreign ones.
echo "type = internal" > "$tmp/out/handmade"
sh "$GEN" --sv-dir tests/fixtures/sv --out "$tmp/out" --hand-dirs "$tmp/hand" --share "$SHARE" --quiet 2>/dev/null
check "re-run keeps non-generated files"        "[ -f $tmp/out/handmade ]"
check "re-run regenerates"                      "[ -f $tmp/out/NetworkManager ]"

# Against Ribbon's own hand-written services, those win over the fixtures' runit services.
sh "$GEN" --sv-dir tests/fixtures/sv --out "$tmp/out2" --hand-dirs "$HAND" --share "$SHARE" > "$tmp/log2" 2>&1
for n in NetworkManager bluetoothd chronyd cronie; do
	check "hand-written $n wins (not generated)" "[ ! -e $tmp/out2/$n ] && grep -q \"skip      $n (hand-written\" $tmp/log2"
done

# --check reports refusals with a non-zero exit status.
if sh "$GEN" --check --quiet --sv-dir tests/fixtures/sv --hand-dirs "$HAND" --share "$SHARE" 2>/dev/null; then
	echo "  FAIL --check should fail with refused services"; fail=1
else
	echo "  ok   --check exits non-zero when something is refused"
fi

# Generated + hand-written services must lint cleanly together.
python3 tests/lint-dinit.py "$tmp/out" "$tmp/hand" srcpkgs/ribbon-tools/files/services srcpkgs/ribbon-desktop/files/services >/dev/null ||
	{ echo "  FAIL generated services don't lint"; python3 tests/lint-dinit.py "$tmp/out" "$tmp/hand" srcpkgs/ribbon-tools/files/services srcpkgs/ribbon-desktop/files/services; fail=1; }

# sv compatibility shim answers from dinitctl.
mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho "$@" >> %s/dinitctl.calls\n[ "$1 $2" = "is-started dbus" ]\n' "$tmp" > "$tmp/bin/dinitctl"
chmod +x "$tmp/bin/dinitctl"
PATH="$tmp/bin:$PATH" sh srcpkgs/ribbon-dinit/files/sv check dbus && r1=0 || r1=1
PATH="$tmp/bin:$PATH" sh srcpkgs/ribbon-dinit/files/sv -w 5 check /var/service/nope && r2=0 || r2=1
check "sv check dbus -> dinitctl is-started dbus"  "[ $r1 -eq 0 ] && grep -qx 'is-started dbus' $tmp/dinitctl.calls"
check "sv -w 5 check missing -> fails"             "[ $r2 -eq 1 ] && grep -qx 'is-started nope' $tmp/dinitctl.calls"

exit $fail
