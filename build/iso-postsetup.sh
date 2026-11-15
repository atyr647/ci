#!/bin/sh
# void-mklive post-setup hook (-x): runs with the ISO rootfs as $1, before
# the initramfs is generated.
set -e
ROOTFS=$1

# dinit services for the live session (links in /etc/dinit.d/boot.d); only
# services that exist, since a missing one would stop the boot.
mkdir -p "$ROOTFS/etc/dinit.d/boot.d"
for s in greetd NetworkManager bluetoothd power-profiles-daemon scx agetty@tty2 agetty@tty3; do
	if [ -d "$ROOTFS/etc/sv/$s" ] || [ -e "$ROOTFS/usr/lib/dinit.d/${s%%@*}" ]; then
		ln -sfn "../$s" "$ROOTFS/etc/dinit.d/boot.d/$s"
	else
		echo "iso-postsetup: service $s not present; not enabled" >&2
	fi
done

# Offline driver repository: NVIDIA's three driver branches, the Broadcom
# wl Wi-Fi driver, and the other drivers the installer's Hardware page can
# pick (fingerprint, Xbox pads, printing, firmware), with everything they
# need that the live system lacks (DKMS toolchain etc.), so they install without internet. The installers
# bind-mount this into the target; it is not copied to installed systems.
OFF="$ROOTFS/var/lib/ribbon/offline-repo"
mkdir -p "$OFF"
if [ "${RIBBON_OFFLINE_DRIVERS:-yes}" = yes ]; then
	# shellcheck disable=SC2086
	for set in "nvidia nvidia-libs-32bit nvidia-vaapi-driver" \
		"nvidia580 nvidia580-libs-32bit" "nvidia470 nvidia470-libs-32bit" \
		"broadcom-wl-dkms" "intel-ucode" \
		"fprintd libfprint" "xpadneo" "cups cups-filters" "broadcom-bt-firmware" \
		"libcamera" "linux-firmware"; do
		XBPS_ARCH="${RIBBON_ARCH:-x86_64}" xbps-install -r "$ROOTFS" $RIBBON_XBPS_REPOS \
			-c "$OFF" --download-only -y $set ||
			echo "iso-postsetup: could not bundle '$set' (it will need internet)" >&2
	done
	if ls "$OFF"/*.xbps >/dev/null 2>&1; then
		xbps-rindex -a "$OFF"/*.xbps
		du -sh "$OFF"
	fi
fi

# The live desktop starts the installer from labwc's autostart.
cat >> "$ROOTFS/usr/share/ribbon/xdg/labwc/autostart" <<'EOS'
# Ribbon live ISO: offer the installer
[ -e /etc/ribbon/live ] && ribbon-installer-launch >/dev/null 2>&1 &
EOS

# Hostname and boot defaults for the live system.
echo ribbon-live > "$ROOTFS/etc/hostname"
grep -q ribbon-grub "$ROOTFS/etc/default/grub" 2>/dev/null ||
	printf '\n. /etc/default/ribbon-grub\n' >> "$ROOTFS/etc/default/grub"

# Convert runit services once at build time: catches conversion problems
# early and stores the fallback copy in /var/lib/ribbon/dinit.d.
chroot "$ROOTFS" /usr/bin/ribbon-sv2dinit --check ||
	echo "iso-postsetup: some runit services could not be converted (see above)" >&2
mkdir -p "$ROOTFS/run/dinit.d"
chroot "$ROOTFS" /usr/bin/ribbon-sv2dinit --quiet || :
