#!/bin/sh
# Xfce removal (U44): tests/test-xfce-removal.sh (no Xfce in depends or files/, settings.ini and X resources from ribbon-theme).
set -u
cd "$(dirname "$0")/../.." || exit 1
if timeout -k 5 300 bash tests/test-xfce-removal.sh; then
	echo "  ok   xfce removal (tests/test-xfce-removal.sh)"
else
	echo "  FAIL xfce removal (tests/test-xfce-removal.sh)"; exit 1
fi
