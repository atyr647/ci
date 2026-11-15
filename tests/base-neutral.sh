#!/bin/bash
# The base-specific pieces behind their seams (docs/SYSTEM-UPDATES.md, "Phasing, from Void to independence"):
#   1. no package-manager wrapper: no xbps-install wrapper installed or put first on root's PATH, ribbon.conf
#      without its lines, ribbon-tools without an xbps dependency (only ribbon-base, the Void base, has it);
#   2. make install's `base` lines: Void's xbps.d files and kernel.d hook point only where xbps is the base's
#      package manager (build/install/install.sh, RIBBON_PKG_BACKEND);
#   3. kernel-changed (/usr/lib/ribbon/kernel-changed), the base-neutral kernel hook, and Void's kernel.d hook
#      point that calls it: the Limine menu, and /run/ribbon/reboot-required for a kernel installed outside
#      ribbon update (not for the running one, not in a chroot);
#   4. ribbon-dinit: the runit compatibility only where the base has runit services (/etc/sv), no xbps in init;
#      the console keymap and font from /etc/vconsole.conf (boot.sh's console step), rc.conf's only without it.
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
TOOLS=$REPO/srcpkgs/ribbon-tools
DINIT=$REPO/srcpkgs/ribbon-dinit/files
fails=0
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else fail "$d"; fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---- 1. no wrapper in front of the package manager ------------------------------------
echo "no package-manager wrapper"
check "no xbps-install wrapper in ribbon-tools (files, template, manifest)" sh -c "[ ! -e '$TOOLS/files/bin/xbps-install-wrapper' ] && ! grep -q 'xbps-install' '$TOOLS/template' && ! grep -q 'xbps-install' build/install/manifests/ribbon-tools.manifest && ! grep -q 'usr/lib/ribbon/bin' '$TOOLS/template'"
check "sudoers: no secure_path putting a wrapper first on root's PATH" sh -c "! grep -q secure_path srcpkgs/ribbon-base/files/sudoers && grep -qx '%wheel ALL=(ALL:ALL) ALL' srcpkgs/ribbon-base/files/sudoers"
check "ribbon.conf: no wrapper and no runit setting" sh -c "! grep -qi -e wrapper -e SV2DINIT srcpkgs/ribbon-base/files/ribbon.conf && grep -qx 'SNAPSHOT_BEFORE_UPDATE=yes' srcpkgs/ribbon-base/files/ribbon.conf"
check "nothing reads SV2DINIT_AFTER_UPDATE or sets RIBBON_NO_SNAPSHOT any more" sh -c "! grep -rqE 'SV2DINIT_AFTER_UPDATE|RIBBON_NO_SNAPSHOT=1' srcpkgs/ribbon-tools srcpkgs/ribbon-base srcpkgs/ribbon-dinit srcpkgs/ribbon-kit/files srcpkgs/ribbon-desktop/files"
deps() { XBPS_CROSS_BASE='' bash -c '. "$1" >/dev/null 2>&1; echo " $depends "' _ "$1"; }
check "ribbon-tools does not depend on xbps; ribbon-base (the Void base) does" sh -c "case '$(deps "$TOOLS/template")' in *' xbps '*) exit 1 ;; esac; case '$(deps srcpkgs/ribbon-base/template)' in *' xbps '*) exit 0 ;; esac; exit 1"

# ---- 2. make install's base lines ----------------------------------------------------------
echo "make install: the base's own files"
lst() { RIBBON_PKG_BACKEND=$1 O=$T/nobuild sh build/install/install.sh list "$2" 2>/dev/null; }
n=$(lst xbps ribbon-base | grep -c '/xbps.d/' || :)
check "ribbon-base on xbps: Void's xbps.d files ($n)" test "$n" = 2
n=$(lst none ribbon-base | grep -c 'xbps' || :)
check "ribbon-base on a base without xbps: no xbps.d file ($n)" test "$n" = 0
check "ribbon-base on any base: the rest (sudoers, ribbon.conf, dracut.conf, nftables.conf)" sh -c "[ \"\$(RIBBON_PKG_BACKEND=none O='$T/nobuild' sh build/install/install.sh list ribbon-base | grep -cE 'sudoers.d/10-ribbon|ribbon/ribbon.conf|10-ribbon.conf|nftables.conf')\" = 4 ]"
check "ribbon-tools on xbps: Void's kernel.d hook point, post-install and post-remove" sh -c "[ \"\$(RIBBON_PKG_BACKEND=xbps O='$T/nobuild' sh build/install/install.sh list ribbon-tools | grep -c '^f 755 /etc/kernel.d/post-\(install\|remove\)/60-ribbon-limine\$')\" = 2 ]"
check "ribbon-tools on any base: kernel-changed, no kernel.d" sh -c "out=\$(RIBBON_PKG_BACKEND=none O='$T/nobuild' sh build/install/install.sh list ribbon-tools); printf '%s\n' \"\$out\" | grep -qx 'f 755 /usr/lib/ribbon/kernel-changed' && ! printf '%s\n' \"\$out\" | grep -q kernel.d"
check "list names the record left on the target" sh -c "RIBBON_PKG_BACKEND=none O='$T/nobuild' sh build/install/install.sh list ribbon-installer | grep -qx 'r /var/lib/ribbon/installed/ribbon-installer.files'"
mkdir -p "$T/xroot/var/db/xbps" "$T/xroot/etc"
check "the base is found in DESTDIR when it is a system (its xbps database)" sh -c "O='$T/nobuild' DESTDIR='$T/xroot' RIBBON_PKG_BACKEND= sh build/install/install.sh list ribbon-base | grep -q '/etc/xbps.d/00-repository-main.conf'"
check "a manifest's base line with no directive is refused" sh -c "mkdir -p '$T/man'; echo 'base xbps' > '$T/man/x.manifest'; ! MANIFESTS='$T/man' RIBBON_PKG_BACKEND=xbps sh build/install/install.sh list x 2>/dev/null"
# install and uninstall: the record on the target goes with the package
D=$T/dest
if O=$T/nobuild RECORD=$T/rec DESTDIR=$D RIBBON_PKG_BACKEND=none sh build/install/install.sh install ribbon-installer >/dev/null 2>&1; then
	check "install: the target's record lists the package's files" sh -c "[ \"\$(grep -c '^f ' '$D/var/lib/ribbon/installed/ribbon-installer.files')\" = \"\$(grep -c '^f ' '$T/rec/ribbon-installer.files')\" ]"
	O=$T/nobuild RECORD=$T/rec DESTDIR=$D sh build/install/install.sh uninstall ribbon-installer >/dev/null 2>&1
	check "uninstall: nothing left, the target's record included" test -z "$(find "$D" -mindepth 1 | head -n1)"
else
	fail "install.sh install ribbon-installer"
fi

# ---- 3. the kernel hook --------------------------------------------------------------------------
echo "kernel hook"
KC=$TOOLS/files/bin/kernel-changed
R=$T/kroot; mkdir -p "$R/etc/default"
printf '#!/bin/sh\necho "ribbon-limine $*" >> "%s"\n' "$T/klog" > "$T/limine"; chmod +x "$T/limine"
kc() { : > "$T/klog"; rm -rf "$T/run"; RIBBON_ROOT=$R RIBBON_RUN=$T/run RIBBON_LIMINE=$T/limine RIBBON_RUNNING=6.18.58_1 RIBBON_CHROOTED=${CHR:-0} sh "$KC" "$@"; }
printf 'RIBBON_ROOT_CMDLINE="root=UUID=x"\n' > "$R/etc/default/ribbon-limine"
printf 'BOOTLOADER=limine\n' > "$R/etc/default/ribbon-boot"
kc install 6.18.63-ribbon_1
check "a new kernel: the Limine menu again, and the restart flag" sh -c "[ \"\$(cat '$T/klog')\" = 'ribbon-limine update' ] && [ -e '$T/run/reboot-required' ]"
kc install 6.18.58_1
check "the running kernel reinstalled: the menu, no restart flag" sh -c "[ -s '$T/klog' ] && [ ! -e '$T/run/reboot-required' ]"
kc remove 6.18.40_1
check "a kernel removed: the menu, no restart flag" sh -c "[ \"\$(cat '$T/klog')\" = 'ribbon-limine update' ] && [ ! -e '$T/run/reboot-required' ]"
CHR=1 kc install 6.18.63-ribbon_1
check "inside a chroot (an installer's target): no restart flag for the running system" test ! -e "$T/run/reboot-required"
printf 'BOOTLOADER="grub"\n' > "$R/etc/default/ribbon-boot"
kc install 6.18.63-ribbon_1
check "GRUB is the boot loader: no Limine menu, the restart flag still" sh -c "[ ! -s '$T/klog' ] && [ -e '$T/run/reboot-required' ]"
printf '#!/bin/sh\nexit 1\n' > "$T/limine"
printf 'BOOTLOADER=limine\n' > "$R/etc/default/ribbon-boot"
kc install 6.18.63-ribbon_1 2>/dev/null; rc=$?
check "a menu that cannot be written does not fail the kernel package (exit $rc)" test "$rc" = 0
# Void's hook point: which directory ran it says install or remove; the version is its second word
H=$TOOLS/files/kernel.d/60-ribbon-limine
mkdir -p "$T/hk/post-install" "$T/hk/post-remove"
printf '#!/bin/sh\necho "kernel-changed $*" > "%s"\n' "$T/hlog" > "$T/kc-stub"; chmod +x "$T/kc-stub"
for d in post-install post-remove; do sed "s|/usr/lib/ribbon/kernel-changed|$T/kc-stub|" "$H" > "$T/hk/$d/60-ribbon-limine"; chmod +x "$T/hk/$d/60-ribbon-limine"; done
"$T/hk/post-install/60-ribbon-limine" linux6.18 6.18.63_1
check "kernel.d post-install: kernel-changed install VERSION" test "$(cat "$T/hlog")" = "kernel-changed install 6.18.63_1"
"$T/hk/post-remove/60-ribbon-limine" linux6.18 6.18.40_1
check "kernel.d post-remove: kernel-changed remove VERSION" test "$(cat "$T/hlog")" = "kernel-changed remove 6.18.40_1"
check "the kernel.d hook point only calls kernel-changed (nothing else of Ribbon's in Void's hook)" sh -c "grep -v '^[[:space:]]*#' '$H' | grep -q 'exec /usr/lib/ribbon/kernel-changed' && ! grep -v '^[[:space:]]*#' '$H' | grep -q -e ribbon-limine -e reboot-required"

# ---- 4. ribbon-dinit -----------------------------------------------------------------------------
echo "ribbon-dinit"
check "init converts runit services only where the base has them (/etc/sv)" grep -q '^if \[ -d /etc/sv \] && .*ribbon-sv2dinit' "$DINIT/init"
check "no xbps in ribbon-dinit's programs" sh -c "! grep -v '^[[:space:]]*#' '$DINIT/init' '$DINIT/boot.sh' '$DINIT/shutdown-hook' '$DINIT/ribbon-sv2dinit' | grep -q xbps"
check "ribbon doctor checks runit services only where there are any" grep -q '^if \[ -d /etc/sv \] && have ribbon-sv2dinit' "$TOOLS/files/bin/ribbon-doctor"
# boot.sh's console settings, on a fake /etc (its paths taken to it)
B=$T/boot; mkdir -p "$B/etc"
sed -e "s|/etc/rc.conf|$B/etc/rc.conf|g" -e "s|/etc/vconsole.conf|$B/etc/vconsole.conf|g" "$DINIT/boot.sh" |
	sed -n '1,/^msg()/p' | sed '$d' > "$T/console.sh"
cons() { sh -c ". '$T/console.sh'; echo \"\$KEYMAP|\${FONT:-}|\${FONT_MAP:-}\""; }
printf 'KEYMAP="es"\nFONT="lat9w-16"\n' > "$B/etc/rc.conf"
check "no vconsole.conf: rc.conf's keymap and font (Void's way)" test "$(cons)" = "es|lat9w-16|"
printf 'KEYMAP=de-latin1\nFONT_MAP=8859-1\n' > "$B/etc/vconsole.conf"
check "vconsole.conf is the source: its keymap wins, rc.conf's font where it has none" test "$(cons)" = "de-latin1|lat9w-16|8859-1"
printf 'KEYMAP=\nFONT="ter-v16n"\n' > "$B/etc/vconsole.conf"
check "an empty KEYMAP= in vconsole.conf does not clear rc.conf's" test "$(cons)" = "es|ter-v16n|"
rm -f "$B/etc/rc.conf"; printf "KEYMAP='uk'\n" > "$B/etc/vconsole.conf"
check "another base (no rc.conf): vconsole.conf alone" test "$(cons)" = "uk||"

[ "$fails" -eq 0 ] && echo "base-neutral pieces: all checks passed" || { echo "base-neutral pieces: $fails failure(s)"; exit 1; }
