#!/bin/sh
# build/install/install.sh - install, list or uninstall one Ribbon package from its manifest, on any base.
#
#   build/install/install.sh install PACKAGE [--if-built]
#   build/install/install.sh list PACKAGE          what install would put down: "f MODE PATH", "l PATH TARGET",
#                                                  "d PATH", "s PATH MODE OWNER GROUP" (a state directory), "x PATH
#                                                  WHERE" (a file of the package that comes from elsewhere), "u NAME
#                                                  HOME GROUPS" (a system account), "p PATH SRC" (PAM lines put
#                                                  into a PAM file of the base), "r PATH" (the record left on
#                                                  the target)
#   build/install/install.sh uninstall PACKAGE     remove what the last install recorded
#
# Environment: DESTDIR (the staging root; empty means /), PREFIX (only /usr: Ribbon's programs name /usr/lib/ribbon
# and /usr/share/ribbon in their code), O (what build.sh built, default out/build), DISTDIR (default out/distfiles),
# RECORD (where the installed file lists go, default O/installed: RECORD/PACKAGE.files), MANIFESTS (the manifests'
# directory, default build/install/manifests; the tests point it elsewhere), CACHES (1: make the base's caches,
# applications/mimeinfo.cache and the MIME database, in DESTDIR too; they are made by default only without DESTDIR),
# RIBBON_PKG_BACKEND (the base's package manager, for the manifests' `base` lines: by default what
# srcpkgs/ribbon-tools/files/lib/pkg.sh finds in DESTDIR when DESTDIR is a system (it has an /etc), else on this
# machine).
#
# The record also goes onto the target, DESTDIR/var/lib/ribbon/installed/PACKAGE.files (the paths as the installed
# system sees them): with it, Ribbon's tools know and can remove a package without a package manager (pkg.sh;
# postinstall live-cleanup removes the installer by it).
#
# The manifests (build/install/manifests/PACKAGE.manifest) translate each srcpkgs/*/template's do_install; their
# directives are described in build/install/README. tests/steps.d/90-install.sh holds them to the templates.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
abs() { case $1 in /*) echo "$1" ;; *) echo "$ROOT/$1" ;; esac; }
O=$(abs "${O:-out/build}")
DISTDIR=$(abs "${DISTDIR:-out/distfiles}")
RECORD=$(abs "${RECORD:-$O/installed}")
DESTDIR=${DESTDIR:-}
DESTDIR=${DESTDIR%/}
PREFIX=${PREFIX:-/usr}
PREFIX=${PREFIX%/}

die() { printf '%s\n' "install: $*" >&2; exit 1; }
note() { printf '%s\n' "install: $*" >&2; }

[ "$PREFIX" = /usr ] || die "PREFIX=$PREFIX: only /usr is supported (the shell, the apps and the services name /usr/lib/ribbon and /usr/share/ribbon in their code)"
[ $# -ge 2 ] || die "usage: install.sh install|list|uninstall PACKAGE [--if-built]"
cmd=$1 pkg=$2 ifbuilt=${3:-}
M=$(abs "${MANIFESTS:-build/install/manifests}")/$pkg.manifest
[ -f "$M" ] || die "no package $pkg ($M)"
FILES=$ROOT/srcpkgs/$pkg/files
BUILT=$O/$pkg
# the record on the target, where pkg.sh looks (RIBBON_RECORDS there)
TREC=/var/lib/ribbon/installed
# the base's package manager, for `base BACKEND DIRECTIVE...` lines
if [ -z "${RIBBON_PKG_BACKEND:-}" ]; then
	broot=; [ -n "$DESTDIR" ] && [ -d "$DESTDIR/etc" ] && broot=$DESTDIR
	RIBBON_PKG_BACKEND=$(RIBBON_ROOT=$broot bash "$ROOT/srcpkgs/ribbon-tools/files/lib/pkg.sh" backend 2>/dev/null) || RIBBON_PKG_BACKEND=none
fi

# src TOKEN: the path a manifest source names (a leading ? is stripped by the caller)
src() {
	case $1 in
		@files/*) echo "$FILES/${1#@files/}" ;;
		@build/*) echo "$BUILT/${1#@build/}" ;;
		@dist/*) echo "$DISTDIR/${1#@dist/}" ;;
		@repo/*) echo "$ROOT/${1#@repo/}" ;;
		*) die "$M: source $1 must start with @files/, @build/, @dist/ or @repo/" ;;
	esac
}

# caches LIST: the base's caches that index what a package puts down, made again when LIST (a record: "f PATH",
# "l PATH") names a file they index, as the base's package manager does through its triggers. Without
# applications/mimeinfo.cache GLib (gio, the portals) and xdg-mime see no type a .desktop file declares; without
# mime's caches no type a mime/packages file adds. As automake's install hooks do, only when installing onto the
# running system (DESTDIR empty), or into a root that will run as it is (CACHES=1); a staging DESTDIR, packed by a
# package manager whose triggers make them on the target, holds none. A tool that is not there is said, not fatal.
caches() {
	[ -z "$DESTDIR" ] || [ "${CACHES:-}" = 1 ] || return 0
	if grep -qE '^[fl] /usr/share/applications/.*\.desktop$' "$1"; then
		if command -v update-desktop-database >/dev/null 2>&1; then
			[ -d "$DESTDIR/usr/share/applications" ] && update-desktop-database -q "$DESTDIR/usr/share/applications"
			# the last entry gone (an uninstall from a staging root): its cache goes too
			[ -n "$(find "$DESTDIR/usr/share/applications" -name '*.desktop' 2>/dev/null | head -n1)" ] ||
				rm -f "$DESTDIR/usr/share/applications/mimeinfo.cache"
		else
			note "$pkg: update-desktop-database (desktop-file-utils) is not installed: applications/mimeinfo.cache not made again"
		fi
	fi
	if grep -qE '^[fl] /usr/share/mime/packages/.*\.xml$' "$1"; then
		if command -v update-mime-database >/dev/null 2>&1; then
			[ -d "$DESTDIR/usr/share/mime/packages" ] && update-mime-database "$DESTDIR/usr/share/mime" >/dev/null 2>&1
			# no type package left (an uninstall from a staging root; a base always has shared-mime-info's own):
			# what update-mime-database made goes too
			if [ -d "$DESTDIR/usr/share/mime" ] && [ -z "$(find "$DESTDIR/usr/share/mime/packages" -name '*.xml' 2>/dev/null | head -n1)" ]; then
				find "$DESTDIR/usr/share/mime" -mindepth 1 -maxdepth 1 ! -name packages -exec rm -rf {} +
			fi
		else
			note "$pkg: update-mime-database (shared-mime-info) is not installed: the MIME caches not made again"
		fi
	fi
	return 0
}

uninstall() {
	R=$RECORD/$pkg.files
	[ -f "$R" ] || die "nothing recorded for $pkg ($R): it was not installed with this RECORD"
	rd=$(sed -n '1s/^# DESTDIR=//p' "$R")
	[ "$rd" = "$DESTDIR" ] || die "$pkg was installed with DESTDIR=$rd, not DESTDIR=$DESTDIR"
	grep -E '^[fl] ' "$R" | cut -d' ' -f2- | while IFS= read -r p; do
		if [ -L "$DESTDIR$p" ] || [ -f "$DESTDIR$p" ]; then rm -f "$DESTDIR$p"; fi
	done
	# PAM lines put into a file of the base: those lines come out again, the file stays (an account stays too)
	grep '^p ' "$R" | while read -r _ p s; do
		[ -f "$DESTDIR$p" ] && [ -f "$s" ] || continue
		awk 'NR == FNR { if ($0 != "") drop[$0] = 1; next } !($0 in drop)' "$s" "$DESTDIR$p" > "$DESTDIR$p.ribbon-new" &&
			cat "$DESTDIR$p.ribbon-new" > "$DESTDIR$p"
		rm -f "$DESTDIR$p.ribbon-new"
	done
	# the caches lose what went (before the record goes)
	caches "$R"
	rm -f "$DESTDIR$TREC/$pkg.files"
	# directories the install made, deepest first, when nothing else is in them
	# the directories any Ribbon install made (RECORD/dirs), deepest first, when nothing is left in them: a directory
	# two packages share goes with the last of them
	rm -f "$R"
	touch "$RECORD/dirs"
	awk '{ print length($0) " " $0 }' "$RECORD/dirs" | sort -rn | cut -d' ' -f2- | while IFS= read -r p; do
		rmdir "$DESTDIR$p" 2>/dev/null || :
		[ -d "$DESTDIR$p" ] && echo "$p"
	done | LC_ALL=C sort > "$RECORD/dirs.new"
	mv "$RECORD/dirs.new" "$RECORD/dirs"
	[ -s "$RECORD/dirs" ] || rm -f "$RECORD/dirs"
	rmdir "$RECORD" 2>/dev/null || :
	echo "uninstall: $pkg"
}
[ "$cmd" = uninstall ] && { uninstall; exit 0; }
case $cmd in install | list) ;; *) die "unknown command $cmd" ;; esac

if grep -q '^needs ' "$M"; then
	v=$(sed -n 's/^needs //p' "$M")
	missing=$(grep -o ' @build/[^ ]*' "$M" | sed 's| @build/||' | while read -r b; do [ -e "$BUILT/$b" ] || echo "$b"; done)
	if [ -n "$missing" ] && [ "$cmd" = install ]; then
		[ "$ifbuilt" = --if-built ] && { note "$pkg skipped: it was not built (make build $v=...)"; exit 0; }
		die "$pkg was not built: make build $v=..."
	fi
fi

# everything below writes through these: in list mode they print, in install mode they install and record
REC=
made() { echo "d $1" >> "$REC"; echo "$1" >> "$RECORD/dirs"; } # a directory this install made
mkd() { # PATH (absolute, under DESTDIR): make it and its parents, recording the ones that were not there
	[ -d "$DESTDIR$1" ] && return 0
	mkd "$(dirname "$1")"
	if [ "$cmd" = install ]; then mkdir "$DESTDIR$1"; chmod 755 "$DESTDIR$1"; made "$1"; fi
}
put() { # MODE DIR SRC NAME
	if [ "$cmd" = list ]; then echo "f $1 /$2/$4"; return 0; fi
	mkd "/$2"
	rm -f "$DESTDIR/$2/$4"
	cp "$3" "$DESTDIR/$2/$4"
	chmod "$1" "$DESTDIR/$2/$4"
	echo "f /$2/$4" >> "$REC"
}
file() { # MODE DIR SRCTOKEN [NAME]
	mode=$1 dir=$2 tok=$3 name=${4:-}
	opt=; case $tok in '?'*) opt=1; tok=${tok#?} ;; esac
	s=$(src "$tok")
	set +f
	# shellcheck disable=SC2086
	set -- $s
	set -f
	for f in "$@"; do
		if [ ! -f "$f" ]; then
			if [ "$cmd" = list ] && [ -z "$opt" ]; then echo "f $mode /$dir/${name:-$(basename "$f")}"; continue; fi
			if [ -n "$opt" ]; then note "$pkg: /$dir/${name:-$(basename "$f")} left out ($f is not there)"; continue; fi
			die "$pkg: $f is missing (make build first?)"
		fi
		put "$mode" "$dir" "$f" "${name:-$(basename "$f")}"
	done
}
link() { # PATH TARGET
	if [ "$cmd" = list ]; then echo "l /$1 $2"; return 0; fi
	mkd "/$(dirname "$1")"
	rm -f "$DESTDIR/$1"
	ln -s "$2" "$DESTDIR/$1"
	echo "l /$1" >> "$REC"
}
tree() { # SRCDIR DIR: SRCDIR copied into DIR, as vcopy (cp -a) does, modes kept
	s=$(src "$1") dir=$2
	[ -d "$s" ] || die "$pkg: $s is missing (make build first?)"
	b=$(basename "$s")
	(cd "$(dirname "$s")" && find "$b" | LC_ALL=C sort) | while IFS= read -r rel; do
		if [ -d "$(dirname "$s")/$rel" ]; then
			if [ "$cmd" = list ]; then echo "d /$dir/$rel"; else mkd "/$dir/$rel"; fi
		else
			m=$(stat -c %a "$(dirname "$s")/$rel")
			put "$m" "$(dirname "$dir/$rel")" "$(dirname "$s")/$rel" "$(basename "$rel")"
		fi
	done
	if [ "$cmd" = install ]; then # the directories keep their modes, as cp -a keeps them
		(cd "$(dirname "$s")" && find "$b" -type d) | while IFS= read -r rel; do
			chmod "$(stat -c %a "$(dirname "$s")/$rel")" "$DESTDIR/$dir/$rel"; done
	fi
}
apps() { # APPSDIR: the template's drop-in loop (apps:begin .. apps:end)
	a=$(src "$1")
	set +f
	for d in "$a"/*/; do
		[ -d "$d" ] || continue
		app=$(basename "$d")
		for f in "$d"*.tcl; do [ -f "$f" ] && put 644 "usr/lib/ribbon/$app" "$f" "$(basename "$f")"; done
		for f in "$d"bin/*; do [ -f "$f" ] && put 755 usr/bin "$f" "$(basename "$f")"; done
		for f in "$d"applications/*.desktop; do [ -f "$f" ] && put 644 usr/share/applications "$f" "$(basename "$f")"; done
		for f in "$d"policy/*.policy; do [ -f "$f" ] && put 644 usr/share/polkit-1/actions "$f" "$(basename "$f")"; done
		for f in "$d"policy/*.rules; do [ -f "$f" ] && put 644 usr/share/polkit-1/rules.d "$f" "$(basename "$f")"; done
	done
	set -f
	return 0
}
state() { # PATH MODE OWNER GROUP: a make_dirs directory
	if [ "$cmd" = list ]; then echo "s $1 $2 $3 $4"; return 0; fi
	mkd "$(dirname "$1")"
	if [ ! -d "$DESTDIR$1" ]; then mkdir "$DESTDIR$1"; made "$1"; fi
	chmod "$2" "$DESTDIR$1"
	if [ "$(id -u)" = 0 ] && [ -z "$DESTDIR" ]; then
		chown "$3:$4" "$1" 2>/dev/null || note "$pkg: $1 should belong to $3:$4 (create the account, then chown it)"
	fi
}

nologin() { # the base's nologin shell
	for sh in /usr/sbin/nologin /usr/bin/nologin /sbin/nologin; do [ -x "$DESTDIR$sh" ] && { echo "$sh"; return 0; }; done
	echo /sbin/nologin
}
# account_files NAME HOME GROUPS: the account written into DESTDIR/etc's passwd, group (and shadow, gshadow when they
# are there), as useradd -r -U would make it: a free id below 1000 from 999 down, for the user and its own group
account_files() {
	E=$DESTDIR/etc
	if ! grep -q "^$1:" "$E/passwd"; then
		id=$(awk -F: 'FNR == 1 { f++ } f == 1 { u[$3] = 1 } f == 2 { g[$3] = 1 }
			END { for (i = 999; i >= 100; i--) if (!(i in u) && !(i in g)) { print i; exit } }' "$E/passwd" "$E/group")
		[ -n "$id" ] || die "$pkg: no free system id for the account $1"
		gid=$(awk -F: -v n="$1" '$1 == n { print $3 }' "$E/group")
		if [ -z "$gid" ]; then
			gid=$id
			echo "$1:x:$gid:" >> "$E/group"
			[ -f "$E/gshadow" ] && echo "$1:!::" >> "$E/gshadow"
		fi
		echo "$1:x:$id:$gid:$pkg $1 user:$2:$(nologin)" >> "$E/passwd"
		[ -f "$E/shadow" ] && echo "$1:!:$(($(date +%s) / 86400))::::::" >> "$E/shadow"
	fi
	for f in group gshadow; do
		[ -f "$E/$f" ] || continue
		# the working copy is made 0600 (gshadow may hold group passwords); cat keeps the file's own mode
		(umask 077; awk -F: -v OFS=: -v n="$1" -v gs=",$3," '
			index(gs, "," $1 ",") && $1 != n {
				m = "," $4 ","; if (!index(m, "," n ",")) $4 = ($4 == "" ? n : $4 "," n) }
			{ print }' "$E/$f" > "$E/$f.ribbon-new") && cat "$E/$f.ribbon-new" > "$E/$f"
		rm -f "$E/$f.ribbon-new"
	done
}
account() { # NAME HOME GROUPS: a system account (the template's system_accounts), added to those of GROUPS that exist
	if [ "$cmd" = list ]; then echo "u $1 $2 $3"; return 0; fi
	if [ -z "$DESTDIR" ] && [ "$(id -u)" != 0 ]; then
		note "$pkg: the account $1 was not made (install as root)"; return 0
	fi
	if [ -z "$DESTDIR" ] && command -v useradd >/dev/null 2>&1 && command -v usermod >/dev/null 2>&1; then
		own=-U; getent group "$1" >/dev/null && own="-g $1"
		# shellcheck disable=SC2086
		getent passwd "$1" >/dev/null || useradd -r $own -M -d "$2" -s "$(nologin)" -c "$pkg $1 user" "$1" ||
			die "$pkg: useradd $1 failed"
		for g in $(echo "$3" | tr ',' ' '); do
			getent group "$g" >/dev/null || continue
			id -nG "$1" | tr ' ' '\n' | grep -qx "$g" || usermod -aG "$g" "$1" || die "$pkg: usermod -aG $g $1 failed"
		done
		return 0
	fi
	if [ ! -f "$DESTDIR/etc/passwd" ] || [ ! -f "$DESTDIR/etc/group" ]; then
		note "$pkg: the account $1 was not made (no $DESTDIR/etc/passwd)"; return 0
	fi
	account_files "$@"
}
# pam PATH SRC: SRC's lines go into the base's PAM file PATH (its greetd package's), ahead of its password check: before
# the first auth line (or @include of an auth stack) that is not pam_nologin, pam_securetty or pam_shells. Nothing
# happens when the file already has SRC's rules, or when the base has no such file (no greetd installed).
pam() {
	s=$(src "$2")
	if [ "$cmd" = list ]; then echo "p /$1 $s"; return 0; fi
	t=$DESTDIR/$1
	[ -f "$s" ] || die "$pkg: $s is missing"
	[ -f "$t" ] || { note "$pkg: /$1 is not there (the base's greetd is not installed): its lines from $s left out"; return 0; }
	norm() { sed -e 's/#.*//' -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//' "$1" | grep -v '^$' || :; }
	if norm "$s" | while IFS= read -r l; do norm "$t" | grep -qxF "$l" || exit 1; done; then
		head -n1 "$s" | grep -qxF -f - "$t" && echo "p /$1 $s" >> "$REC"
		return 0
	fi
	awk 'NR == FNR { add = add $0 "\n"; next }
		!done && (/^[ \t]*-?auth[ \t]/ && !/pam_(nologin|securetty|shells)\.so/ || /^[ \t]*@include[ \t]+[^ \t]*auth/) {
			printf "%s", add; done = 1 }
		{ print }
		END { if (!done) printf "%s", add }' "$s" "$t" > "$t.ribbon-new" && cat "$t.ribbon-new" > "$t"
	rm -f "$t.ribbon-new"
	echo "p /$1 $s" >> "$REC"
}

if [ "$cmd" = install ]; then
	mkdir -p "$RECORD"
	REC=$RECORD/$pkg.files.new
	echo "# DESTDIR=$DESTDIR" > "$REC"
	# an install over an earlier one keeps the directories that earlier one made
	[ -f "$RECORD/$pkg.files" ] && grep '^d ' "$RECORD/$pkg.files" >> "$REC" || :
	touch "$RECORD/dirs"
	[ -z "$DESTDIR" ] || mkdir -p "$DESTDIR"
fi
set -f
while IFS= read -r line || [ -n "$line" ]; do
	case $line in '' | '#'*) continue ;; esac
	# shellcheck disable=SC2086
	set -- $line
	d=$1; shift
	if [ "$d" = base ]; then # base BACKEND DIRECTIVE...: only where the base's package manager is BACKEND
		[ $# -ge 2 ] || die "$M: $line"
		[ "$1" = "$RIBBON_PKG_BACKEND" ] || continue
		shift; d=$1; shift
	fi
	case $d in
		file) [ $# -ge 3 ] || die "$M: $line"; file "$@" ;;
		bin) file 755 usr/bin "$@" ;;
		license) file 644 "usr/share/licenses/$pkg" "$@" ;;
		doc) file 644 "usr/share/doc/$pkg" "$@" ;;
		conf) file 644 etc "$@" ;;
		man) s=${1##*.}; file 644 "usr/share/man/man$s" "$@" ;;
		dir) if [ "$cmd" = list ]; then echo "d /$1"; else mkd "/$1"; fi ;;
		link) link "$@" ;;
		tree) tree "$@" ;;
		apps) apps "$@" ;;
		state) state "$@" ;;
		account) [ $# -eq 3 ] || die "$M: $line"; account "$@" ;;
		pam) [ $# -eq 2 ] || die "$M: $line"; pam "$@" ;;
		external) [ "$cmd" = list ] && echo "x /$1 $2" ;;
		needs) ;;
		*) die "$M: unknown directive $d" ;;
	esac
done < "$M"
if [ "$cmd" = list ]; then echo "r $TREC/$pkg.files"; fi
if [ "$cmd" = install ]; then
	mkd "$TREC"
	{ head -n1 "$REC"; tail -n +2 "$REC" | LC_ALL=C sort -u; } > "$RECORD/$pkg.files"
	rm -f "$REC"
	# the target's copy: the same lines, for the root it is on
	{ echo "# DESTDIR="; tail -n +2 "$RECORD/$pkg.files"; } > "$DESTDIR$TREC/$pkg.files.new" &&
		chmod 644 "$DESTDIR$TREC/$pkg.files.new" && mv -f "$DESTDIR$TREC/$pkg.files.new" "$DESTDIR$TREC/$pkg.files"
	caches "$RECORD/$pkg.files"
	LC_ALL=C sort -u -o "$RECORD/dirs" "$RECORD/dirs"
	echo "install: $pkg -> ${DESTDIR:-/}"
fi
