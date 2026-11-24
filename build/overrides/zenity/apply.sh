#!/bin/sh
# Ribbon OS override of void-packages/srcpkgs/zenity ($1 = that dir).
#
# Ribbon's own scripts no longer use zenity (ribbon-welcome and Appearance
# are Tk), but Steam depends on it and the Star Citizen LUG Helper and
# winetricks use it for their dialogs. Void builds it with WebKitGTK 6
# (119 MiB with what only it needs), used by nothing but
# `zenity --text-info --html`; Ribbon builds it without (docs/STACK.md §2.1).
# FOR INDEPENDENCE: not in build-packages.sh's OVERRIDES yet; Ribbon
# rebuilds Void packages only once it builds everything (docs/STACK.md
# "At independence"). Its binary packages are listed in ./packages, which
# the collection step will need for the subpackages.
set -e
dir=$1
grep -q 'Ribbon OS override' "$dir/template" && exit 0
grep -q '^build_options_default="webkit"$' "$dir/template" || { echo "zenity override: webkit option not found" >&2; exit 1; }
sed -i -e '1a # Ribbon OS override: built without WebKitGTK (build/overrides/zenity).' \
	-e 's/^build_options_default="webkit"$/build_options_default=""/' "$dir/template"
