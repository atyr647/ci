#!/bin/sh
# Ribbon branding for base-files: os-release identifies the system as Ribbon
# OS (ID_LIKE=void, so tools that know Void keep working), and /etc/issue (the
# console's greeting) names it.
set -e
dir=$1 here=$(dirname "$0")
cp "$here/os-release" "$dir/files/os-release"
# the console's greeting (agetty's /etc/issue) names Ribbon OS, not Void
printf 'Ribbon OS \\r (\\n) (\\l)\n\n' > "$dir/files/issue"
grep -q 'Ribbon OS override' "$dir/template" ||
	sed -i '1a # Ribbon OS override: files/os-release replaced with Ribbon branding.' "$dir/template"
