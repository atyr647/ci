# Ribbon OS: papirus-icon-theme-extra's pkg_install (build/overrides/papirus-icon-theme)
vmove usr/share/icons/Papirus-Light
for _v in Papirus Papirus-Dark; do
	for _s in 22x22 32x32 64x64; do
		for _d in "$_s" "$_s@2x"; do
			if [ -e "${DESTDIR}/usr/share/icons/$_v/$_d" ] || [ -L "${DESTDIR}/usr/share/icons/$_v/$_d" ]; then
				vmove "usr/share/icons/$_v/$_d"
			fi
		done
	done
done
# links left pointing at what moved go with it (until none are left)
while _l=$(cd "${DESTDIR}" && find usr/share/icons -xtype l) && [ -n "$_l" ]; do
	for _f in $_l; do vmove "$_f"; done
done
unset _v _s _d _l _f
