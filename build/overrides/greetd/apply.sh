#!/bin/sh
# Ribbon OS override of void-packages/srcpkgs/greetd ($1 = that dir): /etc/pam.d/greetd is a configuration file.
#
# Ribbon adds its lines to greetd's PAM file (ribbon-desktop's INSTALL: "Log in without a password"), as on any base.
# Void's template lists only /etc/greetd/config.toml in conf_files, so xbps took the edited PAM file for a damaged
# one (xbps-pkgdb: "hash mismatch for /etc/pam.d/greetd", which ribbon-doctor reported on every installed system)
# and a greetd update would have put Void's file back over Ribbon's lines. As a configuration file it is kept on
# update (a new one lands as .new-VERSION) and xbps checks only that it is there.
set -e
dir=$1
grep -q 'Ribbon OS override' "$dir/template" && exit 0
grep -q '^conf_files="/etc/greetd/config.toml"$' "$dir/template" ||
	{ echo "greetd override: conf_files is not what this override expects" >&2; exit 1; }
sed -i -e '1a # Ribbon OS override: /etc/pam.d/greetd is a configuration file (build/overrides/greetd).' \
	-e 's|^conf_files="/etc/greetd/config.toml"$|conf_files="/etc/greetd/config.toml /etc/pam.d/greetd"|' "$dir/template"
