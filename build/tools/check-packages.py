#!/usr/bin/env python3
"""Check that every package Ribbon depends on exists in Void's repositories.

Reads depends= from srcpkgs/*/template and every build/packages/*.list,
downloads (or reuses) Void's repodata for main/nonfree/multilib/multilib-nonfree
and reports names that don't exist. Exit status 1 if anything is missing.

Usage: build/tools/check-packages.py [--mirror URL] [--cache DIR]
"""
import argparse, io, os, plistlib, re, sys, tarfile, urllib.request

REPOS = ["current", "current/nonfree", "current/multilib", "current/multilib/nonfree"]
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def zstd_decompress(data):
    try:
        import zstandard
        return zstandard.ZstdDecompressor().stream_reader(io.BytesIO(data)).read()
    except ImportError:
        import subprocess
        return subprocess.run(["zstd", "-dc"], input=data, capture_output=True, check=True).stdout


def load_index(mirror, cache):
    names = set()
    os.makedirs(cache, exist_ok=True)
    for repo in REPOS:
        path = os.path.join(cache, repo.replace("/", "_") + ".repodata")
        if not os.path.exists(path):
            url = f"{mirror}/{repo}/x86_64-repodata"
            with urllib.request.urlopen(url, timeout=120) as r, open(path, "wb") as f:
                f.write(r.read())
        with open(path, "rb") as f:
            tar = tarfile.open(fileobj=io.BytesIO(zstd_decompress(f.read())))
        index = plistlib.loads(tar.extractfile("index.plist").read())
        for name, meta in index.items():
            names.add(name)
            for prov in meta.get("provides", []):
                names.add(re.sub(r"-[^-]+_[0-9]+$", "", prov))
    return names


def wanted():
    """Yield (source, pkgname)."""
    srcdir = os.path.join(ROOT, "srcpkgs")
    for pkg in sorted(os.listdir(srcdir)):
        tpl = os.path.join(srcdir, pkg, "template")
        if not os.path.exists(tpl):
            continue
        text = open(tpl).read()
        m = re.search(r'^depends="([^"]*)"', text, re.M | re.S)
        if m:
            for tok in m.group(1).split():
                if tok.startswith("$"):
                    continue
                yield f"srcpkgs/{pkg}", re.split(r"[<>=]", tok)[0]
    lists = os.path.join(ROOT, "build", "packages")
    if os.path.isdir(lists):
        for fn in sorted(os.listdir(lists)):
            if fn.endswith(".list"):
                for line in open(os.path.join(lists, fn)):
                    line = line.split("#", 1)[0].strip()
                    for tok in line.split():
                        yield f"build/packages/{fn}", tok
    # The Void packages Ribbon's tools install (ribbon-gpu, ribbon-hw, postinstall, the installer's Hardware
    # and Apps pages): the names in the package seam's map, the only place they are written
    names = os.path.join(ROOT, "srcpkgs/ribbon-tools/files/lib/pkg-names.xbps")
    if os.path.exists(names):
        for line in open(names):
            for tok in line.split("#", 1)[0].split()[1:]:
                yield "pkg-names.xbps", tok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mirror", default="https://repo-default.voidlinux.org")
    ap.add_argument("--cache", default=os.path.join(ROOT, "out", "repodata-cache"))
    a = ap.parse_args()
    names = load_index(a.mirror, a.cache)
    ours = {d for d in os.listdir(os.path.join(ROOT, "srcpkgs"))}
    missing = {}
    for src, pkg in wanted():
        if pkg in names or pkg in ours:
            continue
        missing.setdefault(pkg, set()).add(src)
    for pkg in sorted(missing):
        print(f"MISSING {pkg:32s} used by {', '.join(sorted(missing[pkg]))}")
    print(f"checked against {len(names)} Void packages: {len(missing)} missing")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
