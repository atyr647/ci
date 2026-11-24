#!/bin/sh
# What opens each kind of file on a fresh install (tests/mime-defaults.tcl): the shipped xdg/mimeapps.list and the
# Text editor's and Notes' desktop entries, read by properties/facts.tcl (Properties, the Inspector, Settings'
# reader) with its walk up shared-mime-info's type tree; text kinds to the Text editor, Markdown offered to Notes,
# web pages to the browser, PDFs and music to Firefox (music to VLC when it is installed), archives to nothing.
# GLib's gio mime and xdg-utils' xdg-mime (what xdg-open asks) are held to the same answers when installed.
# Skips without tclsh8.6.
set -u
cd "$(dirname "$0")/../.." || exit 1
if ! command -v tclsh8.6 >/dev/null 2>&1; then
	echo "  skip default apps for file types (no tclsh8.6)"; exit 0
fi
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
if timeout -k 5 120 tclsh8.6 tests/mime-defaults.tcl "$PWD/srcpkgs/ribbon-desktop/files" "$T" >"$T.out" 2>&1; then
	n=$(grep -c '^  ok ' "$T.out")
	grep '^  skip' "$T.out"
	echo "  ok   default apps for file types: text kinds, Markdown, web, PDF, music, video, archives ($n checks)"
	rm -f "$T.out"
	exit 0
fi
cat "$T.out"; rm -f "$T.out"
echo "  FAIL default apps for file types (tests/mime-defaults.tcl)"
exit 1
