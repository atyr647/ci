#!/bin/sh
# Every palette defines every editor, diff and syntax token (STYLE §20), so the
# editor and diff views never fall back to a default in a theme of their own.
D=$(cd "$(dirname "$0")/../.." && pwd)/srcpkgs/ribbon-desktop/files/themes/palettes
fails=0
for f in "$D"/*.conf; do
	for k in SYN_KW SYN_FN SYN_VAR SYN_STR SYN_NUM SYN_COM SYN_OPT SYN_PUN SYN_NUM0 \
		LINE VADD VMOD VDEL WARN ERR MATCH MATCH_ALPHA WELL WELL_ALPHA; do
		grep -q "^$k=" "$f" || { echo "  FAIL $(basename "$f") lacks $k"; fails=1; }
	done
done
[ $fails -eq 0 ] && echo "  ok   every palette defines every token" || exit 1
