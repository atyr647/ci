// Creates a throwaway Ed25519 key, writes pubkey.txt, and signs pack/manifest.txt for every host found under pack/host/<platform>/.
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const root = process.argv[2] || 'pack', sha512 = f => crypto.createHash('sha512').update(fs.readFileSync(f)).digest('hex');
const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
fs.writeFileSync('pubkey.txt', publicKey.export({ type: 'spki', format: 'der' }).slice(-32).toString('hex'));
let m = 'sample-manifest 1\ngame ci-1\n';
for (const plat of fs.readdirSync(path.join(root, 'host')).sort()) for (const name of fs.readdirSync(path.join(root, 'host', plat))) { const f = path.join(root, 'host', plat, name); m += `file ${plat} ${name} ${sha512(f)} ${fs.statSync(f).size} /host/${plat}/${name}\n`; }
for (const name of fs.readdirSync(path.join(root, 'game'))) { const f = path.join(root, 'game', name); m += `file any ${name} ${sha512(f)} ${fs.statSync(f).size} /game/${name}\n`; }
fs.writeFileSync(path.join(root, 'manifest.txt'), m); fs.writeFileSync(path.join(root, 'manifest.sig'), crypto.sign(null, Buffer.from(m), privateKey).toString('hex'));
console.log(m);
