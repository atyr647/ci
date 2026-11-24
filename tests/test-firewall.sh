#!/bin/sh
# Ribbon's firewall (srcpkgs/ribbon-base/files/nftables.conf, nftables in place of ufw): loaded into a private
# network namespace "a" wired to a second one "b" by a veth pair (IPv4 and IPv6), with tests/firewall/net.py as the
# listener and the client. Without the ruleset b reaches a's TCP and UDP listeners (the control); with it:
# connections and datagrams from b to a are dropped, a's own connections to b get their replies, ping and IPv6
# neighbour discovery work, and loading it twice leaves one table. Also: ribbon-base depends on nftables and
# installs the ruleset, and no template, deps.map row or package list names ufw.
# Needs root (or a user namespace), unshare, nsenter, ip, nft and python3; skips the namespace part without them.
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
R=$ROOT/srcpkgs/ribbon-base/files/nftables.conf
NET=$ROOT/tests/firewall/net.py
status=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; status=1; }

grep -Eq '^[[:space:]]*vinstall "\$\{FILESDIR\}/nftables.conf" 644 usr/share/ribbon$' srcpkgs/ribbon-base/template &&
	sed -n '/^depends="/,/"$/p' srcpkgs/ribbon-base/template | grep -qw nftables && ok "ribbon-base depends on nftables and installs the ruleset" ||
	bad "ribbon-base does not depend on nftables or install nftables.conf"
hits=$(grep -n -w ufw srcpkgs/*/template build/install/deps.map build/packages/*.list 2>/dev/null | grep -v ':[0-9]*:[[:space:]]*#' || true)
[ -z "$hits" ] && ok "no template, deps.map row or package list names ufw" || bad "ufw is still a dependency: $hits"
# The installer turns it on: postinstall's services and security steps (its own code, with / moved to a temporary
# root holding what a fresh install has: the nftables service, Ribbon's ruleset, nftables' own /etc/nftables.conf,
# no ufw) leave Ribbon's ruleset in /etc/nftables.conf and the nftables service enabled at boot.
PI=$ROOT/srcpkgs/ribbon-tools/files/bin/postinstall
FR=$(mktemp -d) || exit 1
mkdir -p "$FR/usr/lib/dinit.d" "$FR/usr/share/ribbon" "$FR/etc/dinit.d" "$FR/etc/default"
cp "$ROOT/srcpkgs/ribbon-dinit/files/services/nftables" "$FR/usr/lib/dinit.d/nftables"
cp "$R" "$FR/usr/share/ribbon/nftables.conf"
printf 'flush ruleset\ntable inet filter {\n}\n' > "$FR/etc/nftables.conf"
sed -n '/^enable_svc()/,/^}/p; /^step_services()/,/^}/p; /^step_security()/,/^}/p' "$PI" |
	sed "s#\\([[:space:]\"(]\\)/etc/#\\1$FR/etc/#g; s#/usr/lib/dinit\\.d#$FR/usr/lib/dinit.d#g; s#/usr/share/ribbon/#$FR/usr/share/ribbon/#g" > "$FR/steps.sh"
# enable_svc asks common.sh's svc_exists (with have), which looks under RIBBON_ROOT: taken as they are
sed -n '/^have()/p; /^svc_exists()/,/^}/p' "$ROOT/srcpkgs/ribbon-tools/files/lib/common.sh" >> "$FR/steps.sh"
RIBBON_ROOT=$FR bash -c 'log() { :; }; ribbon-sv2dinit() { :; }; cmdline_add() { :; }; . "$1/steps.sh"; step_services; step_security' _ "$FR" >/dev/null 2>&1
cmp -s "$R" "$FR/etc/nftables.conf" && [ -L "$FR/etc/dinit.d/boot.d/nftables" ] && [ ! -e "$FR/etc/dinit.d/boot.d/ufw" ] &&
	ok "postinstall installs Ribbon's ruleset as /etc/nftables.conf and enables the nftables service" ||
	bad "after postinstall: /etc/nftables.conf is $(cmp -s "$R" "$FR/etc/nftables.conf" && echo "Ribbon's" || echo "not Ribbon's"), boot.d has: $(ls "$FR/etc/dinit.d/boot.d" 2>/dev/null | tr '\n' ' ')"
rm -rf "$FR"

for t in unshare nsenter ip nft python3; do
	command -v $t >/dev/null 2>&1 || { echo "  skip the firewall in a namespace (no $t)"; exit $status; }
done
T=$(mktemp -d) || exit 1
PIDS=
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; rm -rf "$T"' EXIT
# two namespaces, each held by a sleeping process; a veth pair between them
unshare -n sleep 120 & A=$!; unshare -n sleep 120 & B=$!; PIDS="$A $B"
sleep 0.2
if ! ip link add rbfwa type veth peer name rbfwb 2>/dev/null; then echo "  skip the firewall in a namespace (cannot make a veth pair here)"; exit $status; fi
ip link set rbfwa netns $A && ip link set rbfwb netns $B || { ip link del rbfwa 2>/dev/null; bad "could not move the veth pair"; exit 1; }
a() { nsenter -F -t $A -n "$@"; }   # -F: no fork, so a listener's PID is its own
b() { nsenter -F -t $B -n "$@"; }
a ip link set lo up; b ip link set lo up
a ip addr add 10.77.0.1/24 dev rbfwa; a ip link set rbfwa up
b ip addr add 10.77.0.2/24 dev rbfwb; b ip link set rbfwb up
# IPv6 when this kernel has it (fd77::/64; nodad, so the address is usable at once)
if python3 "$NET" ipv6; then
	V6=fd77::1; a ip -6 addr add fd77::1/64 dev rbfwa nodad; b ip -6 addr add fd77::2/64 dev rbfwb nodad
else V6=; echo "  (no IPv6 in this kernel: the IPv4 half only)"; fi
serve() { # NS-PID KIND PORT NAME (nsenter itself in the background, not a function: $! is the listener)
	nsenter -F -t $1 -n python3 "$NET" serve $2 $3 "$T/$4" & PIDS="$PIDS $!"
	i=0; while [ ! -e "$T/$4.ready" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}
serve $A tcp 8080 a-tcp; serve $A udp 9090 a-udp; serve $B tcp 8081 b-tcp
got() { [ -e "$T/a-udp" ] && wc -l < "$T/a-udp" || echo 0; }
udp_in() { # HOST: b sends a datagram to a's UDP listener; prints how many a has had, after a moment
	b python3 "$NET" send "$1" 9090; sleep 0.3; got
}
both() { # NS HOST4 HOST6 PORT: "yes yes" when a TCP connection works to each (IPv6 "-" without it)
	r4=no; r6=-; $1 python3 "$NET" connect $2 $4 && r4=yes
	[ -n "$V6" ] && { r6=no; $1 python3 "$NET" connect $3 $4 && r6=yes; }
	echo "$r4 $r6"
}
yes6() { [ -n "$V6" ] && echo yes || echo -; }
no6() { [ -n "$V6" ] && echo no || echo -; }

# the control: no ruleset
c=$(both b 10.77.0.1 fd77::1 8080); u=$(udp_in 10.77.0.1)
[ "$c" = "yes $(yes6)" ] && [ "$u" = 1 ] && ok "control: without the ruleset b reaches a over TCP and UDP" ||
	bad "control: b cannot reach a even without a firewall (tcp4 tcp6: $c, udp $u)"

if a nft -f "$R" && a nft -f "$R"; then ok "the ruleset loads, and loads again"; else bad "nft -f refuses the ruleset"; exit 1; fi
[ "$(a nft list tables | grep -c 'table inet ribbon')" = 1 ] && ok "loading it twice leaves one table" || bad "loading it twice made two tables"
c=$(both b 10.77.0.1 fd77::1 8080)
[ "$c" = "no $(no6)" ] && ok "incoming TCP connections are dropped (IPv4 and IPv6: $c)" || bad "incoming TCP gets through (IPv4 IPv6: $c)"
udp_in 10.77.0.1 >/dev/null; [ -n "$V6" ] && udp_in fd77::1 >/dev/null
[ "$(got)" = 1 ] && ok "incoming UDP datagrams are dropped" || bad "incoming UDP gets through (a has had $(got), 1 was the control's)"
# a's own connections: forget the neighbours first, so IPv6 neighbour discovery has to pass the ruleset
a ip neigh flush dev rbfwa; b ip neigh flush dev rbfwb
c=$(both a 10.77.0.2 fd77::2 8081)
[ "$c" = "yes $(yes6)" ] && ok "a's own connections out get their replies (IPv4 and IPv6 with neighbour discovery: $c)" ||
	bad "outgoing connections fail behind the ruleset (IPv4 IPv6: $c)"
b python3 "$NET" ping 10.77.0.1 && ok "ping (ICMP echo) is answered" || bad "ping is not answered"
a nft flush ruleset
c=$(both b 10.77.0.1 fd77::1 8080)
[ "$c" = "yes $(yes6)" ] && ok "the service's stop (nft flush ruleset) opens it again" || bad "after a flush b still cannot connect ($c)"
exit $status
