#!/bin/bash
# Linux: build the test programs with Cosmopolitan, add a zip asset, prepare the PE header, sign with osslsigncode (several layouts), check zip readers and a Linux run.
# cwd = repository root; ./cosmo holds cosmocc. Results go to out/ (unsigned), signed/ (Authenticode-signed with the throwaway test PKI), pki/.
set +e
P=platform-probes; S=$P/signing
mkdir -p out signed
cosmo/bin/cosmocc -O2 $P/app.c -o out/app.com || exit 1
cosmo/bin/cosmocc -O2 $P/hello.c -o out/hello.com || exit 1
cosmo/bin/cosmocc -O2 $P/jit_probe.c -o out/jit.com || echo "jit_probe did not build"
cosmo/bin/cosmocc -O2 $P/dl_probe.c -o out/dl.com || echo "dl_probe did not build"
echo signed-test-asset > asset.txt
for z in "-A" ""; do
  cp out/app.com t.com; zip -q $z t.com asset.txt
  if sh ./t.com 2>&1 | grep -q signed-test-asset; then echo "zip flags '$z': the asset resolves under /zip"; mv t.com out/app.com; break; else echo "zip flags '$z': asset NOT found"; fi
done
sh ./out/app.com; sh ./out/dl.com
cp out/dl.com out/dl-copy.com
bash $S/pki.sh pki >/dev/null
for n in app hello dl; do [ -f out/$n.com ] && python3 $P/pe_prepare_for_signing.py out/$n.com signed/$n-prep.exe; done
sudo apt-get install -y osslsigncode >/dev/null 2>&1; osslsigncode --version 2>&1 | head -1
SIGN="osslsigncode sign -certs pki/leaf-chain.pem -key pki/leaf.key -h sha256 -n TestApp"
echo "--- control: osslsigncode on the unprepared file"; $SIGN -in out/app.com -out tmp-unprep.exe 2>&1 | tail -2
python3 $S/tsa_server.py pki 8318 & TSA=$!; sleep 1
echo "--- signing"
$SIGN -in signed/app-prep.exe -out signed/app-ossl.exe 2>&1 | tail -1
$SIGN -ts http://127.0.0.1:8318 -in signed/app-prep.exe -out signed/app-ossl-ts.exe 2>&1 | tail -2
$SIGN -in signed/dl-prep.exe -out signed/dl-ossl.exe 2>&1 | tail -1
$SIGN -in signed/hello-prep.exe -out signed/hello-ossl.exe 2>&1 | tail -1
echo "--- zip slot layout (certificate table inside the EOCD comment, zip EOCD stays the last record)"
for v in plain ts; do
  python3 platform-probes/ape_zip_slot.py reserve signed/app-prep.exe tmp-reserved.exe 16384
  rm -f tmp-signed1.exe
  if [ $v = ts ]; then $SIGN -ts http://127.0.0.1:8318 -in tmp-reserved.exe -out tmp-signed1.exe 2>&1 | tail -6; else $SIGN -in tmp-reserved.exe -out tmp-signed1.exe 2>&1 | tail -1; fi
  [ -f tmp-signed1.exe ] && python3 platform-probes/ape_zip_slot.py fill tmp-signed1.exe signed/app-ossl-$v-slot.exe 16384
done
kill $TSA 2>/dev/null
echo "--- checks per file"
cat > zipcheck.py <<'PY'
import zipfile, sys
try:
    z = zipfile.ZipFile(sys.argv[1]); print('  python zipfile: OK,', len(z.namelist()), 'entries, asset =', z.read('asset.txt').decode().strip())
except Exception as e: print('  python zipfile: FAILED', repr(e))
PY
for f in out/app.com signed/app-prep.exe signed/app-ossl.exe signed/app-ossl-ts.exe signed/app-ossl-plain-slot.exe signed/app-ossl-ts-slot.exe; do
  echo "== $f: $(stat -c %s $f) bytes"
  unzip -l $f > unz.txt 2>&1; echo "  unzip -l exit $?: $(grep -c . unz.txt) lines; $(grep -i 'warning\|error\|cannot' unz.txt | head -2 | tr '\n' '|')$(tail -1 unz.txt)"
  python3 -I zipcheck.py $f
  zipinfo -t $f > zi.txt 2>&1; echo "  zipinfo -t exit $?: $(tail -1 zi.txt)"
  o=$(sh ./$f 2>&1); echo "  sh ./file exit $?: $(echo $o | tr '\n' ' ')"
  case $f in signed/*) osslsigncode verify -in $f -CAfile pki/root.pem -TSA-CAfile pki/root.pem 2>&1 | grep -i "signature verification\|timestamp\|number of verified\|error\|mismatch\|calculated\|current message" | head -6 | sed 's/^/  osslsigncode verify: /';; esac
done
echo "--- other signed files run"; for f in signed/dl-ossl.exe signed/hello-ossl.exe; do echo "$f: $(sh ./$f 2>&1 | tr '\n' ' ')"; done
echo "--- negative control: adding a file to the zip AFTER signing invalidates the signature (assets must be added before signing)"
cp signed/app-ossl.exe after.exe; echo late > late.txt; zip -q -A after.exe late.txt; sh ./after.exe | head -1
osslsigncode verify -in after.exe -CAfile pki/root.pem 2>&1 | grep -i "signature verification\|message digest" | head -3 | sed 's/^/  osslsigncode verify after zip -A: /'
cp after.exe signed/neg-zip-modified.exe
rm -f t.com tmp-*.exe
