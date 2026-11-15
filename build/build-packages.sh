#!/bin/bash
# Build Ribbon's own packages (srcpkgs/*) plus the overridden Void packages
# (build/overrides/*) with xbps-src, into a local xbps repository.
#
# Runs on a Void Linux host or container (see .github/workflows/build.yml):
#   build/build-packages.sh [pkg ...]        (default: everything)
# Environment: see config/ribbon.conf. RIBBON_SIGN_KEY=/path/to/privkey.pem
# signs the repository (needed for a public/hosted repository).
set -euo pipefail
cd "$(dirname "$0")/.."
. config/ribbon.conf

VP=out/void-packages
OWN_PKGS=(tkdnd tcl-unix-sockets tcl-unix-extra mk4tcl mkkitfs ribbon-kernel ribbon-dinit ribbon-tools ribbon-base font-jetbrains-mono ribbon-desktop ribbon-gaming ribbon-installer ribbon-kit)
OVERRIDES=(base-files wlroots0.20)

msg() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# Ribbon's kernel is built by its own workflow only (build/ci/kernel.yml), never here: the image job fetches its
# release into the repository (build/ci/kernel.sh fetch). Without one, the image has Void's linux6.18 only.
kernel_prebuilt() { ls "$RIBBON_REPO_DIR"/ribbon-kernel-[0-9]*.xbps >/dev/null 2>&1; }
# TEMPLATE: ribbon-kernel (with or without a version constraint) out of its depends, so that nothing built here
# needs a kernel package that is not in the repository (ribbon-base's dependency comes back with the release)
drop_kernel_dep() {
	local r
	r=$(awk '/^depends="/ { s = NR } s && NR >= s { q = $0; if (NR == s) sub(/^depends="/, "", q)
		if (q ~ /"/) { print s "," NR; exit } }' "$1")
	[ -n "$r" ] || return 0
	sed -E -i "${r}s/(^|[[:space:]\"])ribbon-kernel([<>=][^[:space:]\"]*)?([[:space:]\"]|\$)/\1\3/g" "$1"
}

if [ ! -d "$VP/.git" ]; then
	msg "Cloning void-packages"
	git clone --depth 1 "$VOID_PACKAGES_GIT" "$VP"
else
	msg "Updating void-packages"
	git -C "$VP" fetch --depth 1 origin master && git -C "$VP" reset --hard FETCH_HEAD
fi

msg "Bootstrapping xbps-src"
echo XBPS_ALLOW_RESTRICTED=yes > "$VP/etc/conf"
# In a container the default chroot method (user namespaces) may be refused; RIBBON_XBPS_CHROOT_CMD=uchroot uses
# xbps-uchroot instead (the builder must be in the group xbuilder).
[ -z "${RIBBON_XBPS_CHROOT_CMD:-}" ] || echo "XBPS_CHROOT_CMD=$RIBBON_XBPS_CHROOT_CMD" >> "$VP/etc/conf"
"$VP/xbps-src" binary-bootstrap

msg "Copying Ribbon packages into void-packages"
for p in "${OWN_PKGS[@]}"; do
	rm -rf "$VP/srcpkgs/$p"
	cp -a "srcpkgs/$p" "$VP/srcpkgs/$p"
	# Ribbon's kernel: its config fragments (build/kernel/config) and its subpackages' srcpkgs links
	if [ "$p" = ribbon-kernel ]; then
		mkdir -p "$VP/srcpkgs/$p/files/config"
		cp build/kernel/config/* "$VP/srcpkgs/$p/files/config/"
		for s in ribbon-kernel-headers ribbon-kernel-dbg; do rm -rf "$VP/srcpkgs/$s"; ln -s ribbon-kernel "$VP/srcpkgs/$s"; done
	fi
	# third-party sources added here first get their checksum computed
	# a template whose checksum is still the placeholder gets it from the distfile as it is today (the line printed
	# is to be pinned in the template: a pinned checksum is what guards against a changed download)
	if grep -q '^checksum=@XGENSUM@' "$VP/srcpkgs/$p/template"; then
		# shellcheck disable=SC1090,SC2034,SC2154
		url=$(set +u; XBPS_CROSS_BASE=; . "$VP/srcpkgs/$p/template" >/dev/null 2>&1; echo "$distfiles")
		sum=$(curl -fsSL --retry 3 "$url" | sha256sum | cut -d' ' -f1)
		[ ${#sum} -eq 64 ] && [ "$sum" != e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ] ||
			{ echo "could not fetch $url for its checksum" >&2; exit 1; }
		sed -i "s/^checksum=@XGENSUM@/checksum=$sum/" "$VP/srcpkgs/$p/template"
		echo "PIN: srcpkgs/$p/template checksum=$sum"
	fi
	# Ribbon's licence goes with every package that ships Ribbon's own files
	if [ -d "$VP/srcpkgs/$p/files" ]; then cp LICENSE "$VP/srcpkgs/$p/files/LICENSE"; fi
	# kit ships the reference kit reader and writer (kit/kitfmt) and the signing policy (kit/kittrust)
	if [ "$p" = ribbon-kit ]; then
		mkdir -p "$VP/srcpkgs/$p/files/kitfmt" "$VP/srcpkgs/$p/files/kittrust"
		cp kit/kitfmt/kitfmt.tcl kit/kitfmt/sha256.tcl kit/kitfmt/pkgIndex.tcl kit/kitfmt/kitpack "$VP/srcpkgs/$p/files/kitfmt/"
		cp kit/kittrust/kittrust.tcl kit/kittrust/pkgIndex.tcl "$VP/srcpkgs/$p/files/kittrust/"
	fi
done

# Repository URLs baked into installed systems (ribbon-base).
: "${RIBBON_REPO_URL:=https://github.com/atyr647/ribbon/releases/download/repo-current}"
: "${RIBBON_CHANNEL_URL:=${VOID_MIRROR}/current}"
sed -i -e "s|@RIBBON_REPO@|${RIBBON_REPO_URL}|g" -e "s|@RIBBON_CHANNEL@|${RIBBON_CHANNEL_URL}|g" \
	"$VP/srcpkgs/ribbon-base/files/xbps-repository-main.conf"

if ! kernel_prebuilt; then
	msg "No Ribbon kernel in $RIBBON_REPO_DIR: ribbon-kernel left out of the packages' dependencies"
	for p in "${OWN_PKGS[@]}"; do [ "$p" = ribbon-kernel ] || drop_kernel_dep "$VP/srcpkgs/$p/template"; done
else
	# xbps-src resolves ribbon-base's run-time dependency in its own repository (hostdir/binpkgs), not in
	# RIBBON_REPO_DIR: without the release there it would build ribbon-kernel from source as a missing dependency
	msg "Ribbon kernel release in $RIBBON_REPO_DIR: indexed in xbps-src's repository for ribbon-base"
	mkdir -p "$VP/hostdir/binpkgs"
	cp -u "$RIBBON_REPO_DIR"/ribbon-kernel-*.xbps "$VP/hostdir/binpkgs/"
	xbps-rindex -a "$VP"/hostdir/binpkgs/ribbon-kernel-*.xbps
fi

msg "Applying overrides to Void packages: ${OVERRIDES[*]}"
for o in "${OVERRIDES[@]}"; do
	git -C "$VP" checkout -- "srcpkgs/$o"
	sh "build/overrides/$o/apply.sh" "$VP/srcpkgs/$o"
done

pkgs=("$@")
[ ${#pkgs[@]} -gt 0 ] || pkgs=("${OVERRIDES[@]}" "${OWN_PKGS[@]}")
for p in "${pkgs[@]}"; do
	# the kernel is built by its own workflow (build/ci/kernel.yml); the image job fetches it into the repository
	if [ "$p" = ribbon-kernel ]; then
		if kernel_prebuilt; then msg "ribbon-kernel: prebuilt (build/ci/kernel.yml)"
		else msg "ribbon-kernel: no release fetched, not built here (build/ci/kernel.yml): Void's linux6.18 only"; fi
		continue
	fi
	msg "Building $p"
	"$VP/xbps-src" -E pkg "$p"
done

mkdir -p "$RIBBON_REPO_DIR"
msg "Collecting packages into $RIBBON_REPO_DIR"
for p in "${OVERRIDES[@]}" "${OWN_PKGS[@]}"; do
	cp -u "$VP"/hostdir/binpkgs/"$p"-[0-9]*.xbps "$RIBBON_REPO_DIR/" 2>/dev/null || :
	cp -u "$VP"/hostdir/binpkgs/"$p"-devel-[0-9]*.xbps "$RIBBON_REPO_DIR/" 2>/dev/null || :
	cp -u "$VP"/hostdir/binpkgs/"$p"-headers-[0-9]*.xbps "$RIBBON_REPO_DIR/" 2>/dev/null || :
done
xbps-rindex -a "$RIBBON_REPO_DIR"/*.xbps
if [ -n "${RIBBON_SIGN_KEY:-}" ]; then
	msg "Signing repository"
	xbps-rindex --sign --signedby "Ribbon OS" --privkey "$RIBBON_SIGN_KEY" "$RIBBON_REPO_DIR"
	xbps-rindex --sign-pkg --privkey "$RIBBON_SIGN_KEY" "$RIBBON_REPO_DIR"/*.xbps
fi
msg "Done: $(ls "$RIBBON_REPO_DIR"/*.xbps | wc -l) packages in $RIBBON_REPO_DIR"
