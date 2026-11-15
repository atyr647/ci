#!/bin/sh
# nftables with Ribbon's ruleset in place of ufw: tests/test-firewall.sh, in private network namespaces.
set -u
cd "$(dirname "$0")/../.." || exit 1
if timeout -k 5 120 sh tests/test-firewall.sh; then
	echo "  ok   firewall ruleset (tests/test-firewall.sh)"
else
	echo "  FAIL firewall ruleset (tests/test-firewall.sh)"; exit 1
fi
