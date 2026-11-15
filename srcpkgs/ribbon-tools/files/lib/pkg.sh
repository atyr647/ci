#!/bin/bash
# /usr/lib/ribbon/pkg.sh - the one place Ribbon's tools talk to the base's
# package manager (bash). Sourced by common.sh, so every tool has it; run as
# a command it answers the installer's questions (pkg.tcl):
#
#   pkg.sh backend | map [ID...] | installed | missing ID... | locales | cache-dir | keymap [KEYMAP]
#
# The tools name packages by Ribbon's own neutral ids (mesa, firmware-amd,
# broadcom-wl, steam, ...). A backend's name map, pkg-names.<backend> next to
# this file, turns an id into that base's package names; a name the map does
# not have is taken as the base's own package name (a package someone typed).
#
# Backends: xbps (the Void base, "phase now" of docs/SYSTEM-UPDATES.md §7.10)
# and kit, which cannot install system packages yet and says so. With neither
# there is no package manager: installs fail with a message, nothing is
# removed, the cache is empty. RIBBON_PKG_BACKEND picks one by hand.
#
# Ribbon's own packages put down by make install (build/install/install.sh)
# are known on any base by the record that install leaves on the system,
# /var/lib/ribbon/installed/PACKAGE.files: an id that pkg-names.ribbon names
# (installer -> ribbon-installer) with such a record is installed, and is
# removed by it, whatever the backend.
#
#   pkg_backend                  xbps | kit | none
#   pkg_name_map ID...           the base's package names, one per line
#   pkg_query ID...              0: all installed, 1: not, 2: cannot tell
#   pkg_missing ID...            the ids that are not installed, one per line
#   pkg_install ID...            install (online, with the install media's
#                                packages as a second source)
#   pkg_install_offline ID...    install from the install media only
#   pkg_remove ID...             remove those installed, with what only they need
#   pkg_reconfigure ID...        run the packages' configure steps again
#   pkg_locale_enable LOCALE     make LOCALE available (glibc)
#   pkg_locales                  the locales this system can generate
#   pkg_cache_dir                downloaded packages (empty: no cache)
#   pkg_clean_cache              delete the downloaded packages
#   pkg_online_host              a host whose name resolving means "online"
#   pkg_services_sync            after the base's packages changed: dinit sees
#                                the services they ship (runit services in
#                                /etc/sv, as Void's packages have them, become
#                                dinit services through ribbon-sv2dinit)
#   pkg_console_keymap [KEYMAP]  the console keymap: /etc/vconsole.conf is the
#                                source on every base; xbps keeps Void's
#                                /etc/rc.conf KEYMAP in step. Without KEYMAP:
#                                print it (us when nothing says)
#
# Everything acts on RIBBON_ROOT when it is set (the installer's target):
# commands run chrooted there, files are read from there.

RIBBON_PKG_DIR=${RIBBON_PKG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
RIBBON_OFFLINE_REPO=${RIBBON_OFFLINE_REPO:-/var/lib/ribbon/offline-repo}
RIBBON_RECORDS=${RIBBON_RECORDS:-/var/lib/ribbon/installed}

_pkg_root() { printf '%s' "${RIBBON_ROOT:-}"; }

_pkg_run() { # command in the target root (as common.sh's in_root)
	if [ -n "${RIBBON_ROOT:-}" ]; then chroot "$RIBBON_ROOT" "$@"; else "$@"; fi
}

_pkg_has() { # a program in the target root
	if [ -n "${RIBBON_ROOT:-}" ]; then
		[ -x "$RIBBON_ROOT/usr/bin/$1" ] || [ -x "$RIBBON_ROOT/usr/sbin/$1" ] || [ -x "$RIBBON_ROOT/bin/$1" ]
	else
		command -v "$1" >/dev/null 2>&1
	fi
}

_pkg_say() { printf 'pkg: %s\n' "$*" >&2; }

# ---- Ribbon's own packages by make install's record -------------------------
_pkg_record() { # ID: the record of the Ribbon package ID names (pkg-names.ribbon), when it is on this root
	local p f
	p=$(awk -v id="$1" 'sub(/#.*/, "") >= 0 && $1 == id { print $2; exit }' "$RIBBON_PKG_DIR/pkg-names.ribbon" 2>/dev/null)
	[ -n "$p" ] || return 1
	f=$(_pkg_root)$RIBBON_RECORDS/$p.files
	[ -f "$f" ] || return 1
	printf '%s\n' "$f"
}

_pkg_unrecorded() { # ID...: those without a record, one per line
	local id
	for id; do _pkg_record "$id" >/dev/null || printf '%s\n' "$id"; done
}

# What the record lists goes: its files and links, then the directories it made that are empty now, deepest
# first, then the record itself. PAM lines it put into a file of the base stay (said).
_pkg_record_remove() { # RECORD
	local rec=$1 r p desktop=
	r=$(_pkg_root)
	while read -r k p; do
		case "$p" in /*) ;; *) continue ;; esac
		case "$p" in */../*|*/..) continue ;; esac
		case "$k" in
			f|l)
				if [ -L "$r$p" ] || [ -f "$r$p" ]; then rm -f -- "$r$p" || return 1; fi
				case "$p" in /usr/share/applications/*.desktop) desktop=1 ;; esac ;;
		esac
	done < "$rec"
	sed -n 's/^d \(\/.*\)/\1/p' "$rec" | awk '{ print length($0) " " $0 }' | sort -rn | cut -d' ' -f2- |
		while IFS= read -r p; do
			case "$p" in */../*|*/..) continue ;; esac
			rmdir -- "$r$p" 2>/dev/null || :
		done
	grep -q '^p ' "$rec" && _pkg_say "$(basename "$rec" .files): the lines it added to the base's PAM files stay"
	rm -f -- "$rec"
	rmdir -- "$r$RIBBON_RECORDS" 2>/dev/null || :
	# the applications' MIME cache loses what went, as the base's package manager's trigger would do
	if [ -n "$desktop" ] && _pkg_has update-desktop-database; then
		_pkg_run update-desktop-database -q /usr/share/applications || :
	fi
	return 0
}

pkg_backend() {
	if [ -n "${RIBBON_PKG_BACKEND:-}" ]; then echo "$RIBBON_PKG_BACKEND"; return 0; fi
	if _pkg_has xbps-install || [ -d "$(_pkg_root)/var/db/xbps" ]; then echo xbps
	elif _pkg_has kit; then echo kit
	else echo none
	fi
}

_pkg_unavailable() { # what a backend that cannot install or remove says; $1: installing | removing
	local what=$1; shift
	case "$(pkg_backend)" in
		kit) _pkg_say "$what system packages through kit is not available yet (docs/SYSTEM-UPDATES.md §7.10 phase 1): $*" ;;
		*) _pkg_say "this system has no package manager Ribbon can use; not ${what%ing}ed: $*" ;;
	esac
	return 1
}

# The map's lines: ID NAME [NAME...]; # starts a comment.
pkg_name_map() {
	local map id
	map=$RIBBON_PKG_DIR/pkg-names.$(pkg_backend)
	for id; do
		if [ -r "$map" ] && awk -v id="$id" 'sub(/#.*/, "") >= 0 && $1 == id { for (i = 2; i <= NF; i++) print $i; f = 1 } END { exit !f }' "$map"; then
			:
		else
			printf '%s\n' "$id"
		fi
	done | awk 'NF && !seen[$0]++'
}

# The whole map, "ID NAME..." per line (pkg.tcl reads it once).
_pkg_map_all() {
	local map; map=$RIBBON_PKG_DIR/pkg-names.$(pkg_backend)
	[ -r "$map" ] || return 0
	sed 's/#.*//' "$map" | awk 'NF >= 2 { $1 = $1; print }'
}

# Installed package names (the base's), one per line.
pkg_installed_names() {
	case "$(pkg_backend)" in
		xbps)
			local r; r=$(_pkg_root)
			if [ -z "$r" ] && command -v xbps-query >/dev/null 2>&1; then
				xbps-query -l 2>/dev/null | awk '{ print $2 }' | sed -E 's/-[^-]+_[0-9]+$//'
			else
				# the package database itself (a target root, or no xbps-query here)
				local f
				for f in "$r"/var/db/xbps/pkgdb-*.plist; do
					[ -r "$f" ] || continue
					awk '/^\t<dict>$/ && k != "" { print k } { k = "" } /^\t<key>[^<]+<\/key>$/ { k = $0; sub(/^\t<key>/, "", k); sub(/<\/key>$/, "", k) }' "$f"
				done
			fi ;;
		*) return 0 ;;
	esac
}

pkg_query() {
	local rest
	mapfile -t rest < <(_pkg_unrecorded "$@")
	[ ${#rest[@]} -gt 0 ] || return 0   # all of them Ribbon's own, by their records
	case "$(pkg_backend)" in xbps) ;; *) return 2 ;; esac
	[ -z "$(pkg_missing "${rest[@]}")" ]
}

pkg_missing() {
	local rest
	mapfile -t rest < <(_pkg_unrecorded "$@")
	[ ${#rest[@]} -gt 0 ] || return 0
	set -- "${rest[@]}"
	case "$(pkg_backend)" in
		xbps) ;;
		*) printf '%s\n' "$@"; return 0 ;;
	esac
	local have id n miss
	have=$(pkg_installed_names)
	for id; do
		miss=0
		for n in $(pkg_name_map "$id"); do
			printf '%s\n' "$have" | grep -qxF -- "$n" || { miss=1; break; }
		done
		[ "$miss" -eq 0 ] || printf '%s\n' "$id"
	done
}

_pkg_offline_ready() { [ -e "$(_pkg_root)$RIBBON_OFFLINE_REPO/$(uname -m)-repodata" ]; }

pkg_install() {
	[ $# -gt 0 ] || return 0
	case "$(pkg_backend)" in
		xbps)
			local names off=()
			mapfile -t names < <(pkg_name_map "$@")
			_pkg_offline_ready && off=(-R "$RIBBON_OFFLINE_REPO")
			if _pkg_run xbps-install -Sy "${off[@]}" "${names[@]}"; then pkg_services_sync; return 0; fi
			if [ ${#off[@]} -gt 0 ]; then
				_pkg_say "online install failed; using the packages on the install media"
				if _pkg_run xbps-install -iy -R "$RIBBON_OFFLINE_REPO" "${names[@]}"; then pkg_services_sync; return 0; fi
			fi
			return 1 ;;
		*) _pkg_unavailable installing "$@" ;;
	esac
}

# Only when the install media carries every package the ids need.
pkg_install_offline() {
	[ $# -gt 0 ] || return 0
	case "$(pkg_backend)" in
		xbps)
			local names n
			_pkg_offline_ready || return 1
			mapfile -t names < <(pkg_name_map "$@")
			for n in "${names[@]}"; do
				compgen -G "$(_pkg_root)$RIBBON_OFFLINE_REPO/$n-[0-9]*.xbps" >/dev/null || return 1
			done
			_pkg_run xbps-install -iy -R "$RIBBON_OFFLINE_REPO" "${names[@]}" || return 1
			pkg_services_sync ;;
		*) _pkg_unavailable installing "$@" ;;
	esac
}

pkg_remove() {
	[ $# -gt 0 ] || return 0
	local id rec rest=()
	for id; do
		if rec=$(_pkg_record "$id"); then _pkg_record_remove "$rec" || return 1; else rest+=("$id"); fi
	done
	[ ${#rest[@]} -gt 0 ] || return 0
	set -- "${rest[@]}"
	case "$(pkg_backend)" in
		xbps)
			local have n gone=()
			have=$(pkg_installed_names)
			for n in $(pkg_name_map "$@"); do
				printf '%s\n' "$have" | grep -qxF -- "$n" && gone+=("$n")
			done
			[ ${#gone[@]} -gt 0 ] || return 0
			_pkg_run xbps-remove -Ry "${gone[@]}" || return 1
			pkg_services_sync ;;
		*) _pkg_unavailable removing "$@" ;;
	esac
}

pkg_reconfigure() {
	[ $# -gt 0 ] || return 0
	case "$(pkg_backend)" in
		xbps) local names; mapfile -t names < <(pkg_name_map "$@"); _pkg_run xbps-reconfigure -f "${names[@]}" ;;
		*) return 0 ;;   # nothing to run again without a package manager
	esac
}

# Locales: Void's glibc-locales package generates what /etc/default/libc-locales
# enables; anywhere else glibc's own localedef makes it.
pkg_locales() {
	local r; r=$(_pkg_root)
	if [ "$(pkg_backend)" = xbps ] && [ -r "$r/etc/default/libc-locales" ]; then
		sed -n 's/^#\{0,1\}[[:space:]]*\([A-Za-z][^[:space:]#]*\)[[:space:]].*/\1/p' "$r/etc/default/libc-locales"
	elif [ -r "$r/usr/share/i18n/SUPPORTED" ]; then
		# "LOCALE CHARSET" (Debian's), or glibc's own form "LOCALE/CHARSET \" under SUPPORTED-LOCALES=\ (Arch's)
		awk '!/^#/ && NF && $1 !~ /=/ { n = $1; sub(/\/.*/, "", n); if (n != "\\") print n }' "$r/usr/share/i18n/SUPPORTED"
	fi
}

pkg_locale_enable() {
	local loc=$1 r f; r=$(_pkg_root)
	f=$r/etc/default/libc-locales
	if [ "$(pkg_backend)" = xbps ] && [ -f "$f" ]; then
		local re; re=$(printf '%s' "$loc" | sed 's/[.[\*^$/]/\\&/g')
		sed -i "s/^#[[:space:]]*\\(${re}[[:space:]].*\\)/\\1/" "$f"
		grep -q "^${re}[[:space:]]" "$f" || { _pkg_say "unknown locale $loc"; return 1; }
		pkg_reconfigure locales
	else
		local lang=${loc%%.*} cs=UTF-8
		case "$loc" in *.*) cs=${loc#*.}; cs=${cs%%@*} ;; esac
		case "$loc" in *@*) lang=$lang@${loc#*@} ;; esac
		_pkg_has localedef || { _pkg_say "no localedef to make $loc"; return 1; }
		_pkg_run localedef -i "$lang" -c -f "$cs" "$loc"
	fi
}

pkg_check_db() { # 0: the package database is consistent, 1: it reports problems, 2: this backend cannot tell
	case "$(pkg_backend)" in
		xbps) _pkg_run xbps-pkgdb -a >/dev/null 2>&1 || return 1 ;;
		*) return 2 ;;
	esac
}

pkg_cache_dir() {
	case "$(pkg_backend)" in
		xbps) echo /var/cache/xbps ;;
		*) : ;;
	esac
}

pkg_clean_cache() {
	case "$(pkg_backend)" in
		xbps) _pkg_run xbps-remove -Oy ;;
		*) return 0 ;;
	esac
}

pkg_online_host() {
	case "$(pkg_backend)" in
		xbps)
			local r; r=$(_pkg_root)
			cat "$r"/etc/xbps.d/*.conf "$r"/usr/share/xbps.d/*.conf 2>/dev/null |
				sed -n 's|^[[:space:]]*repository[[:space:]]*=[[:space:]]*https\{0,1\}://\([^/:[:space:]]*\).*|\1|p' | head -n1 ;;
		*) : ;;
	esac
}

# Void's packages ship runit services; on any base that has them (/etc/sv), ribbon-sv2dinit (ribbon-dinit's runit
# compatibility) turns them into dinit services. A base without runit services has nothing to sync.
pkg_services_sync() { # (tests: RIBBON_SV_DIR in place of ROOT/etc/sv)
	[ -d "${RIBBON_SV_DIR:-$(_pkg_root)/etc/sv}" ] && _pkg_has ribbon-sv2dinit || return 0
	_pkg_run ribbon-sv2dinit --quiet || { _pkg_say "some of the base's runit services could not be converted (ribbon doctor)"; return 1; }
}

# KEY=VALUE files (vconsole.conf, rc.conf): VALUE of the last KEY line, without quotes
_pkg_conf_get() { # FILE KEY
	sed -n "s/^[[:space:]]*$2=[\"']\{0,1\}\([^\"'[:space:]]*\).*/\1/p" "$1" 2>/dev/null | tail -n1
}
_pkg_conf_set() { # FILE KEY VALUE QUOTE: KEY's line (a commented one too) becomes KEY=VALUE, or is added
	local f=$1 k=$2 v=$3 q=$4
	if [ -f "$f" ] && grep -q "^#\{0,1\}[[:space:]]*$k=" "$f"; then
		awk -v k="$k" -v line="$k=$q$v$q" '
			!done && $0 ~ "^#?[ \t]*" k "=" { print line; done = 1; next }
			$0 ~ "^[ \t]*" k "=" { next }
			{ print }' "$f" > "$f.ribbon-new" && cat "$f.ribbon-new" > "$f"
		rm -f "$f.ribbon-new"
	else
		printf '%s=%s%s%s\n' "$k" "$q" "$v" "$q" >> "$f"
	fi
}

pkg_console_keymap() {
	local r v; r=$(_pkg_root)
	if [ $# -eq 0 ]; then
		v=$(_pkg_conf_get "$r/etc/vconsole.conf" KEYMAP)
		[ -n "$v" ] || [ "$(pkg_backend)" != xbps ] || v=$(_pkg_conf_get "$r/etc/rc.conf" KEYMAP)
		printf '%s\n' "${v:-us}"
		return 0
	fi
	case "$1" in ''|*[!A-Za-z0-9._-]*) _pkg_say "not a console keymap: $1"; return 1 ;; esac
	mkdir -p "$r/etc" && _pkg_conf_set "$r/etc/vconsole.conf" KEYMAP "$1" '' || return 1
	# Void's own readers of the keymap (void-runit's rc.conf)
	if [ "$(pkg_backend)" = xbps ] && [ -f "$r/etc/rc.conf" ]; then _pkg_conf_set "$r/etc/rc.conf" KEYMAP "$1" '"'; fi
	return 0
}

# Run as a command: the questions pkg.tcl asks.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	case "${1:-}" in
		backend) pkg_backend ;;
		map) shift; if [ $# -eq 0 ]; then _pkg_map_all; else pkg_name_map "$@"; fi ;;
		installed) pkg_installed_names ;;
		missing) shift; pkg_missing "$@" ;;
		locales) pkg_locales ;;
		cache-dir) pkg_cache_dir ;;
		keymap) shift; pkg_console_keymap "$@" ;;
		*) echo "usage: $0 backend | map [ID...] | installed | missing ID... | locales | cache-dir | keymap [KEYMAP]" >&2; exit 2 ;;
	esac
fi
