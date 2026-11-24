# Ribbon OS: move datacenter, switch, HBA and access-point firmware back
# to the main package (inserted by build/overrides/linux-firmware/apply.sh)
ribbon_datacenter="mellanox mrvl/prestera qed cxgb4 bnx2x liquidio vxge myri10ge* phanfw.bin* ql2*.bin* qlogic cbfw*.bin* ct2fw*.bin* ctfw*.bin* slicoss tehuti hfi1_*.fw* intel/ice intel/qat mediatek/mt7996 ath10k/QCA4019 ath10k/QCA9888 ath10k/QCA9984 ath10k/QCA99X0 ath11k/IPQ5018 ath11k/IPQ6018 ath11k/IPQ8074 ath11k/QCN9074 ath12k/IPQ5332 ath12k/IPQ5424 ath12k/QCN9274"
# links that already point outside -network (into other firmware packages)
_before=$(cd "${PKGDESTDIR}" && find usr/lib/firmware -xtype l | sort)
for _p in $ribbon_datacenter; do
	for _f in "${PKGDESTDIR}"/usr/lib/firmware/$_p; do
		[ -e "$_f" ] || [ -L "$_f" ] || continue
		_rel=${_f#"${PKGDESTDIR}"/}
		mkdir -p "${DESTDIR}/${_rel%/*}"
		mv "$_f" "${DESTDIR}/${_rel}"
	done
done
_after=$(cd "${PKGDESTDIR}" && find usr/lib/firmware -xtype l | sort)
if [ "$_after" != "$_before" ]; then
	msg_error "linux-firmware-network: a firmware link points at firmware the Ribbon split moved\n"
fi
unset _before _after _p _f _rel
