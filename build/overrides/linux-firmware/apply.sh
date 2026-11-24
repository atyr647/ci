#!/bin/sh
# Ribbon OS override of void-packages/srcpkgs/linux-firmware ($1 = that dir).
#
# linux-firmware-network (442 MiB) is what ribbon-base installs for Wi-Fi,
# Bluetooth and Ethernet, but 238 MiB of it is for hardware no desktop or
# laptop has: datacenter NICs and switch ASICs, Fibre Channel and SCSI HBAs,
# Omni-Path, and Wi-Fi access-point chips (docs/STACK.md §2.11). This moves
# that firmware back into the main linux-firmware package, which ribbon-base
# doesn't install; `xbps-install linux-firmware` still gets everything, and
# the installer's hardware table maps those files to it.
#
# Kept in -network: everything not named below, so client Wi-Fi and
# Bluetooth (iwlwifi, intel/ibt, ath9k-ath12k client chips, mt76/mt79xx,
# rtw88/rtw89, rtl_bt, rtl_nic, brcm through -broadcom, qca, mrvl, libertas,
# ti-connectivity, ...), desktop Ethernet (Realtek, Intel e100/igb families,
# tigon, 3com, ...), cameras and sensors under intel/ (ipu, vsc, ish).
# FOR INDEPENDENCE: not in build-packages.sh's OVERRIDES yet; Ribbon
# rebuilds Void packages only once it builds everything (docs/STACK.md
# "At independence"). Its binary packages are listed in ./packages, which
# the collection step will need for the subpackages.
set -e
dir=$1 here=$(dirname "$0")
grep -q 'Ribbon OS override' "$dir/template" && exit 0
anchor='vmove "usr/lib/firmware/mediatek/!('
grep -qF "$anchor" "$dir/template" || { echo "linux-firmware override: anchor not found in template" >&2; exit 1; }
sed -i '1a # Ribbon OS override: datacenter, switch, HBA and access-point firmware leaves linux-firmware-network (build/overrides/linux-firmware).' "$dir/template"
# after the mediatek line inside linux-firmware-network's pkg_install
awk -v anchor="$anchor" -v block="$here/network-split.sh" '
	{ print }
	index($0, anchor) && !done { while ((getline l < block) > 0) print "\t\t" l; done = 1 }
' "$dir/template" > "$dir/template.new"
mv "$dir/template.new" "$dir/template"
grep -q 'ribbon_datacenter' "$dir/template" || { echo "linux-firmware override: not applied" >&2; exit 1; }
