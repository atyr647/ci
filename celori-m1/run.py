#!/usr/bin/env python3
"""Celori M1 cross-OS check: run the engine's wasm tests under a stock Wasmtime CLI and compare their determinism hashes with expected.json (taken from the Linux x86-64 runs).
usage: run.py <wasmtime executable> <label>      exit 0 only when every test passes and every hash equals the expected one"""
import gzip, json, os, re, subprocess, sys, tempfile, time
wt, label = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))
exp = json.load(open(os.path.join(here, "expected.json")))
cooked = os.path.join(here, "assets", "cooked")
tmp = tempfile.mkdtemp()
res = {}
bad = 0
for name in ("physics_test", "gameplay_test", "scene_test", "animation_test", "audio_system_test"):
    wasm = os.path.join(tmp, name + ".wasm")
    open(wasm, "wb").write(gzip.open(os.path.join(here, "wasm", name + ".wasm.gz")).read())
    t0 = time.time()
    p = subprocess.run([wt, "run", "-W", "component-model-async=y", "-S", "p3=y", "--dir", cooked + "::/assets", wasm], capture_output=True, text=True, timeout=600)
    out = p.stdout + p.stderr
    hashes = dict(re.findall(r"^([A-Z_]+HASH\w*) ([0-9a-f]{16})\s*$", out, re.M))
    m = re.search(r"(\d+) checks, (\d+) failed", out)
    ok = p.returncode == 0 and m is not None and m.group(2) == "0" and hashes == exp[name]
    bad += not ok
    res[name] = {"ok": ok, "checks": m.group(1) if m else None, "failed": m.group(2) if m else None, "hashes": hashes, "seconds": round(time.time() - t0, 1)}
    print(f"RESULT [{label}] {name}: {'PASS' if ok else 'FAIL'} checks={res[name]['checks']} failed={res[name]['failed']} hashes={hashes} {res[name]['seconds']}s", flush=True)
    if not ok: print(out[-2000:], flush=True)
json.dump(res, open(f"results-wasm-{label}.json", "w"), indent=1)
sys.exit(1 if bad else 0)
