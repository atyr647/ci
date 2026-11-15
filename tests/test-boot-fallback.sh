#!/bin/bash
# The boot try counter and snapshot fallback (docs/SYSTEM-UPDATES.md 5.5, 7.8):
#   1. the initramfs hook (dracut 90ribbon-snapshot) on a fake root, a fake EFI
#      partition and a fake btrfs/bcachefs disk, with stand-ins for mount and
#      umount that move, copy and link directories as the real mounts would:
#      tries counted down, the snapshot started when they run out (btrfs and
#      bcachefs), the menu's snapshot entries, refusals that leave the normal
#      system booting;
#   2. ribbon-snapshot arm / pre / mark-good / retry / list with stand-ins for
#      snapper and findmnt;
#   3. ribbon-snapshot boot-watch (the ribbon-boot-ok service) on fake elogind
#      session files: good only once the greeter or the shell has been up for
#      a while, a restart when an armed boot gets nowhere, the watchdog pinged
#      and closed, nothing armed on a fallback boot;
#   4. the dinit service: it starts with the filesystems, not after loginready.
# Runs as any user; changes nothing outside its own temporary directory.
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
HOOK=$ROOT/srcpkgs/ribbon-tools/files/dracut/90ribbon-snapshot/ribbon-snapshot-overlay.sh
TOOL=$ROOT/srcpkgs/ribbon-tools/files/bin/ribbon-snapshot
LIB=$ROOT/srcpkgs/ribbon-tools/files/lib
SVC=$ROOT/srcpkgs/ribbon-tools/files/services/ribbon-boot-ok
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

T=$(mktemp -d)
trap '[ -n "${KEEP_TMP:-}" ] || rm -rf "$T"' EXIT
B=$T/bin
mkdir -p "$B" "$T/dev"

# --- stand-ins -------------------------------------------------------------
cat > "$B/mount" <<'EOF'
#!/bin/sh
echo "mount $*" >> "$T/mounts.log"
case " $* " in *" ${MOUNT_FAIL:-@none@}"*) exit 32 ;; esac
mv_all() { mkdir -p "$2"; for e in "$1"/* "$1"/.[!.]*; do [ -e "$e" ] && mv "$e" "$2/"; done; return 0; }
case "$1" in
	--move) mv_all "$2" "$3"; exit 0 ;;
	--bind) exit 0 ;;
esac
type=$2 opts=$4 src=$5 dst=$6
case "$type" in
	vfat) rmdir "$dst" 2>/dev/null; ln -s "$src" "$dst" ;;
	btrfs) sub=${opts##*subvol=}; [ -d "$FAKEDISK/$sub" ] || exit 32; cp -a "$FAKEDISK/$sub/." "$dst/" ;;
	overlay) low=${opts#lowerdir=}; low=${low%%,*}; mkdir -p "$dst"; cp -a "$low/." "$dst/" ;;
esac
exit 0
EOF
cat > "$B/umount" <<'EOF'
#!/bin/sh
echo "umount $*" >> "$T/mounts.log"
[ -L "$1" ] && rm "$1"
exit 0
EOF
cat > "$B/findmnt" <<'EOF'
#!/bin/sh
case "$*" in
	*" FSTYPE "*/boot/efi) echo "${FSTYPE_EFI:-}" ;;
	*" FSTYPE "*/boot) echo "${FSTYPE_BOOT:-}" ;;
	*) echo "${FSTYPE:-btrfs}" ;;
esac
EOF
cat > "$B/snapper" <<'EOF'
#!/bin/sh
echo "snapper $*" >> "$T/snapper.log"
case " $* " in
	*" create "*) echo "${SNAP_NEW:-42}" ;;
	*" list "*) printf 'number\n0\n40\n41\n' ;;
esac
EOF
cat > "$B/id" <<'EOF'
#!/bin/sh
echo 0
EOF
# pgrep: $T/pgrep.mode is yes, no, or flap (up and down on alternate calls)
cat > "$B/pgrep" <<'EOF'
#!/bin/sh
echo "pgrep $*" >> "$T/pgrep.log"
case "$(cat "$T/pgrep.mode" 2>/dev/null)" in
	yes) exit 0 ;;
	flap) n=$(cat "$T/pgrep.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$T/pgrep.n"; [ $((n % 2)) -eq 0 ] ;;
	*) exit 1 ;;
esac
EOF
cat > "$B/reboot" <<'EOF'
#!/bin/sh
echo reboot >> "$T/reboot.log"
EOF
chmod +x "$B"/*
export T

# --- 1. the initramfs hook ----------------------------------------------------
KV=6.18.2_1
# a fresh normal root (what dracut mounted at $NEWROOT), EFI partition and disk
fresh() { # fstype
	rm -rf "$T/sysroot" "$T/run" "$T/ov" "$T/esp-mnt" "$T/disk"
	mkdir -p "$T/sysroot/etc" "$T/sysroot/usr/lib/modules/$KV" "$T/sysroot/home/adam" "$T/esp/ribbon"
	echo new > "$T/sysroot/etc/os-release"
	echo mine > "$T/sysroot/home/adam/notes.txt"
	ln -sfn "$T/esp" "$T/dev/esp"; : > "$T/dev/root"
	if [ "$1" = btrfs ]; then
		cat > "$T/sysroot/etc/fstab" <<EOF
# written by ribbon-install
UUID=root / btrfs rw,noatime,subvol=@ 0 0
UUID=root /.snapshots btrfs rw,noatime,subvol=@snapshots 0 0
UUID=root /home btrfs rw,noatime,subvol=@home 0 0
UUID=esp /boot vfat rw,noatime 0 2
EOF
		mkdir -p "$T/disk/@snapshots/41/snapshot/etc" "$T/disk/@snapshots/41/snapshot/usr/lib/modules/6.17.9_1"
		echo old > "$T/disk/@snapshots/41/snapshot/etc/os-release"
	else
		cat > "$T/sysroot/etc/fstab" <<EOF
UUID=root / bcachefs noatime 0 0
UUID=esp /boot vfat rw,noatime 0 2
EOF
		mkdir -p "$T/sysroot/.snapshots/20261101-120000/etc" "$T/sysroot/.snapshots/20261101-120000/usr/lib/modules/$KV"
		echo old > "$T/sysroot/.snapshots/20261101-120000/etc/os-release"
	fi
	echo "$T/dev/root $T/sysroot $1 rw 0 0" > "$T/mounts"
}
counter() { printf 'tries=%s\nsnapshot=%s\nstate=%s\n' "$1" "$2" "$3" > "$T/esp/ribbon/trying"; }
cget() { sed -n "s/^$1=//p" "$T/esp/ribbon/trying"; }
boot() { # kernel command line
	: > "$T/mounts.log"; : > "$T/kmsg"
	CMDLINE="$*" NEWROOT=$T/sysroot RIBBON_RUN=$T/run RIBBON_OVERLAY=$T/ov RIBBON_ESP_MNT=$T/esp-mnt \
		RIBBON_KMSG=$T/kmsg RIBBON_MOUNTS=$T/mounts RIBBON_KVER=$KV RIBBON_DEV_ANY=1 FAKEDISK=$T/disk \
		PATH="$B:$PATH" ${HOOK_SH:-sh} -c '
		getarg() { for w in $CMDLINE; do case $w in "$1"*) echo "${w#"$1"}"; return 0 ;; esac; done; return 1; }
		label_uuid_to_dev() { echo "$T/dev/${1#*=}"; }
		. "$0"' "$HOOK"
}
logged() { grep -qxF -- "$1" "$T/mounts.log"; }
said() { grep -qF -- "$1" "$T/kmsg"; }
osrel() { cat "$T/sysroot/etc/os-release" 2>/dev/null; }
NORMAL="root=UUID=root rootfstype=btrfs rootflags=subvol=@ rw quiet"

echo "initramfs hook (90ribbon-snapshot), btrfs"
fresh btrfs; rm -f "$T/esp/ribbon/trying"
boot "$NORMAL"
check "no counter: the EFI partition is looked at and let go" sh -c "grep -q '^mount -t vfat -o rw,noatime $T/dev/esp $T/esp-mnt\$' '$T/mounts.log' && grep -q '^umount $T/esp-mnt' '$T/mounts.log'"
check "no counter: the normal system boots, no overlay" sh -c "[ \"\$(cat '$T/sysroot/etc/os-release')\" = new ] && ! grep -q -- '-t overlay' '$T/mounts.log' && [ ! -e '$T/run/snapshot-boot' ]"

fresh btrfs; counter 3 41 trying
boot "$NORMAL"
check "armed: one try taken (3 -> 2)" test "$(cget tries)/$(cget state)/$(cget snapshot)" = "2/trying/41"
check "armed: the try is recorded in /run/ribbon/boot-try" test "$(cat "$T/run/boot-try" 2>/dev/null)" = 2
check "armed: said so in the kernel log" said "ribbon-boot: trying the updated system (2 tries left after this one)"
check "armed: still the normal system" test "$(osrel)" = new
boot "$NORMAL"; boot "$NORMAL"
check "three boots use up the three tries" test "$(cget tries)/$(cget state)" = "0/trying"
check "the third try still boots the updated system" test "$(osrel)" = new

fresh btrfs; counter 0 41 trying
boot "$NORMAL"
check "tries used up: the counter says fallback" test "$(cget tries)/$(cget state)/$(cget snapshot)" = "0/fallback/41"
check "tries used up: snapshot 41 mounted read-only from @snapshots (fstab's subvol)" logged "mount -t btrfs -o ro,subvol=@snapshots/41/snapshot $T/dev/root $T/ov/lower"
check "tries used up: an overlay on the snapshot is the root" sh -c "grep -q '^mount -t overlay -o lowerdir=$T/ov/lower,upperdir=$T/ov/upper,workdir=$T/ov/work overlay $T/sysroot\$' '$T/mounts.log' && [ \"\$(cat '$T/sysroot/etc/os-release')\" = old ]"
check "tries used up: the running kernel's modules from the updated root (the snapshot has 6.17 only)" logged "mount --bind $T/ov/cur/usr/lib/modules/$KV $T/sysroot/usr/lib/modules/$KV"
check "tries used up: /run/ribbon/snapshot-boot says fallback, snapshot 41" sh -c "grep -qx mode=fallback '$T/run/snapshot-boot' && grep -qx snapshot=41 '$T/run/snapshot-boot'"
check "tries used up: said so in the kernel log" said "starting snapshot 41"
fresh btrfs; counter 0 41 fallback
boot "$NORMAL"
check "a later boot falls back again (until rollback or retry)" sh -c "[ \"\$(cat '$T/sysroot/etc/os-release')\" = old ] && grep -qx state=fallback '$T/esp/ribbon/trying'"
fresh btrfs; counter 0 41 fallback
boot "$NORMAL ribbon.fallback=0"
check "ribbon.fallback=0 skips the counter for one boot" sh -c "[ \"\$(cat '$T/sysroot/etc/os-release')\" = new ] && ! grep -q vfat '$T/mounts.log'"
fresh btrfs; counter 0 77 trying
boot "$NORMAL"
check "a snapshot that is gone: the normal system boots, nothing half-mounted" sh -c "[ \"\$(cat '$T/sysroot/etc/os-release')\" = new ] && [ -e '$T/sysroot/home/adam/notes.txt' ] && ! grep -q -- '-t overlay' '$T/mounts.log' && [ ! -e '$T/run/snapshot-boot' ]"
check "a snapshot that is gone: said so" said "snapshot 77 could not be mounted"
fresh btrfs; counter 0 41 trying
MOUNT_FAIL="-t overlay" boot "$NORMAL"
check "the overlay fails: the normal system is put back" sh -c "[ \"\$(cat '$T/sysroot/etc/os-release')\" = new ] && grep -q '^umount $T/ov/lower' '$T/mounts.log' && [ ! -e '$T/run/snapshot-boot' ]"
fresh btrfs; counter 0 '../x' trying
boot "$NORMAL"
check "a snapshot name with a path in it is refused" sh -c "[ \"\$(cat '$T/sysroot/etc/os-release')\" = new ] && ! grep -q 'btrfs -o' '$T/mounts.log'"
fresh btrfs; printf 'tries=$(reboot)\nsnapshot=41\nstate=trying\n' > "$T/esp/ribbon/trying"
boot "$NORMAL"
check "a counter that isn't a number counts as used up (never run)" sh -c "grep -qx state=fallback '$T/esp/ribbon/trying' && [ ! -e '$T/reboot.log' ]"

fresh btrfs; counter 2 41 trying
mkdir -p "$T/disk/@snapshots/6/snapshot/etc"; echo six > "$T/disk/@snapshots/6/snapshot/etc/os-release"
# the menu's snapshot entry: dracut has already mounted the snapshot as the root
cp -a "$T/disk/@snapshots/6/snapshot/." "$T/sysroot/"
boot "root=UUID=root rootfstype=btrfs rootflags=subvol=@snapshots/6/snapshot ro"
check "menu entry (rootflags=subvol=@snapshots/6/snapshot): the overlay goes on it" sh -c "grep -q '^mount --move $T/sysroot $T/ov/lower' '$T/mounts.log' && grep -qx mode=menu '$T/run/snapshot-boot' && [ \"\$(cat '$T/sysroot/etc/os-release')\" = six ]"
check "menu entry: no try is taken" test "$(cget tries)" = 2

# GRUB's layout (ribbon-install, answers.tcl): the EFI partition at /boot/efi, /boot on the root
fresh btrfs; counter 0 41 trying
sed -i 's| /boot vfat | /boot/efi vfat |' "$T/sysroot/etc/fstab"
boot "$NORMAL"
check "EFI partition at /boot/efi (GRUB): the counter there is read, the snapshot starts" sh -c "grep -qx state=fallback '$T/esp/ribbon/trying' && [ \"\$(cat '$T/sysroot/etc/os-release')\" = old ]"
fresh btrfs; counter 2 41 trying
sed -i 's|^UUID=esp /boot vfat .*|UUID=boot /boot ext4 rw 0 2|' "$T/sysroot/etc/fstab"; : > "$T/dev/boot"
boot "$NORMAL"
check "a /boot that is not FAT is not mounted as the EFI partition" sh -c "! grep -q vfat '$T/mounts.log' && [ ! -e '$T/run/boot-try' ]"

# Only what a host-only initramfs holds: dracut's base module (80base install(): inst_multiple) plus
# what module-setup.sh installs; no tail, cat or head.
IB=$T/ibin; rm -rf "$IB"; mkdir -p "$IB"
mods=$(sed -n '/^install()/,/^}/s/^[[:space:]]*inst_multiple \(.*\)$/\1/p' "$ROOT/srcpkgs/ribbon-tools/files/dracut/90ribbon-snapshot/module-setup.sh")
for c in cp dmesg flock ln ls mkdir mkfifo mknod modprobe mv readlink rm rmmod sed setsid sleep tr chown findmnt kmod less sysctl $mods; do
	p=$(command -v "$c") && ln -sf "$p" "$IB/$c"
done
for c in mount umount; do printf '#!/bin/sh\nPATH=%s exec %s "$@"\n' "$B:$PATH" "$B/$c" > "$IB/$c"; chmod +x "$IB/$c"; done
KVH=$(uname -r)
iboot() {
	: > "$T/mounts.log"; : > "$T/kmsg"
	CMDLINE="$*" NEWROOT=$T/sysroot RIBBON_RUN=$T/run RIBBON_OVERLAY=$T/ov RIBBON_ESP_MNT=$T/esp-mnt \
		RIBBON_KMSG=$T/kmsg RIBBON_MOUNTS=$T/mounts RIBBON_DEV_ANY=1 FAKEDISK=$T/disk \
		PATH="$IB" /bin/sh -c '
		getarg() { for w in $CMDLINE; do case $w in "$1"*) echo "${w#"$1"}"; return 0 ;; esac; done; return 1; }
		label_uuid_to_dev() { echo "$T/dev/${1#*=}"; }
		. "$0"' "$HOOK" 2> "$T/hook.err"
}
fresh btrfs; counter 3 41 trying
iboot "$NORMAL"
check "host-only initramfs tools only: a try is taken (3 -> 2), the updated system boots" sh -c "[ \"\$(sed -n 's/^tries=//p' '$T/esp/ribbon/trying')/\$(sed -n 's/^state=//p' '$T/esp/ribbon/trying')\" = 2/trying ] && [ \"\$(cat '$T/sysroot/etc/os-release')\" = new ]"
fresh btrfs; counter 0 41 trying; mkdir -p "$T/sysroot/usr/lib/modules/$KVH"
iboot "$NORMAL"
check "host-only initramfs tools only: the running kernel's modules are bound into the snapshot" logged "mount --bind $T/ov/cur/usr/lib/modules/$KVH $T/sysroot/usr/lib/modules/$KVH"

echo "initramfs hook (90ribbon-snapshot), bcachefs"
fresh bcachefs; counter 0 20261101-120000 trying
boot "root=UUID=root rootfstype=bcachefs rw"
check "tries used up: the snapshot under /.snapshots is the overlay's lower layer" sh -c "grep -q '^mount -t overlay -o lowerdir=$T/ov/cur/.snapshots/20261101-120000,upperdir=' '$T/mounts.log' && [ \"\$(cat '$T/sysroot/etc/os-release')\" = old ]"
check "bcachefs: the live /home is bound over the snapshot's (nothing saved is lost)" logged "mount --bind $T/ov/cur/home $T/sysroot/home"
check "bcachefs: the live /.snapshots too" logged "mount --bind $T/ov/cur/.snapshots $T/sysroot/.snapshots"
check "bcachefs: no modules bound when the snapshot has the running kernel's" sh -c "! grep -q 'usr/lib/modules' '$T/mounts.log'"
fresh bcachefs; rm -f "$T/esp/ribbon/trying"
boot "root=UUID=root rootfstype=bcachefs rw ribbon.snapshot=20261101-120000"
check "menu entry ribbon.snapshot=<name>: boots that snapshot" sh -c "grep -qx mode=snapshot '$T/run/snapshot-boot' && [ \"\$(cat '$T/sysroot/etc/os-release')\" = old ] && ! grep -q vfat '$T/mounts.log'"
fresh bcachefs
boot "root=UUID=root rootfstype=bcachefs rw ribbon.snapshot=nope"
check "ribbon.snapshot= naming nothing: the normal system boots" sh -c "[ \"\$(cat '$T/sysroot/etc/os-release')\" = new ] && [ ! -e '$T/run/snapshot-boot' ]"

# --- 2. ribbon-snapshot: arm, pre, mark-good, retry, list --------------------------
R=$T/root
mkdir -p "$R/etc/default" "$R/etc/ribbon" "$T/boot"
echo 'BOOTLOADER=none' > "$R/etc/default/ribbon-boot"
snap() {
	PATH="$B:$PATH" RIBBON_LIB=$LIB RIBBON_ROOT=$R RIBBON_STATE=$T/state RIBBON_BOOT=$T/boot \
		RIBBON_RUN=$T/run RIBBON_KMSG=$T/kmsg bash "$TOOL" "$@"
}
tget() { sed -n "s/^$1=//p" "$T/boot/ribbon/trying"; }
echo "ribbon-snapshot arm / pre / mark-good / retry"
rm -rf "$T/run" "$T/boot/ribbon"
snap arm >/dev/null
check "arm: the newest snapper snapshot, 3 tries" test "$(tget tries)/$(tget snapshot)/$(tget state)" = "3/41/trying"
fresh btrfs; cp "$T/boot/ribbon/trying" "$T/esp/ribbon/trying"; boot "$NORMAL"
check "arm: the file is the one the initramfs reads (it takes a try from it)" test "$(cget tries)/$(cget snapshot)/$(cget state)" = "2/41/trying"
echo 'BOOT_TRIES=2' > "$R/etc/ribbon/ribbon.conf"
out=$(SNAP_NEW=43 snap pre "ribbon update 2026-11-15" 2>&1)
check "pre: takes the snapshot (snapper create) and prints its number" sh -c "grep -q 'create -t single -c number -d ribbon update 2026-11-15 -p' '$T/snapper.log' && printf '%s\n' \"\$1\" | grep -qx 43" - "$out"
check "pre: arms the fallback with that snapshot, BOOT_TRIES from ribbon.conf" test "$(tget tries)/$(tget snapshot)" = "2/43"
rm -f "$R/etc/ribbon/ribbon.conf"
check "list: shows the armed counter" sh -c "PATH='$B:$PATH' RIBBON_LIB='$LIB' RIBBON_ROOT='$R' RIBBON_STATE='$T/state' RIBBON_BOOT='$T/boot' bash '$TOOL' list | grep -qx 'Boot fallback: armed, 2 tries left before snapshot 43'"
mkdir -p "$T/run"; : > "$T/run/snapshot-boot"
snap mark-good
check "mark-good on a snapshot boot: the counter stays, last-good untouched" sh -c "[ -e '$T/boot/ribbon/trying' ] && [ ! -e '$T/state/last-good' ]"
rm -f "$T/run/snapshot-boot"
snap mark-good
check "mark-good: the counter is cleared, the newest snapshot is last-good" sh -c "[ ! -e '$T/boot/ribbon/trying' ] && [ \"\$(cat '$T/state/last-good')\" = 41 ]"
FSTYPE=ext4 snap arm >/dev/null 2>&1
check "arm on ext4: nothing armed (no snapshots to start)" test ! -e "$T/boot/ribbon/trying"
FSTYPE=bcachefs snap arm install >/dev/null
check "arm on bcachefs: names the snapshot" test "$(tget snapshot)/$(tget tries)" = "install/3"
snap arm '../../etc' >/dev/null 2>&1
check "arm refuses a snapshot name with a path in it (the counter keeps what it had)" test "$(tget snapshot)" = install
printf 'tries=0\nsnapshot=41\nstate=fallback\n' > "$T/boot/ribbon/trying"
check "list: a fallback in effect says how to keep it or try again" sh -c "PATH='$B:$PATH' RIBBON_LIB='$LIB' RIBBON_ROOT='$R' RIBBON_STATE='$T/state' RIBBON_BOOT='$T/boot' bash '$TOOL' list | grep -q 'booting snapshot 41 (keep it: sudo ribbon rollback 41; try again: sudo ribbon-snapshot retry)'"
snap retry >/dev/null
check "retry: the updated system gets its tries back" test "$(tget tries)/$(tget snapshot)/$(tget state)" = "3/41/trying"
rm -f "$T/boot/ribbon/trying"
# where the counter goes without RIBBON_BOOT: the FAT partition at /boot, else at /boot/efi (GRUB)
snapnb() { PATH="$B:$PATH" RIBBON_LIB=$LIB RIBBON_ROOT=$R RIBBON_STATE=$T/state RIBBON_RUN=$T/run bash "$TOOL" "$@"; }
rm -rf "${R:?}/boot"; mkdir -p "$R/boot/efi"
FSTYPE_BOOT=btrfs FSTYPE_EFI=vfat snapnb arm >/dev/null 2>&1
check "arm: EFI partition at /boot/efi (GRUB): the counter goes there, where the initramfs reads it" test -f "$R/boot/efi/ribbon/trying" -a ! -e "$R/boot/ribbon/trying"
rm -rf "${R:?}/boot"; mkdir -p "$R/boot/efi"
FSTYPE_BOOT=vfat FSTYPE_EFI=vfat snapnb arm >/dev/null 2>&1
check "arm: FAT at /boot (Limine): the counter goes there" test -f "$R/boot/ribbon/trying" -a ! -e "$R/boot/efi/ribbon/trying"
rm -rf "${R:?}/boot"; mkdir -p "$R/boot"
out=$(FSTYPE_BOOT=btrfs snapnb arm 2>&1)
check "arm: no FAT partition at /boot or /boot/efi: not armed, and says so" sh -c "[ -z \"\$(find '$R/boot' -name trying)\" ] && printf '%s' \"\$1\" | grep -q 'not armed'" - "$out"
rm -rf "${R:?}/boot"
check "retry with nothing in effect fails" sh -c "! PATH='$B:$PATH' RIBBON_LIB='$LIB' RIBBON_ROOT='$R' RIBBON_BOOT='$T/boot' bash '$TOOL' retry 2>/dev/null"

# --- 3. boot-watch ---------------------------------------------------------------
S=$T/sessions
session() { # id class uid [remote]
	mkdir -p "$S"
	printf 'UID=%s\nUSER=x\nACTIVE=1\nSTATE=active\nREMOTE=%s\nTYPE=wayland\nCLASS=%s\nSEAT=seat0\nLEADER=1\n' "$3" "${4:-0}" "$2" > "$S/$1"
}
watch() { # seconds limit; the rest as env
	rm -f "$T/reboot.log" "$T/pgrep.n"; : > "$T/kmsg"; : > "$T/pgrep.log"
	PATH="$B:$PATH" RIBBON_LIB=$LIB RIBBON_ROOT=$R RIBBON_STATE=$T/state RIBBON_BOOT=$T/boot RIBBON_RUN=$T/run \
		RIBBON_KMSG=$T/kmsg RIBBON_SESSIONS=$S RIBBON_WATCHDOG=$T/watchdog RIBBON_POLL=0.2 \
		BOOT_GOOD_STABLE=${STABLE:-1} BOOT_GOOD_TIMEOUT=${LIMIT:-3} timeout "$1" bash "$TOOL" boot-watch >/dev/null
}
# (an armed boot: the counter says trying and the initramfs took this boot's try)
arm3() { mkdir -p "$T/boot/ribbon" "$T/run"; printf 'tries=2\nsnapshot=41\nstate=trying\n' > "$T/boot/ribbon/trying"; echo 2 > "$T/run/boot-try"; }
echo "ribbon-snapshot boot-watch (ribbon-boot-ok)"
rm -rf "$T/run" "$S" "$T/state"; : > "$T/watchdog"
arm3; session c1 greeter 120; echo yes > "$T/pgrep.mode"
watch 10
check "the greeter up for the stable time: boot marked good, counter cleared" sh -c "[ ! -e '$T/boot/ribbon/trying' ] && [ \"\$(cat '$T/state/last-good')\" = 41 ] && grep -q 'boot marked good (session c1' '$T/kmsg'"
check "it asks for the greeter's own process, as the greeter's user" grep -q -- "-u 120 -f greeter/main.tcl" "$T/pgrep.log"
check "armed: the watchdog was pinged and closed with the magic V" sh -c "grep -q '^\\.\\.*V\$' '$T/watchdog'"
check "no restart" test ! -e "$T/reboot.log"

rm -rf "$S"; : > "$T/watchdog"; arm3; echo no > "$T/pgrep.mode"
watch 10
check "armed, no login screen within the limit: a restart" test -s "$T/reboot.log"
check "... the counter is left for the initramfs" test "$(tget tries)" = 2
check "... said so in the kernel log" grep -q "no login screen within 3 s; restarting (2 tries left before snapshot 41)" "$T/kmsg"
check "... the watchdog stays armed for a hang during the restart (no V)" sh -c "grep -q '^\\.\\.*\$' '$T/watchdog' && ! grep -q V '$T/watchdog'"

arm3; session c2 greeter 120; echo no > "$T/pgrep.mode"
watch 10
check "a greeter session whose greeter is not running (Tcl broken) is not good" sh -c "[ -s '$T/reboot.log' ] && [ -e '$T/boot/ribbon/trying' ]"
arm3; echo flap > "$T/pgrep.mode"
STABLE=2 LIMIT=4 watch 10
check "a greeter that keeps coming and going is not good" sh -c "[ -s '$T/reboot.log' ] && [ -e '$T/boot/ribbon/trying' ]"
rm -rf "$S"; arm3; session c3 user 1000; echo yes > "$T/pgrep.mode"
watch 10
check "a desktop (class user) with the shell running: good" sh -c "[ ! -e '$T/boot/ribbon/trying' ] && grep -q -- '-u 1000 -f shell/main.tcl' '$T/pgrep.log'"
rm -rf "$S"; arm3; session c4 user 1000 1; echo yes > "$T/pgrep.mode"
watch 10
check "a remote session does not count" sh -c "[ -e '$T/boot/ribbon/trying' ] && [ -s '$T/reboot.log' ]"
rm -rf "$S"; arm3; session c5 manager 0; echo yes > "$T/pgrep.mode"
watch 10
check "a session of another class does not count" test -s "$T/reboot.log"

rm -rf "$S"; arm3; rm -f "$T/run/boot-try"; : > "$T/watchdog"; echo no > "$T/pgrep.mode"
watch 3 2>/dev/null; st=$?
check "counter armed but this boot took no try (ribbon.fallback=0, or the initramfs could not reach it): no restart" sh -c "[ $st -eq 124 ] && [ ! -e '$T/reboot.log' ] && [ ! -s '$T/watchdog' ]"
rm -rf "$S"; rm -f "$T/boot/ribbon/trying"; : > "$T/watchdog"; echo no > "$T/pgrep.mode"
watch 3 2>/dev/null; st=$?
check "not armed: no restart, ever (still waiting when stopped)" sh -c "[ $st -eq 124 ] && [ ! -e '$T/reboot.log' ] && [ ! -s '$T/watchdog' ]"
mkdir -p "$T/run"; printf 'mode=fallback\nsnapshot=41\n' > "$T/run/snapshot-boot"
mkdir -p "$T/boot/ribbon"; printf 'tries=0\nsnapshot=41\nstate=fallback\n' > "$T/boot/ribbon/trying"
watch 3 2>/dev/null; st=$?
check "fallback boot, nothing on screen: no restart loop" sh -c "[ $st -eq 124 ] && [ ! -e '$T/reboot.log' ]"
session c6 greeter 120; echo yes > "$T/pgrep.mode"
watch 10
check "fallback boot reaching the login screen: said so, the fallback stays" sh -c "grep -q 'this boot of a snapshot reached the login screen' '$T/kmsg' && grep -qx state=fallback '$T/boot/ribbon/trying'"
rm -f "$T/run/snapshot-boot"; rm -rf "$S"; arm3; : > "$T/watchdog"; echo no > "$T/pgrep.mode"
( PATH="$B:$PATH" RIBBON_LIB=$LIB RIBBON_ROOT=$R RIBBON_STATE=$T/state RIBBON_BOOT=$T/boot RIBBON_RUN=$T/run \
	RIBBON_KMSG=$T/kmsg RIBBON_SESSIONS=$S RIBBON_WATCHDOG=$T/watchdog RIBBON_POLL=0.2 BOOT_GOOD_TIMEOUT=60 \
	bash "$TOOL" boot-watch >/dev/null & p=$!
	for _ in $(seq 50); do [ -s "$T/watchdog" ] && break; sleep 0.1; done
	kill -TERM "$p"; wait "$p" )
check "stopped (shutdown at the login screen): the watchdog is closed with V, no restart" sh -c "grep -q 'V\$' '$T/watchdog' && [ ! -e '$T/reboot.log' ]"

# --- 4. the service ---------------------------------------------------------------
echo "dinit service ribbon-boot-ok"
check "runs boot-watch as a process" sh -c "grep -qx 'command = /usr/bin/ribbon-snapshot boot-watch' '$SVC' && grep -qx 'type = process' '$SVC'"
check "starts with the filesystems, not after loginready or greetd (a hang before login is counted)" sh -c "grep -qx 'depends-on: early-filesystems' '$SVC' && ! grep -Eq '^(depends-on|waits-for|after): *(loginready|greetd)' '$SVC'"
check "the service lints" python3 "$ROOT/tests/lint-dinit.py" --known runit-compat --known NetworkManager --known bluetoothd \
	--known chronyd --known cronie --known ufw --known polkitd \
	"$ROOT/srcpkgs/ribbon-dinit/files/services" "$ROOT/srcpkgs/ribbon-tools/files/services" "$ROOT/srcpkgs/ribbon-desktop/files/services"
check "the dracut module puts the hook in pre-pivot and the FAT modules in" sh -c "grep -q 'inst_hook pre-pivot 90' '$ROOT/srcpkgs/ribbon-tools/files/dracut/90ribbon-snapshot/module-setup.sh' && grep -q 'instmods vfat' '$ROOT/srcpkgs/ribbon-tools/files/dracut/90ribbon-snapshot/module-setup.sh'"

[ "$fail" -eq 0 ] && echo "  boot fallback: all checks passed"
exit "$fail"
