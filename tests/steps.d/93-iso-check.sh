#!/bin/sh
# The live image's last check (build/iso-check.sh, run by build/iso-postsetup.sh) and the order build/build-iso.sh gives
# void-mklive its repositories in. On 23 Nov the image turned out to hold Void's base-files and bcachefs-dkms where
# Ribbon builds its own (mklive looks in the LAST -r first, and Ribbon's was given first), and a bcachefs module that
# DKMS had failed to build was simply missing. xbps-query and xbps-uhelper are stood in for (there is no xbps here):
# the stand-ins read a made-up package database.
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
C=$PWD/build/iso-check.sh
mkdir -p "$T/bin" "$T/repo" "$T/root/db"
cat > "$T/bin/xbps-uhelper" <<'EOF'
#!/bin/sh
case $1 in
binpkgver) b=$(basename "$2"); echo "${b%.x86_64.xbps}" ;;
getpkgname) echo "${2%-*}" ;;
*) exit 1 ;;
esac
EOF
cat > "$T/bin/xbps-query" <<'EOF'
#!/bin/sh
# xbps-query -r ROOT -p PROPERTY NAME
[ "$1" = -r ] && [ "$3" = -p ] || exit 1
f=$2/db/$5.$4
[ -f "$f" ] || exit 2
cat "$f"
EOF
cat > "$T/bin/xbps-pkgdb" <<'EOF'
#!/bin/sh
# xbps-pkgdb -r ROOT -a: ROOT/db/pkgdb.problems holds what it reports
[ "$1" = -r ] && [ "$3" = -a ] || exit 2
[ -s "$2/db/pkgdb.problems" ] || exit 0
cat "$2/db/pkgdb.problems"; exit 1
EOF
chmod 755 "$T/bin/xbps-uhelper" "$T/bin/xbps-query" "$T/bin/xbps-pkgdb"
pkg() { # NAME VERSION [REPOSITORY]: in Ribbon's repository, and installed from REPOSITORY (default Ribbon's)
	: > "$T/repo/$1-$2.x86_64.xbps"
	echo "$1-$2" > "$T/root/db/$1.pkgver"; echo "${3:-$T/repo}" > "$T/root/db/$1.repository"
}
mods() { # KERNEL MODULE...
	k=$1; shift
	mkdir -p "$T/root/usr/lib/modules/$k/kernel"
	for m; do mkdir -p "$T/root/usr/lib/modules/$k/extra"; : > "$T/root/usr/lib/modules/$k/extra/$m.ko.xz"; done
}
chk() { PATH=$T/bin:$PATH RIBBON_REPO_DIR=$T/repo sh "$C" "$T/root" > "$T/out" 2>&1; }
pkg ribbon-tools 0.1.0_1; pkg base-files 0.146_1; pkg bcachefs-dkms 1.36.1_1
: > "$T/repo/ribbon-extra-1.0_1.x86_64.xbps"      # in the repository, not installed in the image: not the check's business
mods 6.18.64-ribbon_1 zfs bcachefs; mods 6.18.64_1 zfs bcachefs
if chk && grep -q "3 packages from Ribbon's repository, 2 kernels .*, the package database consistent" "$T/out"; then
	ok "an image of Ribbon's packages, each kernel with zfs and bcachefs, passes (a package the image does not install is not looked at)"
else bad "a good image: $(cat "$T/out")"; fi
printf 'ERROR: greetd: hash mismatch for /etc/pam.d/greetd.\nERROR: ribbon-gaming: dependency not satisfied: wine-32bit>=0\n' > "$T/root/db/pkgdb.problems"
if chk || ! grep -q "the package database reports problems" "$T/out" || ! grep -q "iso-check:   ERROR: greetd: hash mismatch for /etc/pam.d/greetd." "$T/out" ||
	! grep -q "dependency not satisfied: wine-32bit" "$T/out"; then
	bad "a package database with problems was not refused, or not shown: $(cat "$T/out")"
else ok "a package database xbps-pkgdb -a finds faults in (an edited package file, an unmet dependency) stops the image, each fault shown"; fi
rm "$T/root/db/pkgdb.problems"
echo "https://repo-default.voidlinux.org/current" > "$T/root/db/base-files.repository"
if chk || ! grep -q "base-files (base-files-0.146_1) was installed from https://repo-default.voidlinux.org/current, not from Ribbon's repository" "$T/out"; then
	bad "Void's build of a package Ribbon overrides was not refused: $(cat "$T/out")"
else ok "a package Ribbon builds that the image took from Void's repository (same version) stops the image, named"; fi
echo "$T/repo/" > "$T/root/db/base-files.repository"
echo "bcachefs-dkms-1.36.0_1" > "$T/root/db/bcachefs-dkms.pkgver"
if chk || ! grep -q "bcachefs-dkms: the image has bcachefs-dkms-1.36.0_1, Ribbon's repository bcachefs-dkms-1.36.1_1" "$T/out"; then
	bad "another version than Ribbon's was not refused: $(cat "$T/out")"
else ok "and so does another version than the repository's"; fi
echo "bcachefs-dkms-1.36.1_1" > "$T/root/db/bcachefs-dkms.pkgver"
rm "$T/root/usr/lib/modules/6.18.64-ribbon_1/extra/bcachefs.ko.xz"
if chk || ! grep -q "kernel 6.18.64-ribbon_1 has no bcachefs module" "$T/out" || grep -q "kernel 6.18.64_1 has no" "$T/out"; then
	bad "a kernel without its bcachefs module was not refused: $(cat "$T/out")"
else ok "a kernel whose bcachefs module DKMS did not build stops the image, the kernel and module named"; fi
: > "$T/root/usr/lib/modules/6.18.64-ribbon_1/extra/bcachefs.ko.xz"
rm "$T"/root/db/*
if chk || ! grep -q "nothing of Ribbon's repository" "$T/out"; then bad "an image with none of Ribbon's packages: $(cat "$T/out")"
else ok "an image with nothing of Ribbon's repository installed is refused"; fi

# build-iso.sh: Ribbon's repository is the last -r (mklive looks there first), it stops if mklive changes that, the
# hook runs the check, and the hook is told where the repository is
I=build/build-iso.sh
last=$(grep -E '^[[:space:]]+-r "' $I | tail -n1)
case $last in *'-r "$RIBBON_REPO_DIR"'*) ok "build-iso.sh gives void-mklive Ribbon's repository last (the one it looks in first)" ;; *) bad "the last -r of build-iso.sh: $last" ;; esac
grep -q 'no longer puts a later -r first' $I && grep -q 'export RIBBON_XBPS_REPOS RIBBON_ARCH RIBBON_REPO_DIR' $I &&
	grep -q 'iso-check.sh" "$ROOTFS"' build/iso-postsetup.sh &&
	ok "build-iso.sh stops if mklive's order changes; iso-postsetup.sh runs iso-check.sh on the image" ||
	bad "build-iso.sh's guard, or iso-postsetup.sh's call of iso-check.sh"
# what the package database check found in the first installed systems (24 Nov), each kept from coming back:
# greetd's PAM file is a configuration file in Ribbon's build of greetd (ribbon-desktop's INSTALL adds its lines to it)
mkdir -p "$T/greetd"
printf '# Template file for greetd\npkgname=greetd\nconf_files="/etc/greetd/config.toml"\n' > "$T/greetd/template"
if sh build/overrides/greetd/apply.sh "$T/greetd" && grep -qx 'conf_files="/etc/greetd/config.toml /etc/pam.d/greetd"' "$T/greetd/template" &&
	sh build/overrides/greetd/apply.sh "$T/greetd" && [ "$(grep -c '^conf_files=.*/etc/pam.d/greetd' "$T/greetd/template")" = 1 ] &&
	grep -q '^OVERRIDES=(.* greetd[ )]' build/build-packages.sh; then
	ok "greetd's override makes /etc/pam.d/greetd a configuration file (once), and build-packages.sh applies it"
else cat "$T/greetd/template"; bad "the greetd override"; fi
printf 'pkgname=greetd\nconf_files="/etc/greetd/other.toml"\n' > "$T/greetd/template"
sh build/overrides/greetd/apply.sh "$T/greetd" 2>/dev/null && bad "the greetd override changed a template it does not know" ||
	ok "  and stops on a template whose conf_files it does not know"
# the live session's installer launcher is a file of its own, not a line added to a package's file
a=build/live-rootfs/etc/xdg/labwc/autostart
if ! grep -qE '>>?[[:space:]]*"?\$ROOTFS/usr' build/iso-postsetup.sh && head -n1 "$a" | grep -qx '# Ribbon live ISO: offer the installer.*' &&
	grep -q "grep -q '^# Ribbon live ISO: offer the installer' /etc/xdg/labwc/autostart" srcpkgs/ribbon-tools/files/bin/postinstall; then
	ok "the live installer launcher is build/live-rootfs's /etc/xdg/labwc/autostart (iso-postsetup.sh edits nothing in /usr), and live-cleanup knows it"
else bad "the live launcher: iso-postsetup.sh writes into /usr, or postinstall's live-cleanup does not match $a"; fi
# the console's greeting: base-files' issue names Ribbon OS, and live-cleanup puts it back over mklive's live one
mkdir -p "$T/bf/files" "$T/lc/etc"
printf 'Void \\r (\\n) (\\l)\n\n' > "$T/bf/files/issue"; printf 'pkgname=base-files\n' > "$T/bf/template"
cp build/overrides/base-files/os-release "$T/bf/os-release.ref" 2>/dev/null
sh build/overrides/base-files/apply.sh "$T/bf" >/dev/null 2>&1
[ "$(head -n1 "$T/bf/files/issue")" = 'Ribbon OS \r (\n) (\l)' ] && ok "base-files' /etc/issue names Ribbon OS" ||
	bad "base-files' issue: $(cat "$T/bf/files/issue")"
sed -n '/^step_live_cleanup() {/,/^}/p' srcpkgs/ribbon-tools/files/bin/postinstall | grep -q 'issue.new-' &&
	grep -q "Live system" srcpkgs/ribbon-tools/files/bin/postinstall &&
	ok "live-cleanup puts base-files' /etc/issue back over void-mklive's live greeting" ||
	bad "live-cleanup leaves the live system's /etc/issue (Void Linux Live, its passwords) on the installed system"
# wine replaces wine-32bit (WoW64): nothing of Ribbon's may depend on it
grep -hv '^[[:space:]]*#' srcpkgs/*/template | grep -q 'wine-32bit' && bad "a template depends on wine-32bit, which wine replaces" ||
	ok "no template depends on wine-32bit (Void's wine is WoW64 and replaces it)"

# the live root is dracut-ng's overlayfs: rd.overlay=1 (mklive's own rd.overlayfs=1 is not read by dracut-ng 112)
grep -E '^[[:space:]]+-C "[^"]*\<rd\.overlay=1\>' $I >/dev/null &&
	ok "build-iso.sh asks dracut for the overlayfs live root (rd.overlay=1)" ||
	bad "build-iso.sh's command line does not ask for dracut-ng's overlayfs (rd.overlay=1)"
exit $fail
