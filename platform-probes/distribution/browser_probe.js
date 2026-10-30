// What does a real Chrome do with a downloaded executable on macOS: quarantine attribute on the downloaded file? Is a file kept in the page's own storage (OPFS) reachable and marked?
// usage: node browser_probe.js <file to serve> <work dir>
const { chromium } = require('playwright-core');
const http = require('http'), fs = require('fs'), path = require('path'), cp = require('child_process');
const [file, work] = process.argv.slice(2);
const R = (...a) => console.log('RESULT', ...a);
const sh = c => { try { return cp.execSync(c, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim(); } catch (e) { return 'exit ' + e.status + ' ' + String(e.stderr || '').trim().slice(0, 120); } };
(async () => {
  const body = fs.readFileSync(file);
  const srv = http.createServer((q, r) => {
    if (q.url === '/') { r.setHeader('content-type', 'text/html'); r.end('<a id=a href="/dl/game" download>download</a>'); }
    else { r.setHeader('content-type', 'application/octet-stream'); r.setHeader('content-disposition', 'attachment; filename="game"'); r.end(body); }
  }).listen(8123);
  const ud = path.join(work, 'profile'); fs.mkdirSync(ud, { recursive: true });
  const ctx = await chromium.launchPersistentContext(ud, { channel: 'chrome', headless: true, acceptDownloads: true });
  R('browser:', ctx.browser() ? ctx.browser().version() : 'persistent context');
  const page = await ctx.newPage(); await page.goto('http://127.0.0.1:8123/');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#a')]);
  const p = await dl.path();
  R('download stored at', p, 'size', fs.statSync(p).size, 'mode', (fs.statSync(p).mode & 0o777).toString(8));
  R('download extended attributes:', JSON.stringify(sh(`xattr -l "${p}"`)));
  // the page keeps the file in its own storage (Origin Private File System)
  const n = await page.evaluate(async () => {
    const root = await navigator.storage.getDirectory(); const fh = await root.getFileHandle('game.bin', { create: true });
    const w = await fh.createWritable(); const resp = await fetch('/dl/game'); await resp.body.pipeTo(w); return (await fh.getFile()).size;
  });
  R('OPFS file written by the page, size', n);
  const found = sh(`find "${ud}" -type f -size ${body.length}c 2>/dev/null | head -5`);
  R('on-disk candidates in the profile for the OPFS file:', JSON.stringify(found));
  for (const f of found.split('\n').filter(Boolean)) {
    R('  ', f.replace(ud, '<profile>'), 'mode', (fs.statSync(f).mode & 0o777).toString(8), 'xattrs', JSON.stringify(sh(`xattr -l "${f}"`)));
    const copy = path.join(work, 'from-opfs'); fs.copyFileSync(f, copy); fs.chmodSync(copy, 0o755);
    R('  a copy of it, marked executable, started from a shell: ', JSON.stringify(sh(`"${copy}" 2>&1 | head -2`)));
    break;
  }
  const fsa = await page.evaluate(() => ({ showSaveFilePicker: typeof window.showSaveFilePicker, showDirectoryPicker: typeof window.showDirectoryPicker }));
  R('File System Access API present (needs a user gesture and a native dialog, so not driven here):', JSON.stringify(fsa));
  await ctx.close(); srv.close();
})().catch(e => { console.log('RESULT browser probe failed:', String(e).slice(0, 300)); process.exit(0); });
