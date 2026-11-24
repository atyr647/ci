#!/bin/sh
# A root filesystem made of system kits alone (build/kits/kit-rootfs.sh, kitd --root), and the boot hook mounting its
# /usr (ribbon-kit's dracut 90ribbon-usrview, here with the real losetup and mount, not stand-ins). Ribbon's own
# packages are built, made kits (ribbon-kits.sh), signed and published with the test keys; the root is made from that
# repository; then the hook is run on it as the initramfs would, and /usr is held to the staged files.
# Runs as root in a private mount namespace; skips without root, erofs, mkfs.erofs, a C compiler or Mk4tcl.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
[ "${1:-}" = --inside ] || {
	for t in tclsh8.6 make cc mkfs.erofs losetup unshare; do command -v "$t" >/dev/null 2>&1 || { echo "  skip a root from kits (no $t)"; exit 0; }; done
	[ "$(id -u)" = 0 ] || { echo "  skip a root from kits (needs root: loop devices and mounts)"; exit 0; }
	grep -qw erofs /proc/filesystems || { echo "  skip a root from kits (the kernel has no erofs)"; exit 0; }
	[ -n "${KITFMT_MK4TCL:-}" ] || { echo "  skip a root from kits (kitpack needs Mk4tcl: KITFMT_MK4TCL)"; exit 0; }
	unshare -m --propagation private true 2>/dev/null || { echo "  skip a root from kits (no private mount namespace)"; exit 0; }
	exec timeout -k 5 900 unshare -m --propagation private sh "$0" --inside
}
T=$(mktemp -d); trap 'umount -l "$T/root/usr" 2>/dev/null; rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
F=$ROOT/tests/fixtures/kittrust
KT=$ROOT/kit/kittrust
cc -O2 -o "$T/kit-swapmount" srcpkgs/mkkitfs/files/src/swapmount.c || { echo "  FAIL kit-swapmount does not build"; exit 1; }
export KIT_SWAPMOUNT=$T/kit-swapmount KIT_NOSYNC=1 KIT_EROFS_MIN=1.0 SOURCE_DATE_EPOCH=1700000000
unset KIT_INDEX KIT_USR_VIEWS KIT_USR KITD_ROOT DESTDIR MANIFESTS

make -s build O="$T/o" DISTDIR="$T/dist" >"$T/build.log" 2>&1 || { cat "$T/build.log"; echo "  FAIL make build"; exit 1; }
O=$T/o KIT_SIGN=$F/test-system.key sh build/kits/ribbon-kits.sh "$T/k" >"$T/kits.log" 2>&1 || { cat "$T/kits.log"; echo "  FAIL ribbon-kits.sh"; exit 1; }
L=$T/keys/trusted-keys; mkdir -p "$T/keys"
{ tclsh8.6 $KT/kitkey init -repository org.ribbon.test -root $F/test-root.pub "$L" &&
  tclsh8.6 $KT/kitkey add -role system -from -30d "$L" $F/test-system.pub &&
  tclsh8.6 $KT/kitkey add -role index -from -30d "$L" $F/test-index.pub &&
  tclsh8.6 $KT/kitkey sign -key $F/test-root.key "$L" &&
  tclsh8.6 $KT/kitindex build -key $F/test-index.key -keys "$L" "$T/k/kits" "$T/repo"; } >"$T/pub.log" 2>&1 || { cat "$T/pub.log"; echo "  FAIL publishing the kits"; exit 1; }
printf 'keys = %s\nmirror = file://%s\ntimeout = 5\n' "$L" "$T/repo" > "$T/kit.conf"
export KIT_CONF=$T/kit.conf

R=$T/root
if sh build/kits/kit-rootfs.sh "$R" ribbon-desktop ribbon-tools ribbon-dinit >"$T/log" 2>&1; then ok "a root is made from the repository's kits: $(tail -1 "$T/log" | sed 's/.*: //')"
else bad "kit-rootfs.sh"; sed 's/^/     /' "$T/log"; exit 1; fi
{ ! grep -q " $R/usr " /proc/mounts && [ -z "$(ls -A "$R/usr")" ]; } && ok "/usr is left empty and nothing is left mounted: it is the view's place" || bad "/usr: $(ls -A "$R/usr" | head -3) $(grep "$R" /proc/mounts)"
{ [ "$(readlink "$R/bin")" = usr/bin ] && [ "$(readlink "$R/lib64")" = usr/lib ] && [ "$(stat -c %a "$R/tmp")" = 1777 ] && [ "$(stat -c %a "$R/root")" = 700 ]; } && ok "the skeleton of a merged-/usr system: /bin, /sbin, /lib, /lib64 link into /usr; /tmp 1777, /root 0700" || bad "skeleton: $(ls -la "$R")"
V=$R/var/lib/kit/system/usr
n=$(cat "$V/current" 2>/dev/null)
bad_paths=$(sed 1d "$V/view-$n.erofs.devices" | cut -f2 | while read -r p; do case $p in /var/lib/kit/store/*/kit) [ -f "$R$p" ] || echo "$p" ;; *) echo "$p" ;; esac; done)
[ -z "$bad_paths" ] && [ "$(sed 1d "$V/view-$n.erofs.devices" | wc -l)" -ge 5 ] && ok "the view's device list names each kit as the installed system will see it (/var/lib/kit/store/…), not by the build's path" || bad "device list: $(cat "$V/view-$n.erofs.devices")"
{ cmp -s "$R/etc/ribbon/ribbon.conf" srcpkgs/ribbon-base/files/ribbon.conf && [ -f "$R/etc/kit.conf" ] && [ -d "$R/var/lib/greetd" ]; } && ok "the kits' defaults are in the root's /etc and /var (ribbon.conf, kit.conf, /var/lib/greetd)" || bad "defaults: $(ls -R "$R/etc" | head -20)"
[ ! -e "$R/var/cache/kit" ] && [ ! -e "$R/var/lib/kit/staging" ] && ok "kitd's working files are not left in the root" || bad "left: $(ls "$R/var/cache" "$R/var/lib/kit")"
grep -q 'org.ribbon.desktop' "$R/var/lib/kit/active" && grep -q 'org.ribbon.base' "$R/var/lib/kit/active" && ok "the root's installed set holds what was asked for and what it needs" || bad "active: $(cat "$R/var/lib/kit/active")"

# ---- the boot: the initramfs hook on this root, with the real losetup and mount ----------------------------------
loops_before=$(losetup -a | wc -l)
NEWROOT=$R RIBBON_RUN=$T/run RIBBON_KMSG=$T/kmsg sh srcpkgs/ribbon-kit/files/dracut/90ribbon-usrview/ribbon-usrview.sh
[ "$(cat "$T/run/usr-view" 2>/dev/null)" = "$n" ] && grep -q " $R/usr erofs ro" /proc/mounts && ok "the boot hook mounts the view as the root's /usr (it says: $(sed 's/^<5>//' "$T/kmsg" | tail -1))" || bad "the hook: $(cat "$T/run/usr-view" "$T/kmsg" 2>&1)"
mkdir "$T/want"
for p in $(sed 1d "$V/view-$n.erofs.devices" | cut -f6 | sed 's/^org\.ribbon\.//'); do
	t=$T/k/trees/ribbon-$p; [ -d "$t" ] || t=$T/k/trees/$p
	cp -a "$t/." "$T/want/"
done
if diff -r --no-dereference "$T/want" "$R/usr" >"$T/diff" 2>&1 && [ "$(find "$R/usr" | wc -l)" -gt 300 ]; then ok "/usr at boot is the kits' files, every one equal ($(find "$R/usr" ! -type d | wc -l) files)"
else bad "/usr differs: $(head -5 "$T/diff")"; fi
[ -x "$R/bin/ribbon-session" ] && [ -f "$R/lib/ribbon/common.sh" ] && ok "through the skeleton's links the system's paths resolve (/bin/ribbon-session, /lib/ribbon/common.sh)" || bad "links do not resolve"
umount "$R/usr"
[ "$(losetup -a | wc -l)" = "$loops_before" ] && ok "unmounted, no loop device is left" || bad "loop devices left: $(losetup -a)"

# ---- refusals -------------------------------------------------------------------------------------------------------
if sh build/kits/kit-rootfs.sh "$R" ribbon-base >"$T/log" 2>&1; then bad "a root that is not empty was written into"; else ok "a directory that is not empty is refused"; fi
if tclsh8.6 srcpkgs/ribbon-kit/files/bin/kitd --root / list >"$T/log" 2>&1; then bad "kitd --root / ran"; else ok "kitd --root refuses / (the running system is changed through the bus)"; fi
if sh build/kits/kit-rootfs.sh "$T/root2" no-such-kit >"$T/log" 2>&1 || grep -q " $T/root2/usr " /proc/mounts; then bad "a kit that does not exist: $(cat "$T/log")"; else ok "a kit the repository does not have fails the build, nothing left mounted"; fi
exit $fail
