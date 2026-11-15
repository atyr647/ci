#!/bin/bash
# /usr/lib/ribbon/pkg-update.sh - the package-manager seam's update part (bash),
# for ribbon-update. Sourced after pkg.sh (common.sh), whose pkg_backend,
# _pkg_run and _pkg_say it uses; a pkg.sh that already has these functions
# wins (ribbon-update sources this file only when pkg_upgrade is missing).
#
#   pkg_refresh             fetch the repositories' indexes (root)
#   pkg_updates             what an update would change, without changing anything
#                           and without root (the index is read from the network
#                           into memory): one line per package, fields split by |
#                             NAME|OLD|NEW|BYTES|ACTION|TAGS
#                           (OLD empty for a new package, BYTES the download,
#                           empty when it is cached, ACTION install | update,
#                           TAGS space-separated: restart). Exit 0: the list
#                           (maybe empty); 1: the package manager failed;
#                           2: this base has none Ribbon updates (kit's job)
#   pkg_versions            the installed packages: NAME VERSION per line
#   pkg_upgrade_self [-y]   the package manager itself
#   pkg_upgrade [-y]        everything else; -y asks nothing. Then, as after
#                           every change of the base's packages, pkg.sh's
#                           pkg_services_sync (their runit services as dinit's)
#
# A package that only takes effect at the next boot carries `restart`
# (docs/KIT-CLI.md "The prompt", SYSTEM-UPDATES.md §7.5): the kernel, kernel
# modules and their drivers, firmware and microcode, and the core parts running
# processes cannot let go of. Which of the base's packages those are is the
# backend's knowledge, so it is here (for xbps: _pkg_restart_xbps).

_pkg_ver_strip() { # a version for people: 6.18.60_1 -> 6.18.60 (the build revision dropped)
	printf '%s' "${1%_[0-9]*}"
}

# xbps: the restart class by Void's package names
_pkg_restart_xbps() {
	case "$1" in
		*-headers|*-dbg|*-devel|*-doc) return 1 ;;
		linux[0-9]*.[0-9]*|linux|linux-lts|linux-mainline) return 0 ;;          # the kernel
		linux-firmware|linux-firmware-*|*-firmware|intel-ucode|linux-ucode) return 0 ;;  # firmware, microcode
		*-dkms|nvidia|nvidia[0-9]*|nvidia-libs|nvidia[0-9]*-libs) return 0 ;;   # modules and their drivers
		glibc|dinit|dbus|dbus-libs|elogind|libelogind|turnstile|greetd) return 0 ;;
		libgcc|libstdc++|libcrypto3|libssl3|openssl|zlib) return 0 ;;
	esac
	return 1
}

pkg_refresh() {
	case "$(pkg_backend)" in
		xbps) _pkg_run xbps-install -S ;;
		*) return 0 ;;
	esac
}

pkg_versions() {
	case "$(pkg_backend)" in
		xbps) _pkg_run xbps-query -l 2>/dev/null | awk '{ v = $2; sub(/-[^-]+$/, "", $2); n = $2; sub(/^.*-/, "", v); print n, v }' ;;
		*) return 0 ;;
	esac
}

# xbps-install -n prints "PKGVER ACTION ARCH REPOSITORY INSTALLED-SIZE DOWNLOAD-SIZE" per package. When xbps itself
# has an update, xbps refuses the rest until it is updated: then the plan is xbps alone, as the update will do it.
pkg_updates() {
	case "$(pkg_backend)" in
		xbps) ;;
		*) return 2 ;;
	esac
	local out rc have
	out=$(_pkg_run xbps-install -Mun 2>&1); rc=$?
	if [ $rc -ne 0 ] && printf '%s\n' "$out" | grep -q "'xbps' package must be updated"; then
		out=$(_pkg_run xbps-install -Mun xbps 2>&1); rc=$?
	fi
	# exit 6 (ENXIO): nothing to update
	[ $rc -eq 6 ] && return 0
	if [ $rc -ne 0 ]; then
		_pkg_say "$(printf '%s\n' "$out" | grep . | tail -n1)"
		return 1
	fi
	have=$(pkg_versions)
	local pv act arch repo isz dsz n v old tags
	while read -r pv act arch repo isz dsz; do
		case "$act" in install|update) ;; *) continue ;; esac
		[ -n "$pv" ] && [ "${pv#*-}" != "$pv" ] || continue
		n=${pv%-*}; v=${pv##*-}
		old=$(printf '%s\n' "$have" | awk -v n="$n" '$1 == n { print $2; exit }')
		[ "$act" = update ] && [ -z "$old" ] && act=install
		# the build revision only when it is all that changed
		if [ -n "$old" ] && [ "$(_pkg_ver_strip "$old")" != "$(_pkg_ver_strip "$v")" ]; then
			old=$(_pkg_ver_strip "$old"); v=$(_pkg_ver_strip "$v")
		elif [ -z "$old" ]; then
			v=$(_pkg_ver_strip "$v")
		fi
		tags=; _pkg_restart_xbps "$n" && tags=restart
		[ "${dsz:-0}" = 0 ] && dsz=
		printf '%s|%s|%s|%s|%s|%s\n' "$n" "$old" "$v" "$dsz" "$act" "$tags"
	done <<< "$out"
}

pkg_upgrade_self() {
	local y=; [ "${1:-}" = -y ] && y=-y
	case "$(pkg_backend)" in
		xbps) _pkg_run xbps-install -u $y xbps ;;
		*) return 0 ;;
	esac
}

pkg_upgrade() {
	local y=; [ "${1:-}" = -y ] && y=-y
	case "$(pkg_backend)" in
		xbps)
			local rc=0
			_pkg_run xbps-install -u $y || rc=$?
			pkg_services_sync || :   # what did change has its services, even after a failure part-way
			return $rc ;;
		kit) _pkg_say "the system's packages are kits here: kit check updates them"; return 0 ;;
		*) _pkg_say "this system has no package manager Ribbon can use; the system's packages were not updated"; return 0 ;;
	esac
}
