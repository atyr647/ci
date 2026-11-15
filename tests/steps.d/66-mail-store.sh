#!/bin/sh
# Mail's model (U39: apps/mail/mime.tcl, store.tcl, thread.tcl, search.tcl): tests/mail-store.tcl with tclsh8.6
# against the fixture Maildirs in tests/fixtures/maildir (copied to a temporary root): RFC 2047 and RFC 2231,
# multipart, attachments listed undecoded, the Maildir store and its index, JWZ threading, from: search, the
# Mail-A-Ledger, A2-Thread and A4-Search models, and broken mail. Skips without tclsh8.6. Hard timeout.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip mail store (no tclsh8.6)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
if TMPDIR="$T" timeout -k 5 60 tclsh8.6 tests/mail-store.tcl </dev/null >"$T/out" 2>&1 && grep -q "^mail store: ok" "$T/out"; then
	grep -a '^  ok' "$T/out"
	exit 0
fi
sed 's/^/       /' "$T/out"
echo "  FAIL mail store"
exit 1
