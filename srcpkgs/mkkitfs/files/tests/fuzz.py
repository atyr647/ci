#!/usr/bin/env python3
"""Damaged-kit fuzz pass for mkkitfs's reader.

    fuzz.py MKKITFS GOLDEN_DIR KEYFILE [iterations] [seed]

Takes the valid golden kits and damages copies of them the way tests/mkgolden.tcl damages its
eight (a flipped byte in a chunk, the seal, the image; a truncation), and at random: flipped bytes
anywhere, runs of zeros or random bytes, truncations and appended bytes, aimed at the seal, the
Metakit header and tails, the structure and the payload.  Each damaged kit goes through
`mkkitfs expect`, which opens it, reads and hashes every file and verifies it.  What must hold:

  - no crash, no hang (a signal or a 20 s timeout is a failure); with FUZZ_SANITIZER=1 (a sanitizer
    build, tests/fuzz-sanitize.sh) no sanitizer report either, whatever the exit status;
  - an exit status of 0 or 1 and an output line "open ok" or "open fail CODE";
  - a kit that opens never yields wrong bytes: every file it reads has the content hash of the
    original golden kit's .expect, and every file it cannot read fails with HASH, CODEC or IO.
"""
import os
import random
import re
import subprocess
import sys
import tempfile


# what AddressSanitizer, LeakSanitizer and UndefinedBehaviorSanitizer print when they find something
SANITIZER_MARKS = ("ERROR: AddressSanitizer", "ERROR: LeakSanitizer", "LeakSanitizer has encountered",
                   "runtime error:", "SUMMARY: UndefinedBehaviorSanitizer", "SUMMARY: AddressSanitizer")


def expect_hashes(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^entry (.+) file \d+ \d+ \S+ \d+ \d+ ([0-9a-f]{64})$", line.rstrip("\n"))
        if m:
            out[m.group(1)] = m.group(2)
    return out


def damage(data, rnd):
    b = bytearray(data)
    n = len(b)
    kind = rnd.choice(["flip", "flip", "flip", "flips", "zeros", "random", "truncate", "append", "tail", "seal", "head"])
    if kind == "flip":
        i = rnd.randrange(n)
        b[i] ^= rnd.choice([0x01, 0x80, 0x5A, 0xFF])
    elif kind == "flips":
        for _ in range(rnd.randint(2, 16)):
            b[rnd.randrange(n)] ^= rnd.randrange(1, 256)
    elif kind == "zeros":
        i = rnd.randrange(n)
        b[i:i + rnd.randint(1, 512)] = bytes(min(n - i, rnd.randint(1, 512)))
        b = b[:n]
    elif kind == "random":
        i = rnd.randrange(n)
        k = min(n - i, rnd.randint(1, 256))
        b[i:i + k] = bytes(rnd.randrange(256) for _ in range(k))
    elif kind == "truncate":
        b = b[:rnd.randrange(1, n)]
    elif kind == "append":
        b += bytes(rnd.randrange(256) for _ in range(rnd.randint(1, 64)))
    elif kind == "tail":   # Metakit's tails, the last 24 bytes
        i = n - 1 - rnd.randrange(24)
        b[i] ^= rnd.randrange(1, 256)
    elif kind == "seal":   # the seal block (the 4 KiB in front of the store, for kits without a header)
        i = rnd.randrange(min(n, 4096))
        b[i] ^= rnd.randrange(1, 256)
    else:                  # the Metakit header and the structure right after it
        i = 4096 + rnd.randrange(min(256, n - 4096)) if n > 4352 else rnd.randrange(n)
        b[i] ^= rnd.randrange(1, 256)
    return bytes(b), kind


def main():
    exe, gold, keys = sys.argv[1:4]
    iters = int(sys.argv[4]) if len(sys.argv) > 4 else 300
    seed = int(sys.argv[5]) if len(sys.argv) > 5 else 1
    rnd = random.Random(seed)
    sanitizer = os.environ.get("FUZZ_SANITIZER") == "1"
    kits = {}
    for name in ("app", "app-header", "system"):
        kits[name] = (open(os.path.join(gold, name + ".kit"), "rb").read(), expect_hashes(os.path.join(gold, name + ".expect")))
    stats = {"refused": 0, "opened": 0, "unreadable": 0}
    codes = {}
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        p = os.path.join(tmp, "damaged.kit")
        for it in range(iters):
            name = rnd.choice(sorted(kits))
            data, want = kits[name]
            dmg, kind = damage(data, rnd)
            with open(p, "wb") as f:
                f.write(dmg)
            try:
                r = subprocess.run([exe, "expect", "--keys", keys, p], capture_output=True, timeout=20)
            except subprocess.TimeoutExpired:
                print(f"FAIL {it}: {name} {kind}: hang")
                bad += 1
                continue
            out = r.stdout.decode("utf-8", "replace")
            err = r.stderr.decode("utf-8", "replace")
            if sanitizer and any(m in err for m in SANITIZER_MARKS):
                print(f"FAIL {it}: {name} {kind}: sanitizer report (exit {r.returncode})\n{err[-4000:]}")
                if os.environ.get("FUZZ_KEEP"):
                    open(os.path.join(os.environ["FUZZ_KEEP"], f"sanitizer-{seed}-{it}.kit"), "wb").write(dmg)
                bad += 1
                continue
            if r.returncode < 0 or r.returncode > 1:
                print(f"FAIL {it}: {name} {kind}: exit {r.returncode}\n{err[-2000:]}")
                if os.environ.get("FUZZ_KEEP"):   # a directory to keep the kits that failed in
                    open(os.path.join(os.environ["FUZZ_KEEP"], f"crash-{seed}-{it}.kit"), "wb").write(dmg)
                bad += 1
                continue
            first = out.split("\n", 1)[0]
            if first.startswith("open fail "):
                stats["refused"] += 1
                c = first.split()[2]
                codes[c] = codes.get(c, 0) + 1
                continue
            if first != "open ok":
                print(f"FAIL {it}: {name} {kind}: unexpected output {first!r}")
                bad += 1
                continue
            stats["opened"] += 1
            for line in out.splitlines():
                m = re.match(r"^entry (.+) file \d+ \d+ \S+ \d+ \d+ ([0-9a-f]{64})$", line)
                if m:
                    if want.get(m.group(1)) != m.group(2):
                        print(f"FAIL {it}: {name} {kind}: {m.group(1)} read WRONG data without an error")
                        bad += 1
                    continue
                m = re.match(r"^entry (.+) read fail (\S+)$", line)
                if m:
                    stats["unreadable"] += 1
                    if m.group(2) not in ("HASH", "CODEC", "IO"):
                        print(f"FAIL {it}: {name} {kind}: {m.group(1)} failed with {m.group(2)}")
                        bad += 1
    print(f"fuzz: {iters} damaged kits (seed {seed}): {stats['refused']} refused "
          f"({', '.join(f'{k} {v}' for k, v in sorted(codes.items()))}), {stats['opened']} opened "
          f"({stats['unreadable']} files unreadable, every other file correct), {bad} failures")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
