#!/usr/bin/env python3
"""Measure Ribbon's software stack from Void's repodata (docs/STACK.md).

Resolves run_depends (xbps-src has already added the shared-library
dependencies to them) into full dependency closures and sums
installed_size. Uses the same repodata cache as check-packages.py
(out/repodata-cache).

  stack-size.py [--rev REV] [--independence] COMMAND ...
                                          --rev reads Ribbon's templates
                                          from a git revision (default: the
                                          working tree); --independence
                                          applies the overrides kept for
                                          independence (build/overrides:
                                          linux-firmware, scx, papirus,
                                          zenity), which aren't built yet

  stack-size.py closure PKG...            closure size and members, biggest first
  stack-size.py drop ROOTS -- PKG...      what removing PKG... from ROOTS frees
                                          (packages no longer reachable)
  stack-size.py why ROOTS -- PKG          one dependency path from ROOTS to PKG
  stack-size.py without PKG...           what the installed system (@system) frees
                                          when the metapackages stop naming PKG...
                                          (PKG stays if something else needs it)
  stack-size.py system                    the installed system, by direct
                                          dependency (exclusive and shared sizes)

ROOTS may name Ribbon's own srcpkgs (ribbon-base, ribbon-desktop, ...): their
depends= are read from srcpkgs/*/template. The token @system means
ribbon-base ribbon-desktop ribbon-gaming plus the AMD Mesa set (ribbon-gpu),
i.e. an installed desktop on an AMD machine.
"""
import io, os, plistlib, re, subprocess, sys, tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CACHE = os.path.join(ROOT, "out", "repodata-cache")
REPOS = ["current", "current_nonfree", "current_multilib", "current_multilib_nonfree"]
# Packages Ribbon will rebuild smaller at independence (build/overrides/*,
# not built yet): bytes that move to a package Ribbon doesn't install,
# measured from the files in Void's .xbps (docs/STACK.md, "At independence").
OVERRIDE_BYTES = {
    "linux-firmware-network": -249583600,   # datacenter, switch, HBA, AP firmware -> linux-firmware
    "linux-firmware": +249583600,
    "scx": -136365736,                      # every scheduler but scx_lavd -> scx-extra
    "papirus-icon-theme": -64535310,        # Papirus-Light, 22/32/64 px -> papirus-icon-theme-extra
}
# ... and dependencies they no longer have
OVERRIDE_DROP_DEPS = {
    "zenity": ["libwebkitgtk60"],           # built without WebKitGTK
}
AMD = ("mesa-dri mesa-dri-32bit vulkan-loader vulkan-loader-32bit libglvnd-32bit "
       "libdrm-32bit mesa-vulkan-radeon mesa-vulkan-radeon-32bit mesa-vaapi").split()


def load():
    idx = {}
    for repo in REPOS:
        path = os.path.join(CACHE, repo + ".repodata")
        data = subprocess.run(["zstd", "-dc", path], capture_output=True, check=True).stdout
        tar = tarfile.open(fileobj=io.BytesIO(data))
        for name, meta in plistlib.loads(tar.extractfile("index.plist").read()).items():
            idx.setdefault(name, meta)
    prov = {}
    for name, meta in idx.items():
        for p in meta.get("provides", []):
            prov.setdefault(re.sub(r"-[^-]+_[0-9]+$", "", p), []).append(name)
    return idx, prov


def ribbon_templates(rev=None):
    texts = {}
    if rev:
        git = ["git", "-C", ROOT]
        names = subprocess.run(git + ["ls-tree", "--name-only", f"{rev}:srcpkgs"],
                               capture_output=True, text=True, check=True).stdout.split()
        for pkg in names:
            r = subprocess.run(git + ["show", f"{rev}:srcpkgs/{pkg}/template"],
                               capture_output=True, text=True)
            if r.returncode == 0:
                texts[pkg] = r.stdout
    else:
        src = os.path.join(ROOT, "srcpkgs")
        for pkg in os.listdir(src):
            tpl = os.path.join(src, pkg, "template")
            if os.path.exists(tpl):
                texts[pkg] = open(tpl).read()
    out = {}
    for pkg, text in texts.items():
        m = re.search(r'^depends="([^"]*)"', text, re.M | re.S)
        toks = m.group(1).split() if m else []
        out[pkg] = [re.split(r"[<>=]", t)[0] for t in toks if not t.startswith("$")]
    return out


class Repo:
    def __init__(self, rev=None, independence=False):
        self.idx, self.prov = load()
        self.ours = ribbon_templates(rev)
        if independence:
            for pkg, delta in OVERRIDE_BYTES.items():
                if pkg in self.idx:
                    self.idx[pkg] = dict(self.idx[pkg], installed_size=self.idx[pkg]["installed_size"] + delta)
            for pkg, gone in OVERRIDE_DROP_DEPS.items():
                if pkg in self.idx:
                    deps = [d for d in self.idx[pkg].get("run_depends", []) if self.name(d) not in gone]
                    self.idx[pkg] = dict(self.idx[pkg], run_depends=deps)

    def name(self, dep):
        # "name>=1.0_1", "name<2", or an exact "name-1.0_1"
        if re.search(r"[<>=]", dep):
            return re.split(r"[<>=]", dep)[0]
        return re.sub(r"-[^-]+_[0-9]+$", "", dep)

    def deps(self, pkg, chosen):
        if pkg in self.ours:
            return self.ours[pkg]
        meta = self.idx.get(pkg, {})
        # xbps-src already turns shlib-requires into run_depends
        return [self.name(d) for d in meta.get("run_depends", [])]

    def resolve(self, n, chosen):
        if n in self.idx or n in self.ours:
            return n
        cands = self.prov.get(n, [])
        for c in cands:
            if c in chosen:
                return c
        return sorted(cands, key=len)[0] if cands else None

    def expand(self, roots):
        out = []
        for r in roots:
            if r == "@system":
                out += ["ribbon-base", "ribbon-desktop", "ribbon-gaming"] + AMD
            else:
                out.append(r)
        return out

    def closure(self, roots, drop=()):
        drop = set(drop)
        seen, parent = set(), {}
        stack = [r for r in self.expand(roots) if r not in drop]
        seen.update(stack)
        while stack:
            p = stack.pop()
            for d in self.deps(p, seen):
                r = self.resolve(d, seen)
                if r and r not in seen and r not in drop:
                    seen.add(r)
                    parent[r] = p
                    stack.append(r)
        return seen, parent

    def direct(self):
        """(metapackage, dependency) for the installed system's top level."""
        metas = ["ribbon-base", "ribbon-desktop", "ribbon-gaming"]
        out = []
        for meta in metas:
            out += [(meta, d) for d in self.ours[meta] if d not in metas]
        return out + [("ribbon-gpu", d) for d in AMD]

    def size(self, pkgs):
        return sum(self.idx.get(p, {}).get("installed_size", 0) for p in pkgs)


def mb(n):
    return f"{n / 1048576:8.1f} MiB"


def main(argv):
    rev, independence = None, False
    while argv[:1] in (["--rev"], ["--independence"]):
        if argv[0] == "--rev":
            rev, argv = argv[1], argv[2:]
        else:
            independence, argv = True, argv[1:]
    if not argv:
        argv = ["help"]
    repo = Repo(rev, independence)
    cmd, args = argv[0], argv[1:]
    if cmd == "closure":
        s, _ = repo.closure(args)
        print(f"{len(s)} packages, {mb(repo.size(s))}")
        for p in sorted(s, key=lambda p: -repo.size([p])):
            print(f"  {mb(repo.size([p]))}  {p}")
    elif cmd in ("drop", "why"):
        i = args.index("--")
        roots, pkgs = args[:i], args[i + 1:]
        full, parent = repo.closure(roots)
        if cmd == "why":
            p, chain = pkgs[0], []
            while p in parent:
                chain.append(p)
                p = parent[p]
            print(" <- ".join(chain + [p]) if pkgs[0] in full else f"{pkgs[0]} not in closure")
            return
        rest, _ = repo.closure(roots, drop=pkgs)
        gone = full - rest
        print(f"frees {len(gone)} packages, {mb(repo.size(gone))} (of {mb(repo.size(full))})")
        still = sorted({q for q in rest for d in repo.deps(q, rest) if repo.resolve(d, rest) in pkgs})
        if still:
            print("  (still wanted by: " + " ".join(still) + ")")
        for p in sorted(gone, key=lambda p: -repo.size([p])):
            print(f"  {mb(repo.size([p]))}  {p}")
    elif cmd == "without":
        roots = [d for _, d in repo.direct()]
        full, _ = repo.closure(roots)
        rest, _ = repo.closure([r for r in roots if r not in args])
        gone = full - rest
        kept = [a for a in args if a in rest]
        print(f"frees {len(gone)} packages, {mb(repo.size(gone))} (of {mb(repo.size(full))})")
        if kept:
            print("  (still pulled in by others: " + " ".join(kept) + ")")
        for p in sorted(gone, key=lambda p: -repo.size([p])):
            print(f"  {mb(repo.size([p]))}  {p}")
    elif cmd == "system":
        # direct dependencies of the three metapackages (and of Ribbon's own
        # packages they name), so "exclusive" = what leaves when the
        # metapackage stops naming it; other packages may still pull it
        direct = repo.direct()
        roots = [d for _, d in direct]
        full, _ = repo.closure(roots)
        print(f"@system: {len(full)} packages, {mb(repo.size(full))}")
        for meta, d in direct:
            rest, _ = repo.closure([r for r in roots if r != d])
            own, _ = repo.closure([d])
            gone = full - rest
            print(f"{meta:15s} {d:28s} exclusive {mb(repo.size(gone))}  closure {mb(repo.size(own))}")
    else:
        print(__doc__)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except BrokenPipeError:
        sys.stderr.close()
