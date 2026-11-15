#!/usr/bin/env python3
"""Reads through a mounted kit, against the same tree as plain files.

    reads.py concurrent KITDIR REFDIR [threads] [seconds]
        threads read random ranges of random files of the mounted kit and of the plain copy and
        compare them; every few reads a file's page cache is dropped (posix_fadvise DONTNEED), so
        the reads keep reaching the server, many at once.  Any difference or error fails.

    reads.py bench KITDIR REFDIR [remount-command]
        cold and warm: every file read whole; 200 small files; 4 KiB reads at random offsets of
        the biggest file; the biggest file whole.  "Cold" drops the kernel's caches first (needs
        root: /proc/sys/vm/drop_caches) and runs remount-command, if given, so the kit's server
        side starts cold too.  Prints one line per measurement, in ms.
"""
import os
import random
import subprocess
import sys
import threading
import time


def files_of(top):
    out = []
    for d, _, fs in os.walk(top):
        for f in fs:
            p = os.path.join(d, f)
            if os.path.isfile(p) and not os.path.islink(p):
                out.append(os.path.relpath(p, top))
    return sorted(out)


def concurrent(kit, ref, threads=8, seconds=10.0):
    names = files_of(ref)
    sizes = {n: os.path.getsize(os.path.join(ref, n)) for n in names}
    names = [n for n in names if sizes[n] > 0]
    stop = time.time() + seconds
    errors = []
    counts = [0] * threads

    def worker(t):
        rnd = random.Random(t)
        n = "?"
        try:
            while time.time() < stop and not errors:
                n = rnd.choice(names)
                a = os.open(os.path.join(kit, n), os.O_RDONLY)
                b = os.open(os.path.join(ref, n), os.O_RDONLY)
                size = sizes[n]
                off = rnd.randrange(size)
                ln = rnd.choice([1, 100, 4096, 65536, 131072, 300000, 1 << 20])
                if rnd.random() < 0.2:
                    os.posix_fadvise(a, 0, 0, os.POSIX_FADV_DONTNEED)
                x = os.pread(a, ln, off)
                y = os.pread(b, ln, off)
                os.close(a)
                os.close(b)
                if x != y:
                    errors.append(f"{n} at {off}+{ln}: {len(x)} bytes differ from the plain copy's {len(y)}")
                counts[t] += 1
        except OSError as e:
            errors.append(f"{n}: {e}")

    ts = [threading.Thread(target=worker, args=(t,)) for t in range(threads)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    total = sum(counts)
    if errors:
        print("  FAIL concurrent reads:", *errors[:5], sep="\n    ")
        return 1
    print(f"  ok   concurrent reads: {threads} threads, {total} random reads of {len(names)} files in {seconds:.0f} s, all equal to the plain copy")
    return 0


def drop(remount):
    if remount:
        subprocess.run(remount, shell=True, check=True, stdout=subprocess.DEVNULL)
    os.sync()
    with open("/proc/sys/vm/drop_caches", "w") as f:
        f.write("3\n")


def timed(fn):
    t = time.perf_counter()
    n = fn()
    return (time.perf_counter() - t) * 1000, n


def read_all(top, names):
    n = 0
    for name in names:
        with open(os.path.join(top, name), "rb", buffering=0) as f:
            while True:
                b = f.read(1 << 20)
                if not b:
                    break
                n += len(b)
    return n


def bench(kit, ref, remount=None):
    names = files_of(ref)
    sizes = {n: os.path.getsize(os.path.join(ref, n)) for n in names}
    small = [n for n in names if sizes[n] < 16384][:200]
    big = max(names, key=lambda n: sizes[n])
    offs = random.Random(7).sample(range(0, sizes[big] - 4096, 4096), 50)
    can_drop = os.access("/proc/sys/vm/drop_caches", os.W_OK)

    def rand4k(top):
        fd = os.open(os.path.join(top, big), os.O_RDONLY)
        try:
            return sum(len(os.pread(fd, 4096, o)) for o in offs)
        finally:
            os.close(fd)

    tests = [
        ("all files", lambda top: read_all(top, names)),
        ("200 small files", lambda top: read_all(top, small)),
        (f"50 x 4 KiB at random offsets of {os.path.basename(big)}", rand4k),
        (f"{os.path.basename(big)} ({sizes[big] >> 20} MiB) whole", lambda top: read_all(top, [big])),
    ]
    total = sum(sizes.values())
    print(f"  bench: {len(names)} files, {total / 1e6:.1f} MB; cold = {'caches dropped' + (' + kit remounted' if remount else '') if can_drop else 'NOT cold (no root for drop_caches)'}")
    for label, fn in tests:
        row = []
        for which, top, rm in (("kit", kit, remount), ("plain", ref, None)):
            if can_drop:
                drop(rm)
            cold, _ = timed(lambda: fn(top))
            warm = min(timed(lambda: fn(top))[0] for _ in range(3))
            row.append(f"{which} cold {cold:8.1f} warm {warm:7.1f}")
        print(f"  {label:44s} {row[0]}   |   {row[1]}")
    return 0


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    mode, kit, ref = sys.argv[1:4]
    if mode == "concurrent":
        return concurrent(kit, ref, int(sys.argv[4]) if len(sys.argv) > 4 else 8, float(sys.argv[5]) if len(sys.argv) > 5 else 10)
    if mode == "bench":
        return bench(kit, ref, sys.argv[4] if len(sys.argv) > 4 else None)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
