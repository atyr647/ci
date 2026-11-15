#!/bin/sh
# build/install/install.sh makes the base's caches again, as a package manager's triggers do: after an install that
# puts down a .desktop file, applications/mimeinfo.cache (update-desktop-database), without which GLib and xdg-mime see
# no type the entry declares; after one that puts down a mime/packages file, the MIME database (update-mime-database).
# A package of the test's own (MANIFESTS) installs Notes' entry and Ribbon's kit type into a scratch DESTDIR with
# CACHES=1 (a root that runs as it is; without DESTDIR the same happens on the running system); gio mime,
# reading that DESTDIR, must then name Notes for text/markdown, and after uninstall nothing, with the scratch root
# empty; a staging DESTDIR without CACHES=1 gets no caches. Where update-desktop-database is not installed, a stand-in on PATH writes the same cache (the call and its
# folder are what is tested); without gio that check skips.
set -u
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fails=$((fails + 1)); }
mkdir -p "$T/man" "$T/bin" "$T/home" "$T/cfg"
cat >"$T/man/cachetest.manifest" <<'M'
file 644 usr/share/applications @repo/srcpkgs/ribbon-desktop/files/apps/notes/applications/ribbon-notes.desktop
file 644 usr/share/mime/packages @repo/srcpkgs/ribbon-desktop/files/mime/ribbon-kit.xml
M
if ! command -v update-desktop-database >/dev/null 2>&1; then
	cat >"$T/bin/update-desktop-database" <<'S'
#!/bin/sh
# a stand-in: the [MIME Cache] of every entry's MimeType in the folder
[ "$1" = -q ] && shift
echo "$1" >> "${UDD_LOG:-/dev/null}"
{ echo '[MIME Cache]'
  for f in "$1"/*.desktop; do
	[ -f "$f" ] || continue
	sed -n 's/^MimeType=//p' "$f" | tr ';' '\n' | sed '/^$/d' | sed "s|\$|=$(basename "$f")|"
  done | sort | awk -F= '{ a[$1] = a[$1] $2 ";" } END { for (t in a) print t "=" a[t] }' | sort; } > "$1/mimeinfo.cache"
S
	chmod +x "$T/bin/update-desktop-database"
fi
printf '#!/bin/sh\n' >"$T/bin/ribbon-notes"; chmod +x "$T/bin/ribbon-notes"   # GLib lists only apps it can run
D=$T/root
inst() { PATH="$T/bin:$PATH" UDD_LOG="$T/udd.log" MANIFESTS="$T/man" RECORD="$T/rec" DESTDIR="$D" CACHES=${CACHES:-1} sh build/install/install.sh "$1" cachetest; }
gm() { PATH="$T/bin:$PATH" HOME="$T/home" XDG_CONFIG_HOME="$T/cfg" XDG_CONFIG_DIRS="$T/cfg" XDG_DATA_HOME="$T/home/.local/share" \
	XDG_DATA_DIRS="$D/usr/share" gio mime "$1" 2>&1; }

inst install >"$T/install.out" 2>&1 || { sed 's/^/       /' "$T/install.out"; bad "install.sh install"; }
if grep -q '^text/markdown=.*ribbon-notes\.desktop;' "$D/usr/share/applications/mimeinfo.cache" 2>/dev/null; then
	ok "install made applications/mimeinfo.cache, with the entry's types"
else bad "no applications/mimeinfo.cache naming ribbon-notes.desktop after install"; fi
grep -q mimeinfo.cache "$T/rec/cachetest.files" && bad "the cache is recorded as a file of the package" ||
	ok "the cache is not one of the package's files (it is the base's)"
if command -v gio >/dev/null 2>&1; then
	case $(gm text/markdown) in *"Registered applications:"*ribbon-notes.desktop*) ok "GLib (gio mime) sees the type the entry declares" ;;
		*) bad "gio mime text/markdown: $(gm text/markdown | head -n1)" ;; esac
else echo "  skip the GLib check (no gio)"; fi
if command -v update-mime-database >/dev/null 2>&1; then
	grep -qx 'application/x-ribbon-kit' "$D/usr/share/mime/types" 2>/dev/null &&
		ok "install made the MIME database again: it knows application/x-ribbon-kit" || bad "the MIME database does not know application/x-ribbon-kit"
else echo "  skip the MIME database check (no update-mime-database)"; fi

inst uninstall >"$T/uninstall.out" 2>&1 || { sed 's/^/       /' "$T/uninstall.out"; bad "install.sh uninstall"; }
if command -v gio >/dev/null 2>&1; then
	case $(gm text/markdown) in *ribbon-notes.desktop*) bad "after uninstall GLib still names Notes" ;; *) ok "after uninstall GLib names nothing" ;; esac
fi
if [ -z "$(find "$D" -mindepth 1 2>/dev/null | head -n1)" ]; then ok "uninstall leaves the scratch root empty (the caches too)"
else find "$D" -mindepth 1 | head | sed 's/^/       left: /'; bad "uninstall left files"; fi
# a staging DESTDIR (no CACHES): the package's files only, as a package manager packs them
CACHES=0 inst install >"$T/stage.out" 2>&1 || { sed 's/^/       /' "$T/stage.out"; bad "install.sh install into a staging root"; }
if [ ! -e "$D/usr/share/applications/mimeinfo.cache" ] && [ ! -e "$D/usr/share/mime/types" ] && [ -f "$D/usr/share/applications/ribbon-notes.desktop" ]; then
	ok "a staging DESTDIR without CACHES=1 holds the package's files and no caches"
else bad "a staging DESTDIR got caches: $(find "$D" -name mimeinfo.cache -o -name types | head -n2)"; fi
CACHES=0 inst uninstall >/dev/null 2>&1
[ $fails -eq 0 ] && echo "install caches: all checks passed"
[ $fails -eq 0 ]
