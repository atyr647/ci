#!/bin/bash
# ribbon-gpu (srcpkgs/ribbon-tools/files/bin/ribbon-gpu) on a fake root, with stand-ins for lspci (fixtures), ribbon-hw
# and the package install: the drivers it picks for the GPUs it finds, the files it writes for them, and what it takes
# away again when the drivers change. Review findings of 17 Nov: a hybrid laptop must not get NVIDIA's vendor
# variables for the whole session (labwc would fail to start), the proprietary setup must go when another driver is
# chosen, nouveau is blacklisted only when the nvidia module exists, a laptop's NVIDIA GPU gets runtime power
# management on the first install, prime-run works with a 3D-controller GPU, unnamed new cards are `nvidia`, and one
# NVIDIA branch only.
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
G=srcpkgs/ribbon-tools/files/bin/ribbon-gpu
LIBSRC=srcpkgs/ribbon-tools/files/lib
mkdir -p "$T/lib" "$T/bin"
cp "$LIBSRC"/*.sh "$LIBSRC"/pkg-names.* "$T/lib/" 2>/dev/null
# the package install is a log line; nothing is installed
printf '\npkg_install() { echo "pkg_install $*" >> "$LOG"; }\n' >> "$T/lib/common.sh"
cat > "$T/bin/lspci" <<'SH'
#!/bin/sh
# lspci -mm -nn -d ::CCCC: the fixture's lines of that class
for a in "$@"; do case $a in ::*) cls=${a#::} ;; esac; done
grep "\\[$cls\\]\" " "$FIX" 2>/dev/null
exit 0
SH
cat > "$T/bin/ribbon-hw" <<'SH'
#!/bin/sh
[ "${1:-}" = is-laptop ] && [ -n "${LAPTOP:-}" ]
SH
cat > "$T/bin/id" <<'SH'
#!/bin/sh
echo 0
SH
chmod +x "$T/bin/lspci" "$T/bin/ribbon-hw" "$T/bin/id"
R=$T/root
LOG=$T/log
export LOG
INTEL='00:02.0 "VGA compatible controller [0300]" "Intel Corporation [8086]" "CometLake-H GT2 [UHD Graphics] [9bc4]"'
TU117='01:00.0 "3D controller [0302]" "NVIDIA Corporation [10de]" "TU117M [GeForce GTX 1650 Mobile / Max-Q] [1f91]"'
TU106='01:00.0 "VGA compatible controller [0300]" "NVIDIA Corporation [10de]" "TU106 [GeForce RTX 2060] [1f08]"'
GM107='02:00.0 "VGA compatible controller [0300]" "NVIDIA Corporation [10de]" "GM107 [GeForce GTX 750 Ti] [1380]"'
GK107='03:00.0 "VGA compatible controller [0300]" "NVIDIA Corporation [10de]" "GK107 [GeForce GT 640] [0fc1]"'
GF108='04:00.0 "VGA compatible controller [0300]" "NVIDIA Corporation [10de]" "GF108 [GeForce GT 430] [0de1]"'
NEWID='05:00.0 "VGA compatible controller [0300]" "NVIDIA Corporation [10de]" "Device [2684]"'
AMD='06:00.0 "VGA compatible controller [0300]" "Advanced Micro Devices, Inc. [AMD/ATI] [1002]" "Navi 23 [Radeon RX 6600] [73ff]"'
fresh() { # FIXTURE-LINES... ; a root with the boot configuration file and (unless NOMOD) a built nvidia module
	rm -rf "$R" "$LOG"; : > "$LOG"
	mkdir -p "$R/etc/default" "$R/usr/lib/modules/6.18.1/extra"
	printf 'BOOTLOADER=limine\nRIBBON_CMDLINE_EXTRA=""\n' > "$R/etc/default/ribbon-boot"
	[ -n "${NOMOD:-}" ] || : > "$R/usr/lib/modules/6.18.1/extra/nvidia.ko"
	printf '%s\n' "$@" > "$T/fixture"
}
gpuq() { gpu "$@" >/dev/null; }
gpu() { FIX=$T/fixture PATH=$T/bin:$PATH RIBBON_LIB=$T/lib RIBBON_ROOT=$R bash "$G" "$@" 2>"$T/err"; }
has() { grep -q -- "$1" "$2" 2>/dev/null; }
S=$R/etc/ribbon/session.d/20-nvidia.sh
M=$R/etc/modprobe.d/ribbon-nvidia.conf

# detect and classify
fresh "$TU117" "$NEWID" "$GF108" "$GK107" "$GM107"
out=$(gpu detect)
echo "$out" | grep -q 'TU117M.*' && echo "$out" | grep -E 'nvidia +nvidia +TU117' >/dev/null && ok "a Turing card is the current branch (nvidia)" || bad "TU117: $out"
echo "$out" | grep -E 'nvidia +nvidia +Device' >/dev/null && ok "a card the local pci.ids does not name ('Device [2684]') is a new card: nvidia, not nouveau" || bad "unnamed: $out"
echo "$out" | grep -E 'nvidia +nouveau +GF108' >/dev/null && ok "a Fermi card is nouveau's" || bad "GF108: $out"
echo "$out" | grep -E 'nvidia +nvidia470 +GK107' >/dev/null && ok "a Kepler card is nvidia470's" || bad "GK107: $out"
echo "$out" | grep -E 'nvidia +nvidia580 +GM107' >/dev/null && ok "a Maxwell card is nvidia580's" || bad "GM107: $out"

# an Intel + NVIDIA laptop
fresh "$INTEL" "$TU117"
LAPTOP=1 gpuq install --auto; rc=$?
[ $rc = 0 ] && has 'pkg_install' "$LOG" && has 'mesa-vulkan-intel' "$LOG" && has 'nvidia' "$LOG" && ok "hybrid laptop: the Intel and the NVIDIA packages are installed" || bad "hybrid install rc=$rc: $(cat "$LOG" "$T/err")"
if [ -f "$S" ] && ! has 'GBM_BACKEND' "$S" && ! has '__GLX_VENDOR_LIBRARY_NAME' "$S" && ! has 'LIBVA_DRIVER_NAME' "$S" && has '__GL_SHADER_DISK_CACHE_SIZE' "$S"; then
	ok "hybrid: no NVIDIA vendor variable for the whole session (labwc stays on the Intel GPU); the shader cache is still set"
else bad "hybrid session file: $(cat "$S" 2>&1)"; fi
has 'NVreg_DynamicPowerManagement=0x02' "$M" && ok "a laptop's NVIDIA GPU gets runtime power management at the first install (not only when ribbon-hw runs after it)" || bad "power management: $(cat "$M")"
has '^blacklist nouveau' "$M" && has 'nvidia_drm' "$R/etc/dracut.conf.d/20-ribbon-nvidia.conf" && ok "the nvidia module is there: nouveau is blacklisted and the modules go in the initramfs" || bad "blacklist / dracut"
[ -x "$R/usr/local/bin/prime-run" ] && ! grep -q 'lspci' "$R/usr/local/bin/prime-run" && grep -q '/proc/driver/nvidia/version' "$R/usr/local/bin/prime-run" && ok "prime-run asks the driver, not lspci's VGA class (a laptop's NVIDIA GPU is a 3D controller)" || bad "prime-run: $(cat "$R/usr/local/bin/prime-run" 2>&1)"
has 'nvidia_drm.modeset=1' "$R/etc/default/ribbon-boot" && ok "the kernel flags are added" || bad "cmdline"

# NVIDIA alone, on a desktop
fresh "$TU106"
gpuq install --auto
has 'export GBM_BACKEND=nvidia-drm' "$S" && has 'export LIBVA_DRIVER_NAME=nvidia' "$S" && ok "NVIDIA alone: the session gets the vendor variables" || bad "sole session file: $(cat "$S" 2>&1)"
! has 'DynamicPowerManagement' "$M" && ok "a desktop: no runtime power management option" || bad "desktop power option"
[ ! -e "$R/usr/local/bin/prime-run" ] && ok "one GPU vendor: no prime-run" || bad "prime-run on a single GPU"

# and the proprietary setup goes when another driver is chosen
gpuq install amd
if [ ! -e "$S" ] && [ ! -e "$M" ] && [ ! -e "$R/etc/dracut.conf.d/20-ribbon-nvidia.conf" ] && [ ! -e "$R/etc/elogind/system-sleep/ribbon-nvidia" ]; then
	ok "install amd after nvidia: the modprobe blacklist, the session variables, the initramfs snippet and the sleep hook are gone"
else bad "stale NVIDIA files: $(ls "$R"/etc/modprobe.d "$R"/etc/ribbon/session.d 2>&1)"; fi
! has 'nvidia_drm' "$R/etc/default/ribbon-boot" && ok "  and so are the kernel flags" || bad "stale cmdline: $(cat "$R/etc/default/ribbon-boot")"
fresh "$AMD"
gpuq install --auto
[ ! -e "$S" ] && ok "an AMD-only machine with nothing of NVIDIA's to remove is fine" || bad "stray session file"

# no nvidia module built: nouveau stays
NOMOD=1 fresh "$TU106"
NOMOD=1 gpuq install --auto
if [ -f "$M" ] && ! has '^blacklist nouveau' "$M" && [ ! -e "$R/etc/dracut.conf.d/20-ribbon-nvidia.conf" ] && has 'DKMS' "$T/err"; then
	ok "no nvidia module for any kernel (DKMS failed): nouveau is not blacklisted, the initramfs is not told to load it, and it says so"
else bad "no-module case: $(cat "$M" "$T/err" 2>&1)"; fi

# one NVIDIA branch
fresh "$TU106" "$GM107"
gpuq install --auto
has 'nvidia580' "$LOG" && ! grep -qE 'nvidia470' "$LOG" && ok "Turing and Maxwell together: the 580 branch, which runs both" || bad "mixed branch: $(cat "$LOG")"
fresh "$TU106" "$GK107"
gpuq install --auto
if ! has 'nvidia470' "$LOG" && has 'left out\|does not support it' "$T/err"; then ok "Turing and Kepler: the newer branch, and it says the Kepler card is not supported by it"; else bad "kepler mix: $(cat "$LOG" "$T/err")"; fi
fresh "$TU106" "$GF108"
gpuq install --auto
! has 'nouveau' "$LOG" && has '^blacklist nouveau' "$M" && ok "a Fermi card beside a Turing one: the proprietary driver, nouveau blacklisted, and it says so" || bad "nouveau mix: $(cat "$LOG" "$M" 2>&1)"
fresh "$TU106"
gpuq install nvidia nvidia470; rc=$?
[ $rc != 0 ] && has 'choose one NVIDIA driver' "$T/err" && [ ! -s "$LOG" ] && ok "two NVIDIA drivers asked for by hand: refused before anything is installed" || bad "two drivers: rc=$rc $(cat "$T/err")"
gpuq install nvidia nouveau; rc=$?
[ $rc != 0 ] && ok "nvidia with nouveau: refused too" || bad "nvidia + nouveau"
exit $fail
