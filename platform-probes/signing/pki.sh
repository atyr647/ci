#!/bin/bash
# Throwaway test PKI: a root CA, a code-signing leaf (what a real publisher certificate looks like: EKU codeSigning, chain to a root), a time-stamping authority.
# usage: pki.sh <outdir>      (test keys only; nothing here is a real identity)
set -e
d=${1:-pki}; mkdir -p "$d"; cd "$d"
openssl req -x509 -newkey rsa:3072 -nodes -keyout root.key -out root.pem -days 30 -subj '/CN=Test Root CA (CI only)' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' 2>/dev/null
openssl x509 -in root.pem -outform DER -out root.cer
mk() {  # name, subject, extension lines
  openssl req -newkey rsa:3072 -nodes -keyout $1.key -out $1.csr -subj "$2" 2>/dev/null
  printf "$3" > $1.ext
  openssl x509 -req -in $1.csr -CA root.pem -CAkey root.key -CAcreateserial -out $1.pem -days 20 -extfile $1.ext 2>/dev/null
}
mk leaf '/CN=Test Software Publisher/O=CI Test' 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n'
mk tsa  '/CN=Test Timestamp Authority/O=CI Test' 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,timeStamping\n'
cat leaf.pem root.pem > leaf-chain.pem; cat tsa.pem root.pem > tsa-chain.pem
# .pfx in the old (3DES/SHA1) container so every Windows version imports it
openssl pkcs12 -export -inkey leaf.key -in leaf.pem -certfile root.pem -out leaf.pfx -passout pass:pw -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null \
  || openssl pkcs12 -export -legacy -inkey leaf.key -in leaf.pem -certfile root.pem -out leaf.pfx -passout pass:pw
echo 01 > tsaserial
cat > tsa.cnf <<EOF
oid_section = new_oids
[ new_oids ]
tsa_policy1 = 1.2.3.4.1
[ tsa ]
default_tsa = tsa_config1
[ tsa_config1 ]
dir = $PWD
serial = \$dir/tsaserial
crypto_device = builtin
signer_cert = \$dir/tsa.pem
certs = \$dir/tsa-chain.pem
signer_key = \$dir/tsa.key
signer_digest = sha256
default_policy = tsa_policy1
other_policies = tsa_policy1
digests = sha256, sha384, sha512
accuracy = secs:1
ordering = yes
tsa_name = yes
ess_cert_id_chain = no
ess_cert_id_alg = sha256
EOF
ls
