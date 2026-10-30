// usage: node [v8 flags] node_revec.js revec_test.wasm  -> prints ns per 128-bit element-op group for run1/run2/run4 (best of 7)
const fs = require('fs');
const inst = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[2])), {});
const e = inst.exports; e.init();
for (const name of ['run1', 'run2', 'run4']) {
  const f = e[name]; f(2000);   // warm up / tier up
  let best = 1e30; const iters = 20000;
  for (let r = 0; r < 7; r++) { const t0 = process.hrtime.bigint(); f(iters); const dt = Number(process.hrtime.bigint() - t0); best = Math.min(best, dt); }
  console.log(`${name} ${(best / iters / 2048 * 1000).toFixed(1)} ps/float`);
}
