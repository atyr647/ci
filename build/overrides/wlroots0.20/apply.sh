#!/bin/sh
# Apply Ribbon's override to void-packages/srcpkgs/wlroots0.20 ($1 = that dir).
# xbps-src applies every patch in patches/ automatically. Ribbon's repo is
# listed first on installed systems with bestmatching=false, so this build
# is the one used even when the version matches Void's.
set -e
dir=$1 here=$(dirname "$0")
mkdir -p "$dir/patches"
cp "$here"/patches/*.patch "$dir/patches/"
grep -q 'Ribbon OS override' "$dir/template" ||
	sed -i '1a # Ribbon OS override: adds patches/ribbon-sdr-white.patch (configurable HDR SDR white).' "$dir/template"
