#!/bin/bash
# The package manager's seam (srcpkgs/ribbon-tools/files/lib/pkg.sh, pkg.tcl and
# pkg-names.xbps), on stand-ins: xbps-install, xbps-query, xbps-remove,
# xbps-reconfigure, chroot, dracut, localedef, getent and nm-online on PATH log
# what they are asked and answer from fixture files. Checked:
#   1. every package id the tools use is in the xbps name map, and no tool
#      outside the seam names xbps or a Void package (the map's names);
#   2. the xbps backend: names, installed, missing, install (online, then the
#      install media), offline-only install, remove, reconfigure, locales,
#      cache, the host that means "online", the package database of a root;
#   3. a base with no package manager, and kit (cannot install yet): honest
#      failures, nothing removed, no cache;
#   4. regen_initramfs: dracut for each kernel, the boot menu after, no xbps;
#   5. pending: the pkg queue through the seam, the old xbps queue taken over,
#      an unknown kind refused; postinstall's drivers, later, apps and locale
#      steps; ribbon-gpu install with Void names only from the map;
#      ribbon-reserve's package cache on a root without xbps;
#   6. pkg.tcl (the installer): the map, installed, missing and locales, with
#      the real pkg.sh on a fake root and with a stand-in pkg.sh;
#   7. the base-neutral parts: the base's services after a change (runit
#      services only where there are any), the console keymap (vconsole.conf,
#      Void's rc.conf only with xbps), Ribbon's own packages by make install's
#      record on a base without a package manager (live-cleanup's installer).
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
LIB=$REPO/srcpkgs/ribbon-tools/files/lib
BIN=$REPO/srcpkgs/ribbon-tools/files/bin
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
S=$T/stubs LOG=$T/log
mkdir -p "$S"
export STUB_LOG=$LOG STUB_DIR=$T

# ---- stand-ins -----------------------------------------------------------------
cat > "$S/xbps-install" <<'EOF'
#!/bin/sh
echo "xbps-install $* [RIBBON_NO_SNAPSHOT=${RIBBON_NO_SNAPSHOT:-}]" >> "$STUB_LOG"
case " $* " in *" -S"*) [ -e "$STUB_DIR/fail-online" ] && exit 1 ;; esac
[ -e "$STUB_DIR/fail-all" ] && exit 1
exit 0
EOF
cat > "$S/xbps-query" <<'EOF'
#!/bin/sh
[ "$1" = -l ] || { echo "xbps-query $*" >> "$STUB_LOG"; exit 2; }
while read -r n; do [ -n "$n" ] && echo "ii $n-1.0_1 a package"; done < "$STUB_DIR/installed"
EOF
printf '#!/bin/sh\necho "xbps-pkgdb $*" >> "$STUB_LOG"\n[ ! -e "$STUB_DIR/pkgdb-bad" ]\n' > "$S/xbps-pkgdb"
for c in xbps-remove xbps-reconfigure dracut ribbon-limine localedef ribbon-sv2dinit; do
	printf '#!/bin/sh\necho "%s $*" >> "$STUB_LOG"\n' "$c" > "$S/$c"
done
cat > "$S/chroot" <<'EOF'
#!/bin/sh
r=$1; shift
echo "chroot $r" >> "$STUB_LOG"
exec "$@"
EOF
printf '#!/bin/sh\nexit 0\n' > "$S/getent"
printf '#!/bin/sh\nexit 0\n' > "$S/nm-online"
chmod +x "$S"/*
NOX=$T/nox   # a PATH without any xbps (the base has no package manager)
mkdir -p "$NOX"
for c in chroot dracut ribbon-limine localedef getent nm-online; do ln -s "$S/$c" "$NOX/$c"; done
XPATH=$S:$PATH
NPATH=$NOX:$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do [ -x "$d/xbps-install" ] || [ -x "$d/kit" ] || printf '%s:' "$d"; done)
NPATH=${NPATH%:}
printf 'linux-firmware-amd\nmesa-dri\nmesa-dri-32bit\nbolt\n' > "$T/installed"

seam() { # PATH-to-use, then a bash snippet with pkg.sh sourced
	local p=$1; shift
	PATH=$p RIBBON_ROOT=${ROOT:-} RIBBON_PKG_BACKEND=${BACKEND:-} bash -c '. "$1/pkg.sh"; shift; eval "$*"' _ "$LIB" "$@"
}
logged() { grep -qxF -- "$1" "$LOG"; }
nolog() { ! grep -q -- "$1" "$LOG"; }

# ---- 1. the map covers the tools' ids; Void names only in the map ----------------
echo "name map"
MAP=$LIB/pkg-names.xbps
ids=$T/ids
{
	# shellcheck disable=SC2046
	RIBBON_LIB=$LIB bash "$BIN/ribbon-gpu" packages nvidia nvidia580 nvidia470 nouveau amd intel | tr ' ' '\n'
	echo microcode-intel
	HW=srcpkgs/ribbon-installer/files/backend/hwdb.tcl
	grep -o 'packages {[^}$[]*}' "$HW" | sed 's/packages {//; s/}//' | tr ' ' '\n' | grep -vx drv
	sed -n '/variable firmware_packages {/,/^    }/p' "$HW" | sed '1d;$d' | tr -s ' \n' '\n\n' | grep . | awk 'NR % 2 == 0'
	grep -o '{pkg [A-Za-z0-9._+-]*}' srcpkgs/ribbon-installer/files/backend/answers.tcl | sed 's/{pkg //; s/}//'
	grep -o 'install_pkgs [a-z][a-z0-9-]*' "$BIN/ribbon-hw" | cut -d' ' -f2
	grep -oE 'drop="[^"]*"|drop="\$drop [^"]*"' "$BIN/postinstall" | sed 's/drop="//; s/"$//; s/\$drop//' | tr ' ' '\n'
	grep -oE 'pkg_(install|remove|reconfigure) [a-z][a-z0-9 -]*' "$BIN/postinstall" "$BIN/ribbon-hw" "$LIB/pkg.sh" | cut -d' ' -f2- | tr ' ' '\n'
	echo broadcom-wl
} | grep . | sort -u > "$ids"
keys=$T/keys
sed 's/#.*//' "$MAP" | awk 'NF >= 2 { print $1 }' | sort > "$keys"
check "the map has no id twice" sh -c "[ -z \"\$(uniq -d '$keys')\" ]"
missing=$(comm -23 "$ids" "$keys" | tr '\n' ' ')
check "every id the tools use is in pkg-names.xbps ($(wc -l < "$ids") ids)${missing:+; missing: $missing}" test -z "$missing"
TOOLS="$BIN/postinstall $BIN/pending $BIN/ribbon-gpu $BIN/ribbon-hw $BIN/ribbon-reserve $BIN/ribbon-doctor $BIN/ribbon-update $LIB/common.sh
	srcpkgs/ribbon-installer/files/bin/ribbon-install srcpkgs/ribbon-installer/files/backend/*.tcl"
# shellcheck disable=SC2086
hits=$(grep -nE 'xbps-|/var/db/xbps|/var/cache/xbps|voidlinux|libc-locales' $TOOLS | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || :)
check "no xbps command or Void path outside the seam${hits:+: $hits}" test -z "$hits"
# the base's names that are not also ids: they must appear nowhere but the map
void=$(sed 's/#.*//' "$MAP" | awk 'NF >= 2 { for (i = 2; i <= NF; i++) print $i }' | sort -u | comm -23 - "$keys")
leak=
for n in $void; do
	# shellcheck disable=SC2086
	grep -qwF -- "$n" $TOOLS && leak="$leak $n"
done
check "Void package names only in the map (checked $(echo "$void" | wc -w))${leak:+; used:$leak}" test -z "$leak"

# every seam file is installed beside common.sh, by the template and by make install's manifest
for f in "$LIB"/*; do
	b=${f##*/}
	check "lib/$b installed by the template and the manifest" sh -c "grep -qF '\"\${FILESDIR}/lib/$b\" 644 usr/lib/ribbon' '$REPO/srcpkgs/ribbon-tools/template' && grep -qxF 'file 644 usr/lib/ribbon @files/lib/$b' '$REPO/build/install/manifests/ribbon-tools.manifest'"
done

# ---- 2. the xbps backend -----------------------------------------------------------
echo "xbps backend"
: > "$LOG"
check "backend: xbps when xbps-install is there" test "$(seam "$XPATH" pkg_backend)" = xbps
check "names: an id becomes Void's packages, a name the map lacks stays" \
	test "$(seam "$XPATH" 'pkg_name_map nvidia firmware-amd nvidia somepkg' | tr '\n' ' ')" = "nvidia nvidia-libs-32bit linux-firmware-amd somepkg "
check "installed names (xbps-query -l)" test "$(seam "$XPATH" pkg_installed_names | tr '\n' ' ')" = "linux-firmware-amd mesa-dri mesa-dri-32bit bolt "
check "missing: an id is there only when all its packages are" \
	test "$(seam "$XPATH" 'pkg_missing firmware-amd mesa bolt cups' | tr '\n' ' ')" = "mesa cups "
check "query: 0 when installed, 1 when not" seam "$XPATH" 'pkg_query firmware-amd bolt && ! pkg_query bolt cups'
check "check-db: xbps-pkgdb -a, 0 when consistent" seam "$XPATH" pkg_check_db
touch "$T/pkgdb-bad"
seam "$XPATH" pkg_check_db; check "check-db: 1 when xbps-pkgdb reports problems" test $? = 1
rm -f "$T/pkgdb-bad"
seam "$NPATH" pkg_check_db; check "check-db: 2 (cannot tell) with no package manager" test $? = 2
: > "$LOG"
RIBBON_OFFLINE_REPO=$T/nooffline
export RIBBON_OFFLINE_REPO
seam "$XPATH" 'pkg_install nvidia steam' >/dev/null 2>&1
check "install: xbps-install -Sy with Void's names, no snapshot" logged "xbps-install -Sy nvidia nvidia-libs-32bit steam [RIBBON_NO_SNAPSHOT=]"
mkdir -p "$T/off"; : > "$T/off/$(uname -m)-repodata"; : > "$T/off/broadcom-wl-dkms-6.30_1.$(uname -m).xbps"
export RIBBON_OFFLINE_REPO=$T/off
: > "$LOG"; touch "$T/fail-online"
seam "$XPATH" 'pkg_install broadcom-wl' >/dev/null 2>&1
check "install: the install media's packages as a second source, then alone when online fails" \
	sh -c "grep -qxF 'xbps-install -Sy -R $T/off broadcom-wl-dkms [RIBBON_NO_SNAPSHOT=]' '$LOG' && grep -qxF 'xbps-install -iy -R $T/off broadcom-wl-dkms [RIBBON_NO_SNAPSHOT=]' '$LOG'"
: > "$LOG"
check "install-offline: only what the media carries" seam "$XPATH" 'pkg_install_offline broadcom-wl && ! pkg_install_offline xone'
check "install-offline: xone was not attempted" nolog "xone"
rm -f "$T/fail-online"; export RIBBON_OFFLINE_REPO=$T/nooffline
: > "$LOG"
seam "$XPATH" 'pkg_remove bolt cups zfs' >/dev/null
check "remove: only what is installed, with what only it needs" logged "xbps-remove -Ry bolt"
: > "$LOG"
check "remove: nothing installed, nothing run" seam "$XPATH" 'pkg_remove cups zfs'
check "remove: nothing installed, xbps-remove not called" nolog xbps-remove
seam "$XPATH" 'pkg_reconfigure locales'
check "reconfigure: xbps-reconfigure -f with Void's name" logged "xbps-reconfigure -f glibc-locales"
check "cache: /var/cache/xbps" test "$(seam "$XPATH" pkg_cache_dir)" = /var/cache/xbps
: > "$LOG"; seam "$XPATH" pkg_clean_cache
check "cache cleanup: xbps-remove -O" logged "xbps-remove -Oy"
# a mounted system: its package database and its own files
R=$T/root
mkdir -p "$R/var/db/xbps" "$R/etc/xbps.d" "$R/etc/default"
{
	printf '<?xml version="1.0"?>\n<plist version="1.0">\n<dict>\n'
	for p in cups linux-firmware-network intel-ucode; do printf '\t<key>%s</key>\n\t<dict>\n\t\t<key>pkgver</key>\n\t\t<string>%s-1_1</string>\n\t</dict>\n' "$p" "$p"; done
	printf '</dict>\n</plist>\n'
} > "$R/var/db/xbps/pkgdb-0.38.plist"
printf '# mirror\nrepository=https://mirror.example.org/current\nrepository=https://other.example.org/x\n' > "$R/etc/xbps.d/00-repo.conf"
printf '#en_US.UTF-8 UTF-8\n#en_GB.UTF-8 UTF-8\n#de_DE ISO-8859-1\n' > "$R/etc/default/libc-locales"
check "a root's package database (no xbps here): xbps by its database" test "$(ROOT=$R seam "$NPATH" pkg_backend)" = xbps
check "a root's installed packages, read from its pkgdb" test "$(ROOT=$R seam "$NPATH" pkg_installed_names | tr '\n' ' ')" = "cups linux-firmware-network intel-ucode "
check "a root's missing ids" test "$(ROOT=$R seam "$NPATH" 'pkg_missing microcode-intel firmware-network firmware-amd' | tr '\n' ' ')" = "firmware-amd "
check "online host: the first repository's" test "$(ROOT=$R seam "$NPATH" pkg_online_host)" = mirror.example.org
check "locales from /etc/default/libc-locales" test "$(ROOT=$R seam "$NPATH" pkg_locales | tr '\n' ' ')" = "en_US.UTF-8 en_GB.UTF-8 de_DE "
: > "$LOG"
ROOT=$R seam "$XPATH" 'pkg_locale_enable en_GB.UTF-8'
check "locale enable: uncommented, the others left" sh -c "grep -qx 'en_GB.UTF-8 UTF-8' '$R/etc/default/libc-locales' && grep -qx '#en_US.UTF-8 UTF-8' '$R/etc/default/libc-locales'"
check "locale enable: glibc-locales reconfigured in the root" sh -c "grep -qxF 'chroot $R' '$LOG' && grep -qxF 'xbps-reconfigure -f glibc-locales' '$LOG'"
check "locale enable: an unknown locale fails" sh -c "! ROOT='$R' RIBBON_PKG_DIR='$LIB' PATH='$XPATH' RIBBON_ROOT='$R' bash -c '. \"$LIB/pkg.sh\"; pkg_locale_enable xx_YY.UTF-8' 2>/dev/null"

# ---- 3. no package manager; kit ---------------------------------------------------
echo "no package manager, kit"
N=$T/plain
mkdir -p "$N/usr/bin" "$N/usr/share/i18n"
printf 'en_US.UTF-8 UTF-8\nde_DE.UTF-8 UTF-8\n' > "$N/usr/share/i18n/SUPPORTED"
: > "$LOG"
check "backend: none" test "$(ROOT=$N seam "$NPATH" pkg_backend)" = none
check "install fails, and says why" sh -c "! ROOT='$N' PATH='$NPATH' RIBBON_ROOT='$N' bash -c '. \"$LIB/pkg.sh\"; pkg_install steam' 2>'$T/err' && grep -q 'no package manager' '$T/err'"
check "query: cannot tell (2)" sh -c "PATH='$NPATH' RIBBON_ROOT='$N' bash -c '. \"$LIB/pkg.sh\"; pkg_query bolt'; [ \$? -eq 2 ]"
check "missing: every id" test "$(ROOT=$N seam "$NPATH" 'pkg_missing bolt cups' | tr '\n' ' ')" = "bolt cups "
check "remove: refused, nothing run" sh -c "! PATH='$NPATH' RIBBON_ROOT='$N' bash -c '. \"$LIB/pkg.sh\"; pkg_remove installer' 2>/dev/null"
check "no cache, cleanup does nothing" test "$(ROOT=$N seam "$NPATH" 'pkg_cache_dir; pkg_clean_cache && echo empty')" = empty
check "names pass through without a map" test "$(ROOT=$N seam "$NPATH" 'pkg_name_map nvidia')" = nvidia
check "locales from glibc's SUPPORTED" test "$(ROOT=$N seam "$NPATH" pkg_locales | tr '\n' ' ')" = "en_US.UTF-8 de_DE.UTF-8 "
cp "$N/usr/share/i18n/SUPPORTED" "$T/SUPPORTED.deb"
printf '# glibc localedata\nSUPPORTED-LOCALES=\\\nen_US.UTF-8/UTF-8 \\\nde_DE/ISO-8859-1 \\\nsr_RS@latin/UTF-8 \\\n' > "$N/usr/share/i18n/SUPPORTED"
check "locales from SUPPORTED in glibc's own form (LOCALE/CHARSET \\, as Arch has it)" test "$(ROOT=$N seam "$NPATH" pkg_locales | tr '\n' ' ')" = "en_US.UTF-8 de_DE sr_RS@latin "
cp "$T/SUPPORTED.deb" "$N/usr/share/i18n/SUPPORTED"
: > "$N/usr/bin/localedef"; chmod +x "$N/usr/bin/localedef"
ROOT=$N seam "$NPATH" 'pkg_locale_enable de_DE.UTF-8'
check "locale enable: glibc's localedef in the root" logged "localedef -i de_DE -c -f UTF-8 de_DE.UTF-8"
check "nothing called xbps" nolog xbps
: > "$N/usr/bin/kit"; chmod +x "$N/usr/bin/kit"
check "backend: kit when kit is the system's" test "$(ROOT=$N seam "$NPATH" pkg_backend)" = kit
check "kit: install not available yet, said so" sh -c "! PATH='$NPATH' RIBBON_ROOT='$N' bash -c '. \"$LIB/pkg.sh\"; pkg_install nvidia' 2>'$T/err' && grep -q 'kit is not available yet' '$T/err'"
check "kit: remove not available yet, said so (not 'no package manager')" sh -c "! PATH='$NPATH' RIBBON_ROOT='$N' bash -c '. \"$LIB/pkg.sh\"; pkg_remove installer' 2>'$T/err' && grep -q 'kit is not available yet' '$T/err' && ! grep -q 'no package manager' '$T/err'"
rm -f "$N/usr/bin/kit"
# the running system (no target root): the kit backend asks kitd through plain `kit` (the kit's signed kind routes it) (a stand-in that logs its words
# and answers with $KIT_RC); ids reach kit as they are, a map (pkg-names.kit) renames them
KB=$T/kitbin; mkdir -p "$KB"
printf '#!/bin/sh\necho "kit $*" >> "%s"\nexit "${KIT_RC:-0}"\n' "$LOG" > "$KB/kit"; chmod +x "$KB/kit"
kitseam() { PATH="$KB:$NPATH" RIBBON_PKG_BACKEND=kit bash -c ". '$LIB/common.sh'; . '$LIB/pkg-update.sh'; $1"; }
: > "$LOG"
kitseam 'pkg_install firmware-amd mesa'
check "kit backend, running system: install is kit grab --yes with the ids' names" logged "kit grab --yes firmware-amd mesa"
: > "$LOG"; kitseam 'pkg_remove mesa'
check "kit backend: remove is kit toss --yes" logged "kit toss --yes mesa"
: > "$LOG"; kitseam 'pkg_upgrade -y'
check "kit backend: upgrade is kit check --yes (kitd takes the snapshot)" logged "kit check --yes"
KIT_RC=3 kitseam 'pkg_install mesa'; rc=$?
check "kit backend: kit's exit status is the seam's (a failed grab fails the install)" test "$rc" = 3
KIT_RC=4 kitseam 'pkg_upgrade'; rc=$?
check "kit backend: a failed system check fails the upgrade" test "$rc" = 4
: > "$LOG"; mkdir -p "$T/kroot2/usr/bin"; cp "$KB/kit" "$T/kroot2/usr/bin/kit"
PATH="$NPATH" RIBBON_ROOT="$T/kroot2" RIBBON_PKG_BACKEND=kit RIBBON_KITD=/nonexistent bash -c ". '$LIB/common.sh'; pkg_install mesa" 2>"$T/err"; rc=$?
check "kit backend, a target root without a kitd here: nothing is run and it says so" sh -c "[ '$rc' != 0 ] && [ ! -s '$LOG' ] && grep -q 'no kitd here' '$T/err'"
printf '#!/bin/sh\necho "kitd $*" >> "%s"\nexit "${KIT_RC:-0}"\n' "$LOG" > "$KB/kitd"; chmod +x "$KB/kitd"
PATH="$NPATH" RIBBON_ROOT="$T/kroot2" RIBBON_PKG_BACKEND=kit RIBBON_KITD="$KB/kitd" bash -c ". '$LIB/common.sh'; pkg_install firmware-amd mesa && pkg_remove mesa"; rc=$?
check "kit backend, a target root: kitd itself puts the kits in (kitd --root ROOT grab ...), and takes them out" sh -c "[ '$rc' = 0 ] && grep -qxF 'kitd --root $T/kroot2 grab firmware-amd mesa' '$LOG' && grep -qxF 'kitd --root $T/kroot2 toss mesa' '$LOG' && ! grep -q '^kit ' '$LOG'"
KIT_RC=4 PATH="$NPATH" RIBBON_ROOT="$T/kroot2" RIBBON_PKG_BACKEND=kit RIBBON_KITD="$KB/kitd" bash -c ". '$LIB/common.sh'; pkg_install mesa"; rc=$?
check "kit backend, a target root: kitd's exit status is the seam's" test "$rc" = 4

# ---- 4. regen_initramfs -------------------------------------------------------------
echo "initramfs"
K=$T/kroot
mkdir -p "$K/usr/lib/modules/6.18.2_1" "$K/usr/lib/modules/6.12.60_1" "$K/usr/lib/modules/6.9.1_1/extra" "$K/etc/default" "$K/boot"
: > "$K/usr/lib/modules/6.18.2_1/modules.dep"; : > "$K/usr/lib/modules/6.12.60_1/modules.dep"
: > "$K/boot/vmlinuz-6.18.2_1"; : > "$K/usr/lib/modules/6.12.60_1/vmlinuz"   # the image on /boot, or beside the modules
mkdir -p "$K/usr/lib/modules/6.6.1_1"; : > "$K/usr/lib/modules/6.6.1_1/modules.dep"   # a removed kernel's leftovers
printf 'BOOTLOADER=limine\n' > "$K/etc/default/ribbon-boot"
regen() { PATH=$1 RIBBON_ROOT=$K bash -c '. "$1/common.sh"; regen_initramfs' _ "$LIB" 2>"$T/err"; }
: > "$LOG"; regen "$XPATH"
check "dracut for each installed kernel" sh -c "grep -qxF 'dracut -q --force /boot/initramfs-6.18.2_1.img 6.18.2_1' '$LOG' && grep -qxF 'dracut -q --force /boot/initramfs-6.12.60_1.img 6.12.60_1' '$LOG'"
check "a modules folder without a kernel (6.9.1_1) is left alone" nolog "6.9.1_1"
check "a removed kernel's modules.dep without its image (6.6.1_1) is left alone" nolog "6.6.1_1"
check "no xbps-reconfigure" nolog xbps
check "Limine not set up yet: its menu is not touched" nolog ribbon-limine
: > "$K/etc/default/ribbon-limine"
: > "$LOG"; regen "$NPATH"
check "on any base; then the Limine menu, as the kernel hook does" sh -c "grep -q '^dracut ' '$LOG' && grep -qxF 'ribbon-limine update' '$LOG'"

# ---- 5. the tools ----------------------------------------------------------------------
echo "tools"
Q=$T/q BD=$T/boot.d
pend() { PATH=$1 RIBBON_LIB=$LIB RIBBON_PENDING_DIR=$Q RIBBON_PENDING_LOG=$T/pending.log RIBBON_BOOTD=$BD \
	RIBBON_PKG_BACKEND=${BACKEND:-} bash "$BIN/pending" "${@:2}"; }
pend "$XPATH" add pkg mesa nvidia
check "pending add pkg: queued, and the service enabled" sh -c "[ \"\$(cat '$Q/pkg')\" = 'mesa nvidia' ] && [ -L '$BD/ribbon-pending' ]"
check "pending add xbps: refused (a kind of its own no more)" sh -c "! PATH='$XPATH' RIBBON_LIB='$LIB' RIBBON_PENDING_DIR='$Q' RIBBON_BOOTD='$BD' bash '$BIN/pending' add xbps foo 2>/dev/null"
if [ "$(id -u)" -eq 0 ]; then
	printf 'oldpkg\n' > "$Q/xbps"
	: > "$LOG"; pend "$XPATH" run
	check "pending run: the queue through the seam (Void names), the old xbps queue with it" \
		sh -c "grep -q '^xbps-install -Sy .*mesa-dri.*nvidia-libs-32bit.*oldpkg' '$LOG' && [ ! -e '$Q/pkg' ] && [ ! -e '$Q/xbps' ]"
	check "pending run: everything done, the service disabled" sh -c "[ ! -e '$BD/ribbon-pending' ] && grep -q 'all pending jobs done' '$T/pending.log'"
	pend "$NPATH" add pkg steam
	BACKEND=none pend "$NPATH" run
	check "pending run without a package manager: the job stays queued" sh -c "[ \"\$(cat '$Q/pkg')\" = steam ] && [ -L '$BD/ribbon-pending' ]"
	rm -rf "$Q" "$BD"
else
	echo "  skip pending run (needs root)"
fi
post() { PATH=$1 RIBBON_LIB=$LIB RIBBON_PENDING=$T/pending-stub RIBBON_OFFLINE_REPO=$T/nooffline bash "$BIN/postinstall" "${@:2}"; }
printf '#!/bin/sh\necho "pending $*" >> "$STUB_LOG"\n' > "$T/pending-stub"; chmod +x "$T/pending-stub"
: > "$LOG"; post "$XPATH" drivers "firmware-amd broadcom-wl cups" "" >/dev/null
check "postinstall drivers: what is missing, by Void's names" logged "xbps-install -Sy broadcom-wl-dkms cups [RIBBON_NO_SNAPSHOT=]"
touch "$T/fail-all"
: > "$LOG"; post "$XPATH" drivers "broadcom-wl cups" "" >/dev/null
check "postinstall drivers: what can't be had now is queued, by id" logged "pending add pkg broadcom-wl cups"
rm -f "$T/fail-all"
: > "$LOG"; post "$XPATH" later "steam bolt" "com.discordapp.Discord" >/dev/null
check "postinstall later: the missing apps queued, Flatpaks too" sh -c "grep -qxF 'pending add pkg steam' '$LOG' && grep -qxF 'pending add flatpak com.discordapp.Discord' '$LOG'"
: > "$LOG"; post "$XPATH" apps "steam" >/dev/null
check "postinstall apps: installed now" logged "xbps-install -Sy steam [RIBBON_NO_SNAPSHOT=]"
: > "$LOG"; post "$NPATH" apps "steam" >/dev/null 2>&1
check "postinstall apps without a package manager: queued for later" logged "pending add pkg steam"
G=$T/groot
mkdir -p "$G/usr/bin" "$G/etc/default" "$G/usr/lib/modules/6.18.2_1"
: > "$G/usr/bin/xbps-install"; chmod +x "$G/usr/bin/xbps-install"
: > "$G/usr/lib/modules/6.18.2_1/modules.dep"; mkdir -p "$G/boot"; : > "$G/boot/vmlinuz-6.18.2_1"
if [ "$(id -u)" -eq 0 ]; then
	: > "$LOG"
	PATH=$XPATH RIBBON_LIB=$LIB RIBBON_ROOT=$G RIBBON_OFFLINE_REPO=$T/nooffline bash "$BIN/ribbon-gpu" install amd >/dev/null 2>&1
	check "ribbon-gpu install amd: in the target, Void's names from the map" \
		sh -c "grep -q '^xbps-install -Sy .*linux-firmware-amd.*mesa-dri .*mesa-vulkan-radeon-32bit' '$LOG' && grep -qxF 'chroot $G' '$LOG'"
	check "ribbon-gpu install: the initramfs rebuilt with dracut" logged "dracut -q --force /boot/initramfs-6.18.2_1.img 6.18.2_1"
else
	echo "  skip ribbon-gpu install (needs root)"
fi
check "ribbon-gpu packages: ids" test "$(RIBBON_LIB=$LIB bash "$BIN/ribbon-gpu" packages nvidia)" = "nvidia va-nvidia vulkan-loader"
if [ "$(id -u)" -eq 0 ]; then
	: > "$LOG"
	PATH=$NPATH RIBBON_LIB=$LIB RIBBON_ROOT=$N RESERVE_STATE_DIR=$T/st bash "$BIN/ribbon-reserve" cleanup pkgcache >/dev/null 2>&1
	check "ribbon-reserve cleanup pkgcache without xbps: nothing run" nolog xbps
	check "ribbon-reserve state without xbps: no package cache" grep -qx 'pkgcache=0' "$T/st/reserve"
	PATH=$XPATH RIBBON_LIB=$LIB RIBBON_ROOT=$R RESERVE_STATE_DIR=$T/st bash "$BIN/ribbon-reserve" cleanup pkgcache >/dev/null 2>&1
	check "ribbon-reserve cleanup pkgcache with xbps: xbps-remove -O" logged "xbps-remove -Oy"
	mkdir -p "$R/var/cache/xbps"; head -c 5000 /dev/zero > "$R/var/cache/xbps/a-1_1.x86_64.xbps"
	# any cleanup as root rewrites the state (trash: an empty one of the test's own)
	XDG_DATA_HOME=$T/xdg PATH=$XPATH RIBBON_LIB=$LIB RIBBON_ROOT=$R RESERVE_STATE_DIR=$T/st bash "$BIN/ribbon-reserve" cleanup trash >/dev/null 2>&1
	check "ribbon-reserve state with xbps: the cache's size" grep -qx 'pkgcache=[0-9]\{4,\}' "$T/st/reserve"
else
	echo "  skip ribbon-reserve cleanup (needs root)"
fi

# ---- 7. the base-neutral parts -----------------------------------------------------------
echo "base-neutral parts"
SV=$T/sv; mkdir -p "$SV"
: > "$LOG"
RIBBON_SV_DIR=$SV seam "$XPATH" 'pkg_install steam' >/dev/null 2>&1
check "install on a base with runit services: the services converted after it" sh -c "grep -qxF 'xbps-install -Sy steam [RIBBON_NO_SNAPSHOT=]' '$LOG' && [ \"\$(tail -n1 '$LOG')\" = 'ribbon-sv2dinit --quiet' ]"
: > "$LOG"
RIBBON_SV_DIR=$SV seam "$XPATH" 'pkg_remove bolt' >/dev/null 2>&1
check "remove: the services converted after it" sh -c "[ \"\$(tr '\n' '|' < '$LOG')\" = 'xbps-remove -Ry bolt|ribbon-sv2dinit --quiet|' ]"
: > "$LOG"
RIBBON_SV_DIR=$T/nosv seam "$XPATH" 'pkg_install steam; pkg_services_sync' >/dev/null 2>&1
check "a base without runit services (no /etc/sv): nothing to convert" nolog "ribbon-sv2dinit"
touch "$T/fail-all"; : > "$LOG"
RIBBON_SV_DIR=$SV seam "$XPATH" 'pkg_install steam' >/dev/null 2>&1
check "a failed install converts nothing" nolog "ribbon-sv2dinit"
rm -f "$T/fail-all"

K=$T/kmroot; mkdir -p "$K/etc" "$K/var/db/xbps"
printf '# void-runit\n#KEYMAP="es"\nHARDWARECLOCK="UTC"\n' > "$K/etc/rc.conf"
check "keymap: us when nothing says" test "$(ROOT=$K seam "$NPATH" pkg_console_keymap)" = us
ROOT=$K seam "$NPATH" 'pkg_console_keymap de-latin1'
check "keymap on xbps: /etc/vconsole.conf, and Void's rc.conf kept in step (its other lines too)" sh -c "[ \"\$(cat '$K/etc/vconsole.conf')\" = KEYMAP=de-latin1 ] && grep -qx 'KEYMAP=\"de-latin1\"' '$K/etc/rc.conf' && grep -qx 'HARDWARECLOCK=\"UTC\"' '$K/etc/rc.conf' && [ \"\$(grep -c KEYMAP '$K/etc/rc.conf')\" = 1 ]"
printf 'FONT=ter-v16n\nKEYMAP=us\n' > "$K/etc/vconsole.conf"
ROOT=$K seam "$NPATH" 'pkg_console_keymap fr'
check "keymap: an existing vconsole.conf keeps its font" sh -c "[ \"\$(tr '\n' ' ' < '$K/etc/vconsole.conf')\" = 'FONT=ter-v16n KEYMAP=fr ' ]"
check "keymap read back: vconsole.conf's" test "$(ROOT=$K seam "$NPATH" pkg_console_keymap)" = fr
rm -f "$K/etc/vconsole.conf"
check "keymap read back on xbps without vconsole.conf: Void's rc.conf" test "$(ROOT=$K seam "$NPATH" pkg_console_keymap)" = fr
check "keymap: a name with shell or sed characters is refused" sh -c "! RIBBON_ROOT='$K' PATH='$NPATH' bash '$LIB/pkg.sh' keymap 'us/../x' 2>/dev/null && [ ! -e '$K/etc/vconsole.conf' ]"
rm -rf "$K/var/db/xbps"; printf '#KEYMAP="es"\n' > "$K/etc/rc.conf"
RIBBON_ROOT=$K PATH=$NPATH bash "$LIB/pkg.sh" keymap uk
check "keymap on another base (pkg.sh keymap): vconsole.conf only, rc.conf untouched" sh -c "[ \"\$(cat '$K/etc/vconsole.conf')\" = KEYMAP=uk ] && [ \"\$(cat '$K/etc/rc.conf')\" = '#KEYMAP=\"es\"' ]"
check "keymap on another base: rc.conf is not read" sh -c "rm -f '$K/etc/vconsole.conf'; printf 'KEYMAP=\"es\"\n' > '$K/etc/rc.conf'; [ \"\$(RIBBON_ROOT='$K' PATH='$NPATH' bash '$LIB/pkg.sh' keymap)\" = us ]"

# Ribbon's own packages by make install's record (build/install/install.sh), on a base without a package manager
M=$T/mk; mkdir -p "$M/etc"
if O=$T/nobuild RECORD=$T/rec DESTDIR=$M RIBBON_PKG_BACKEND=none sh build/install/install.sh install ribbon-installer >/dev/null 2>"$T/mk.err"; then
	mkdir -p "$M/usr/share/applications"; : > "$M/usr/share/applications/other.desktop"   # another package's
	rec=$M/var/lib/ribbon/installed/ribbon-installer.files
	check "make install leaves its record on the target (the paths as that system sees them)" sh -c "[ \"\$(head -n1 '$rec')\" = '# DESTDIR=' ] && grep -qxF 'f /usr/bin/ribbon-install' '$rec' && ! grep -qF '$M' '$rec'"
	check "query: Ribbon's installer is installed by its record (no package manager)" sh -c "PATH='$NPATH' RIBBON_ROOT='$M' bash -c '. \"$LIB/pkg.sh\"; pkg_query installer'"
	check "missing: not the recorded installer, still the rest" test "$(ROOT=$M seam "$NPATH" 'pkg_missing installer cups' | tr '\n' ' ')" = "cups "
	ROOT=$M seam "$NPATH" 'pkg_remove installer'; rc=$?
	left=$(cd "$M" && find . ! -type d | sort | tr '\n' ' ')
	check "remove: by the record, every file and the record gone, another package's left (exit $rc; left: $left)" \
		test "$rc:$left" = "0:./usr/share/applications/other.desktop "
	check "remove: the directories it made and left empty are gone" sh -c "[ ! -e '$M/usr/lib/ribbon/installer-backend' ] && [ ! -e '$M/var/lib/ribbon/installed' ] && [ -d '$M/usr/share/applications' ]"
	check "after the removal: no record, so nothing to tell (2)" sh -c "PATH='$NPATH' RIBBON_ROOT='$M' bash -c '. \"$LIB/pkg.sh\"; pkg_query installer'; [ \$? -eq 2 ]"
	check "postinstall live-cleanup drops the installer through the seam (pkg_query, pkg_remove)" sh -c "grep -q 'local drop=\"installer\"' '$BIN/postinstall' && grep -q 'pkg_query \"\$p\" || continue' '$BIN/postinstall' && grep -q 'pkg_remove \"\$p\"' '$BIN/postinstall'"
else
	sed 's/^/       /' "$T/mk.err"; fail "make install of ribbon-installer into a scratch root"
fi
check "pkg-names.ribbon names the installer's package, and every name is a package of this repository" sh -c "awk 'sub(/#.*/, \"\") >= 0 && NF == 2 { print \$2 }' '$LIB/pkg-names.ribbon' | while read -r p; do [ -f \"build/install/manifests/\$p.manifest\" ] || exit 1; done && grep -qE '^installer[[:space:]]+ribbon-installer\$' '$LIB/pkg-names.ribbon'"

# ---- 6. pkg.tcl ------------------------------------------------------------------------
echo "pkg.tcl"
cat > "$T/stub-pkg.sh" <<'EOF'
case "$1" in
	map) echo "mesa mesa-dri mesa-dri-32bit"; echo "firmware-amd linux-firmware-amd" ;;
	installed) printf 'mesa-dri\nmesa-dri-32bit\n' ;;
	locales) printf 'en_GB.UTF-8\n' ;;
esac
EOF
out=$(PATH=$NPATH tclsh8.6 <<EOF
source $LIB/pkg.tcl
puts [list [::rbpkg::has $R microcode-intel] [::rbpkg::has $R firmware-amd] [::rbpkg::missing $R {firmware-network firmware-amd cups}] [::rbpkg::locales $R]]
set env(RIBBON_PKG) $T/stub-pkg.sh
::rbpkg::reset
puts [list [::rbpkg::has $N mesa] [::rbpkg::missing $N {mesa firmware-amd}] [::rbpkg::locales $N]]
EOF
)
check "pkg.tcl on a root's pkgdb: has, missing, locales" test "$(echo "$out" | sed -n 1p)" = "1 0 firmware-amd {en_US.UTF-8 en_GB.UTF-8 de_DE}"
check "pkg.tcl with a stand-in seam (a base without xbps)" test "$(echo "$out" | sed -n 2p)" = "1 firmware-amd en_GB.UTF-8"

[ "$fails" -eq 0 ] || { echo "package seam: $fails failure(s)"; exit 1; }
echo "package seam: all checks passed"
