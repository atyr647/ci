#!/bin/sh
# Mail sync (W2): tests/mail-sync.tcl runs Mail's IMAP and SMTP clients and the account sync
# (srcpkgs/ribbon-desktop/files/apps/mail/{net,imap,smtp,sync}.tcl) against tests/mail-fixture-server.tcl, a small
# IMAP4rev1 + SMTP server on 127.0.0.1, with a stand-in for the mail store: logins (SASL-IR, "+" continuation, LOGIN
# with a literal), the first sync through 7-byte reads, IDLE, flags both ways, expunges, CONDSTORE, UIDVALIDITY,
# batches, a dropped connection, polling, SMTP send and its refusals, the copy in Sent, moves and deletes on the server
# (UID MOVE; UID COPY + \Deleted + UID EXPUNGE; COPY + \Deleted; kept over a quit). With openssl and the Tcl tls
# package it makes a throwaway certificate for localhost and 127.0.0.1 (and one for another host) and also checks
# IMAPS, IMAP and SMTP STARTTLS (and their injection refusal), SMTPS, untrusted and wrong-host certificates.
# Without tclsh8.6 it skips; without openssl or tls the TLS checks skip. Every run has a hard timeout.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip mail sync (no tclsh8.6)"
	exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
if command -v openssl >/dev/null 2>&1; then
	mkdir -p "$T/certs"
	if openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
		-keyout "$T/certs/good.key" -out "$T/certs/good.pem" >/dev/null 2>&1 &&
		openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost -addext 'subjectAltName=DNS:other.test' \
		-keyout "$T/certs/other.key" -out "$T/certs/other.pem" >/dev/null 2>&1
	then MAIL_TEST_CERTS=$T/certs; export MAIL_TEST_CERTS
	else echo "  skip making test certificates (openssl failed)"; fi
fi
if TMPDIR=$T timeout -k 5 300 tclsh8.6 tests/mail-sync.tcl </dev/null >"$T/out" 2>&1; then
	cat "$T/out"
	exit 0
fi
cat "$T/out"
echo "  FAIL mail sync"
exit 1
