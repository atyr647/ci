# /usr/lib/ribbon/common.sh - shared helpers for Ribbon OS tools (bash).

RIBBON_CONF=${RIBBON_CONF:-/etc/ribbon/ribbon.conf}
RIBBON_ROOT=${RIBBON_ROOT:-}          # set to a mount point to act on a target system
[ -r "${RIBBON_ROOT}${RIBBON_CONF}" ] && . "${RIBBON_ROOT}${RIBBON_CONF}"
# The package manager, behind one seam (pkg_install, pkg_query, ...).
. "$(dirname "${BASH_SOURCE[0]}")/pkg.sh"

if [ -t 1 ]; then
	_b=$'\033[1m' _r=$'\033[31m' _g=$'\033[32m' _y=$'\033[33m' _n=$'\033[0m'
else
	_b= _r= _g= _y= _n=
fi

msg()  { printf '%s==>%s %s\n' "$_b" "$_n" "$*"; }
ok()   { printf '%s ok%s  %s\n' "$_g" "$_n" "$*"; }
warn() { printf '%swarn%s %s\n' "$_y" "$_n" "$*" >&2; }
err()  { printf '%serror%s %s\n' "$_r" "$_n" "$*" >&2; }
die()  { err "$*"; exit 1; }

need_root() {
	[ "$(id -u)" -eq 0 ] || die "this needs root (try: sudo $0 $*)"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Run a command in the target root if RIBBON_ROOT is set (installer use).
in_root() {
	if [ -n "$RIBBON_ROOT" ]; then
		chroot "$RIBBON_ROOT" "$@"
	else
		"$@"
	fi
}

root_fstype() {
	findmnt -no FSTYPE "${RIBBON_ROOT:-/}" 2>/dev/null | head -n1
}

# btrfs: a swap file, and ribbon-reserve's spare file, must not live in a subvolume that snapshots take (an active swap file
# blocks the snapshot; a snapshot pins the file's extents, so deleting the spare frees nothing). /swap is its own
# subvolume: the installer's @swap mounted there, or, on a layout without it, one made here inside the root's (a nested
# subvolume is left out of the root's snapshots). Other filesystems: nothing to do. Returns 1, saying why, when it cannot.
ensure_swap_subvol() {
	local d=${RIBBON_ROOT}/swap
	[ "$(root_fstype)" = btrfs ] || return 0
	if mountpoint -q "$d" 2>/dev/null || btrfs subvolume show "$d" >/dev/null 2>&1; then return 0; fi
	if [ -e "$d" ] || [ -L "$d" ]; then
		rmdir "$d" 2>/dev/null || { err "$d is not a btrfs subvolume and is not an empty folder: move it away first"; return 1; }
	fi
	btrfs subvolume create "$d" >/dev/null 2>&1 || { err "could not make the btrfs subvolume $d"; return 1; }
	chattr +C "$d" 2>/dev/null   # files made in it later are NOCOW, as a swap file needs
	return 0
}

# Set KEY=VALUE in a shell-style config file (creates it if missing).
conf_set() {
	local file=$1 key=$2 val=$3
	mkdir -p "$(dirname "$file")"
	touch "$file"
	if grep -q "^${key}=" "$file"; then
		sed -i "s|^${key}=.*|${key}=${val}|" "$file"
	else
		printf '%s=%s\n' "$key" "$val" >> "$file"
	fi
}

# Boot settings shared by every boot loader: BOOTLOADER and the kernel flags
# (RIBBON_CMDLINE, RIBBON_CMDLINE_EXTRA). Systems installed before
# /etc/default/ribbon-boot existed keep the flags in ribbon-grub.
boot_conf() {
	if [ -e "${RIBBON_ROOT}/etc/default/ribbon-boot" ] || [ ! -e "${RIBBON_ROOT}/etc/default/ribbon-grub" ]; then
		echo "${RIBBON_ROOT}/etc/default/ribbon-boot"
	else
		echo "${RIBBON_ROOT}/etc/default/ribbon-grub"
	fi
}

# The boot loader in use: limine | grub | zfsbootmenu | none. The installer
# records it as BOOTLOADER in /etc/default/ribbon-boot; older systems are
# recognised by their files.
boot_loader() {
	local bl
	bl=$(sed -n 's/^BOOTLOADER="\{0,1\}\([a-z]*\)"\{0,1\}[[:space:]]*$/\1/p' "${RIBBON_ROOT}/etc/default/ribbon-boot" 2>/dev/null | tail -n1)
	if [ -z "$bl" ]; then
		if [ -e "${RIBBON_ROOT}/etc/zfsbootmenu/config.yaml" ]; then bl=zfsbootmenu
		elif [ -e "${RIBBON_ROOT}/etc/default/ribbon-limine" ]; then bl=limine
		elif [ -e "${RIBBON_ROOT}/boot/grub/grub.cfg" ]; then bl=grub
		else bl=none
		fi
	fi
	echo "$bl"
}

# Kernel flags that find and mount the root filesystem, worked out from the
# mounted system: root=UUID=... rootfstype=... [rootflags=subvol=@]
# [rd.luks.uuid=...] rw. Boot loaders without a probe of their own (Limine)
# need them; GRUB's grub-mkconfig adds root= and rootflags itself.
root_cmdline() {
	local mnt=${RIBBON_ROOT:-/} src fs uuid sub parent luks
	src=$(findmnt -no SOURCE "$mnt" | head -n1 | sed 's/\[.*\]$//')
	fs=$(findmnt -no FSTYPE "$mnt" | head -n1)
	[ -b "$src" ] || { err "cannot find the block device of $mnt (got '$src')"; return 1; }
	uuid=$(blkid -s UUID -o value "$src")
	[ -n "$uuid" ] || { err "$src has no filesystem UUID"; return 1; }
	printf 'root=UUID=%s rootfstype=%s' "$uuid" "$fs"
	if [ "$fs" = btrfs ]; then
		sub=$(findmnt -no OPTIONS "$mnt" | head -n1 | tr ',' '\n' | sed -n 's|^subvol=/\{0,1\}||p')
		[ -n "$sub" ] && printf ' rootflags=subvol=%s' "$sub"
	fi
	if [ "$(lsblk -dno TYPE "$src" 2>/dev/null)" = crypt ]; then
		parent=$(lsblk -dno PKNAME "$src" 2>/dev/null | head -n1)
		[ -n "$parent" ] && luks=$(blkid -s UUID -o value "/dev/$parent")
		[ -n "${luks:-}" ] && printf ' rd.luks.uuid=%s' "$luks"
	fi
	printf ' rw\n'
}

# Add words to RIBBON_CMDLINE_EXTRA (idempotent); every boot loader uses them.
cmdline_add() {
	local f cur w
	f=$(boot_conf)
	[ -f "$f" ] || return 0
	cur=$(sed -n 's/^RIBBON_CMDLINE_EXTRA="\(.*\)"$/\1/p' "$f")
	for w in "$@"; do
		case " $cur " in *" $w "*) ;; *) cur="${cur:+$cur }$w" ;; esac
	done
	sed -i "s|^RIBBON_CMDLINE_EXTRA=.*|RIBBON_CMDLINE_EXTRA=\"${cur}\"|" "$f"
}

cmdline_remove() {
	local f cur w out=
	f=$(boot_conf)
	[ -f "$f" ] || return 0
	cur=$(sed -n 's/^RIBBON_CMDLINE_EXTRA="\(.*\)"$/\1/p' "$f")
	for w in $cur; do
		case " $* " in *" $w "*) ;; *) out="${out:+$out }$w" ;; esac
	done
	sed -i "s|^RIBBON_CMDLINE_EXTRA=.*|RIBBON_CMDLINE_EXTRA=\"${out}\"|" "$f"
}

# Current RIBBON_CMDLINE_EXTRA words.
cmdline_extra() {
	sed -n 's/^RIBBON_CMDLINE_EXTRA="\(.*\)"$/\1/p' "$(boot_conf)" 2>/dev/null
}

# Rewrite the boot menu for whichever boot loader is installed (new kernels,
# kernel flags, snapshot entries).
update_bootloader() {
	case "$(boot_loader)" in
		zfsbootmenu)
			# ZFSBootMenu reads the kernel command line from a dataset property.
			in_root /usr/lib/ribbon/postinstall zbm-cmdline >/dev/null ;;
		limine)
			in_root ribbon-limine update ;;
		grub)
			if in_root sh -c 'command -v update-grub' >/dev/null 2>&1; then
				in_root update-grub >/dev/null
			elif in_root sh -c 'command -v grub-mkconfig' >/dev/null 2>&1; then
				in_root grub-mkconfig -o /boot/grub/grub.cfg >/dev/null
			fi ;;
		*) return 0 ;;
	esac
}

# The non-root user running a session (for per-user actions from sudo).
session_user() {
	if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
		echo "$SUDO_USER"
	elif [ -n "${PKEXEC_UID:-}" ]; then
		id -un "$PKEXEC_UID"
	else
		id -un
	fi
}

# Is a dinit service installed? Services converted from runit (/etc/sv, the
# compatibility layer ribbon-sv2dinit belongs to) count where that layer is.
svc_exists() {
	local s=${1%%@*} r=${RIBBON_ROOT}
	[ -e "$r/usr/lib/dinit.d/$s" ] || [ -e "$r/etc/dinit.d/$s" ] && return 0
	have ribbon-sv2dinit && [ -d "$r/etc/sv/$s" ]
}

# Rebuild every installed kernel's initramfs with dracut (a kernel is a
# /usr/lib/modules/<version> with its modules.dep), then refresh the boot
# menu as the kernel hooks do (kernel flags may have changed).
regen_initramfs() {
	local d v n=0
	for d in "${RIBBON_ROOT}"/usr/lib/modules/*/; do
		v=${d%/}; v=${v##*/}
		[ -e "$d/modules.dep" ] || continue
		# an installed kernel has its image: /boot/vmlinuz-V (Void, Debian), or beside its modules (Arch, Fedora);
		# a removed kernel's leftovers (DKMS output, a depmod run after the removal) have none
		[ -e "${RIBBON_ROOT}/boot/vmlinuz-$v" ] || [ -e "$d/vmlinuz" ] || continue
		n=$((n + 1))
		in_root dracut -q --force "/boot/initramfs-$v.img" "$v" >/dev/null 2>&1 ||
			warn "initramfs rebuild failed for $v; run: dracut --force /boot/initramfs-$v.img $v"
	done
	[ "$n" -gt 0 ] || { warn "no kernel found in ${RIBBON_ROOT}/usr/lib/modules"; return 0; }
	case "$(boot_loader)" in
		limine) [ -r "${RIBBON_ROOT}/etc/default/ribbon-limine" ] || return 0 ;;
		grub) [ -e "${RIBBON_ROOT}/boot/grub/grub.cfg" ] || return 0 ;;
	esac
	update_bootloader || warn "boot menu not updated; run: sudo ribbon boot update"
}
