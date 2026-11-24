#!/bin/sh
# GRUB's defaults (srcpkgs/ribbon-base/files/ribbon-grub, sourced by /etc/default/grub when GRUB is the boot loader):
# Ribbon's own kernel is GRUB's entry 0 when one is installed. GRUB sorts kernels by version, and Void's kernel of the
# same version (6.18.64_1) comes before Ribbon's (6.18.64-ribbon_1); GRUB_TOP_LEVEL (GRUB 2.12) moves the newest of
# Ribbon's to the top. The file reads /boot, so it is sourced in a sandbox whose /boot is made here.
# Skips without bwrap.
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v bwrap >/dev/null 2>&1 || { echo "  skip GRUB's defaults (no bwrap)"; exit 0; }
bwrap --ro-bind / / --dev /dev true 2>/dev/null || { echo "  skip GRUB's defaults (bubblewrap cannot make a sandbox here)"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
G=$PWD/srcpkgs/ribbon-base/files/ribbon-grub
top() { bwrap --ro-bind / / --dev /dev --bind "$T/boot" /boot sh -c '. "$1"; echo "${GRUB_TOP_LEVEL:-}"' top "$G"; }
mkdir -p "$T/boot"
for v in 6.18.63_1 6.18.64_1; do : > "$T/boot/vmlinuz-$v"; done
[ -z "$(top)" ] && ok "with Void's kernels only, nothing is moved: entry 0 is the newest" || bad "GRUB_TOP_LEVEL without a Ribbon kernel: '$(top)'"
for v in 6.18.63-ribbon_1 6.18.64-ribbon_1 6.18.64-ribbon_2; do : > "$T/boot/vmlinuz-$v"; done
[ "$(top)" = /boot/vmlinuz-6.18.64-ribbon_2 ] && ok "the newest of Ribbon's kernels is entry 0, ahead of Void's of the same version" ||
	bad "GRUB_TOP_LEVEL: '$(top)'"
: > "$T/boot/vmlinuz-6.18.70_1"
[ "$(top)" = /boot/vmlinuz-6.18.64-ribbon_2 ] && ok "and stays there when Void's kernel is newer" || bad "with a newer Void kernel: '$(top)'"
exit $fail
