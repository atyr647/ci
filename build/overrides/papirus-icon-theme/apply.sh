#!/bin/sh
# Ribbon OS override of void-packages/srcpkgs/papirus-icon-theme ($1 = that dir).
#
# Ribbon uses Papirus-Dark (GTK apps, and ribbon-theme's generated "Ribbon"
# folder theme, which inherits it). The Tk shell, Files, Properties and
# Appearance draw their own line icons and load no theme icons. So the
# package keeps Papirus and Papirus-Dark at 8, 16, 18, 24, 42, 48, 84, 96
# and 128 px (all SVG: GTK scales the nearest size for any other), and a new
# subpackage papirus-icon-theme-extra takes Papirus-Light and the 22, 32 and
# 64 px directories: 61.5 of the theme's 111.5 MiB (docs/STACK.md §2.8).
# Installing the extra package puts everything back; index.theme is
# unchanged, and GTK skips the directories that aren't there.
# FOR INDEPENDENCE: not in build-packages.sh's OVERRIDES yet; Ribbon
# rebuilds Void packages only once it builds everything (docs/STACK.md
# "At independence"). Its binary packages are listed in ./packages, which
# the collection step will need for the subpackages.
set -e
dir=$1 here=$(dirname "$0")
grep -q 'Ribbon OS override' "$dir/template" && exit 0
grep -q '^do_install()' "$dir/template" || { echo "papirus override: do_install not found" >&2; exit 1; }
if grep -q '_package()' "$dir/template"; then echo "papirus override: template already has subpackages" >&2; exit 1; fi
sed -i '1a # Ribbon OS override: Papirus-Light and the 22/32/64 px sizes go to papirus-icon-theme-extra (build/overrides/papirus-icon-theme).' "$dir/template"
{
	printf '\npapirus-icon-theme-extra_package() {\n'
	printf '\tshort_desc+=" - Papirus-Light and the 22, 32 and 64 px sizes"\n'
	printf '\tdepends="papirus-icon-theme>=${version}_${revision}"\n'
	printf '\tpkg_install() {\n'
	sed 's/^/\t\t/' "$here/extra.sh"
	printf '\t}\n}\n'
} >> "$dir/template"
# xbps-src finds a subpackage through a link next to its main package
ln -sfn papirus-icon-theme "$dir/../papirus-icon-theme-extra"
