#!/bin/sh
# kit-image.sh - a system made of kits and nothing else, made bootable and booted in QEMU (docs/RECIPES.md, "An image
# from kits"). Nothing of the host goes into it: the root is kitd's (kit-rootfs.sh), its /usr is the merged view of the
# kits, its initramfs is built inside it by the kits' own dracut with Ribbon's module that mounts the view
# (90ribbon-usrview), and the filesystem is made by the kits' own mke2fs.
#
#   build/kits/kit-image.sh OUT DIR      (root) from the kits kit-set.sh built in OUT: DIR/root.ext4, DIR/vmlinuz,
#                                        DIR/initramfs.img
#   build/kits/kit-image.sh boot DIR     boot it in QEMU: DIR/serial.log, DIR/result.txt (one line per check, then
#                                        "RESULT kit-image: ok (N checks)" or "FAILED (...)"); exit 0 only when ok
#
# This is a TEST image: the kits are signed here with the test keys (tests/fixtures/kittrust, or KIT_IMAGE_KEYS: a
# directory with test-root, test-system and test-index .key/.pub), which no machine trusts, and its services are this
# script's own three (mount what is missing, udevd, a probe that reports on the serial console and powers off):
# Ribbon's own services come with Ribbon's own kits, whose needs are not all kits yet. It shows that the kits make a
# system that boots: kernel, initramfs, the view mounted before the switch to the real root, dinit as PID 1, udev,
# accounts, a clean shutdown.
# KIT_IMAGE_KITS names the kits to install (short names; what they need comes with them). Environment otherwise as
# kit-rootfs.sh's and kitd's (KITFMT_MK4TCL, TCLLIBPATH for Mk4tcl; KIT_EROFS_MIN). BOOT_SECONDS bounds the boot (600).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
die() { echo "kit-image: $*" >&2; exit 1; }
KITS=${KIT_IMAGE_KITS:-kernel base-files glibc bash coreutils util-linux kmod eudev dinit shadow procps-ng iproute2 e2fsprogs btrfs-progs dosfstools dracut cpio erofs-utils less sed grep gawk findutils diffutils tar gzip xz bzip2 zstd file which tzdata iana-etc linux-pam sudo dbus ca-certificates openssl kbd dash}

boot() {
	d=$1
	for f in root.ext4 vmlinuz initramfs.img; do [ -f "$d/$f" ] || die "no $d/$f (kit-image.sh OUT DIR makes it)"; done
	command -v qemu-system-x86_64 >/dev/null 2>&1 || die "no qemu-system-x86_64"
	kvm=; [ -w /dev/kvm ] && kvm="-enable-kvm -cpu host"
	# a copy: the boot writes to its root
	cp --reflink=auto "$d/root.ext4" "$d/boot.ext4"
	# shellcheck disable=SC2086
	timeout "${BOOT_SECONDS:-600}" qemu-system-x86_64 $kvm -m 2048 -smp 2 -nographic -no-reboot \
		-kernel "$d/vmlinuz" -initrd "$d/initramfs.img" -drive "file=$d/boot.ext4,if=virtio,format=raw" \
		-append "root=/dev/vda rw init=/usr/bin/dinit console=ttyS0 panic=-1 loglevel=4 rd.shell=0 rd.emergency=halt" \
		> "$d/serial.log" 2>&1 || :
	rm -f "$d/boot.ext4"
	tr -d '\r' < "$d/serial.log" | sed -n 's/^.*\(KITIMG .*\)$/\1/p' > "$d/result.txt"
	fails=$(grep -c '^KITIMG FAIL' "$d/result.txt" || :); oks=$(grep -c '^KITIMG ok' "$d/result.txt" || :)
	if ! grep -q '^KITIMG done' "$d/result.txt"; then v="FAILED (the probe did not finish: see $d/serial.log)"
	elif [ "$fails" != 0 ]; then v="FAILED ($(sed -n 's/^KITIMG FAIL //p' "$d/result.txt" | tr '\n' ';'))"
	elif ! grep -aq 'reboot: Power down' "$d/serial.log"; then v="FAILED (the system did not power itself off)"
	else v="ok ($oks checks)"; fi
	echo "RESULT kit-image: $v" | tee -a "$d/result.txt"
	case $v in ok*) return 0 ;; *) return 1 ;; esac
}

if [ "${1:-}" = boot ]; then [ $# -eq 2 ] || die "usage: kit-image.sh boot DIR"; boot "$(cd "$2" && pwd)"; exit $?; fi
[ $# -eq 2 ] || die "usage: kit-image.sh OUT DIR | kit-image.sh boot DIR"
[ "$(id -u)" = 0 ] || die "root makes an image (loop devices, mounts, chroot)"
OUT=$(cd "$1" 2>/dev/null && pwd) || die "no directory $1"
[ -f "$OUT/kits.txt" ] || die "$OUT holds no built set (kit-set.sh writes kits.txt)"
mkdir -p "$2"; D=$(cd "$2" && pwd)
W=$D/work; R=$W/root
KEYS=${KIT_IMAGE_KEYS:-$ROOT/tests/fixtures/kittrust}
KT=$ROOT/kit/kittrust
TCLSH=$(command -v tclsh || command -v tclsh8.6) || die "no tclsh"
unmount() {
	for m in "$R/dev" "$R/sys" "$R/proc" "$R/usr" "$R/usr"; do
		if mountpoint -q "$m" 2>/dev/null; then umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || :; fi
	done
}
unmount; rm -rf "$W"; mkdir -p "$W/kits" "$W/keys"
trap unmount EXIT INT TERM

# a program of the kits, run from their trees with their own loader and libraries (nothing of the host's)
LP=$(for t in "$OUT"/trees/*/lib; do printf '%s:' "$t"; done)
kitrun() { _t=$1 _p=$2; shift 2; "$OUT/trees/glibc/lib/ld-linux-x86-64.so.2" --library-path "$LP" "$OUT/trees/$_t/bin/$_p" "$@"; }
[ -x "$OUT/trees/erofs-utils/bin/mkfs.erofs" ] && [ -x "$OUT/trees/e2fsprogs/bin/mke2fs" ] || die "$OUT has no erofs-utils or e2fsprogs kit"

# ---- the repository: the set's kits, signed with the test keys, and their index ---------------------------------------
echo "kit-image: signing $(ls "$OUT"/kits/*.kit | wc -l) kits with the TEST keys and publishing them"
cp --reflink=auto "$OUT"/kits/*.kit "$W/kits/"
L=$W/keys/trusted-keys
{ "$TCLSH" "$KT/kitkey" init -repository org.ribbon.test -root "$KEYS/test-root.pub" "$L" &&
  "$TCLSH" "$KT/kitkey" add -role system -from -30d "$L" "$KEYS/test-system.pub" &&
  "$TCLSH" "$KT/kitkey" add -role index -from -30d "$L" "$KEYS/test-index.pub" &&
  "$TCLSH" "$KT/kitkey" sign -key "$KEYS/test-root.key" "$L" &&
  "$TCLSH" "$KT/kitseal" -key "$KEYS/test-system.key" -keys "$L" "$W"/kits/*.kit &&
  "$TCLSH" "$KT/kitindex" build -key "$KEYS/test-index.key" -keys "$L" "$W/kits" "$W/repo"; } > "$W/publish.log" 2>&1 ||
	{ tail -n 20 "$W/publish.log" >&2; die "the kits could not be signed and published"; }
printf 'keys = %s\nmirror = file://%s\ntimeout = 5\n' "$L" "$W/repo" > "$W/kit.conf"

# ---- the root: kitd installs the kits; the view is built with the kits' own mkfs.erofs --------------------------------
printf '#!/bin/sh\nexec "%s" --library-path "%s" "%s" "$@"\n' "$OUT/trees/glibc/lib/ld-linux-x86-64.so.2" "$LP" \
	"$OUT/trees/erofs-utils/bin/mkfs.erofs" > "$W/mkfs.erofs"
chmod 755 "$W/mkfs.erofs"
cc -O2 -o "$W/kit-swapmount" "$ROOT/srcpkgs/mkkitfs/files/src/swapmount.c" || die "kit-swapmount does not build"
# shellcheck disable=SC2086
KIT_CONF=$W/kit.conf KIT_MKFS_EROFS=$W/mkfs.erofs KIT_SWAPMOUNT=$W/kit-swapmount KIT_NOSYNC=1 \
	sh "$ROOT/build/kits/kit-rootfs.sh" "$R" $KITS > "$W/rootfs.log" 2>&1 || { tail -n 20 "$W/rootfs.log" >&2; die "the root was not made"; }
tail -n 1 "$W/rootfs.log"
KV=$(basename "$(ls -d "$OUT"/trees/kernel/lib/modules/*/ | head -n1)")
[ -f "$OUT/trees/kernel/lib/modules/$KV/vmlinuz" ] || die "the kernel kit holds no vmlinuz"

# ---- this image's own services (see the head of this file) ------------------------------------------------------------
mkdir -p "$R/etc/dinit.d" "$R/etc/kit-image"
echo ribbon-kits > "$R/etc/hostname"
printf 'type = internal\nwaits-for = kits-probe\n' > "$R/etc/dinit.d/boot"
printf 'type = scripted\ncommand = /etc/kit-image/early.sh\nrestart = false\n' > "$R/etc/dinit.d/kits-early"
printf 'type = process\ncommand = /usr/bin/udevd\ndepends-on = kits-early\n' > "$R/etc/dinit.d/kits-udevd"
printf 'type = scripted\ncommand = /etc/kit-image/probe.sh\ndepends-on = kits-udevd\nrestart = false\n' > "$R/etc/dinit.d/kits-probe"
cat > "$R/etc/kit-image/early.sh" <<'EOF'
#!/bin/sh
# what the initramfs did not hand over, and a writable root
PATH=/usr/bin; export PATH
mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys || mount -t sysfs sys /sys
mountpoint -q /dev || mount -t devtmpfs dev /dev
mountpoint -q /run || mount -t tmpfs -o mode=755 run /run
mkdir -p /dev/pts /dev/shm
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts
mount -o remount,rw /
hostname "$(cat /etc/hostname)"
exit 0
EOF
cat > "$R/etc/kit-image/probe.sh" <<'EOF'
#!/bin/sh
# the image's report, on the console: one line per check
PATH=/usr/bin; export PATH
exec > /dev/console 2>&1
ok() { echo "KITIMG ok $*"; }
bad() { echo "KITIMG FAIL $*"; }
chk() { _w=$1; shift; if "$@" >/dev/null 2>&1; then ok "$_w"; else bad "$_w"; fi; }
k=$(uname -r)
case $k in *-ribbon_*) ok "the kernel is Ribbon's ($k)" ;; *) bad "the kernel is $k" ;; esac
[ "$(cat /proc/1/comm)" = dinit ] && ok "PID 1 is dinit" || bad "PID 1 is $(cat /proc/1/comm)"
grep -q ' /usr erofs ro' /proc/mounts && ok "/usr is the kits' view, mounted read-only by the initramfs (view $(cat /run/ribbon/usr-view 2>/dev/null))" ||
	bad "/usr is not an erofs view: $(grep ' /usr ' /proc/mounts) $(cat /run/ribbon/usr-view 2>/dev/null)"
n=$(sed 1d "/var/lib/kit/system/usr/view-$(cat /var/lib/kit/system/usr/current).erofs.devices" | wc -l)
[ "$n" -ge 20 ] && ok "the view is made of $n kits" || bad "the view has $n kits"
touch /usr/kit-image-test 2>/dev/null && bad "/usr can be written" || ok "/usr cannot be written"
touch /var/kit-image-test 2>/dev/null && ok "the root is writable" || bad "the root is read-only"
[ "$(id -un)" = root ] && [ "$(id -u nobody)" = 99 ] && ok "the accounts are base-files' (root, nobody)" || bad "accounts: $(id 2>&1)"
grep -q '^NAME="Ribbon OS"' /etc/os-release && ok "os-release says Ribbon OS" || bad "os-release: $(head -n1 /etc/os-release 2>&1)"
udevadm trigger --action=add; udevadm settle --timeout=30
chk "udevd is running here (not the initramfs's) and answers udevadm" sh -c 'pgrep -x udevd >/dev/null && udevadm control --reload'
[ -b /dev/vda ] && [ -e /dev/disk/by-uuid ] && ok "udev named the disk (/dev/disk/by-uuid)" || bad "no /dev/disk/by-uuid"
lsmod | grep -q '^erofs ' && lsmod | grep -q '^virtio_blk ' && ok "the kernel's modules load from the view (erofs, virtio_blk and $(($(lsmod | wc -l) - 3)) more)" || bad "modules: $(lsmod | head -5)"
chk "modprobe loads another module from the view (btrfs)" modprobe btrfs
su -s /usr/bin/sh nobody -c 'test "$(id -un)" = nobody' && ok "su changes to another account (setuid, libxcrypt)" || bad "su nobody failed"
e=$(useradd -m probe-user 2>&1) && [ -d /home/probe-user ] && [ -z "$e" ] && ok "useradd makes an account and its home, and says nothing" || bad "useradd: $e"
echo 'probe-user:kits-image' | chpasswd 2>/dev/null && grep -q '^probe-user:\$y\$' /etc/shadow && ok "a password is set and hashed with yescrypt" || bad "chpasswd: $(grep '^probe-user:' /etc/shadow | cut -c1-20)"
ip link set lo up 2>/dev/null && ip -o addr show lo | grep -q '127.0.0.1' && ok "ip brings the loopback up" || bad "ip: $(ip -o addr show lo 2>&1)"
[ "$(TZ=Europe/Paris date -d @0 +%H)" = 01 ] && ok "time zones are tzdata's (Paris at the epoch: 01h)" || bad "tzdata: $(TZ=Europe/Paris date -d @0)"
grep -q '^ssh[[:space:]]*22/tcp' /etc/services && ok "/etc/services is iana-etc's" || bad "/etc/services"
truncate -s 64M /tmp/fs.img && mkfs.ext4 -q /tmp/fs.img && mkdir -p /mnt/t && mount -o loop /tmp/fs.img /mnt/t && echo x > /mnt/t/f && umount /mnt/t &&
	ok "an ext4 filesystem is made, mounted and written (mkfs.ext4, losetup)" || bad "ext4 on a loop device"
truncate -s 256M /tmp/b.img && mkfs.btrfs -q /tmp/b.img && mount -o loop /tmp/b.img /mnt/t && btrfs subvolume create /mnt/t/@x >/dev/null && umount /mnt/t &&
	ok "a btrfs filesystem is made and a subvolume created" || bad "btrfs on a loop device"
[ "$(dinitctl list | grep -c '^\[')" -ge 3 ] && ok "dinitctl talks to dinit ($(dinitctl list | grep -c '{+}\|\[{+}') services up)" || bad "dinitctl: $(dinitctl list 2>&1 | head -3)"
[ "$(ps -e | wc -l)" -gt 5 ] && [ "$(echo hello | gzip | xz | xz -d | gzip -d)" = hello ] && ok "ps, gzip and xz work" || bad "ps or the compressors"
# PAM: su and chpasswd above went through it; sudo asks it for the user's own password (the rule stands in for
# ribbon-base's file in /etc/sudoers.d), and a wrong one is refused
mkdir -p /etc/sudoers.d && usermod -aG wheel probe-user && echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel && chmod 440 /etc/sudoers.d/wheel
[ "$(echo kits-image | su -s /usr/bin/sh probe-user -c 'sudo -S -p "" id -u' 2>/dev/null)" = 0 ] &&
	ok "sudo runs a command as root after the user's own password (PAM, pam_unix)" || bad "sudo with the right password"
echo wrong | su -s /usr/bin/sh probe-user -c 'sudo -S -p "" -k id -u' >/dev/null 2>&1 && bad "sudo took a wrong password" ||
	ok "and refuses a wrong one"
su -s /usr/bin/sh nobody -c 'sudo -n true' >/dev/null 2>&1 && bad "sudo let nobody (outside wheel) through" ||
	ok "nobody, outside wheel, gets nothing from sudo"
# the system bus, as Ribbon's service will start it: as the dbus account, answering on its socket
mkdir -p /run/dbus && dbus-uuidgen --ensure=/etc/machine-id && dbus-daemon --system --fork >/dev/null 2>&1
sleep 1
dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | grep -q 'org.freedesktop.DBus' &&
	[ "$(ps -o user= -C dbus-daemon | head -n1)" = dbus ] && ok "the system bus runs as dbus and answers on /run/dbus/system_bus_socket" ||
	bad "system bus: $(ps -o user=,args= -C dbus-daemon 2>&1 | head -n2)"
n=$(openssl storeutl -noout -certs /etc/ssl/cert.pem 2>/dev/null | grep -c '^[0-9]*: Certificate')
[ "$n" -ge 100 ] && ok "openssl reads $n certificate authorities from /etc/ssl/cert.pem (ca-certificates)" || bad "the CA bundle: $n"
if loadkeys --parse de >/dev/null 2>&1 && [ -n "$(ls /usr/share/kbd/consolefonts 2>/dev/null)" ]; then
	ok "kbd reads its keymaps (de) and has its console fonts"; else bad "kbd: $(loadkeys --parse de 2>&1 | head -n2)"; fi
[ "$(dash -c 'echo $((6 * 7))')" = 42 ] && ok "dash runs" || bad "dash"
echo "KITIMG done"
# a clean shutdown through dinit, once this script has returned
(sleep 1; dinit-poweroff) &
exit 0
EOF
chmod 755 "$R/etc/kit-image/early.sh" "$R/etc/kit-image/probe.sh"

# ---- the initramfs: the kits' dracut, run in the root, with Ribbon's own module ---------------------------------------
# /usr as it will be at boot: the view, mounted by the real hook; then a writable layer over it for this step only,
# to hold Ribbon's dracut module (it comes with Ribbon's own kit, which this image does not have yet)
NEWROOT=$R RIBBON_RUN=$W/run RIBBON_KMSG=$W/kmsg sh "$ROOT/srcpkgs/ribbon-kit/files/dracut/90ribbon-usrview/ribbon-usrview.sh"
mountpoint -q "$R/usr" || die "the view did not mount: $(cat "$W/kmsg" 2>/dev/null | tail -n 2)"
files=$(find "$R/usr" ! -type d | wc -l)
mkdir -p "$W/up" "$W/wk"
mount -t overlay overlay -o "lowerdir=$R/usr,upperdir=$W/up,workdir=$W/wk" "$R/usr" || die "no overlay over the view"
mkdir -p "$R/usr/lib/dracut/modules.d/90ribbon-usrview"
cp "$ROOT"/srcpkgs/ribbon-kit/files/dracut/90ribbon-usrview/* "$R/usr/lib/dracut/modules.d/90ribbon-usrview/"
chmod 755 "$R"/usr/lib/dracut/modules.d/90ribbon-usrview/*.sh
for m in proc sys dev; do mount --bind "/$m" "$R/$m"; done
# DRACUT_NO_XATTR: dracut copies with cp --preserve=xattr, and the base set's cp has no xattr support yet (attr and acl
# are not in it); nothing in an initramfs needs extended attributes
chroot "$R" /usr/bin/env -i PATH=/usr/bin DRACUT_NO_XATTR=1 /usr/bin/dracut --force --no-hostonly --kver "$KV" --add ribbon-usrview \
	--add-drivers "virtio_blk virtio_pci virtio_scsi ext4 btrfs" --no-hostonly-cmdline "/boot/initramfs-$KV.img" \
	> "$W/dracut.log" 2>&1 || { tail -n 30 "$W/dracut.log" >&2; die "dracut did not build the initramfs"; }
chroot "$R" /usr/bin/env -i PATH=/usr/bin /usr/bin/lsinitrd "/boot/initramfs-$KV.img" > "$W/lsinitrd.txt" 2>&1 || :
grep -q 'ribbon-usrview.sh' "$W/lsinitrd.txt" || die "the initramfs has no ribbon-usrview hook (see $W/dracut.log)"
grep -q 'erofs\.ko' "$W/lsinitrd.txt" || die "the initramfs has no erofs module"
cp "$R/boot/initramfs-$KV.img" "$D/initramfs.img"
cp "$OUT/trees/kernel/lib/modules/$KV/vmlinuz" "$D/vmlinuz"
unmount
[ -z "$(ls -A "$R/usr")" ] || die "$R/usr is not empty after unmounting"

# ---- the filesystem, made by the kits' own mke2fs ---------------------------------------------------------------------
kb=$(du -sk "$R" | cut -f1)
kitrun e2fsprogs mke2fs -q -t ext4 -L ribbon-kits -d "$R" "$D/root.ext4" "$((kb + kb / 3 + 262144))k" || die "mke2fs failed"
rm -rf "$W/kits" "$W/repo" "$W/up" "$W/wk" "$R"
echo "kit-image: $D: root.ext4 ($(du -h "$D/root.ext4" | cut -f1); $files files in /usr from the kits), vmlinuz $KV, initramfs.img ($(du -h "$D/initramfs.img" | cut -f1))"
