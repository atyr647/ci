#!/bin/sh
# kernel-boot-files (srcpkgs/ribbon-tools/files/bin/kernel-boot-files): a kernel found in /usr/lib/modules/VER/vmlinuz
# (a kernel kit, or a base that keeps the image beside its modules) is made bootable on /boot, on any base: copied
# as vmlinuz-VER, initramfs-VER.img built by dracut, kernel-changed told. Fake root; dracut and kernel-changed are
# stand-ins that log their words.
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
KB=srcpkgs/ribbon-tools/files/bin/kernel-boot-files
R=$T/root
LOG=$T/log
cat > "$T/dracut" <<'SH'
#!/bin/sh
echo "dracut $*" >> "$LOG"
[ -e "$T/dracut-fails" ] && exit 1
for last; do :; done; for a in "$@"; do case $a in -*) ;; *) f=$a; break ;; esac; done
printf 'initramfs for %s' "$last" > "$f"
SH
cat > "$T/kc" <<'SH'
#!/bin/sh
echo "kernel-changed $*" >> "$LOG"
SH
chmod +x "$T/dracut" "$T/kc"
fresh() { rm -rf "$R" "$LOG" "$T/dracut-fails"; mkdir -p "$R/boot" "$R/usr/lib/modules/6.18.70-ribbon_1"; : > "$LOG"
	printf 'kernel image' > "$R/usr/lib/modules/6.18.70-ribbon_1/vmlinuz"; }
export LOG T   # the stand-ins log to $LOG and look for $T/dracut-fails
kb() { RIBBON_ROOT=$R RIBBON_DRACUT=$T/dracut RIBBON_KERNEL_CHANGED=$T/kc sh "$KB" "$@" 2>"$T/err"; }

fresh
kb install 6.18.70-ribbon_1; rc=$?
if [ $rc = 0 ] && [ "$(cat "$R/boot/vmlinuz-6.18.70-ribbon_1")" = "kernel image" ] && [ "$(cat "$R/boot/initramfs-6.18.70-ribbon_1.img")" = "initramfs for 6.18.70-ribbon_1" ]; then
	ok "the kernel is copied to /boot/vmlinuz-VER and its initramfs built (initramfs-VER.img)"; else bad "install: rc=$rc $(ls -A "$R/boot") $(cat "$T/err")"; fi
grep -qx "kernel-changed install 6.18.70-ribbon_1" "$LOG" && ok "kernel-changed install VERSION ran (menu, restart note)" || bad "kernel-changed not told: $(cat "$LOG")"
hidden() { for f in "$R"/boot/.[!.]*; do [ -e "$f" ] && echo "$f"; done; }
[ -z "$(hidden)" ] && ok "no temporary file is left on /boot" || bad "temp files: $(ls -A "$R/boot")"
: > "$LOG"; kb install 6.18.70-ribbon_1; rc=$?
if [ $rc = 0 ] && ! grep -q '^dracut' "$LOG"; then ok "again: nothing is rebuilt (same image, initramfs there), kernel-changed still told"; else bad "second run: $(cat "$LOG")"; fi
printf 'a newer image' > "$R/usr/lib/modules/6.18.70-ribbon_1/vmlinuz"; rm -f "$R/boot/initramfs-6.18.70-ribbon_1.img"; : > "$LOG"
kb install 6.18.70-ribbon_1
[ "$(cat "$R/boot/vmlinuz-6.18.70-ribbon_1")" = "a newer image" ] && ok "a changed image replaces the one on /boot" || bad "not replaced"

fresh; touch "$T/dracut-fails"
kb install 6.18.70-ribbon_1; rc=$?
if [ $rc = 1 ] && [ -z "$(ls -A "$R/boot")" ] && grep -q "initramfs for 6.18.70-ribbon_1 could not be built" "$T/err" && ! grep -q '^kernel-changed' "$LOG"; then
	ok "dracut failing: exit 1, says so, and nothing is left on /boot (the menu never lists a kernel that cannot boot)"
else bad "dracut failure: rc=$rc boot=[$(ls -A "$R/boot")] $(cat "$T/err")"; fi
fresh; printf 'old kernel' > "$R/boot/vmlinuz-6.18.70-ribbon_1"; printf 'old ram' > "$R/boot/initramfs-6.18.70-ribbon_1.img"
printf 'new kernel' > "$R/usr/lib/modules/6.18.70-ribbon_1/vmlinuz"; touch "$T/dracut-fails"
kb install 6.18.70-ribbon_1
[ "$(cat "$R/boot/vmlinuz-6.18.70-ribbon_1")" = "new kernel" ] && [ "$(cat "$R/boot/initramfs-6.18.70-ribbon_1.img")" = "old ram" ] && ok "an initramfs already there is not rebuilt, so a dracut that would fail is not called" || bad "existing initramfs touched"

fresh; rm "$R/usr/lib/modules/6.18.70-ribbon_1/vmlinuz"
kb install 6.18.70-ribbon_1; rc=$?
[ $rc = 1 ] && grep -q "no kernel image" "$T/err" && ok "no vmlinuz in the modules directory: exit 1, says so" || bad "missing image: rc=$rc"
fresh; kb install ../../etc; rc=$?
[ $rc = 2 ] && [ -z "$(ls -A "$R/boot")" ] && ok "a version with a path in it is refused (exit 2), nothing written" || bad "path version: rc=$rc"
kb install ".hidden"; [ $? = 2 ] && ok "a leading dot is refused too" || bad "dot version"
kb frobnicate x; [ $? = 2 ] && ok "another verb is a usage error" || bad "usage"
fresh; rmdir "$R/boot"
kb install 6.18.70-ribbon_1; rc=$?
[ $rc = 1 ] && grep -q "boot partition is not mounted" "$T/err" && ok "no /boot: exit 1, says the boot partition may not be mounted" || bad "no boot: rc=$rc $(cat "$T/err")"

# shipped like kernel-changed: the template and the install manifest
grep -q 'bin/kernel-boot-files" 755 usr/lib/ribbon' srcpkgs/ribbon-tools/template && grep -q 'file 755 usr/lib/ribbon @files/bin/kernel-boot-files' build/install/manifests/ribbon-tools.manifest &&
	ok "installed as /usr/lib/ribbon/kernel-boot-files (template and manifest)" || bad "not in the template and manifest"
exit $fail
