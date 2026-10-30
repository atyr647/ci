// usage: node [v8 flags] node_run.js module.wasm [kernel,filter]   -- runs a wasi-sdk shootout module under V8 with Node's WASI
const fs = require('fs'); const { WASI } = require('node:wasi');
const wasi = new WASI({ version: 'preview1', args: ['so'].concat(process.argv.slice(3)), env: {}, returnOnExit: true });
const mod = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
const inst = new WebAssembly.Instance(mod, wasi.getImportObject());
process.exitCode = wasi.start(inst);
