#!/usr/bin/env python3
"""Build the host audio shim (celori_audio.c over the pinned miniaudio) and its test with the C/C++ compiler of the runner, run it in OFFLINE mode, compare the mix hash with expected.json.
usage: audio-shim.py <label> <miniaudio dir> [cc] [c++]"""
import json, os, re, subprocess, sys, platform
label, ma = sys.argv[1], os.path.abspath(sys.argv[2])
cc = sys.argv[3] if len(sys.argv) > 3 else "clang"; cxx = sys.argv[4] if len(sys.argv) > 4 else "clang++"
here = os.path.dirname(os.path.abspath(__file__))
exp = json.load(open(os.path.join(here, "expected.json")))["audio_shim"]
w = os.path.join(here, "work"); os.makedirs(os.path.join(w, ".deps", "miniaudio"), exist_ok=True)
# celori_audio.c includes ../.deps/miniaudio/miniaudio.h relative to its own directory
ad = os.path.join(w, "audio-host"); os.makedirs(ad, exist_ok=True)
import shutil
for f in ("celori_audio.c", "celori_audio.h", "audio_test.cpp"): shutil.copy(os.path.join(here, "audio-host", f), ad)
shutil.copy(os.path.join(ma, "miniaudio.h"), os.path.join(w, ".deps", "miniaudio", "miniaudio.h"))
win = platform.system() == "Windows"
exe = os.path.join(w, "audio_test" + (".exe" if win else ""))
libs = [] if win else (["-lm", "-lpthread"] + (["-ldl"] if platform.system() == "Linux" else []))
obj = os.path.join(w, "celori_audio.o")
def run(cmd):
    print("+", " ".join(cmd), flush=True); return subprocess.run(cmd, capture_output=True, text=True)
for cmd in ([cc, "-O2", "-c", os.path.join(ad, "celori_audio.c"), "-o", obj], [cxx, "-std=c++17", "-O1", os.path.join(ad, "audio_test.cpp"), obj, "-o", exe] + libs):
    r = run(cmd)
    if r.returncode: print(r.stdout[-3000:], r.stderr[-3000:]); sys.exit(2)
r = run([exe, os.path.join(here, "assets", "source"), os.path.join(w, "capture.wav")])
out = r.stdout + r.stderr
m = re.search(r"(\d+) checks, (\d+) failed", out); h = re.search(r"AUDIO_CAPTURE_HASH ([0-9a-f]{16})", out)
ok = r.returncode == 0 and m and m.group(2) == "0" and h and h.group(1) == exp["AUDIO_CAPTURE_HASH"]
print(f"RESULT [{label}] audio_shim: {'PASS' if ok else 'FAIL'} checks={m.group(1) if m else None} failed={m.group(2) if m else None} hash={h.group(1) if h else None} expected={exp['AUDIO_CAPTURE_HASH']}")
if not ok: print(out[-3000:])
sys.exit(0 if ok else 1)
