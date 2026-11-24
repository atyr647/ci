#!/bin/sh
# Test shim for kernels without vfat (containers): FAT through fusefat,
# everything else to the real mount (REAL_MOUNT). test-installer.sh puts it
# on PATH as `mount`.
t='' o='' args=''
while [ $# -gt 0 ]; do
	case "$1" in
		-t) t=$2; shift ;;
		-o) o=$2; shift ;;
		-*) exec "$REAL_MOUNT" ${t:+-t "$t"} ${o:+-o "$o"} "$@" ;;
		*) args="$args $1" ;;
	esac
	shift
done
# shellcheck disable=SC2086
set -- $args
if [ $# -eq 2 ] && { [ "$t" = vfat ] || { [ -z "$t" ] && [ "$(blkid -p -s TYPE -o value "$1" 2>/dev/null)" = vfat ]; }; }; then
	case ",$o," in *,ro,*) m=ro ;; *) m=rw+ ;; esac
	exec fusefat -o "$m" "$1" "$2" >/dev/null 2>&1
fi
exec "$REAL_MOUNT" ${t:+-t "$t"} ${o:+-o "$o"} "$@"
