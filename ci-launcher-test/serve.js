// minimal static file server so the launcher's real network path (curl) is exercised on every OS
const http = require('http'), fs = require('fs'), path = require('path'); const root = path.resolve(process.argv[2]), port = +process.argv[3] || 8099;
http.createServer((q, r) => { const f = path.join(root, decodeURIComponent(q.url.split('?')[0])); if (!f.startsWith(root) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { r.writeHead(404); return r.end(); } r.writeHead(200, { 'Content-Length': fs.statSync(f).size }); fs.createReadStream(f).pipe(r); }).listen(port, '127.0.0.1');
