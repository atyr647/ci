#!/bin/sh
# Apply Ribbon's override to void-packages/srcpkgs/bcachefs-tools ($1 = that dir).
# xbps-src applies every patch in patches/ automatically. Ribbon's repo is listed first on installed systems (and in
# the image's build) with bestmatching=false, so this build of bcachefs-dkms is the one used even when the version
# matches Void's: on Linux 6.18.64 Void's does not build (patches/ribbon-inode-state.patch says why), and a bcachefs
# root whose module did not build for a new kernel does not boot it.
set -e
dir=$1 here=$(dirname "$0")
mkdir -p "$dir/patches"
cp "$here"/patches/*.patch "$dir/patches/"
grep -q 'Ribbon OS override' "$dir/template" ||
	sed -i '1a # Ribbon OS override: adds patches/ribbon-inode-state.patch (builds on Linux 6.18.64).' "$dir/template"
