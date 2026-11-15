#!/bin/sh
# Ribbon branding for base-files: os-release identifies the system as Ribbon
# OS (ID_LIKE=void, so tools that know Void keep working).
set -e
dir=$1 here=$(dirname "$0")
cp "$here/os-release" "$dir/files/os-release"
grep -q 'Ribbon OS override' "$dir/template" ||
	sed -i '1a # Ribbon OS override: files/os-release replaced with Ribbon branding.' "$dir/template"
