#!/bin/sh
# boot-test.sh ISO OUTDIR - boot the live ISO in QEMU and report how far it gets.
#
# The kernel and initramfs are taken out of the ISO and started directly, so that the kernel's and dinit's messages go
# to a serial console (OUTDIR/serial.log) and `ribbon.ci=1` can be put on the command line: with it, the live
# system's CI probe (build/live-rootfs: /usr/lib/ribbon/ci-probe, started by dinit) writes one line per milestone to
# the serial console (lines starting "RIBBON-CI "), and a screenshot of the session taken from inside (grim) as
# base64. The screen is also captured from outside (QMP screendump) every 20 s. OUTDIR/summary.txt ends with
# "RESULT boot: ok" when the session came up with the shell's bars on screen, else "RESULT boot: FAILED (...)".
#   BOOT_SECONDS (default 420) is how long the test waits; with KVM the desktop is up in well under two minutes.
#
# Then the recovery case (the release gate of docs/HANDOFF.md, "Recovery when Tcl or kit is broken"; BUILD-PLAN 9):
# the ISO's root filesystem is laid out on a disk image as ribbon-install lays it out (GPT; FAT32 EFI partition at
# /boot; btrfs with @, @home, @snapshots), with an initramfs dracut makes in it (90ribbon-snapshot) and a snapshot
# @snapshots/1/snapshot of the working system. Then Tcl (and kit) are broken in @ and the boot try counter is armed
# with one try, as `ribbon update` arms it. Boot 1 must take the try and, with no login screen, be restarted by
# ribbon-boot-ok; boot 2 must find the tries used up, start snapshot 1 with its overlay and bring the desktop up.
# OUTDIR/recovery-1.log, recovery-2.log and recovery-screen.png; summary.txt ends with "RESULT recovery: ok" or
# "RESULT recovery: FAILED (...)". It needs root (sudo), losetup, sfdisk, mkfs.vfat, mkfs.btrfs and btrfs on the
# host. RECOVERY_TEST=no leaves it out; RECOVERY_SECONDS (default 480) is the limit for each of the two boots.
set -u
ISO=$1; OUT=$2
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
W=$(mktemp -d)
SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo
REC_MOUNTS='' REC_LOOPS=''
cleanup() {
	kill "$QPID" 2>/dev/null
	for m in $REC_MOUNTS; do $SUDO umount -l "$m" 2>/dev/null; done
	for l in $REC_LOOPS; do $SUDO losetup -d "$l" 2>/dev/null; done
	$SUDO rm -rf "$W"
}
trap cleanup EXIT
QPID=
SECS=${BOOT_SECONDS:-420}
say() { echo "$*" | tee -a "$OUT/summary.txt"; }
bz_release() { # BZIMAGE: the kernel release its setup header names (empty if it is no bzImage)
	[ "$(dd if="$1" bs=1 skip=514 count=4 2>/dev/null)" = HdrS ] || return 0
	_o=$(od -An -t u2 -j 526 -N 2 "$1" | tr -d ' ')
	[ "${_o:-0}" -gt 0 ] || return 0
	dd if="$1" bs=1 skip=$((_o + 512)) count=200 2>/dev/null | tr '\0' '\n' | head -n1 | cut -d' ' -f1
}

# the ISO's own kernel, initramfs and command line (void-mklive: boot/vmlinuz, boot/initrd, boot/grub/grub_void.cfg or
# boot/isolinux/isolinux.cfg)
xorriso -osirrox on -indev "$ISO" -extract /boot "$W/boot" >/dev/null 2>&1
K=$(find "$W/boot" -maxdepth 1 -name 'vmlinuz*' | head -1); I=$(find "$W/boot" -maxdepth 1 -name 'initrd*' | head -1)
[ -n "$K" ] && [ -n "$I" ] || { say "RESULT boot: FAILED (no kernel or initramfs in the ISO: $(ls "$W/boot" 2>/dev/null | tr '\n' ' '))"; exit 1; }
# (lines ending in a backslash continue on the next one, as mklive's grub config writes them)
CMD=$(find "$W/boot" -name '*.cfg' -exec cat {} + 2>/dev/null | sed -e ':a' -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta' |
	grep -hoE 'root=live:[^"]*' | head -1 | sed 's/[[:space:]]*initrd=.*//; s/@@[A-Z_]*@@//g; s/[[:space:]]*$//')
[ -n "$CMD" ] || CMD="root=live:CDLABEL=$(xorriso -indev "$ISO" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: *//p') ro init=/sbin/init rd.luks=0 rd.md=0 rd.dm=0"
CMD="$CMD console=tty0 console=ttyS0,115200 loglevel=6 ribbon.ci=1"
say "kernel: $(basename "$K")  cmdline: $CMD"
# the release the ISO's kernel is: with Ribbon's kernel in the repository (the build job's repo-files.txt) the image
# boots it (build/build-iso.sh), not Void's
KREL=$(bz_release "$K")
say "kernel release: ${KREL:-unknown}"
kwrong=
if grep -q 'ribbon-kernel-[0-9]' "$OUT/repo-files.txt" 2>/dev/null; then
	case $KREL in *-ribbon_*) ;; *) kwrong="the repository holds Ribbon's kernel, and the ISO boots ${KREL:-an unknown kernel}" ;; esac
fi

ACCEL="-accel tcg -cpu max"; [ -w /dev/kvm ] && ACCEL="-accel kvm -cpu host"
say "accel: $ACCEL"
# shellcheck disable=SC2086
qemu-system-x86_64 $ACCEL -m 4096 -smp 4 -machine q35 \
	-kernel "$K" -initrd "$I" -append "$CMD" \
	-drive file="$ISO",media=cdrom,readonly=on,if=none,id=cd -device ide-cd,drive=cd \
	-device virtio-vga -display none -device virtio-rng-pci \
	-netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
	-serial "file:$OUT/serial.log" -qmp "unix:$W/qmp,server,nowait" -no-reboot &
QPID=$!

qmp() { printf '{"execute":"qmp_capabilities"}\n%s\n' "$1" | socat - "unix-connect:$W/qmp" >/dev/null 2>&1; }
shot() { qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$W/s.ppm\"}}"; sleep 1; [ -s "$W/s.ppm" ] && pnmtopng "$W/s.ppm" > "$OUT/$1.png" 2>/dev/null; }

t=0; n=0; ok=0
while [ $t -lt "$SECS" ]; do
	sleep 10; t=$((t + 10))
	kill -0 "$QPID" 2>/dev/null || { say "qemu exited after $t s"; break; }
	if [ $((t % 20)) -eq 0 ]; then n=$((n + 1)); shot "screen-$(printf %02d $n)"; fi
	if grep -q "RIBBON-CI done" "$OUT/serial.log" 2>/dev/null; then ok=1; sleep 3; shot screen-final; break; fi
done
[ $ok = 1 ] || shot screen-timeout
kill "$QPID" 2>/dev/null

# what the probe said, and its own screenshot
grep -a "RIBBON-CI " "$OUT/serial.log" 2>/dev/null | tr -d '\r' | sed 's/^.*RIBBON-CI /RIBBON-CI /' > "$OUT/probe.txt"
sed -n '/RIBBON-CI-SHOT-BEGIN/,/RIBBON-CI-SHOT-END/p' "$OUT/serial.log" 2>/dev/null | tr -d '\r' | grep -v RIBBON-CI-SHOT | base64 -d > "$OUT/session.png" 2>/dev/null
[ -s "$OUT/session.png" ] || rm -f "$OUT/session.png"
# keep the serial log readable: without the screenshot's base64
sed '/RIBBON-CI-SHOT-BEGIN/,/RIBBON-CI-SHOT-END/d' "$OUT/serial.log" > "$W/serial" 2>/dev/null && tail -c 300000 "$W/serial" > "$OUT/serial.log"
cat "$OUT/probe.txt" >> "$OUT/summary.txt"
fails=$(grep -c "RIBBON-CI FAIL" "$OUT/probe.txt")
status=0
if [ -n "$kwrong" ]; then say "RESULT boot: FAILED ($kwrong)"; status=1
elif [ $ok = 1 ] && [ "$fails" -eq 0 ]; then say "RESULT boot: ok"
elif [ $ok = 1 ]; then say "RESULT boot: FAILED ($fails probe checks failed)"; status=1
else say "RESULT boot: FAILED (the probe did not finish within $SECS s; see serial.log and the screenshots)"; status=1
fi

# ---- the recovery case ----------------------------------------------------------------------------------------
rmount() { for a; do last=$a; done; $SUDO mount "$@" && REC_MOUNTS="$last $REC_MOUNTS"; }
rfail() { say "RESULT recovery: FAILED ($*)"; exit 1; }
# run_boot N: boot the disk once (QEMU exits when the guest restarts: -no-reboot); its serial log is recovery-N.log
run_boot() {
	log=$OUT/recovery-$1.log; : > "$log"; rm -f "$W/qmp"
	# shellcheck disable=SC2086
	qemu-system-x86_64 $ACCEL -m 4096 -smp 4 -machine q35 \
		-kernel "$W/rec-vmlinuz" -initrd "$W/rec-initramfs" -append "$RCMD" \
		-drive file="$W/disk.raw",format=raw,if=virtio \
		-device virtio-vga -display none -device virtio-rng-pci \
		-netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
		-serial "file:$log" -qmp "unix:$W/qmp,server,nowait" -no-reboot &
	QPID=$!
	t=0
	while [ $t -lt "${RECOVERY_SECONDS:-480}" ] && kill -0 "$QPID" 2>/dev/null; do
		sleep 5; t=$((t + 5))
		# boot 2 ends once the probe is done AND ribbon-boot-ok has spoken: it calls a boot good only after the session
		# has been up for BOOT_GOOD_STABLE (15) s, which a fast probe finishes well before (stopping at the probe's
		# end lost that line on a quick runner); the deadline above still bounds it
		if [ "$1" = 2 ] && grep -q "RIBBON-CI done" "$log" 2>/dev/null &&
			grep -q "ribbon-boot-ok: this boot of a snapshot reached the login screen\|ribbon-boot-ok: boot marked good" "$log" 2>/dev/null; then
			sleep 3; shot recovery-screen; break
		fi
	done
	kill -0 "$QPID" 2>/dev/null && { [ "$1" = 2 ] || shot "recovery-$1-timeout"; kill "$QPID"; }
	wait "$QPID" 2>/dev/null; QPID=
	sed -i '/RIBBON-CI-SHOT-BEGIN/,/RIBBON-CI-SHOT-END/d' "$log"
	grep -a 'ribbon-boot' "$log" | tr -d '\r' | sed 's/^.*\(ribbon-boot\)/\1/; s/^/  boot '"$1"': /' >> "$OUT/summary.txt"
}
seen() { grep -aqF -- "$2" "$OUT/recovery-$1.log"; }

if [ "${RECOVERY_TEST:-yes}" = no ]; then
	say "RESULT recovery: skipped (RECOVERY_TEST=no)"
	exit $status
fi
(
	# (the mounts and loop devices are this subshell's: clean them up here)
	trap cleanup EXIT
	for t in losetup sfdisk mkfs.vfat mkfs.btrfs btrfs chroot truncate; do
		command -v "$t" >/dev/null 2>&1 || PATH=$PATH:/usr/sbin:/sbin command -v "$t" >/dev/null 2>&1 || rfail "$t is missing on the CI host"
	done
	PATH=$PATH:/usr/sbin:/sbin
	say "recovery: building the disk image"
	# the ISO's root filesystem (void-mklive: LiveOS/squashfs.img, holding LiveOS/rootfs.img or the tree itself)
	mkdir -p "$W/iso" "$W/sq" "$W/live" "$W/top" "$W/esp"
	rmount -o loop,ro "$ISO" "$W/iso" || rfail "cannot mount the ISO"
	[ -e "$W/iso/LiveOS/squashfs.img" ] || rfail "no LiveOS/squashfs.img in the ISO"
	rmount -o loop,ro -t squashfs "$W/iso/LiveOS/squashfs.img" "$W/sq" || rfail "cannot mount the squashfs"
	live=$W/sq
	if [ -e "$W/sq/LiveOS/rootfs.img" ]; then rmount -o loop,ro "$W/sq/LiveOS/rootfs.img" "$W/live" || rfail "cannot mount rootfs.img"; live=$W/live; fi
	# the ISO's kernel, with its own modules (the newest directory would be Void's 6.18.64_1 beside Ribbon's
	# 6.18.64-ribbon_1, and Ribbon's image with Void's modules boots nothing)
	kver=$KREL
	[ -n "$kver" ] && [ -d "$live/usr/lib/modules/$kver" ] || rfail "the live root has no modules for the ISO's kernel (${kver:-unknown release})"
	# the disk: GPT, a 1 GiB EFI partition (FAT32, /boot) and btrfs with Ribbon's subvolumes
	truncate -s 24G "$W/disk.raw"
	printf 'label: gpt\nsize=1GiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B\ntype=0FC63DAF-8483-4772-8E79-3D69D8477DE4\n' |
		$SUDO sfdisk -q "$W/disk.raw" || rfail "sfdisk"
	# one loop device per partition, by offset (partition device nodes need udev, which a container may not have)
	part_loop() {
		# shellcheck disable=SC2046
		set -- $(sfdisk -d "$W/disk.raw" | awk -v p="$W/disk.raw$1" '$1 == p { gsub(/[^0-9]/, "", $4); gsub(/[^0-9]/, "", $6); print $4, $6 }')
		[ -n "${2:-}" ] && $SUDO losetup -f --show -o $(($1 * 512)) --sizelimit $(($2 * 512)) "$W/disk.raw"
	}
	esp=$(part_loop 1) && REC_LOOPS=$esp && sys=$(part_loop 2) && REC_LOOPS="$sys $esp" || rfail "losetup"
	$SUDO mkfs.vfat -F 32 -n EFI "$esp" >/dev/null || rfail "mkfs.vfat"
	$SUDO mkfs.btrfs -q -f -L ribbon "$sys" >/dev/null || rfail "mkfs.btrfs"
	rmount -o compress=zstd "$sys" "$W/top" || rfail "cannot mount the btrfs"
	for s in @ @home @snapshots; do $SUDO btrfs subvolume create "$W/top/$s" >/dev/null || rfail "subvolume $s"; done
	r=$W/top/@
	$SUDO cp -a "$live/." "$r/" || rfail "copying the live root"
	ruuid=$($SUDO blkid -s UUID -o value "$sys"); euuid=$($SUDO blkid -s UUID -o value "$esp")
	$SUDO sh -c "cat > '$r/etc/fstab'" <<-EOF
		# the recovery test's disk (build/ci/boot-test.sh), as ribbon-install writes it
		UUID=$ruuid / btrfs rw,noatime,compress=zstd,subvol=@ 0 0
		UUID=$ruuid /home btrfs rw,noatime,compress=zstd,subvol=@home 0 0
		UUID=$ruuid /.snapshots btrfs rw,noatime,compress=zstd,subvol=@snapshots 0 0
		UUID=$euuid /boot vfat rw,noatime,umask=0077 0 2
	EOF
	$SUDO mkdir -p "$r/.snapshots" "$r/boot" "$r/home"
	rmount -o "subvol=@home" "$sys" "$r/home" || rfail "mount @home"
	rmount "$esp" "$r/boot" || rfail "mount the EFI partition"
	for d in proc sys dev; do rmount --bind "/$d" "$r/$d" || rfail "bind /$d"; done
	# the live user, as an installed system has its first user (the live ISO's greetd config logs anon in)
	grps=$(for g in audio video input wheel network plugdev; do $SUDO chroot "$r" getent group "$g" >/dev/null && printf '%s,' "$g"; done)
	$SUDO chroot "$r" sh -c "id anon >/dev/null 2>&1 || useradd -m -s /bin/bash ${grps:+-G ${grps%,}} anon" || rfail "useradd anon"
	$SUDO mkdir -p "$r/etc/dinit.d/boot.d"
	$SUDO ln -sfn ../ribbon-boot-ok "$r/etc/dinit.d/boot.d/ribbon-boot-ok"
	# a restart after 150 s without a login screen (the default is 300) keeps the test short
	printf '\n# the recovery test (build/ci/boot-test.sh)\nBOOT_GOOD_TIMEOUT=150\n' | $SUDO tee -a "$r/etc/ribbon/ribbon.conf" >/dev/null
	$SUDO cp "$K" "$r/boot/vmlinuz-$kver"
	$SUDO chroot "$r" dracut --force --no-hostonly --kver "$kver" --add "btrfs ribbon-snapshot" "/boot/initramfs-$kver.img" \
		> "$OUT/recovery-dracut.log" 2>&1 || rfail "dracut in the image (recovery-dracut.log)"
	$SUDO chroot "$r" lsinitrd "/boot/initramfs-$kver.img" 2>/dev/null | grep -q 'ribbon-snapshot-overlay.sh' ||
		rfail "the initramfs has no 90ribbon-snapshot hook"
	$SUDO cp "$r/boot/vmlinuz-$kver" "$W/rec-vmlinuz"; $SUDO cp "$r/boot/initramfs-$kver.img" "$W/rec-initramfs"
	$SUDO chmod 644 "$W/rec-vmlinuz" "$W/rec-initramfs"
	# the snapshot of the working system (snapper's layout: @snapshots/<N>/snapshot), taken before the "update"
	for d in dev sys proc boot home; do $SUDO umount "$r/$d" || rfail "umount $d"; done
	$SUDO mkdir -p "$W/top/@snapshots/1"
	$SUDO btrfs subvolume snapshot -r "$r" "$W/top/@snapshots/1/snapshot" >/dev/null || rfail "btrfs snapshot"
	# the broken update: Tcl's library and the kit command are gone from @
	$SUDO mv "$r/usr/lib/tcl8.6" "$r/usr/lib/tcl8.6.broken-by-ci" || rfail "breaking Tcl"
	[ -e "$r/usr/bin/kit" ] && $SUDO mv "$r/usr/bin/kit" "$r/usr/bin/kit.broken-by-ci"
	# (tclsh runs a script even when its init library is missing: what tells is whether init.tcl is where Tcl looks)
	if echo 'puts [file exists [file join $tcl_library init.tcl]]' | $SUDO chroot "$r" tclsh8.6 2>/dev/null | grep -qx 1; then
		rfail "Tcl still works in @ after breaking it"
	fi
	# the try counter, as `ribbon-snapshot arm 1` writes it (ribbon update), with one try
	rmount "$esp" "$W/esp" || rfail "mount the EFI partition"
	$SUDO mkdir -p "$W/esp/ribbon"
	printf '# Ribbon OS boot try counter (ribbon-snapshot arm; docs/SYSTEM-UPDATES.md 7.8)\ntries=1\nsnapshot=1\nstate=trying\n' |
		$SUDO tee "$W/esp/ribbon/trying" >/dev/null
	$SUDO umount "$W/esp"; $SUDO umount "$W/top"
	$SUDO losetup -d "$esp" "$sys"; REC_LOOPS=
	$SUDO chmod 666 "$W/disk.raw"
	RCMD="root=UUID=$ruuid rootfstype=btrfs rootflags=subvol=@ rw console=tty0 console=ttyS0,115200 loglevel=6 ribbon.ci=1"
	say "recovery: kernel $kver  cmdline: $RCMD"

	say "recovery: boot 1 (Tcl and kit broken, one try armed)"
	run_boot 1
	seen 1 "ribbon-boot: trying the updated system (0 tries left after this one)" || rfail "boot 1: the initramfs did not take the try (recovery-1.log)"
	seen 1 "RIBBON-CI ok   the Ribbon shell is running" && rfail "boot 1: the shell ran although Tcl was broken"
	seen 1 "ribbon-boot-ok: no login screen within 150 s; restarting" || rfail "boot 1: ribbon-boot-ok did not restart the machine (recovery-1.log)"
	seen 1 "ribbon-boot-ok: boot marked good" && rfail "boot 1: a broken boot was marked good"

	say "recovery: boot 2 (the tries are used up)"
	run_boot 2
	seen 2 "ribbon-boot: the updated system did not reach the login screen; starting snapshot 1" || rfail "boot 2: no fallback to the snapshot (recovery-2.log)"
	seen 2 "ribbon-boot: booted snapshot 1 (fallback) with a temporary writable overlay" || rfail "boot 2: the snapshot's overlay was not set up (recovery-2.log)"
	seen 2 "RIBBON-CI ok   the Ribbon shell is running" || rfail "boot 2: the desktop did not come up on the snapshot (recovery-2.log)"
	seen 2 "ribbon-boot-ok: this boot of a snapshot reached the login screen" || rfail "boot 2: ribbon-boot-ok did not see the desktop (recovery-2.log)"
	say "RESULT recovery: ok"
) || status=1
exit $status
