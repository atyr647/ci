#!/bin/sh
# The boot try counter and snapshot fallback: the initramfs hook (dracut 90ribbon-snapshot), ribbon-snapshot's
# arm/pre/mark-good/retry and boot-watch (the ribbon-boot-ok service), on fake roots: tests/test-boot-fallback.sh.
# The real fallback (a QEMU boot with Tcl broken) is the recovery case of build/ci/boot-test.sh, in CI.
set -u
cd "$(dirname "$0")/../.." || exit 1
if timeout -k 5 300 bash tests/test-boot-fallback.sh; then
	echo "  ok   boot fallback (tests/test-boot-fallback.sh)"
else
	echo "  FAIL boot fallback (tests/test-boot-fallback.sh)"; exit 1
fi
