#!/bin/sh
# pre-pivot hook (Ribbon OS): boot a read-only snapshot with a tmpfs overlay on
# top, so the system can write (logs, NetworkManager, ...) without touching the
# snapshot (changes vanish at reboot; `ribbon rollback` makes one permanent),
# and keep the boot try counter (docs/SYSTEM-UPDATES.md §5.5, §7.8: D62 A).
#
# A snapshot is booted when
#   - the menu entry says so: rootflags=subvol=@snapshots/<N>/snapshot (btrfs,
#     from ribbon-limine or grub-btrfs), or ribbon.snapshot=<id> (btrfs: snapper
#     number; bcachefs: the name under /.snapshots), or
#   - the try counter ran out: `ribbon-snapshot arm` (run by `ribbon update`)
#     writes <the root's /boot>/ribbon/trying on the EFI (FAT) partition:
#         tries=3  snapshot=<id>  state=trying
#     Each boot of the normal entry takes one try before switching root;
#     ribbon-boot-ok removes the file once the login screen or the desktop is
#     up. A boot that finds tries=0 (that many boots never got there) sets
#     state=fallback and starts the snapshot instead; every later boot does the
#     same until `ribbon rollback` or `ribbon-snapshot retry`. This lives here,
#     not in the boot loader, because Limine has no boot counting (and so it
#     works the same with GRUB). ribbon.fallback=0 on the command line skips it
#     for one boot.
# What the boot did is written to /run/ribbon (snapshot-boot, boot-try) and to
# the kernel log ("ribbon-boot: ...").
# Tests: RIBBON_RUN, RIBBON_OVERLAY, RIBBON_ESP_MNT, RIBBON_KMSG, RIBBON_MOUNTS,
# RIBBON_KVER, RIBBON_DEV_ANY (tests/test-boot-fallback.sh).
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

rb_run=${RIBBON_RUN:-/run/ribbon}
rb_ov=${RIBBON_OVERLAY:-/run/ribbon-overlay}
rb_esp=${RIBBON_ESP_MNT:-/run/ribbon-esp}
rb_kmsg=${RIBBON_KMSG:-/dev/kmsg}

# notice level, so it reaches the console at the usual loglevel
rb_say() { echo "<5>ribbon-boot: $*" >> "$rb_kmsg" 2>/dev/null; }

# The value of KEY= in a counter file, only if it is a plain word.
# (Only the shell and what dracut's base module installs: no tail or cat.)
rb_get() { sed -n "s/^$1=\([A-Za-z0-9._-]*\)[[:space:]]*\$/\1/p" "$2" 2>/dev/null | sed -n '$p'; }

rb_write_counter() { # file tries snapshot state
	{
		echo "# Ribbon OS boot try counter (ribbon-snapshot arm; docs/SYSTEM-UPDATES.md 7.8)"
		echo "tries=$2"
		echo "snapshot=$3"
		echo "state=$4"
	} > "$1.new" && mv -f "$1.new" "$1"
}

# The source and type of what is mounted at $NEWROOT.
rb_root_mount() {
	rb_rdev='' rb_rfs=''
	while read -r d m t _; do
		[ "$m" = "$NEWROOT" ] && { rb_rdev=$d; rb_rfs=$t; }
	done < "${RIBBON_MOUNTS:-/proc/self/mounts}"
}

# The device field, type and options of an fstab entry (mount point $2) in $1.
rb_fstab() {
	rb_fs_dev='' rb_fs_type='' rb_fs_opts=''
	[ -r "$1" ] || return 1
	while read -r d m t o _; do
		case "$d" in ''|\#*) continue ;; esac
		[ "$m" = "$2" ] && { rb_fs_dev=$d; rb_fs_type=$t; rb_fs_opts=$o; return 0; }
	done < "$1"
	return 1
}

rb_dev() {
	case "$1" in
		UUID=*|LABEL=*|PARTUUID=*|PARTLABEL=*) label_uuid_to_dev "$1" ;;
		*) echo "$1" ;;
	esac
}

# Wait up to 5 s for a block device (it is usually there with the root).
# (RIBBON_DEV_ANY=1: any existing path will do; tests only)
rb_isdev() { [ -b "$1" ] || { [ -n "${RIBBON_DEV_ANY:-}" ] && [ -e "$1" ]; }; }
rb_wait_dev() {
	i=0
	while ! rb_isdev "$1" && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
	rb_isdev "$1"
}

# Sets rb_mode=fallback and rb_snap when the counter has run out.
rb_counter() {
	[ "$(getarg ribbon.fallback=)" = 0 ] && return 0
	# the EFI (FAT) partition: at /boot (Ribbon's layout), or at /boot/efi
	# with /boot on the root (GRUB); ribbon-snapshot looks in the same order
	rb_fstab "$NEWROOT/etc/fstab" /boot && [ "$rb_fs_type" = vfat ] ||
		{ rb_fstab "$NEWROOT/etc/fstab" /boot/efi && [ "$rb_fs_type" = vfat ]; } || return 0
	dev=$(rb_dev "$rb_fs_dev")
	[ -n "$dev" ] && rb_wait_dev "$dev" || return 0
	mkdir -p "$rb_esp"
	mount -t vfat -o rw,noatime "$dev" "$rb_esp" 2>/dev/null || return 0
	f=$rb_esp/ribbon/trying
	if [ -f "$f" ]; then
		tries=$(rb_get tries "$f") id=$(rb_get snapshot "$f") state=$(rb_get state "$f")
		case "$tries" in ''|*[!0-9]*) tries=0 ;; esac
		mkdir -p "$rb_run"
		if [ "$state" = fallback ] || [ "$tries" -le 0 ]; then
			if [ -n "$id" ]; then
				[ "$state" = fallback ] || rb_write_counter "$f" 0 "$id" fallback
				rb_mode=fallback rb_snap=$id
				rb_say "the updated system did not reach the login screen; starting snapshot $id"
			else
				rb_say "the updated system did not reach the login screen, and no snapshot is recorded to fall back to"
			fi
		else
			tries=$((tries - 1))
			rb_write_counter "$f" "$tries" "$id" trying
			echo "$tries" > "$rb_run/boot-try"
			rb_say "trying the updated system ($tries tries left after this one)"
		fi
	fi
	umount "$rb_esp" 2>/dev/null
	return 0
}

# Put the overlay on $NEWROOT. menu: the root dracut mounted is the snapshot.
# snapshot|fallback: the root is the normal system; mount snapshot $rb_snap.
rb_overlay() {
	mkdir -p "$rb_ov" && mount -t tmpfs -o mode=0755 ribbon-overlay "$rb_ov" || return 1
	mkdir -p "$rb_ov/lower" "$rb_ov/upper" "$rb_ov/work" "$rb_ov/cur"
	if [ "$rb_mode" = menu ]; then
		mount --move "$NEWROOT" "$rb_ov/lower" || { umount "$rb_ov"; return 1; }
		lower=$rb_ov/lower back=$rb_ov/lower
	else
		case "$rb_snap" in ''|*[!A-Za-z0-9._-]*|.*) rb_say "not a snapshot name: $rb_snap"; umount "$rb_ov"; return 1 ;; esac
		rb_root_mount
		mount --move "$NEWROOT" "$rb_ov/cur" || { umount "$rb_ov"; return 1; }
		back=$rb_ov/cur lower=
		case "$rb_rfs" in
			btrfs)
				rb_fstab "$rb_ov/cur/etc/fstab" /.snapshots
				sub=$(echo ",$rb_fs_opts," | sed -n 's/.*,subvol=\/\{0,1\}\([^,]*\),.*/\1/p')
				mount -t btrfs -o "ro,subvol=${sub:-@snapshots}/$rb_snap/snapshot" "$rb_rdev" "$rb_ov/lower" && lower=$rb_ov/lower
				;;
			bcachefs)
				[ -d "$rb_ov/cur/.snapshots/$rb_snap" ] && lower=$rb_ov/cur/.snapshots/$rb_snap
				;;
		esac
		if [ -z "$lower" ]; then
			rb_say "snapshot $rb_snap could not be mounted ($rb_rfs); starting the normal system"
			mount --move "$rb_ov/cur" "$NEWROOT"; umount "$rb_ov"
			return 1
		fi
	fi
	if ! mount -t overlay -o "lowerdir=$lower,upperdir=$rb_ov/upper,workdir=$rb_ov/work" overlay "$NEWROOT"; then
		rb_say "overlay failed; starting the root as it is"
		[ "$back" = "$rb_ov/cur" ] && umount "$rb_ov/lower" 2>/dev/null
		mount --move "$back" "$NEWROOT"
		return 1
	fi
	if [ "$rb_mode" != menu ]; then
		# The running kernel's modules, when the snapshot has none for it
		# (a snapshot from before a kernel update).
		kver=${RIBBON_KVER:-}
		[ -n "$kver" ] || read -r kver < /proc/sys/kernel/osrelease
		if [ ! -d "$lower/usr/lib/modules/$kver" ] && [ -d "$rb_ov/cur/usr/lib/modules/$kver" ]; then
			mkdir -p "$NEWROOT/usr/lib/modules/$kver" &&
				mount --bind "$rb_ov/cur/usr/lib/modules/$kver" "$NEWROOT/usr/lib/modules/$kver"
		fi
		# bcachefs keeps /home and the snapshots in the root filesystem itself:
		# give the snapshot the live ones, so nothing a person saves is lost.
		if [ "$rb_rfs" = bcachefs ]; then
			for d in home .snapshots; do
				[ -d "$rb_ov/cur/$d" ] || continue
				mkdir -p "$NEWROOT/$d" && mount --bind "$rb_ov/cur/$d" "$NEWROOT/$d"
			done
		fi
	fi
	mkdir -p "$rb_run"
	printf 'mode=%s\nsnapshot=%s\nflags=%s\n' "$rb_mode" "$rb_snap" "$rb_flags" > "$rb_run/snapshot-boot"
	rb_say "booted ${rb_snap:+snapshot $rb_snap }($rb_mode) with a temporary writable overlay"
	return 0
}

rb_flags=$(getarg rootflags=)
rb_mode='' rb_snap=''
case "$rb_flags" in
	*subvol=@snapshots/*|*subvol=/@snapshots/*|*subvol=.snapshots/*|*subvol=/.snapshots/*) rb_mode=menu ;;
esac
if [ -z "$rb_mode" ]; then
	rb_snap=$(getarg ribbon.snapshot=)
	if [ -n "$rb_snap" ]; then rb_mode=snapshot; else rb_counter; fi
fi
[ -n "$rb_mode" ] && rb_overlay
:
