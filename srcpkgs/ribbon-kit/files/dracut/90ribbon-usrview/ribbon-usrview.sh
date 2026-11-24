#!/bin/sh
# pre-pivot hook (Ribbon OS): mount the merged erofs /usr view of the system kits on the new root's /usr
# (docs/SYSTEM-UPDATES.md 7.2, D57 C / D58 B), what ::kit::mount::restore does once the system runs.
#
# kitd keeps the views in <root>/var/lib/kit/system/usr (srcpkgs/ribbon-kit/files/lib/mount.tcl):
#   current               the number N of the view /usr shows
#   view-N.erofs          the view's metadata image
#   view-N.erofs.devices  its kits' images, in the order mkfs.erofs took them:
#                           ribbon-usr-view 1
#                           kit <TAB> PATH <TAB> OFFSET <TAB> LENGTH <TAB> ROOT <TAB> NAME <TAB> VERSION
# Each kit's image is attached read-only as a loop device at its sealed offset (losetup -r -o OFFSET --sizelimit
# LENGTH), the view is mounted with them as its devices (mount -t erofs -o ro,device=L1,device=L2,...), and the loop
# devices are detached again at once (autoclear: the mount keeps them until it goes).  Nothing is mounted unless
# every line is sound and every device attaches; then /usr stays what is on the root, and the kernel log says why.
# What the boot did goes to /run/ribbon/usr-view ("N", or "none: WHY") and to the kernel log ("ribbon-boot: ...").
# Tests: RIBBON_RUN, RIBBON_KMSG (tests/kit-usrview-initramfs.sh, on a fake root with stand-in losetup and mount).

rbu_run=${RIBBON_RUN:-/run/ribbon}
rbu_kmsg=${RIBBON_KMSG:-/dev/kmsg}
rbu_top=${NEWROOT:-/sysroot}
rbu_tab=$(printf '\t')

rbu_say() { echo "<5>ribbon-boot: $*" >> "$rbu_kmsg" 2>/dev/null; }
rbu_record() { mkdir -p "$rbu_run" 2>/dev/null && echo "$1" > "$rbu_run/usr-view" 2>/dev/null; }

# a whole number, without a sign or leading zeros (as mount.tcl writes them)
rbu_num() { case $1 in ''|*[!0-9]*|0?*) return 1 ;; esac; return 0; }

rbu_usrview() {
	rbu_dir=$rbu_top/var/lib/kit/system/usr
	[ -f "$rbu_dir/current" ] || return 0
	rbu_n=$(sed -n '1s/^\([0-9][0-9]*\)$/\1/p' "$rbu_dir/current")
	if ! rbu_num "$rbu_n"; then rbu_say "/usr view: $rbu_dir/current holds no view number; /usr is left as it is"; rbu_record "none: no view number"; return 0; fi
	rbu_view=$rbu_dir/view-$rbu_n.erofs
	if [ ! -f "$rbu_view" ] || [ ! -f "$rbu_view.devices" ]; then
		rbu_say "/usr view $rbu_n: its files are missing; /usr is left as it is"; rbu_record "none: view $rbu_n is missing"; return 0
	fi
	# check every line before anything is attached
	rbu_first=1 rbu_count=0
	while IFS= read -r rbu_line || [ -n "$rbu_line" ]; do
		if [ "$rbu_first" = 1 ]; then
			rbu_first=0
			[ "$rbu_line" = "ribbon-usr-view 1" ] && continue
			rbu_say "/usr view $rbu_n: not a view's device list; /usr is left as it is"; rbu_record "none: view $rbu_n has no device list"; return 0
		fi
		IFS=$rbu_tab read -r rbu_tag rbu_path rbu_off rbu_len _ rbu_name rbu_version rbu_extra <<-EOT
		$rbu_line
		EOT
		if [ "$rbu_tag" != kit ] || [ -n "$rbu_extra" ] || [ -z "$rbu_version" ] || ! rbu_num "$rbu_off" || ! rbu_num "$rbu_len"; then
			rbu_say "/usr view $rbu_n: a bad line in its device list; /usr is left as it is"; rbu_record "none: view $rbu_n has a bad line"; return 0
		fi
		case $rbu_path in
			/*) ;;
			*) rbu_say "/usr view $rbu_n: $rbu_name's path is not absolute; /usr is left as it is"; rbu_record "none: view $rbu_n has a bad path"; return 0 ;;
		esac
		case /$rbu_path/ in
			*/../*|*/./*) rbu_say "/usr view $rbu_n: $rbu_name's path is not plain; /usr is left as it is"; rbu_record "none: view $rbu_n has a bad path"; return 0 ;;
		esac
		if [ ! -f "$rbu_top$rbu_path" ]; then
			rbu_say "/usr view $rbu_n: $rbu_name ($rbu_path) is missing; /usr is left as it is"; rbu_record "none: $rbu_name is missing"; return 0
		fi
		rbu_count=$((rbu_count + 1))
	done < "$rbu_view.devices"
	if [ "$rbu_count" = 0 ]; then rbu_say "/usr view $rbu_n: it names no kit; /usr is left as it is"; rbu_record "none: view $rbu_n names no kit"; return 0; fi
	# loop and erofs are modules in the kernel (the initramfs carries them: module-setup.sh's instmods); /dev/loop-control
	# and the erofs driver only exist once they are loaded. Quiet: built in is fine, and a failure shows as the attach's.
	if command -v modprobe >/dev/null 2>&1; then modprobe -a -q loop erofs 2>/dev/null || :; fi
	# attach them in order
	rbu_devs='' rbu_opts=ro
	rbu_first=1
	while IFS= read -r rbu_line || [ -n "$rbu_line" ]; do
		if [ "$rbu_first" = 1 ]; then rbu_first=0; continue; fi
		IFS=$rbu_tab read -r _ rbu_path rbu_off rbu_len _ rbu_name _ <<-EOT
		$rbu_line
		EOT
		if ! rbu_dev=$(losetup --find --show --read-only --offset "$rbu_off" --sizelimit "$rbu_len" "$rbu_top$rbu_path") || [ -z "$rbu_dev" ]; then
			rbu_say "/usr view $rbu_n: $rbu_name's image could not be attached; /usr is left as it is"
			for rbu_d in $rbu_devs; do losetup -d "$rbu_d" 2>/dev/null; done
			rbu_record "none: $rbu_name could not be attached"
			return 0
		fi
		rbu_devs="$rbu_devs $rbu_dev"
		rbu_opts="$rbu_opts,device=$rbu_dev"
	done < "$rbu_view.devices"
	# the view's own image as a loop device too, attached here: given the file, mount (util-linux 2.41 and later) no
	# longer makes one for erofs, the kernel then reads the file itself (CONFIG_EROFS_FS_BACKED_BY_FILE), and in that
	# mode it refuses devices that are not files: the kits are block devices (their images lie at an offset in a .kit)
	if ! rbu_vdev=$(losetup --find --show --read-only "$rbu_view") || [ -z "$rbu_vdev" ]; then
		rbu_say "/usr view $rbu_n: its image could not be attached; /usr is left as it is"
		for rbu_d in $rbu_devs; do losetup -d "$rbu_d" 2>/dev/null; done
		rbu_record "none: view $rbu_n could not be attached"
		return 0
	fi
	rbu_devs="$rbu_devs $rbu_vdev"
	mkdir -p "$rbu_top/usr" 2>/dev/null
	if mount -t erofs -o "$rbu_opts" "$rbu_vdev" "$rbu_top/usr"; then
		rbu_say "/usr is view $rbu_n ($rbu_count system kits)"
		rbu_record "$rbu_n"
	else
		rbu_say "/usr view $rbu_n could not be mounted; /usr is left as it is"
		rbu_record "none: view $rbu_n could not be mounted"
	fi
	# the mount holds what it uses; the devices go when it goes (or now, when it did not mount)
	for rbu_d in $rbu_devs; do losetup -d "$rbu_d" 2>/dev/null; done
	return 0
}

rbu_usrview
