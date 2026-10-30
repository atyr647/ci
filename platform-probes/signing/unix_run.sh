#!/bin/bash
# Linux / macOS: run every signed variant (sh ./file and ./file), check the zip asset, check that the file hash and the Authenticode signature survive the run.
# cwd = repository root; signed/ (Linux-signed), winsigned/ (Microsoft-signed, optional), pki/.
set +e
echo "RESULT host: $(uname -s) $(uname -m) $(uname -r)"
if [ "$(uname -s)" = Darwin ]; then brew install osslsigncode >/dev/null 2>&1; else sudo apt-get install -y osslsigncode >/dev/null 2>&1; fi
mkdir -p w; cp signed/*.exe w/ 2>/dev/null; cp winsigned/*.exe w/ 2>/dev/null; chmod +x w/*.exe
for f in w/*.exe; do
  b=$(basename $f); h0=$(shasum -a 256 $f | cut -d' ' -f1)
  o1=$(sh ./$f 2>&1 | tr '\n' ' '); e1=$?
  o2=$(./$f 2>&1 | tr '\n' ' '); e2=$?
  h1=$(shasum -a 256 $f | cut -d' ' -f1)
  case $b in app*) ok=$(echo "$o1" | grep -c signed-test-asset);; *) ok=n/a;; esac
  v=n/a; if command -v osslsigncode >/dev/null; then v=$(osslsigncode verify -in $f -CAfile pki/root.pem -TSA-CAfile pki/root.pem 2>&1 | grep -i 'signature verification' | head -1); fi
  echo "RESULT $b: sh ./file -> $o1| direct ./file -> $o2| asset found=$ok; hash unchanged by the runs=$([ $h0 = $h1 ] && echo yes || echo NO); osslsigncode: $v"
done
