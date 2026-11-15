#!/bin/sh
# Ask for the bcachefs passphrase before dracut mounts an encrypted root.
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh
[ "$(getarg rootfstype=)" = bcachefs ] || return 0
dev=$(getarg root=)
case "$dev" in UUID=*) dev=/dev/disk/by-uuid/${dev#UUID=} ;; esac
modprobe -q bcachefs
if bcachefs unlock -c "$dev" >/dev/null 2>&1; then
	tries=0
	while [ $tries -lt 3 ]; do
		bcachefs unlock -k session "$dev" && break
		tries=$((tries + 1))
	done
fi
