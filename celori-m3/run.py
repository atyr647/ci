#!/usr/bin/env python3
"""M2/M3 cross-OS check. Three parts, all deterministic:
  1. the engine's schema test (a wasm32-wasip3 component) under a stock Wasmtime CLI: its SCHEMA_HASH (a hash of the generated JSON Schema, the component inspection and a game component's
     schema) must equal the value taken from the Linux x86-64 run
  2. the image-comparison tests (pure Python): they must all pass on this OS and Python
  3. the comparison of real captures: the metrics for three pairs (the same scene with a vanished pillar, a 2 percent dimmer sun, a tinted ground) against the reference capture must equal the
     values in expected.json (the numbers are IEEE doubles computed in pure Python; equality is checked to 1e-9)
usage: run.py <wasmtime executable> <label>      exit 0 only when everything passes"""
import gzip, json, os, re, subprocess, sys, tempfile, time
wt, label = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, "tools"))
exp = json.load(open(os.path.join(here, "expected.json")))
tmp = tempfile.mkdtemp()
bad = 0
res = {}

def report(name, ok, detail=""):
    global bad
    bad += not ok
    res[name] = {"ok": ok, "detail": detail}
    print(f"RESULT [{label}] {name}: {'PASS' if ok else 'FAIL'} {detail}", flush=True)

# 1. wasm
wasm = os.path.join(tmp, "schema_test.wasm")
open(wasm, "wb").write(gzip.open(os.path.join(here, "wasm", "schema_test.wasm.gz")).read())
t0 = time.time()
p = subprocess.run([wt, "run", "-W", "component-model-async=y", "-S", "p3=y", wasm], capture_output=True, text=True, timeout=600)
out = p.stdout + p.stderr
h = dict(re.findall(r"^([A-Z_]+HASH\w*) ([0-9a-f]{16})\s*$", out, re.M)); m = re.search(r"(\d+) checks, (\d+) failed", out)
report("schema_test (wasm)", p.returncode == 0 and m is not None and m.group(2) == "0" and h == exp["schema_test"], f"checks={m.group(1) if m else None} failed={m.group(2) if m else None} hashes={h} {time.time() - t0:.1f}s")
if bad: print(out[-1500:], flush=True)

# 2. image comparison tests
p = subprocess.run([sys.executable, os.path.join(here, "tools", "image_compare_test.py")], capture_output=True, text=True, timeout=600)
npass = p.stdout.count("PASS "); nfail = p.stdout.count("FAIL ")
report("image_compare_test", p.returncode == 0 and nfail == 0 and npass == exp["image_compare_test_checks"], f"pass={npass} fail={nfail}")
if p.returncode: print(p.stdout[-1500:], flush=True)

# 3. real captures
import check_png, image_compare as ic
def load(n):
    f = os.path.join(tmp, n + ".png"); open(f, "wb").write(gzip.open(os.path.join(here, "fixtures", n + ".png.gz")).read()); return check_png.decode(f)
w, h_, ra = load("golden")
for n in ("pillar_removed", "sun_2pct", "ground_tint"):
    w2, h2, rb = load(n)
    t0 = time.time(); m = ic.compare(ra, rb, w, h_)
    want = exp["captures"][n]
    ok = (w2, h2) == (w, h_) and m["changed_bbox"] == want["changed_bbox"] and m["max_channel_diff"] == want["max_channel_diff"] and all(abs(m[k] - want[k]) < 1e-9 for k in ("mean_abs_channel_diff", "pixels_over_8_pct", "ssim", "min_block_ssim"))
    report("capture " + n, ok, f"mean={m['mean_abs_channel_diff']:.4f} over8={m['pixels_over_8_pct']:.3f}% ssim={m['ssim']:.5f} worst={m['min_block_ssim']:.4f} bbox={m['changed_bbox']} {time.time() - t0:.1f}s")
json.dump(res, open(f"results-m3-{label}.json", "w"), indent=1)
sys.exit(1 if bad else 0)
