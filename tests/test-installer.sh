#!/bin/bash
# The installer backend on loop-device disks: ribbon-install-probe (disks,
# partitions, free space, Windows and Linux found, NTFS resize limits and
# safety), --check-answers, and ribbon-install --answers --progress for the
# three disk modes (erase, alongside Windows, manual) up to the copied system
# and its fstab (RIBBON_INSTALL_STOP_AFTER=copy), then the whole install
# once, steps 4-6 with a stand-in for chroot (tests/installer-fake-chroot.sh:
# the new system's own tools only log). Needs root, loop devices, gdisk, util-linux, dosfstools,
# btrfs-progs, e2fsprogs, rsync and tclsh8.6; the Windows cases need
# ntfs-3g (mkntfs, ntfsresize, ntfscp) and FUSE. Skips what it can't do.
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
BIN=$REPO/srcpkgs/ribbon-installer/files/bin
fail=0
check() { # description, then a command that must succeed
	local d=$1; shift
	if "$@"; then echo "  ok   $d"; else echo "  FAIL $d"; fail=1; fi
}
skip() { echo "  skip $*"; exit 0; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" -eq 0 ] || skip "installer disk tests (need root)"
for t in losetup sgdisk sfdisk partx mkfs.vfat mkfs.btrfs mkfs.ext4 blkid lsblk rsync tclsh8.6 mknod; do
	have "$t" || skip "installer disk tests (no $t)"
done
[ -e /dev/loop-control ] || skip "installer disk tests (no loop devices)"
NTFS=yes
for t in mkntfs ntfsresize ntfscp ntfscat ntfsinfo ntfs-3g ntfsfix; do have "$t" || NTFS=no; done
[ -e /dev/fuse ] || NTFS=no

W=$(mktemp -d "${TMPDIR:-/tmp}/ribbon-installer-test.XXXXXX")
LOOPS=()
cleanup() {
	set +e
	for m in $(findmnt -rno TARGET | grep "^$W" | sort -r); do umount -l "$m" 2>/dev/null; done
	for m in ribbon-root ribbon-home; do [ -e "/dev/mapper/$m" ] && cryptsetup close "$m" 2>/dev/null; done
	for l in "${LOOPS[@]}"; do
		losetup -d "$l" 2>/dev/null
		rm -f "$l"p[0-9]* 2>/dev/null
	done
	[ -n "${KEEP_TMP:-}" ] || rm -rf "${W:?}"
}
trap cleanup EXIT
# the images are sparse, but NTFS, rsync and mkfs write about 1 GB
[ "$(df -B1M --output=avail "$W" | tail -n1)" -ge 1200 ] || skip "installer disk tests (less than 1.2 GB free in ${TMPDIR:-/tmp})"

# Containers often have no udev: make the partition device nodes ourselves.
# A udevadm on PATH does it whenever the installer waits for udev.
mkdir -p "$W/bin"
cat > "$W/bin/udevadm" <<'EOF'
#!/bin/sh
for s in /sys/class/block/loop*p*; do
	[ -e "$s/dev" ] || continue
	n=${s##*/}; d=$(cat "$s/dev"); ma=${d%:*}; mi=${d#*:}
	if [ -b "/dev/$n" ]; then
		[ "$(stat -c '%t:%T' "/dev/$n")" = "$(printf '%x:%x' "$ma" "$mi")" ] && continue
		rm -f "/dev/$n"
	fi
	mknod "/dev/$n" b "$ma" "$mi"
done
exit 0
EOF
chmod +x "$W/bin/udevadm"
# No vfat in this kernel (containers)? Mount FAT with fusefat instead.
if ! grep -qw vfat /proc/filesystems && ! modprobe vfat 2>/dev/null; then
	have fusefat || skip "installer disk tests (no vfat in the kernel and no fusefat)"
	REAL_MOUNT=$(command -v mount); export REAL_MOUNT
	cp tests/installer-mount-shim.sh "$W/bin/mount"; chmod +x "$W/bin/mount"
fi
export PATH="$W/bin:$PATH"

newdisk() { # name size -> loop device in $NEW (not in a subshell: LOOPS is for cleanup)
	truncate -s "$2" "$W/$1.img"
	NEW=$(losetup -f --show -P "$W/$1.img") || return 1
	LOOPS+=("$NEW")
}
nodes() { partx -a "$1" 2>/dev/null; partx -u "$1" 2>/dev/null; udevadm; }
q() { tclsh8.6 tests/installer-query.tcl "$@"; }

probe() { RIBBON_UEFI=yes RIBBON_PROBE_DISKS="$DISKS" RIBBON_PROBE_MEDIA="$MEDIA" RIBBON_PROBE_GEOIP=0 RIBBON_PROBE_TMP=$W/ptmp \
	tclsh8.6 "$BIN/ribbon-install-probe" "$@"; }

# Windows' kernel image, as far as the probe reads it: a PE version resource
# saying 10.0.22631 (Windows 11).
fake_ntoskrnl() {
	tclsh8.6 <<EOF
set f [open {$1} wb]
puts -nonewline \$f "MZ[string repeat \0 4000]"
puts -nonewline \$f [binary format iiii 0xFEEF04BD 0x10000 0xa0000 [expr {(22631 << 16) | 4460}]]
puts -nonewline \$f [string repeat \0 4000]
close \$f
EOF
}

# Mark an NTFS volume dirty (VOLUME_IS_DIRTY in \$Volume's information), as
# Windows leaves it after a crash. ntfsfix -d clears it again.
ntfs_dirty() {
	tclsh8.6 /dev/stdin "$1" <<'EOF'
set f [open [lindex $argv 0] r+b]
set boot [read $f 512]
binary scan $boot @11su@13cu@48wu@56wu@64c bps spc mftlcn mirrlcn crec
set cs [expr {$bps * $spc}]
set rs [expr {$crec < 0 ? 1 << -$crec : $crec * $cs}]
foreach lcn [list $mftlcn $mirrlcn] {
set off [expr {$lcn * $cs + 3 * $rs}]
seek $f $off
set rec [read $f $rs]
binary scan $rec @20su a
while {$a < $rs} {
	binary scan $rec @${a}iu@[expr {$a + 4}]iu type len
	if {$type == 0x70} {
		binary scan $rec @[expr {$a + 20}]su voff
		set flags_at [expr {$a + $voff + 10}]
		binary scan $rec @${flags_at}su flags
		seek $f [expr {$off + $flags_at}]
		puts -nonewline $f [binary format s [expr {$flags | 1}]]
		break
	}
	if {$type == 0xffffffff || $len == 0} break
	incr a $len
}
}
close $f
EOF
}

MEDIA=/dev/nonexistent-media
echo "making disks"
# --- Windows disk: ESP, MSR, Windows (NTFS), free space, recovery at the end
newdisk windows 100G || skip "installer disk tests (losetup failed)"; WD=$NEW
sgdisk -n1:1MiB:+512MiB -t1:EF00 -c1:"EFI system partition" -n2:0:+16MiB -t2:0C01 -c2:"Microsoft reserved partition" \
	-n3:0:+60GiB -t3:0700 -c3:"Basic data partition" -n4:-700MiB:-0 -t4:2700 -c4:Recovery "$WD" >/dev/null
nodes "$WD"
mkfs.vfat -F32 -n SYSTEM "${WD}p1" >/dev/null
mkdir -p "$W/m"
mount "${WD}p1" "$W/m" && mkdir -p "$W/m/EFI/Microsoft/Boot" "$W/m/EFI/BOOT" &&
	echo "Windows Boot Manager" > "$W/m/EFI/Microsoft/Boot/bootmgfw.efi" &&
	echo "Microsoft fallback" > "$W/m/EFI/BOOT/BOOTX64.EFI" && umount "$W/m"
if [ "$NTFS" = yes ]; then
	mkntfs -Q -F -L Windows "${WD}p3" >/dev/null 2>&1
	mkntfs -Q -F -L Recovery "${WD}p4" >/dev/null 2>&1
	if ntfs-3g "${WD}p3" "$W/m"; then
		mkdir -p "$W/m/Windows/System32/config" "$W/m/Users/alex"
		fake_ntoskrnl "$W/m/Windows/System32/ntoskrnl.exe"
		head -c 300000000 /dev/zero > "$W/m/Users/alex/big.vhd"   # 300 MB in use
		head -c 65536 /dev/zero > "$W/m/hiberfil.sys"
		umount "$W/m"
	else
		echo "  (ntfs-3g mount failed: Windows cases skipped)"; NTFS=no
	fi
fi
# --- a second Windows disk whose EFI partition is Windows' usual 100 MB
newdisk smallesp 64G; SD=$NEW
sgdisk -n1:1MiB:+100MiB -t1:EF00 -n3:0:+40GiB -t3:0700 "$SD" >/dev/null
nodes "$SD"
mkfs.vfat -F32 "${SD}p1" >/dev/null 2>&1
mount "${SD}p1" "$W/m" && mkdir -p "$W/m/EFI/Microsoft/Boot" && head -c 80000000 /dev/zero > "$W/m/EFI/Microsoft/Boot/bootmgfw.efi"; umount "$W/m"
if [ "$NTFS" = yes ]; then
	mkntfs -Q -F -L Windows "${SD}p3" >/dev/null 2>&1
	ntfs-3g "${SD}p3" "$W/m" && mkdir -p "$W/m/Windows/System32" && fake_ntoskrnl "$W/m/Windows/System32/ntoskrnl.exe" && umount "$W/m"
fi
mkdir -p "$W/m" && mount "${SD}p1" "$W/m" && (cd "$W/m" && find . -type f -exec md5sum {} + | sort) > "$W/smallesp.sums"; umount "$W/m"
# --- Windows on a disk without an EFI partition (its boot files on another disk)
newdisk noesp 48G; ND=$NEW
sgdisk -n2:1MiB:+16MiB -t2:0C01 -n3:0:+12GiB -t3:0700 "$ND" >/dev/null
nodes "$ND"
if [ "$NTFS" = yes ]; then
	mkntfs -Q -F -L Windows "${ND}p3" >/dev/null 2>&1
	ntfs-3g "${ND}p3" "$W/m" && mkdir -p "$W/m/Windows/System32" && fake_ntoskrnl "$W/m/Windows/System32/ntoskrnl.exe" && umount "$W/m"
fi
# --- a Linux disk: Fedora on ext4, then free space
newdisk linux 48G; LD=$NEW
sgdisk -n1:1MiB:+4GiB -t1:8300 "$LD" >/dev/null
nodes "$LD"
mkfs.ext4 -q -F -L fedora "${LD}p1"
mount "${LD}p1" "$W/m" && mkdir -p "$W/m/etc" && printf 'NAME="Fedora Linux"\nPRETTY_NAME="Fedora Linux 41 (Workstation Edition)"\n' > "$W/m/etc/os-release" && umount "$W/m"
# --- an empty disk for erase installs, and one that plays the install media
newdisk empty 40G; ED=$NEW
newdisk media 1G; MD=$NEW
DISKS="$WD $SD $ND $LD $ED $MD"
MEDIA=$MD
if [ "${1:-}" = --setup-only ]; then
	# debugging: keep the disks (detach them yourself)
	trap - EXIT
	printf 'W=%s WD=%s SD=%s ND=%s LD=%s ED=%s MD=%s\n' "$W" "$WD" "$SD" "$ND" "$LD" "$ED" "$MD"
	exit 0
fi

echo "ribbon-install-probe: disks"
start=$(date +%s%N)
probe --only disks > "$W/probe" 2> "$W/probe.err" || cat "$W/probe.err"
ms=$(( ($(date +%s%N) - start) / 1000000 ))
check "probe prints a dict" q "$W/probe" 'dict size $d'
check "probe takes under 2 s on 6 disks ($ms ms)" test "$ms" -lt 2000
check "install media is left out" test "$(q "$W/probe" "disk $MD")" = ""
check "five disks listed" test "$(q "$W/probe" 'llength [dict get $d disks]')" = 5
check "GPT, size in bytes" test "$(q "$W/probe" "list [get [disk $WD] table] [get [disk $WD] size]")" = "gpt 107374182400"
check "ESP found, with its free space" test "$(q "$W/probe" "list [get [part ${WD}p1] type] [get [part ${WD}p1] fs] [expr {[get [part ${WD}p1] free] > 500000000}]")" = "esp vfat 1"
check "partition start and size in bytes" test "$(q "$W/probe" "list [get [part ${WD}p1] start] [get [part ${WD}p1] size]")" = "1048576 536870912"
check "MSR and recovery types" test "$(q "$W/probe" "list [get [part ${WD}p2] type] [get [part ${WD}p4] type]")" = "msr recovery"
check "free space between Windows and recovery" sh -c "test \"\$(tclsh8.6 tests/installer-query.tcl '$W/probe' 'dict get [lindex [get [disk $WD] free] 0] size')\" -gt 37000000000"
check "Fedora found by its os-release" test "$(q "$W/probe" "get [part ${LD}p1] os name")" = "Fedora Linux 41 (Workstation Edition)"
check "disk-level os list" test "$(q "$W/probe" "get [lindex [get [disk $LD] os] 0] kind")" = linux
check "empty disk: no table, all free" test "$(q "$W/probe" "list [get [disk $ED] table] [llength [get [disk $ED] parts]] [llength [get [disk $ED] free]]")" = "{} 0 1"
check "probe left nothing mounted" sh -c "! findmnt -rno TARGET | grep -q '^$W/ptmp'"
if [ "$NTFS" = yes ]; then
	check "Windows 11 found (kernel version)" test "$(q "$W/probe" "get [part ${WD}p3] os")" = "name {Windows 11} kind windows"
	check "NTFS used space" sh -c "u=\$(tclsh8.6 tests/installer-query.tcl '$W/probe' 'get [part ${WD}p3] used'); [ \"\$u\" -gt 280000000 ] && [ \"\$u\" -lt 450000000 ]"
	check "resize: safe, min above use, max leaves 32 GiB" test "$(q "$W/probe" "set r [get [part ${WD}p3] resize]; list [dict get \$r safe] [expr {[dict get \$r min] > 2000000000 && [dict get \$r min] < 13000000000}] [expr {[dict get \$r max] == 64424509440}]")" = "1 1 1"
	check "alongside possible on the Windows disk, kernels on its EFI partition" test "$(q "$W/probe" "get [disk $WD] alongside")" = "possible 1 part ${WD}p3 esp ${WD}p1 boot esp why {}"
	check "alongside possible with a 100 MB EFI partition: a boot partition is made" test "$(q "$W/probe" "get [disk $SD] alongside")" = "possible 1 part ${SD}p3 esp ${SD}p1 boot new why {}"
	sd_after=$(q "$W/probe" "set e [expr {[get [part ${SD}p3] start] + [get [part ${SD}p3] size]}]; foreach f [get [disk $SD] free] { if {[dict get \$f start] == \$e} { puts -nonewline [dict get \$f size] } }")
	check "resize max leaves Ribbon 32 GiB plus the 1 GiB boot partition" test "$(q "$W/probe" "get [part ${SD}p3] resize max")" = "$(( 40 * 1073741824 + sd_after - 33 * 1073741824 ))"
	check "alongside possible without an EFI partition: one is made" test "$(q "$W/probe" "get [disk $ND] alongside")" = "possible 1 part ${ND}p3 esp {} boot new why {}"

	echo "ribbon-install-probe: Windows safety"
	printf 'HIBR' > "$W/hibr"; head -c 65532 /dev/urandom >> "$W/hibr"
	ntfscp -f "${WD}p3" "$W/hibr" /hiberfil.sys >/dev/null 2>&1
	out=$(probe --windows-ready "${WD}p3"); rc=$?
	check "hibernated Windows: not safe (exit 0, a dict)" test "$rc $(printf '%s' "$out" | tclsh8.6 <(echo 'puts [dict get [read stdin] safe]'))" = "0 0"
	check "the why explains Fast Startup" grep -q 'Fast Startup' <<<"$out"
	# what Windows does on a full shutdown (here: ntfs-3g drops the file)
	ntfs-3g -o remove_hiberfile "${WD}p3" "$W/m" && umount "$W/m"
	check "after a full shutdown: safe" sh -c "RIBBON_UEFI=yes RIBBON_PROBE_DISKS='$DISKS' RIBBON_PROBE_MEDIA='$MEDIA' tclsh8.6 '$BIN/ribbon-install-probe' --windows-ready '${WD}p3' | grep -q 'safe 1'"
	ntfs_dirty "${WD}p3"
	check "the dirty flag is set (ntfsinfo)" sh -c "ntfsinfo -f -m '${WD}p3' | grep -q 'Volume Flags: 0x0001'"
	out=$(probe --windows-ready "${WD}p3")
	check "dirty NTFS: not safe, says why" grep -q "didn't shut down cleanly" <<<"$out"
	ntfsfix -d "${WD}p3" >/dev/null 2>&1
	out=$(probe --windows-ready "${WD}p3")
	check "after a clean shutdown: safe again" grep -q 'safe 1' <<<"$out"
else
	echo "  skip Windows cases (no ntfs-3g/ntfsprogs or FUSE)"
fi

echo "--check-answers"
ans() { # file, then dict text
	local f=$W/$1.ans; shift
	printf '%s\n' "$*" > "$f"; chmod 600 "$f"; echo "$f"
}
base="version 1 locale en_GB.UTF-8 keymap gb timezone Europe/London fs btrfs encrypt 0 bootloader limine swap {mode zram} drivers {} apps {steam discord} games {} user {fullname {Alex Tyrone} name alex hostname alex-desktop autologin 0}"
expect() { # description, expected (ok | error-substring), answers text
	local d=$1 want=$2; shift 2
	local f; f=$(ans case "$*")
	local got; got=$(RIBBON_UEFI=yes probe --check-answers "$f")
	if [ "$want" = ok ]; then check "$d" sh -c "[ \"\$1\" = ok ] || { echo \"    got: \$1\"; exit 1; }" sh "$got"
	else check "$d" sh -c "case \"\$1\" in error*\"\$2\"*) exit 0 ;; *) echo \"    got: \$1\"; exit 1 ;; esac" sh "$got" "$want"; fi
}
expect "erase on the empty disk" ok "$base disk $ED mode erase"
expect "the install media is refused" "install media" "$base disk $MD mode erase"
expect "unknown disk" "not found" "$base disk /dev/nope mode erase"
expect "bad user name" "user name" "$base disk $ED mode erase user {fullname {Alex Tyrone} name Alex! hostname alex-desktop autologin 0}"
expect "system user name" "used by the system" "$base disk $ED mode erase user {fullname {Alex Tyrone} name root hostname alex-desktop autologin 0}"
expect "bad host name" "computer name" "$base disk $ED mode erase user {fullname {Alex Tyrone} name alex hostname -bad- autologin 0}"
expect "unknown mode" "mode must be" "$base disk $ED mode wipe"
expect "custom swap" ok "$base disk $ED mode erase swap {mode custom size 8589934592}"
expect "custom swap over half of Ribbon's space" "more than half" "$base disk $ED mode erase swap {mode custom size 25769803776}"
expect "custom swap too small" "at least 256 MiB" "$base disk $ED mode erase swap {mode custom size 1000}"
expect "custom swap on ZFS" "swap files don't work" "$base disk $ED mode erase swap {mode custom size 25769803776} fs zfs bootloader zfsbootmenu"
expect "GRUB with bcachefs" "Limine" "$base disk $ED mode erase fs bcachefs bootloader grub"
expect "unknown driver id" "unknown driver id" "$base disk $ED mode erase drivers {gpu7 latest}"
expect "game drive on the erased disk" "erased" "$base disk $LD mode erase games {{dev ${LD}p1 name x}}"
expect "game drive elsewhere" ok "$base disk $ED mode erase games {{dev ${LD}p1 name library}}"
if [ "$NTFS" = yes ]; then
	expect "alongside: keep 30 GiB" ok "$base disk $WD mode alongside alongside {part ${WD}p3 keep 32212254720}"
	expect "alongside: Windows below its minimum" "must keep at least" "$base disk $WD mode alongside alongside {part ${WD}p3 keep 1073741824}"
	expect "alongside: Ribbon below 32 GiB" "at most" "$base disk $WD mode alongside alongside {part ${WD}p3 keep 75161927680}"
	expect "alongside: small EFI partition, a boot partition instead" ok "$base disk $SD mode alongside alongside {part ${SD}p3 keep 21474836480}"
	expect "alongside: small EFI partition, with GRUB" ok "$base bootloader grub disk $SD mode alongside alongside {part ${SD}p3 keep 21474836480}"
	expect "alongside: the boot partition comes out of Ribbon's 32 GiB-plus share" "at most" "$base disk $SD mode alongside alongside {part ${SD}p3 keep $((31 * 1073741824))}"
	expect "alongside: ZFS still needs a whole disk" "whole disk" "$base fs zfs bootloader zfsbootmenu disk $SD mode alongside alongside {part ${SD}p3 keep 21474836480}"
	expect "alongside: no EFI partition on the disk" ok "$base disk $ND mode alongside alongside {part ${ND}p3 keep $((11 * 1073741824))}"
	expect "alongside: not the Windows partition" "not a Windows partition" "$base disk $WD mode alongside alongside {part ${WD}p1 keep 32212254720}"
fi
G=1073741824
fs0=$(q "$W/probe" "dict get [lindex [get [disk $LD] free] 0] start")
m_esp="{new 1 disk $LD start $fs0 size $((1 * G)) format 1 fs vfat mount /boot}"
m_root="{new 1 disk $LD start $((fs0 + G)) size $((34 * G)) format 1 fs btrfs mount /}"
m_swap="{new 1 disk $LD start $((fs0 + 35 * G)) size $((512 * 1048576)) format 1 fs swap mount {}}"
m_data="{dev ${LD}p1 format 0 fs ext4 mount /data}"
expect "manual: ESP, /, swap, kept data partition" ok "$base disk $LD mode manual manual {$m_esp $m_root $m_swap $m_data}"
expect "manual: no /" "no / partition" "$base disk $LD mode manual manual {$m_esp $m_data}"
expect "manual: no EFI partition" "no EFI partition" "$base disk $LD mode manual manual {$m_root}"
expect "manual: /boot/efi needs GRUB" "needs GRUB" "$base disk $LD mode manual manual {${m_esp/\/boot/\/boot\/efi} $m_root}"
expect "manual: /boot/efi with GRUB" ok "$base bootloader grub disk $LD mode manual manual {${m_esp/\/boot/\/boot\/efi} $m_root}"
expect "manual: partition used twice" "used twice" "$base disk $LD mode manual manual {$m_esp $m_root $m_data {dev ${LD}p1 format 0 mount /srv}}"
expect "manual: two at one mount point" "two partitions are mounted at /" "$base disk $LD mode manual manual {$m_esp $m_root {dev ${LD}p1 format 1 fs btrfs mount /}}"
expect "manual: / too small" "needs at least" "$base disk $LD mode manual manual {$m_esp {new 1 disk $LD start $((fs0 + G)) size $((8 * G)) format 1 fs btrfs mount /}}"
expect "manual: overlapping new partitions" "overlaps" "$base disk $LD mode manual manual {$m_esp {new 1 disk $LD start $fs0 size $((34 * G)) format 1 fs btrfs mount /}}"
expect "manual: outside free space" "not inside free space" "$base disk $LD mode manual manual {$m_esp {new 1 disk $LD start 1048576 size $((34 * G)) format 1 fs btrfs mount /}}"
expect "manual: / must be formatted" "must be formatted" "$base disk $LD mode manual manual {$m_esp {dev ${LD}p1 format 0 mount /}}"
expect "manual: delete Fedora, / in its space and beyond" ok "$base disk $LD mode manual manual {{dev ${LD}p1 delete 1} {new 1 disk $LD start 1048576 size $G format 1 fs vfat mount /boot} {new 1 disk $LD start $((G + 1048576)) size $((36 * G)) format 1 fs btrfs mount /}}"
expect "manual: deleted, then used" "used twice" "$base disk $LD mode manual manual {{dev ${LD}p1 delete 1} $m_esp $m_root $m_data}"
expect "keymap with a variant" ok "$base disk $ED mode erase keymap {us intl}"
expect "account picture that isn't an image" "PNG or GIF" "$base disk $ED mode erase user {name alex hostname h picture /etc/hostname}"
expect "manual: ZFS" "whole disk" "$base fs zfs disk $LD mode manual manual {$m_esp $m_root}"
# / needs snapshots: ext4, XFS and F2FS are refused for it, but an existing
# partition of theirs is still mounted elsewhere
for f in ext4 xfs f2fs; do
	expect "$f for / is refused" "can't hold the system" "$base fs $f disk $ED mode erase"
	expect "manual: $f for / is refused" "can't hold the system (/)" "$base disk $LD mode manual manual {$m_esp {new 1 disk $LD start $((fs0 + G)) size $((34 * G)) format 1 fs $f mount /}}"
	expect "manual: a new $f partition is refused" "can't format as '$f'" "$base disk $LD mode manual manual {$m_esp $m_root {new 1 disk $LD start $((fs0 + 35 * G)) size $((512 * 1048576)) format 1 fs $f mount /data}}"
done
expect "manual: the existing ext4 partition mounted at /home" ok "$base disk $LD mode manual manual {$m_esp $m_root {dev ${LD}p1 format 0 mount /home}}"

# ---- installs, up to the copied system ----------------------------------
SRC=$W/src
mkdir -p "$SRC/usr/bin" "$SRC/etc" "$SRC/home/anon" "$SRC/var/lib/ribbon/offline-repo"
for i in $(seq 200); do head -c 20000 /dev/urandom > "$SRC/usr/bin/tool$i"; done
echo 'old' > "$SRC/etc/fstab"; echo secret > "$SRC/home/anon/live-only"
inst() { # answers-file -> protocol output in $W/out
	printf 'password "pw 1"\npassphrase "disk pass"\n' |
		env RIBBON_INSTALL_SRC=${INST_SRC-$SRC} ${INST_ENV:-} RIBBON_INSTALL_TARGET=$W/target RIBBON_INSTALL_STOP_AFTER=copy RIBBON_UEFI=yes \
		RIBBON_PROBE_DISKS="$DISKS" RIBBON_PROBE_MEDIA="$MEDIA" RIBBON_PROBE_GEOIP=0 RIBBON_PROBE_TMP=$W/ptmp TMPDIR=$W \
		bash "$BIN/ribbon-install" --answers "$1" --secrets-stdin --progress > "$W/out" 2>&1
}
lines_ok() { # every output line is a protocol line (a Tcl list)
	tclsh8.6 /dev/stdin "$W/out" <<'EOF'
set f [open [lindex $argv 0]]; set ok 1
while {[gets $f l] >= 0} {
	if {[catch {lindex $l 0} k] || $k ni {STEP PROGRESS LOG DONE ERROR}} { puts "    bad line: $l"; set ok 0 }
}
exit [expr {!$ok}]
EOF
}
mountroot() { mkdir -p "$W/r"; mount -o "${2:-ro}" "$1" "$W/r"; }

echo "ribbon-install --answers: erase (btrfs)"
inst "$(ans erase "$base disk $ED mode erase")"
check "DONE, exit 0" sh -c "tail -n1 '$W/out' | grep -qx DONE" || tail -n 4 "$W/out"
check "only protocol lines" lines_ok
check "steps 1 and 3 with their titles, no Encrypting" sh -c "grep '^STEP' '$W/out' | tr '\n' '|' | grep -qx 'STEP 1 6 {Preparing the disk}|STEP 3 6 {Copying Ribbon}|'"
check "rsync progress became percentages" sh -c "grep -c '^PROGRESS [0-9]* {[^}]*copied' '$W/out' | grep -qv '^0$'"
check "percentages never go down" sh -c "grep '^PROGRESS' '$W/out' | awk '{if (\$2 < p) exit 1; p = \$2}'"
check "partitions: 2 GiB ESP + btrfs" test "$(blkid -p -s TYPE -o value "${ED}p1") $(blkid -p -s TYPE -o value "${ED}p2") $(blockdev --getsize64 "${ED}p1")" = "vfat btrfs 2147483648"
check "nothing left mounted" sh -c "! findmnt -rno TARGET | grep -q '^$W/target'"
mountroot "${ED}p2"
check "btrfs subvolumes" sh -c "ls '$W/r' | tr '\n' ' ' | grep -qx '@ @cache @home @log @snapshots @swap @tmp '"
check "system copied, /home left out" sh -c "[ -e '$W/r/@/usr/bin/tool200' ] && [ ! -e '$W/r/@/home/anon/live-only' ]"
check "fstab: / and /boot by UUID" sh -c "grep -q '^UUID=$(blkid -s UUID -o value "${ED}p2") / btrfs noatime,compress=zstd:1,subvol=@ 0 0$' '$W/r/@/etc/fstab' && grep -q '^UUID=$(blkid -s UUID -o value "${ED}p1") /boot vfat' '$W/r/@/etc/fstab'"
umount "$W/r"

# A live system booted without dracut's overlay (24 Nov: Void's dracut-ng 112 does not read mklive's rd.overlayfs=1,
# and the first real install in CI stopped at "no live root at /run/rootfsbase"): no layer directory, the untouched
# base as a read-only block device (/dev/mapper/live-base), which the installer mounts read-only and lets go of.
echo "ribbon-install --answers: from the live base device, with no overlay layer"
# the base holds one file the earlier installs' source did not, so the copy is seen to come from it
cp -a "$SRC" "$W/base-src"; echo base > "$W/base-src/usr/bin/only-in-base"
mke2fs -q -t ext4 -d "$W/base-src" "$W/base.img" 64M
LB=$(losetup -f --show -r "$W/base.img")
INST_SRC='' INST_ENV="RIBBON_LIVE_LAYER=$W/no-layer RIBBON_LIVE_BASE=$LB" inst "$(ans erase-base "$base disk $ED mode erase")"
check "DONE, from the base device" sh -c "tail -n1 '$W/out' | grep -qx DONE" || tail -n 4 "$W/out"
check "the base device is let go of (not mounted)" sh -c "! findmnt -rno SOURCE | grep -qx '$LB'"
mountroot "${ED}p2"
check "the system was copied from it" sh -c "[ \"\$(cat '$W/r/@/usr/bin/only-in-base')\" = base ] && cmp -s '$W/r/@/usr/bin/tool200' '$SRC/usr/bin/tool200' && [ ! -e '$W/r/@/home/anon/live-only' ]"
umount "$W/r"
losetup -d "$LB"
INST_SRC='' INST_ENV="RIBBON_LIVE_LAYER=$W/no-layer RIBBON_LIVE_BASE=$W/no-base" inst "$(ans erase-none "$base disk $ED mode erase")"
check "with neither, it stops and names both" sh -c "grep -q 'no live system to copy (neither $W/no-layer nor $W/no-base)' '$W/out'"

if cryptsetup --version >/dev/null 2>&1 && [ -e /dev/mapper/control ]; then
	echo "ribbon-install --answers: erase, encrypted btrfs"
	inst "$(ans erase2 "$base disk $ED mode erase encrypt 1")"
	if grep -q 'Device mapper\|dm_crypt\|Cannot initialize device-mapper\|Failed to open key file' "$W/out"; then
		echo "  skip encrypted install (no dm-crypt here)"
	else
		check "DONE" sh -c "tail -n1 '$W/out' | grep -qx DONE" || tail -n 4 "$W/out"
		check "the Encrypting step" sh -c "grep -qx 'STEP 2 6 Encrypting' '$W/out'"
		check "root is LUKS2" test "$(blkid -p -s TYPE -o value "${ED}p2")" = crypto_LUKS
		check "passphrase from the secrets opens it" sh -c "printf 'disk pass' | cryptsetup open --test-passphrase --key-file - '${ED}p2'"
		check "the mapping was closed" test ! -e /dev/mapper/ribbon-root
	fi
fi

if [ "$NTFS" = yes ]; then
	echo "ribbon-install --answers: alongside Windows"
	esp_uuid=$(blkid -s UUID -o value "${WD}p1")
	keep=$((30 * G))
	inst "$(ans along "$base disk $WD mode alongside alongside {part ${WD}p3 keep $keep}")"
	check "DONE" sh -c "tail -n1 '$W/out' | grep -qx DONE" || tail -n 4 "$W/out"
	check "only protocol lines" lines_ok
	vs=$(ntfsresize --info --force --no-action "${WD}p3" 2>/dev/null | sed -n 's/^Current volume size: \([0-9]*\) bytes.*/\1/p')
	check "Windows' filesystem is 30 GiB ($vs)" sh -c "[ '${vs:-0}' -le $keep ] && [ '${vs:-0}' -gt $((keep - 1048576)) ]"
	check "ntfsresize left it marked for Windows' own check" sh -c "ntfsinfo -f -m '${WD}p3' | grep -q 'Volume Flags: 0x0001'"
	check "Windows' partition is 30 GiB" test "$(blockdev --getsize64 "${WD}p3")" = "$keep"
	check "Windows' files are intact" sh -c "ntfscat -f '${WD}p3' /Windows/System32/ntoskrnl.exe | head -c 2 | grep -q MZ"
	new=$(sfdisk --dump "$WD" | awk -F'[ :,=]+' 'tolower($0) ~ /name="ribbon"/ {print $1}')
	check "Ribbon's partition is right after Windows" test "$(sfdisk --dump "$WD" | awk -v d="$new" -F'[ :,=]+' '$1 == d {for (i = 1; i < NF; i++) if ($i == "start") print $(i+1)}')" = "$(( (1048576 + 512 * 1048576 + 16 * 1048576 + keep) / 512 ))"
	check "it fills the space up to the recovery partition" sh -c "[ \$(blockdev --getsize64 '$new') -gt $((68 * G)) ]"
	check "the recovery partition is untouched" test "$(blkid -p -s LABEL -o value "${WD}p4")" = Recovery
	check "the EFI partition was not reformatted" test "$(blkid -s UUID -o value "${WD}p1")" = "$esp_uuid"
	mountroot "$new"
	check "fstab mounts the shared EFI partition at /boot" sh -c "grep -q '^UUID=$esp_uuid /boot vfat' '$W/r/@/etc/fstab'"
	umount "$W/r"
	mount "${WD}p1" "$W/m"
	check "Windows Boot Manager is still there" test -e "$W/m/EFI/Microsoft/Boot/bootmgfw.efi"
	umount "$W/m"

	echo "ribbon-install --answers: alongside Windows with a 100 MB EFI partition"
	sd_esp_uuid=$(blkid -s UUID -o value "${SD}p1")
	keep=$((20 * G))
	inst "$(ans along2 "$base disk $SD mode alongside alongside {part ${SD}p3 keep $keep}")"
	check "DONE" sh -c "tail -n1 '$W/out' | grep -qx DONE" || tail -n 4 "$W/out"
	check "only protocol lines" lines_ok
	check "Windows' partition is 20 GiB" test "$(blockdev --getsize64 "${SD}p3")" = "$keep"
	boot=$(sfdisk --dump "$SD" | awk -F'[ :,=]+' 'tolower($0) ~ /name="ribbon_boot"/ {print $1}')
	new=$(sfdisk --dump "$SD" | awk -F'[ :,=]+' 'tolower($0) ~ /name="ribbon"/ {print $1}')
	startof() { sfdisk --dump "$SD" | awk -v d="$1" -F'[ :,=]+' '$1 == d {for (i = 1; i < NF; i++) if ($i == "start") print $(i+1)}'; }
	check "a boot partition right after Windows" test "$(startof "$boot")" = "$(( (1048576 + 100 * 1048576 + keep) / 512 ))"
	check "it is XBOOTLDR, FAT32, 1 GiB" test "$(blkid -p -s PART_ENTRY_TYPE -o value "$boot") $(blkid -p -s TYPE -o value "$boot") $(blockdev --getsize64 "$boot")" = "bc13c2ff-59e6-4262-a352-b275fd6f7172 vfat $G"
	check "the probe calls it xbootldr" sh -c "RIBBON_UEFI=yes RIBBON_PROBE_DISKS='$SD' RIBBON_PROBE_MEDIA='$MEDIA' RIBBON_PROBE_GEOIP=0 RIBBON_PROBE_TMP='$W/ptmp' tclsh8.6 '$BIN/ribbon-install-probe' --only disks > '$W/probe2' && [ \"\$(tclsh8.6 tests/installer-query.tcl '$W/probe2' 'get [part $boot] type')\" = xbootldr ]"
	check "Ribbon's partition follows it, to the end of the disk" sh -c "[ '$(startof "$new")' = '$(( (1048576 + 100 * 1048576 + keep + G) / 512 ))' ] && [ \$(blockdev --getsize64 '$new') -gt $((42 * G)) ]"
	check "only one EFI partition on the disk" test "$(sfdisk --dump "$SD" | grep -ci 'type=c12a7328')" = 1
	check "Windows' EFI partition was not reformatted" test "$(blkid -s UUID -o value "${SD}p1")" = "$sd_esp_uuid"
	mount "${SD}p1" "$W/m"
	check "nothing on it changed (Ribbon's kernels go elsewhere)" sh -c "(cd '$W/m' && find . -type f -exec md5sum {} + | sort) | cmp -s - '$W/smallesp.sums'"
	umount "$W/m"
	mountroot "$new"
	check "fstab: the boot partition at /boot" sh -c "grep -q '^UUID=$(blkid -s UUID -o value "$boot") /boot vfat defaults,umask=0077 0 2$' '$W/r/@/etc/fstab'"
	check "fstab: Windows' EFI partition at /boot/efi" sh -c "grep -q '^UUID=$sd_esp_uuid /boot/efi vfat defaults,umask=0077 0 2$' '$W/r/@/etc/fstab'"
	check "fstab: /boot before /boot/efi" sh -c "grep -n ' /boot' '$W/r/@/etc/fstab' | cut -d' ' -f2 | tr '\n' ' ' | grep -qx '/boot /boot/efi '"
	check "Limine reads the kernels from the boot partition (its GUID)" grep -qx "LIMINE_XBOOTLDR=$(blkid -p -s PART_ENTRY_UUID -o value "$boot")" "$W/r/@/etc/default/ribbon-limine"
	umount "$W/r"

	echo "ribbon-install --answers: alongside Windows, no EFI partition on its disk"
	keep=$((11 * G))
	inst "$(ans along3 "$base disk $ND mode alongside alongside {part ${ND}p3 keep $keep}")"
	check "DONE" sh -c "tail -n1 '$W/out' | grep -qx DONE" || tail -n 4 "$W/out"
	boot=$(sfdisk --dump "$ND" | awk -F'[ :,=]+' 'tolower($0) ~ /name="ribbon_efi"/ {print $1}')
	new=$(sfdisk --dump "$ND" | awk -F'[ :,=]+' 'tolower($0) ~ /name="ribbon"/ {print $1}')
	check "a new EFI partition (FAT32, 1 GiB)" test "$(blkid -p -s PART_ENTRY_TYPE -o value "$boot") $(blkid -p -s TYPE -o value "$boot") $(blockdev --getsize64 "$boot")" = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b vfat $G"
	mountroot "$new"
	check "fstab: it is /boot, no /boot/efi" sh -c "grep -q '^UUID=$(blkid -s UUID -o value "$boot") /boot vfat' '$W/r/@/etc/fstab' && ! grep -q ' /boot/efi ' '$W/r/@/etc/fstab'"
	check "no XBOOTLDR setting for Limine" sh -c "! grep -qs LIMINE_XBOOTLDR '$W/r/@/etc/default/ribbon-limine'"
	umount "$W/r"
fi

echo "ribbon-install --answers: manual"
inst "$(ans man "$base disk $LD mode manual manual {$m_esp $m_root $m_swap $m_data}")"
check "DONE" sh -c "tail -n1 '$W/out' | grep -qx DONE" || tail -n 4 "$W/out"
esp=$(sfdisk --dump "$LD" | awk -F'[ :,=]+' 'tolower($0) ~ /type=c12a7328/ {print $1}')
root=$(sfdisk --dump "$LD" | awk -v s=$(( (fs0 + G) / 512 )) -F'[ :,=]+' '{for (i = 1; i < NF; i++) if ($i == "start" && $(i+1) == s) print $1}')
swp=$(sfdisk --dump "$LD" | awk -F'[ :,=]+' 'tolower($0) ~ /type=0657fd6d/ {print $1}')
check "new ESP (FAT32, 1 GiB), / (btrfs), swap" test "$(blkid -p -s TYPE -o value "$esp") $(blockdev --getsize64 "$esp") $(blkid -p -s TYPE -o value "$root") $(blkid -p -s TYPE -o value "$swp")" = "vfat 1073741824 btrfs swap"
mountroot "${LD}p1"
check "the kept partition still holds Fedora" grep -q Fedora "$W/r/etc/os-release"
umount "$W/r"
mountroot "$root"
check "fstab: / btrfs" sh -c "grep -q '^UUID=$(blkid -s UUID -o value "$root") / btrfs noatime,compress=zstd:1,subvol=@ 0 0$' '$W/r/@/etc/fstab'"
check "fstab: /boot" sh -c "grep -q '^UUID=$(blkid -s UUID -o value "$esp") /boot vfat defaults,umask=0077 0 2$' '$W/r/@/etc/fstab'"
check "fstab: swap" sh -c "grep -q '^UUID=$(blkid -s UUID -o value "$swp") none swap defaults 0 0$' '$W/r/@/etc/fstab'"
check "fstab: the kept ext4 partition at /data, nofail" sh -c "grep -q '^UUID=$(blkid -s UUID -o value "${LD}p1") /data ext4 noatime,nofail 0 2$' '$W/r/@/etc/fstab'"
check "system copied" test -e "$W/r/@/usr/bin/tool1"
umount "$W/r"

echo "ribbon-install --answers: manual, deleting a partition (separate /home)"
inst "$(ans man2 "$base disk $LD mode manual manual {{dev ${LD}p1 delete 1} {new 1 disk $LD start 1048576 size $((4 * G)) format 1 fs btrfs mount /home} {dev $esp format 1 fs vfat mount /boot} {dev $root format 1 fs btrfs mount /}}")"
check "DONE" sh -c "tail -n1 '$W/out' | grep -qx DONE" || tail -n 5 "$W/out"
check "Fedora's partition was replaced by /home (btrfs)" test "$(blkid -p -s TYPE -o value "${LD}p1" 2>/dev/null)" = btrfs
mountroot "$root"
check "fstab: /home btrfs" sh -c "grep -q '^UUID=$(blkid -s UUID -o value "${LD}p1") /home btrfs noatime,compress=zstd:1 0 0$' '$W/r/@/etc/fstab'"
check "no @home subvolume next to a separate /home" test ! -e "$W/r/@home"
umount "$W/r"

echo "ribbon-install --answers: errors"
inst "$(ans bad "$base disk $MD mode erase")"
check "bad answers: ERROR line, exit != 0, nothing done" sh -c "tail -n1 '$W/out' | grep -q '^ERROR {.*install media'"
# ext4, XFS and F2FS for /: refused before anything happens, with one ERROR
# line, by the answers check and by the engine itself
one_error() { # exit status, then the text the ERROR line must hold
	[ "$1" -ne 0 ] && [ "$(grep -c '^ERROR' "$W/out")" = 1 ] && grep -q "^ERROR {.*$2" "$W/out" &&
		! grep -qE '^(STEP|DONE)' "$W/out" && lines_ok
}
table=$(sfdisk --dump "$ED")
for f in ext4 xfs f2fs; do
	inst "$(ans "bad-$f" "$base fs $f disk $ED mode erase")"; rc=$?
	check "answers with $f for /: one ERROR line, nothing done" one_error "$rc" "can't hold the system"
	RIBBON_INSTALL_SRC=$SRC RIBBON_INSTALL_TARGET=$W/target RIBBON_UEFI=yes \
		bash "$BIN/ribbon-install" --disk "$ED" --fs "$f" --user alex --yes --progress > "$W/out" 2>&1; rc=$?
	check "ribbon-install --fs $f: one ERROR line, nothing done" one_error "$rc" "can't hold the system"
done
check "the disk was not touched" test "$(sfdisk --dump "$ED")" = "$table"

# ---- the whole install: steps 4-6 -----------------------------------------
# Past the copy, with tests/installer-fake-chroot.sh standing in for chroot:
# the new system's own tools (postinstall, the initramfs, the boot loader)
# only log what they were asked to do, while the account tools act on the
# target's /etc the way shadow's do (useradd refuses a group it lacks).
# This base has no network or plugdev group.
echo "ribbon-install --answers: the whole install (steps 4-6, a stand-in for chroot)"
printf 'root:x:0:\nwheel:x:1:\naudio:x:12:\nvideo:x:13:\ninput:x:24:\nstorage:x:26:\nkvm:x:24:\n' > "$SRC/etc/group"
mkdir -p "$SRC/etc/default"
printf '#en_US.UTF-8 UTF-8\n#en_GB.UTF-8 UTF-8\n' > "$SRC/etc/default/libc-locales"
printf '#KEYMAP="es"\n' > "$SRC/etc/rc.conf"
CL=$W/chroot.log
FC=$REPO/tests/installer-fake-chroot.sh
check "the stand-in refuses a group the target lacks, as useradd does" sh -c "! FAKE_CHROOT_LOG='$W/fc.log' bash '$FC' '$SRC' /usr/bin/env -i PATH=/usr/bin useradd -m -G wheel,network bob 2>/dev/null"
whole() { # answers-file -> protocol output in $W/out, the chroot's commands in $CL
	: > "$CL"
	printf 'password "pw 1"\npassphrase "disk pass"\n' |
		RIBBON_INSTALL_SRC=$SRC RIBBON_INSTALL_TARGET=$W/target RIBBON_INSTALL_CHROOT=$FC FAKE_CHROOT_LOG=$CL RIBBON_UEFI=yes \
		RIBBON_PROBE_DISKS="$DISKS" RIBBON_PROBE_MEDIA="$MEDIA" RIBBON_PROBE_GEOIP=0 RIBBON_PROBE_TMP=$W/ptmp TMPDIR=$W \
		bash "$BIN/ribbon-install" --answers "$1" --secrets-stdin --progress > "$W/out" 2>&1
}
whole "$(ans whole "${base/\{mode zram\}/\{mode gaming\}} disk $ED mode erase")"
check "DONE, exit 0" sh -c "tail -n1 '$W/out' | grep -qx DONE" || tail -n 6 "$W/out"
check "only protocol lines" lines_ok
check "steps 1, 3, 4, 5 and 6 with their titles (no Encrypting)" sh -c "grep '^STEP' '$W/out' | tr '\n' '|' | grep -qx 'STEP 1 6 {Preparing the disk}|STEP 3 6 {Copying Ribbon}|STEP 4 6 {Setting up the system}|STEP 5 6 {Boot loader}|STEP 6 6 {Your account}|'"
check "percentages never go down, and reach 100" sh -c "grep '^PROGRESS' '$W/out' | awk '{if (\$2 < p) exit 1; p = \$2} END {exit p != 100}'"
check "nothing left mounted" sh -c "! findmnt -rno TARGET | grep -q '^$W/target'"
# the commands, in order, that would have run inside the new system
want="/usr/lib/ribbon/postinstall locale en_GB.UTF-8
dbus-uuidgen --ensure=/etc/machine-id
/usr/lib/ribbon/postinstall boot-choice limine
/usr/lib/ribbon/postinstall live-cleanup
/usr/lib/ribbon/postinstall services
/usr/lib/ribbon/postinstall security
/usr/lib/ribbon/postinstall grub-defaults
/usr/lib/ribbon/postinstall hardware
/usr/lib/ribbon/postinstall reserve
/usr/lib/ribbon/postinstall swap gaming
/usr/lib/ribbon/postinstall later steam com.discordapp.Discord
/usr/lib/ribbon/postinstall initramfs
/usr/lib/ribbon/postinstall bootloader $ED 1
useradd -m -s /bin/bash -c Alex Tyrone -G wheel,audio,video,storage,kvm alex
chpasswd
chpasswd: alex (4 characters)
passwd -l root
/usr/lib/ribbon/postinstall drives
/usr/lib/ribbon/postinstall snapshots"
cmds_ok() { # the log, without the GPU line (it depends on this machine's graphics)
	local got; got=$(grep -v '^/usr/lib/ribbon/postinstall gpu ' "$CL")
	[ "$got" = "$want" ] && return 0
	diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/    /'; return 1
}
check "the new system's commands, in order (groups it lacks left out)" cmds_ok
mountroot "${ED}p2"
check "hostname and hosts" sh -c "[ \"\$(cat '$W/r/@/etc/hostname')\" = alex-desktop ] && grep -qx '127.0.1.1 alex-desktop' '$W/r/@/etc/hosts'"
check "time zone" test "$(readlink "$W/r/@/etc/localtime")" = /usr/share/zoneinfo/Europe/London
# the locale itself is made inside the new system, through the package seam (tests/pkg-seam.sh)
check "locale: LANG, and nothing of the base's edited from outside" sh -c "grep -qx 'LANG=en_GB.UTF-8' '$W/r/@/etc/locale.conf' && grep -qx '#en_GB.UTF-8 UTF-8' '$W/r/@/etc/default/libc-locales'"
# the console keymap: /etc/vconsole.conf (any base); this base has no xbps, so Void's rc.conf is left as it was
check "console keymap in /etc/vconsole.conf; rc.conf (Void's place) untouched on a base without xbps" sh -c "grep -qx 'KEYMAP=uk' '$W/r/@/etc/vconsole.conf' && [ \"\$(cat '$W/r/@/etc/rc.conf')\" = '#KEYMAP=\"es\"' ]"
check "keyboard layout for the greeter and the desktop" sh -c "grep -q 'Option \"XkbLayout\" \"gb\"' '$W/r/@/etc/X11/xorg.conf.d/00-keyboard.conf' && grep -qx 'XKB_DEFAULT_LAYOUT=gb' '$W/r/@/etc/xdg/labwc/environment.d/10-keyboard.env'"
check "the account, its home in @home" sh -c "grep -qx 'alex:x:1000:1000::/home/alex:/bin/bash' '$W/r/@/etc/passwd' && [ -d '$W/r/@home/alex' ]"
# the hardware clock (step 5): Windows' boot manager is on another disk of this machine (the Windows disk's EFI
# partition), so Ribbon keeps the clock in local time as Windows does, and Limine gets a Windows entry
if [ -e "$W/r/@/etc/default/ribbon-limine" ] && grep -q '^LIMINE_WINDOWS_ESP=' "$W/r/@/etc/default/ribbon-limine"; then
	check "Windows on another disk: the hardware clock is local time (adjtime LOCAL, as Windows keeps it)" sh -c "[ \"\$(sed -n 3p '$W/r/@/etc/adjtime')\" = LOCAL ]"
else
	check "Windows on another disk is found (a Windows entry for Limine)" false
fi
umount "$W/r"
# a base without wheel: refused in step 6, with the reason, no account made
sed -i '/^wheel:/d' "$SRC/etc/group"
whole "$(ans whole "$base disk $ED mode erase")"
check "no wheel group: an ERROR line naming it, no account made" sh -c "tail -n1 '$W/out' | grep -q '^ERROR {.*no wheel group' && ! grep -q '^useradd' '$CL'"

# ---- a live system whose /usr is the system kits' view (ribbon-kit): nothing to copy for /usr, the target's own view
# is mounted for the steps in the new system (a stand-in for the boot hook, which binds a marked directory there)
echo "ribbon-install --answers: a system of kits (its /usr is a view)"
printf 'wheel:x:1:\n' >> "$SRC/etc/group"
rm -rf "${SRC:?}/usr"; mkdir -p "$SRC/usr" "$SRC/var/lib/kit/system/usr" "$W/viewtree/bin"
echo 1 > "$SRC/var/lib/kit/system/usr/current"; echo from-the-view > "$W/viewtree/bin/marker"
cat > "$W/hook" <<HOOK
echo "\$NEWROOT" >> "$W/hook.log"
[ -f "\$NEWROOT/var/lib/kit/system/usr/current" ] && mount --bind "$W/viewtree" "\$NEWROOT/usr"
findmnt -rno TARGET "\$NEWROOT/usr" >> "$W/hook.log"
HOOK
: > "$W/hook.log"
# (this install sees only its own disk: no Windows anywhere, so the hardware clock stays UTC)
alldisks=$DISKS; DISKS=$ED
RIBBON_USRVIEW_HOOK=$W/hook whole "$(ans whole "$base disk $ED mode erase")"
DISKS=$alldisks
check "DONE: the install runs with /usr as the target's own view" sh -c "tail -n1 '$W/out' | grep -qx DONE" || tail -n 6 "$W/out"
check "the hook was run on the target, and /usr was mounted there for the new system's steps" sh -c "[ \"\$(sed -n 1p '$W/hook.log')\" = '$W/target' ] && [ \"\$(sed -n 2p '$W/hook.log')\" = '$W/target/usr' ] && grep -q '^LOG.*Mounting the new system' '$W/out'"
check "nothing left mounted, the view included" sh -c "! findmnt -rno TARGET | grep -q '^$W/target'"
mountroot "${ED}p2"
check "the installed root holds the view's files and an empty /usr (the view is mounted at boot)" sh -c "[ -f '$W/r/@/var/lib/kit/system/usr/current' ] && [ -d '$W/r/@/usr' ] && [ -z \"\$(ls -A '$W/r/@/usr')\" ]"
check "no Windows on the machine: no adjtime (the hardware clock is UTC) and no Windows entry for Limine" sh -c "[ ! -e '$W/r/@/etc/adjtime' ] && ! grep -qs '^LIMINE_WINDOWS_ESP=' '$W/r/@/etc/default/ribbon-limine'"
umount "$W/r"
RIBBON_USRVIEW_HOOK=$W/no-such-hook whole "$(ans whole "$base disk $ED mode erase")"
check "no hook to mount the view with: an ERROR line saying so, not a system set up without its /usr" sh -c "tail -n1 '$W/out' | grep -q '^ERROR {.*is not here to mount it' && ! grep -q '^useradd' '$CL'"

[ $fail -eq 0 ] && echo "installer disk tests: all checks passed"
exit $fail
