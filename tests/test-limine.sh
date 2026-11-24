#!/bin/bash
# ribbon-limine against a fake root: fake kernels on /boot, fake snapshots
# and a mock snapper on PATH. Checks the generated /boot/limine.conf.
set -u
cd "$(dirname "$0")/.." || exit 1
LIB=$PWD/srcpkgs/ribbon-tools/files/lib
TOOL=$PWD/srcpkgs/ribbon-tools/files/bin/ribbon-limine
fail=0
check() { # description, then a command that must succeed
	local d=$1; shift
	if "$@"; then echo "  ok   $d"; else echo "  FAIL $d"; fail=1; fi
}
has() { grep -qxF -- "$1" "$conf"; }
hasnt() { ! grep -qF -- "$1" "$conf"; }

t=$(mktemp -d)
trap '[ -n "${KEEP_TMP:-}" ] || rm -rf "$t"' EXIT
R=$t/root bin=$t/bin conf=$t/root/boot/limine.conf
mkdir -p "$R/boot" "$R/etc/default" "$R/etc/ribbon" "$bin"

# Settings as the installer leaves them (btrfs on LUKS).
sed 's/^BOOTLOADER=.*/BOOTLOADER=limine/; s/^RIBBON_CMDLINE_EXTRA=.*/RIBBON_CMDLINE_EXTRA="apparmor=1 security=apparmor"/' \
	srcpkgs/ribbon-base/files/ribbon-boot > "$R/etc/default/ribbon-boot"
echo 'RIBBON_ROOT_CMDLINE="root=UUID=1111-root rootfstype=btrfs rootflags=subvol=@ rd.luks.uuid=2222-luks rw"' > "$R/etc/default/ribbon-limine"
printf 'SNAPSHOT_KEEP=3\n' > "$R/etc/ribbon/ribbon.conf"

kernel() { : > "$R/boot/vmlinuz-$1"; [ "${2:-}" = noinitrd ] || : > "$R/boot/initramfs-$1.img"; }
kernel 6.18.2_1          # current kernel
kernel 6.12.60_1         # fallback LTS kernel
kernel 6.17.9_1          # old kernel, only kept for snapshots
kernel 6.16.1_1 noinitrd # broken: no initramfs
mods() { local d=$1; shift; for v; do mkdir -p "$d/usr/lib/modules/$v"; done; }
mods "$R" 6.18.2_1 6.12.60_1
snap() { local n=$1; shift; mods "$R/.snapshots/$n/snapshot" "$@"; }
snap 1 6.17.9_1                 # "Fresh install": beyond the keep count
snap 2 6.17.9_1
snap 3 6.16.1_1 6.12.60_1       # 6.16 has no initramfs -> boots 6.12
snap 4 6.15.0_1                 # its kernel was pruned from /boot -> not listed
snap 5 6.17.9_1 6.12.60_1       # -> 6.17
snap 6 6.18.2_1 6.12.60_1       # -> 6.18

# Mock snapper: CSV like `snapper --csvout --no-headers --separator TAB list`.
cat > "$bin/snapper" <<EOF
#!/bin/sh
echo "\$*" >> "$t/snapper.args"
case " \$* " in *" list "*) ;; *) exit 1 ;; esac
printf '0\t\tcurrent\n'
printf '1\t2026-10-01 09:00:00\tFresh install\n'
printf '2\t2026-10-20 18:30:00\txbps-install -Su\n'
printf '3\t2026-11-01 12:00:00\t"say ""hi"" /+ caf\303\251"\n'
printf '4\t2026-11-03 08:15:00\tribbon update 2026-11-03\n'
printf '5\t2026-11-05 21:00:00\tribbon update 2026-11-05\n'
printf '6\t2026-11-06 10:42:07\tbefore rollback to 3\n'
EOF
chmod +x "$bin/snapper"

run() { PATH="$bin:$PATH" RIBBON_LIB=$LIB RIBBON_ROOT=$R bash "$TOOL" "$@"; }

echo "ribbon-limine update (btrfs, 6 snapshots, keep 3)"
check "update succeeds" run update
check "snapper is asked without D-Bus, on the target root" grep -q -- "--no-dbus --root $R -c root --csvout" "$t/snapper.args"
check "global options come first" sh -c "sed -n '/^\//q;p' '$conf' | grep -qx 'timeout: 3'"
check "newest kernel is the first (default) entry" sh -c "grep -m1 '^/' '$conf' | grep -qxF '/Ribbon OS (6.18.2_1)'"
check "fallback kernel listed" has "/Ribbon OS (6.12.60_1)"
check "kernel without modules in the root is not a main entry" hasnt "/Ribbon OS (6.17.9_1)"
check "kernel without initramfs is never listed" hasnt "6.16.1_1"
check "pruned kernel is never listed" hasnt "6.15.0_1"
check "main entry cmdline" has "    cmdline: root=UUID=1111-root rootfstype=btrfs rootflags=subvol=@ rd.luks.uuid=2222-luks rw quiet loglevel=3 rd.udev.log_level=3 nowatchdog split_lock_detect=off apparmor=1 security=apparmor"
check "snapshot submenu" has "/Ribbon OS snapshots"
titles=$(grep '^//' "$conf")
check "snapshots newest first, capped at 3, unbootable ones skipped" test "$titles" = "//Snapshot 6  2026-11-06 10:42  before rollback to 3
//Snapshot 5  2026-11-05 21:00  ribbon update 2026-11-05
//Snapshot 3  2026-11-01 12:00  say \"hi\" /+ caf??"
check "snapshot 6 boots its own kernel" sh -c "grep -A3 '^//Snapshot 6 ' '$conf' | grep -qxF '    path: boot():/vmlinuz-6.18.2_1'"
check "snapshot 5 boots 6.17 (kept on /boot for it)" sh -c "grep -A4 '^//Snapshot 5 ' '$conf' | grep -qxF '    module_path: boot():/initramfs-6.17.9_1.img'"
check "snapshot 3 falls back to a kernel with an initramfs" sh -c "grep -A3 '^//Snapshot 3 ' '$conf' | grep -qxF '    path: boot():/vmlinuz-6.12.60_1'"
check "snapshot cmdline for 90ribbon-snapshot (subvol, read-only)" has "    cmdline: root=UUID=1111-root rootfstype=btrfs rootflags=subvol=@snapshots/6/snapshot rd.luks.uuid=2222-luks ro quiet loglevel=3 rd.udev.log_level=3 nowatchdog split_lock_detect=off apparmor=1 security=apparmor"
check "dracut module pattern matches the snapshot rootflags" sh -c "grep -q 'subvol=@snapshots/\*' srcpkgs/ribbon-tools/files/dracut/90ribbon-snapshot/ribbon-snapshot-overlay.sh"
check "every path exists on /boot" sh -c "grep -o 'boot():/[^ ]*' '$conf' | sed 's|boot():|$R/boot|' | xargs ls >/dev/null"
check "no rw in any snapshot entry" sh -c "! awk '/^\/\//{s=1} /^\/[^\/]/{s=0} s && /cmdline:/ && / rw( |$)/' '$conf' | grep -q ."
check "no branding colour option (Limine wants a palette number 0-7 there; a hex colour is not one)" sh -c "! grep -q interface_branding_colour '$conf'"
check "only known Limine options" sh -c "! grep -vE '^(#.*|)$|^/{1,2}[^/ ]|^(timeout|interface_branding|interface_branding_colour): |^    (comment|protocol|path|module_path|cmdline): ' '$conf' | grep -q ."

echo "after a rollback to a root without 6.18 modules"
rm -r "$R/usr/lib/modules/6.18.2_1"
run update
check "default entry follows the restored root" sh -c "grep -m1 '^/' '$conf' | grep -qxF '/Ribbon OS (6.12.60_1)'"
check "snapshots still boot 6.18" sh -c "grep -A3 '^//Snapshot 6 ' '$conf' | grep -qF 'vmlinuz-6.18.2_1'"
mods "$R" 6.18.2_1

echo "Ribbon's own kernel beside Void's of the same version"
kernel 6.18.2-ribbon_1; mods "$R" 6.18.2-ribbon_1
run update
check "Ribbon's kernel is the first (default) entry, Void's of the same version (which sorts ahead) after it" sh -c "test \"\$(grep '^/[^/]' '$conf' | head -n2 | tr '\n' ' ')\" = '/Ribbon OS (6.18.2-ribbon_1) /Ribbon OS (6.18.2_1) '"
kernel 6.18.9_1; mods "$R" 6.18.9_1
run update
check "and stays first when Void's kernel is newer" sh -c "grep -m1 '^/' '$conf' | grep -qxF '/Ribbon OS (6.18.2-ribbon_1)'"
rm -f "$R"/boot/vmlinuz-6.18.2-ribbon_1 "$R"/boot/initramfs-6.18.2-ribbon_1.img "$R"/boot/vmlinuz-6.18.9_1 "$R"/boot/initramfs-6.18.9_1.img
rm -r "$R/usr/lib/modules/6.18.2-ribbon_1" "$R/usr/lib/modules/6.18.9_1"
run update

echo "Windows on the same EFI partition, then on another disk"
check "no Windows entry without Windows" hasnt "/Windows"
mkdir -p "$R/boot/EFI/Microsoft/Boot"; : > "$R/boot/EFI/Microsoft/Boot/bootmgfw.efi"
run update
check "Windows entry chainloads its boot manager" sh -c "grep -A3 '^/Windows$' '$conf' | grep -qxF '    path: boot():/EFI/Microsoft/Boot/bootmgfw.efi' && grep -A3 '^/Windows$' '$conf' | grep -qxF '    protocol: efi'"
check "Ribbon stays the default (first) entry" sh -c "grep -m1 '^/' '$conf' | grep -qxF '/Ribbon OS (6.18.2_1)'"
check "Windows comes after Ribbon's entries and snapshots" sh -c "grep '^/' '$conf' | tail -n1 | grep -qx '/Windows'"
rm -r "$R/boot/EFI/Microsoft"
echo 'LIMINE_WINDOWS_ESP=0f1e2d3c-aaaa-bbbb-cccc-123456789abc' >> "$R/etc/default/ribbon-limine"
run update
check "Windows on another disk: by partition GUID" has "    path: guid(0f1e2d3c-aaaa-bbbb-cccc-123456789abc):/EFI/Microsoft/Boot/bootmgfw.efi"
echo 'LIMINE_WINDOWS=no' >> "$R/etc/default/ribbon-limine"
run update
check "LIMINE_WINDOWS=no leaves it out" hasnt "/Windows"
sed -i '/^LIMINE_WINDOWS/d' "$R/etc/default/ribbon-limine"

echo "kernels on an XBOOTLDR /boot, Windows' EFI partition at /boot/efi"
xb=5e1f0a2b-1c3d-4e5f-8a9b-0c1d2e3f4a5b
echo "LIMINE_XBOOTLDR=$xb" >> "$R/etc/default/ribbon-limine"
mkdir -p "$R/boot/efi/EFI/Microsoft/Boot" "$R/boot/efi/EFI/limine" "$R/boot/efi/EFI/BOOT" "$R/usr/share/limine"
: > "$R/boot/efi/EFI/Microsoft/Boot/bootmgfw.efi"
echo "Microsoft fallback" > "$R/boot/efi/EFI/BOOT/BOOTX64.EFI"
echo "limine old" > "$R/boot/efi/EFI/limine/BOOTX64.EFI"
echo "limine new" > "$R/usr/share/limine/BOOTX64.EFI"
check "update succeeds" run update
check "the menu is on the boot partition" test -s "$R/boot/limine.conf"
check "kernels by the boot partition's GUID" has "    path: guid($xb):/vmlinuz-6.18.2_1"
check "initramfs images too" has "    module_path: guid($xb):/initramfs-6.18.2_1.img"
check "snapshots boot from it as well" sh -c "grep -A3 '^//Snapshot 6 ' '$conf' | grep -qxF '    path: guid($xb):/vmlinuz-6.18.2_1'"
check "no kernel through boot() (that is the EFI partition)" sh -c "! grep -qE 'path: boot\(\):/(vmlinuz|initramfs)' '$conf'"
check "every kernel path exists on /boot" sh -c "grep -o 'guid($xb):/[^ ]*' '$conf' | sed 's|guid($xb):|$R/boot|' | xargs ls >/dev/null"
check "Windows from the EFI partition Limine starts from" sh -c "grep -A3 '^/Windows$' '$conf' | grep -qxF '    path: boot():/EFI/Microsoft/Boot/bootmgfw.efi'"
check "Limine's EFI binary refreshed on the EFI partition" grep -qx "limine new" "$R/boot/efi/EFI/limine/BOOTX64.EFI"
check "Windows' fallback loader left alone" grep -qx "Microsoft fallback" "$R/boot/efi/EFI/BOOT/BOOTX64.EFI"
check "no EFI binary on the boot partition" test ! -e "$R/boot/EFI/limine"
rm -r "$R/boot/efi" "$R/usr/share/limine"
sed -i '/^LIMINE_XBOOTLDR/d' "$R/etc/default/ribbon-limine"

echo "no snapper config (bcachefs)"
printf '#!/bin/sh\necho "no config" >&2; exit 1\n' > "$bin/snapper"
check "update succeeds" run update
check "no snapshot submenu" hasnt "snapshots"
check "kernels still listed" has "/Ribbon OS (6.18.2_1)"

echo "shared boot helpers"
helpers() { RIBBON_ROOT=$R bash -c ". '$LIB/common.sh'; $*"; }
check "boot_loader reads BOOTLOADER" test "$(helpers boot_loader)" = limine
check "cmdline_add edits ribbon-boot" sh -c "RIBBON_ROOT='$R' bash -c '. $LIB/common.sh; cmdline_add nvidia_drm.modeset=1; cmdline_add nvidia_drm.modeset=1' && grep -qx 'RIBBON_CMDLINE_EXTRA=\"apparmor=1 security=apparmor nvidia_drm.modeset=1\"' '$R/etc/default/ribbon-boot'"
run update
check "new flag reaches the menu" sh -c "grep -c 'nvidia_drm.modeset=1' '$conf' | grep -qx 2"
sed -i 's/^BOOTLOADER=.*/BOOTLOADER=/' "$R/etc/default/ribbon-boot"
check "boot_loader detects Limine without BOOTLOADER" test "$(helpers boot_loader)" = limine
rm "$R/etc/default/ribbon-limine"; mkdir -p "$R/boot/grub"; : > "$R/boot/grub/grub.cfg"
check "boot_loader detects GRUB" test "$(helpers boot_loader)" = grub
check "update refuses without RIBBON_ROOT_CMDLINE" sh -c "! PATH='$bin:$PATH' RIBBON_LIB='$LIB' RIBBON_ROOT='$R' bash '$TOOL' update 2>/dev/null"

[ $fail -eq 0 ] && echo "ribbon-limine: all checks passed"
exit $fail
