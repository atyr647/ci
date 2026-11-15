#!/bin/sh
# /usr/lib/ribbon/boot.sh <step> - early boot steps for Ribbon OS under dinit.
#
# Each step is one dinit "scripted" service in /usr/lib/dinit.d/early-*.
# The logic follows Void's runit core-services (void-runit, CC0-1.0) so that
# /etc/rc.conf, /etc/crypttab, /etc/fstab, /etc/modules-load.d etc. behave
# exactly as they do on stock Void. Differences are marked "Ribbon:".

PATH=/usr/bin:/usr/sbin:/bin:/sbin
export PATH

[ -r /etc/rc.conf ] && . /etc/rc.conf
# Ribbon: the console's keymap and font come from /etc/vconsole.conf on every base (the freedesktop file, which
# the installer writes and dracut's i18n module reads too); rc.conf's own (Void's way) only where it has none.
if [ -r /etc/vconsole.conf ]; then
	_v=$(sed -n 's/^[[:space:]]*\(KEYMAP\|FONT\|FONT_MAP\|FONT_UNIMAP\)=["'"'"']\{0,1\}\([^"'"'"'[:space:]]*\).*/\1=\2/p' /etc/vconsole.conf)
	for _kv in $_v; do
		[ -n "${_kv#*=}" ] || continue
		case "${_kv%%=*}" in
			KEYMAP) KEYMAP=${_kv#*=} ;;
			FONT) FONT=${_kv#*=} ;;
			FONT_MAP) FONT_MAP=${_kv#*=} ;;
			FONT_UNIMAP) FONT_UNIMAP=${_kv#*=} ;;
		esac
	done
	unset _v _kv
fi

msg()      { printf '\033[1m=> %s\033[m\n' "$*"; }
msg_warn() { printf '\033[1m\033[33mWARNING: %s\033[m\n' "$*"; }
msg_err()  { printf '\033[1m\033[31mERROR: %s\033[m\n' "$*"; }

is_container() {
	[ -n "${container+x}" ] || [ -e /.dockerenv ]
}

have() { command -v "$1" >/dev/null 2>&1; }

cmdline_has() {
	for _a in $(cat /proc/cmdline); do
		[ "$_a" = "$1" ] && return 0
	done
	return 1
}

step_pseudofs() {
	msg "Mounting pseudo-filesystems..."
	mountpoint -q /proc || mount -o nosuid,noexec,nodev -t proc proc /proc
	mountpoint -q /sys  || mount -o nosuid,noexec,nodev -t sysfs sys /sys
	mountpoint -q /run  || mount -o mode=0755,nosuid,nodev -t tmpfs run /run
	mountpoint -q /dev  || mount -o mode=0755,nosuid -t devtmpfs dev /dev
	mkdir -p /run/lvm /run/user /run/lock /run/log /run/ribbon /dev/pts /dev/shm
	mountpoint -q /dev/pts || mount -o mode=0620,gid=5,nosuid,noexec -n -t devpts devpts /dev/pts
	mountpoint -q /dev/shm || mount -o mode=1777,nosuid,nodev -n -t tmpfs shm /dev/shm
	mountpoint -q /sys/kernel/security || mount -n -t securityfs securityfs /sys/kernel/security 2>/dev/null

	if [ -d /sys/firmware/efi/efivars ]; then
		mountpoint -q /sys/firmware/efi/efivars ||
			mount -o nosuid,noexec,nodev -t efivarfs efivarfs /sys/firmware/efi/efivars
	fi

	if ! is_container; then
		# cgroup v2 only (elogind, gamemode and sched_ext all work with it).
		mkdir -p /sys/fs/cgroup
		mountpoint -q /sys/fs/cgroup || mount -t cgroup2 -o nsdelegate cgroup2 /sys/fs/cgroup
		# Ribbon: sched_ext schedulers need debugfs and bpffs.
		mountpoint -q /sys/kernel/debug || mount -o nosuid,noexec,nodev -t debugfs debugfs /sys/kernel/debug 2>/dev/null
		mountpoint -q /sys/fs/bpf || mount -o nosuid,noexec,nodev,mode=0700 -t bpf bpf /sys/fs/bpf 2>/dev/null
	fi
	return 0
}

step_kmods() {
	is_container && return 0
	[ -e /proc/modules ] || return 0
	# Modules that must exist before udev starts.
	for f in $(kmod static-nodes -f devname 2>/dev/null | cut -d' ' -f1); do
		modprobe -bq "$f" 2>/dev/null
	done
	msg "Loading kernel modules..."
	if have modules-load; then
		modules-load -v | tr '\n' ' ' | sed 's:insmod [^ ]*/::g; s:\.ko\(\.[gx]z\|\.zst\)\? ::g'
		echo
	fi
	return 0
}

step_console() {
	is_container && return 0
	TTYS=${TTYS:-12}
	if [ -n "$FONT" ]; then
		msg "Setting up TTYs font to '${FONT}'..."
		_i=0
		while [ "$_i" -le "$TTYS" ]; do
			setfont ${FONT_MAP:+-m $FONT_MAP} ${FONT_UNIMAP:+-u $FONT_UNIMAP} "$FONT" -C "/dev/tty${_i}" 2>/dev/null
			_i=$((_i + 1))
		done
	fi
	if [ -n "$KEYMAP" ]; then
		msg "Setting up keymap to '${KEYMAP}'..."
		loadkeys -q -u "$KEYMAP"
	fi
	if [ -n "$HARDWARECLOCK" ]; then
		msg "Setting up RTC to '${HARDWARECLOCK}'..."
		TZ=$TIMEZONE hwclock --systz --"$(echo "$HARDWARECLOCK" | tr 'A-Z' 'a-z')" --noadjfile
	fi
	return 0
}

step_devices() {
	is_container && return 0
	if have dmraid; then
		msg "Activating dmraid devices..."
		dmraid -i -ay
	fi
	if have mdadm; then
		msg "Activating software RAID arrays..."
		mdadm -As
	fi
	if have btrfs; then
		msg "Activating btrfs devices..."
		btrfs device scan
	fi
	if have bcachefs; then
		# Ribbon: multi-device bcachefs needs no scan, but make sure the module is there.
		modprobe -q bcachefs 2>/dev/null
	fi
	if have vgchange; then
		msg "Activating LVM devices..."
		vgchange --sysinit -a ay
	fi
	if [ -e /etc/crypttab ] && grep -qv '^\s*\(#\|$\)' /etc/crypttab; then
		msg "Activating encrypted devices..."
		awk -f /usr/lib/ribbon/crypt.awk /etc/crypttab
		if have vgchange; then
			vgchange --sysinit -a ay
		fi
	fi
	if have zpool && have zfs; then
		if [ -e /etc/zfs/zpool.cache ]; then
			msg "Importing cached ZFS pools..."
			zpool import -N -a -c /etc/zfs/zpool.cache
		else
			msg "Scanning for and importing ZFS pools..."
			zpool import -N -a -o cachefile=none
		fi
		msg "Mounting ZFS file systems..."
		zfs mount -a -l
	fi
	return 0
}

step_filesystems() {
	is_container && return 0
	FASTBOOT='' FORCEFSCK=''
	[ -f /fastboot ] && FASTBOOT=1
	[ -f /forcefsck ] && FORCEFSCK="-f"
	cmdline_has fastboot && FASTBOOT=1
	cmdline_has forcefsck && FORCEFSCK="-f"

	if [ -z "$FASTBOOT" ]; then
		msg "Checking filesystems:"
		fsck -A -T -a -t noopts=_netdev $FORCEFSCK
		if [ $? -gt 1 ]; then
			msg_err "filesystem check failed; boot will continue into recovery"
			return 1
		fi
	fi

	msg "Mounting rootfs read-write..."
	LIBMOUNT_FORCE_MOUNT2=always mount -o remount,rw / || return 1

	msg "Mounting all non-network filesystems..."
	# Ribbon: game drives are added with "nofail", so a missing or
	# unplugged drive never stops the boot (see ribbon-drives).
	mount -a -t "nosysfs,nonfs,nonfs4,nosmbfs,nocifs" -O no_netdev || return 1
	return 0
}

step_swap() {
	is_container && return 0
	msg "Initializing swap..."
	if [ -x /usr/bin/ribbon-swap ]; then
		/usr/bin/ribbon-swap boot
	fi
	swapon -a
	return 0
}

step_sysctl() {
	have sysctl || return 0
	msg "Loading sysctl(8) settings..."
	mkdir -p /run/vsysctl.d
	for i in /run/sysctl.d/*.conf /etc/sysctl.d/*.conf \
		/usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf; do
		if [ -e "$i" ] && [ ! -e "/run/vsysctl.d/${i##*/}" ]; then
			ln -s "$i" "/run/vsysctl.d/${i##*/}"
		fi
	done
	for i in /run/vsysctl.d/*.conf; do
		[ -e "$i" ] && sysctl -q -p "$i"
	done
	rm -rf -- /run/vsysctl.d
	[ -e /etc/sysctl.conf ] && sysctl -q -p /etc/sysctl.conf
	return 0
}

step_misc() {
	install -m0664 -o root -g utmp /dev/null /run/utmp
	[ -x /usr/libexec/ribbon/halt ] && /usr/libexec/ribbon/halt -B   # wtmp boot record

	if ! is_container && have seedrng; then
		msg "Seeding random number generator..."
		seedrng || :
	fi

	ip link set up dev lo

	[ -r /etc/hostname ] && read -r HOSTNAME < /etc/hostname
	if [ -n "$HOSTNAME" ]; then
		msg "Setting up hostname to '${HOSTNAME}'..."
		printf "%s" "$HOSTNAME" > /proc/sys/kernel/hostname
	else
		msg_warn "Didn't setup a hostname!"
	fi

	if [ -n "$TIMEZONE" ]; then
		ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
	fi

	# dbus and elogind both want a machine id.
	have dbus-uuidgen && dbus-uuidgen --ensure=/etc/machine-id
	mkdir -p /var/lib/dbus
	[ -e /var/lib/dbus/machine-id ] || ln -sf /etc/machine-id /var/lib/dbus/machine-id

	mkdir -p /var/log/dinit
	dmesg > /var/log/dmesg.log
	if [ "$(sysctl -n kernel.dmesg_restrict 2>/dev/null)" = 1 ]; then
		chmod 0600 /var/log/dmesg.log
	else
		chmod 0644 /var/log/dmesg.log
	fi

	[ -e /var/log/wtmp ] || install -m0664 -o root -g utmp /dev/null /var/log/wtmp
	[ -e /var/log/btmp ] || install -m0600 -o root -g utmp /dev/null /var/log/btmp
	[ -e /var/log/lastlog ] || install -m0600 -o root -g utmp /dev/null /var/log/lastlog
	install -dm1777 /tmp/.X11-unix /tmp/.ICE-unix
	rm -f /etc/nologin /forcefsck /forcequotacheck /fastboot
	[ -x /etc/rc.local ] && /etc/rc.local
	return 0
}

step_apparmor() {
	# AppArmor is enabled by the installer by adding "apparmor=1 security=apparmor"
	# to the kernel command line. Mode comes from /etc/default/apparmor
	# (APPARMOR=complain|enforce|disable), like Void's runit-void-apparmor.
	[ -d /sys/kernel/security/apparmor ] || return 0
	have apparmor_parser || return 0
	APPARMOR=complain
	[ -r /etc/default/apparmor ] && . /etc/default/apparmor
	case "$APPARMOR" in
		enforce) _flag= ;;
		complain) _flag=-C ;;
		*) return 0 ;;
	esac
	msg "Loading AppArmor profiles ($APPARMOR)..."
	for p in /etc/apparmor.d/*; do
		[ -f "$p" ] && apparmor_parser -a $_flag "$p" >/dev/null 2>&1
	done
	return 0
}

case "$1" in
	pseudofs|kmods|console|devices|filesystems|swap|sysctl|misc|apparmor)
		"step_$1"
		;;
	*)
		echo "usage: $0 {pseudofs|kmods|console|devices|filesystems|swap|sysctl|misc|apparmor}" >&2
		exit 2
		;;
esac
