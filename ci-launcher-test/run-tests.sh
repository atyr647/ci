#!/usr/bin/env bash
# usage: run-tests.sh <label>   (cwd = kit dir with launcher.com, pubkey.txt, pack/, *.c)
LABEL=${1:-local}; PUB=$(cat pubkey.txt); fails=0; EXE=""; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=".exe";; esac
res() { if [ "$2" = ok ]; then echo "RESULT [$LABEL] $1: PASS"; else echo "RESULT [$LABEL] $1: FAIL ($3)"; fails=$((fails+1)); fi; }
echo "== machine: $(uname -a)"; node -e "console.log('node', process.version, process.platform, process.arch)"
node serve.js pack 8099 & SRV=$!; sleep 2
cp launcher.com "ape-launcher$EXE"; chmod +x "ape-launcher$EXE"
CC=${CC:-cc}; command -v "$CC" >/dev/null || CC=gcc
"$CC" -O2 -DPUBKEY_HEX="\"$PUB\"" -o "native-launcher$EXE" celori-launcher.c monocypher.c monocypher-ed25519.c 2>build.err && echo "native build ok ($CC)" || { echo "native build FAILED"; cat build.err | head -5; }
want="hello from a WASM module"
t() { name=$1; shift; out=$("$@" 2>&1); code=$?; echo "$out" | sed 's/^/    /' | tail -12; echo "    (exit $code)"; LAST_OUT=$out; LAST_CODE=$code; }
echo "--- 1. Cosmopolitan single file, online (curl) install + run"; rm -rf inst1; t ape "./ape-launcher$EXE" --server http://127.0.0.1:8099 --dir "$PWD/inst1"
case "$LAST_OUT" in *"$want"*) res ape-online-install-and-run ok;; *) res ape-online-install-and-run bad "no game output, exit $LAST_CODE";; esac
echo "--- 2. same file again: nothing should be downloaded"; t ape2 "./ape-launcher$EXE" --server http://127.0.0.1:8099 --dir "$PWD/inst1" --update-only
case "$LAST_OUT" in *"verified and installed"*) res ape-delta-update bad "downloaded again";; *"up to date"*) res ape-delta-update ok;; *) res ape-delta-update bad "exit $LAST_CODE";; esac
echo "--- 3. plain native build of the same source, online"; rm -rf inst2; t nat "./native-launcher$EXE" --server http://127.0.0.1:8099 --dir "$PWD/inst2"
case "$LAST_OUT" in *"$want"*) res native-online-install-and-run ok;; *) res native-online-install-and-run bad "exit $LAST_CODE";; esac
echo "--- 4. default install location for this OS (no --dir), from local files"; t def "./ape-launcher$EXE" --from "$PWD/pack" --update-only
case "$LAST_OUT" in *"install dir"*"ready"*|*"ready"*) res ape-default-install-dir ok;; *) res ape-default-install-dir bad "exit $LAST_CODE";; esac
echo "$LAST_OUT" | grep "install dir" | head -1
echo "--- 5. tampered host binary must be refused"; rm -rf pack_bad inst3; cp -r pack pack_bad
node -e "const fs=require('fs'),p=require('path');const d='pack_bad/host';for(const pl of fs.readdirSync(d))for(const n of fs.readdirSync(p.join(d,pl))){const f=p.join(d,pl,n),b=fs.readFileSync(f);b[Math.floor(b.length/2)]^=255;fs.writeFileSync(f,b);}"
t tam "./ape-launcher$EXE" --from "$PWD/pack_bad" --dir "$PWD/inst3"
if { [ "$LAST_CODE" = 4 ] || { [ -n "$EXE" ] && case "$LAST_OUT" in *REFUSING*) true;; *) false;; esac; }; } && [ ! -e "inst3/wasmtime$EXE" ]; then res tampered-host-refused ok; else res tampered-host-refused bad "exit $LAST_CODE"; fi
echo "--- 6. forged signature must be refused"; rm -rf pack_sig inst4; cp -r pack pack_sig; node -e "const fs=require('fs');let s=fs.readFileSync('pack_sig/manifest.sig','utf8');fs.writeFileSync('pack_sig/manifest.sig',s.slice(0,8)+(s[8]==='0'?'1':'0')+s.slice(9))"
t sig "./ape-launcher$EXE" --from "$PWD/pack_sig" --dir "$PWD/inst4"
if [ "$LAST_CODE" = 3 ] || { [ -n "$EXE" ] && case "$LAST_OUT" in *"signature is invalid"*) true;; *) false;; esac; }; then res forged-signature-refused ok; else res forged-signature-refused bad "exit $LAST_CODE"; fi
kill $SRV 2>/dev/null; echo "== SUMMARY [$LABEL]: $fails failure(s)"; exit $fails
