#!/bin/sh
# build/kits/kit-image.sh (a system made of kits, made bootable and booted in QEMU): what can be checked of it without
# the built set, which takes hours to build (docs/RECIPES.md records its boots): it parses, shellcheck has no warning,
# it says what it needs when it is not given it, and its verdict is read off the serial log as documented.
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
K=build/kits/kit-image.sh
sh -n "$K" && ok "kit-image.sh parses" || bad "kit-image.sh does not parse"
if command -v shellcheck >/dev/null 2>&1; then
	shellcheck -S warning "$K" > "$T/sc" 2>&1 && ok "shellcheck: no warnings" || bad "shellcheck: $(head -n 5 "$T/sc")"
fi
sh "$K" > "$T/o" 2>&1 && bad "no arguments ran" || { grep -q 'usage: kit-image.sh OUT DIR | kit-image.sh boot DIR' "$T/o" && ok "without arguments it says how it is called" || bad "usage: $(cat "$T/o")"; }
mkdir "$T/d"
sh "$K" boot "$T/d" > "$T/o" 2>&1 && bad "boot without an image ran" || { grep -q "no $T/d/root.ext4" "$T/o" && ok "boot without an image says which file is missing" || bad "boot: $(cat "$T/o")"; }
# the probe in the image and the verdict agree on the words: every check is "KITIMG ok|FAIL ...", the end "KITIMG done"
n=$(grep -c 'ok "\|chk "' "$K"); [ "$n" -ge 20 ] && grep -q 'echo "KITIMG done"' "$K" && grep -q "grep -q '^KITIMG done'" "$K" &&
	ok "the image's probe makes $n checks and the verdict waits for its last line" || bad "the probe or the verdict ($n checks)"
grep -q 'TEST image' "$K" && grep -q 'tests/fixtures/kittrust' "$K" && ok "it says its kits are signed with the test keys (no machine trusts them)" || bad "the test keys are not named"
exit $fail
