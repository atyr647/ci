#!/usr/bin/env python3
"""install-compare.py TEMPLATE_WORKDIR OURS_DESTDIR LIST_FILE LEFT_OUT_FILE

Holds one package's `build/install/install.sh install` (OURS_DESTDIR) to what its template installs
(TEMPLATE_WORKDIR, made by tests/install-template-tree.sh). LIST_FILE is `install.sh list PACKAGE`; LEFT_OUT_FILE
holds the paths the install reported as left out (an optional input that was not there), one per line.

Every path the template puts down must be in ours with the same type and mode (a link with the same target), and
nothing else may be in ours, except:
  - the template's external files (a relative source do_install did not write: the third-party distfile's tree):
    each must be declared by an `x` line of the manifest, and ours must not have it;
  - paths ours left out: each must come from a distfile, or be built from one ("dist" or "built" in sources);
  - the manifest's state directories (`s` lines: the template's make_dirs, which xbps makes at install time);
  - the record make install leaves on the target (the `r` line: xbps keeps its own in its package database).
A directory that only held such files goes with them. Files the template took from files/ or wrote itself must be
byte-for-byte the same in ours. Prints one line per difference; exits 1 when there is one.
"""
import hashlib
import os
import sys

tw, ours, listf, leftf = sys.argv[1:5]
tdest = os.path.join(tw, "destdir")


def walk(root):
    out = {}
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            p = os.path.join(d, n)
            rel = "/" + os.path.relpath(p, root)
            st = os.lstat(p)
            if os.path.islink(p):
                out[rel] = ("l", os.readlink(p))
            elif os.path.isdir(p):
                out[rel] = ("d", oct(st.st_mode & 0o7777))
            else:
                out[rel] = ("f", oct(st.st_mode & 0o7777))
    return out


def sha(p):
    with open(p, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


kinds = {}
with open(os.path.join(tw, "sources")) as fh:
    for line in fh:
        p, k = line.rstrip("\n").split("\t")
        kinds[os.path.normpath(p)] = k
declared, state, records = set(), set(), set()
with open(listf) as fh:
    for line in fh:
        w = line.split()
        if w and w[0] == "x":
            declared.add(w[1])
        elif w and w[0] == "s":
            state.add(w[1])
        elif w and w[0] == "r":
            records.add(w[1])
left = set()
with open(leftf) as fh:
    left = {line.strip() for line in fh if line.strip()}

T, O = walk(tdest), walk(ours)
bad = []
external = {p for p, k in kinds.items() if k == "external"}
for p in sorted(external - declared):
    bad.append(f"{p}: the template installs it from outside this repository, and the manifest has no external line")
for p in sorted(declared - set(T)):
    bad.append(f"{p}: the manifest declares it external, but the template does not install it")
for p in sorted(left):
    if kinds.get(p) not in ("dist", "built"):
        bad.append(f"{p}: left out, but the template does not take it from a distfile ({kinds.get(p, 'not installed')})")
gone = declared | left
# ZZZ-like links to an external file are external too
for p, (t, v) in T.items():
    if t == "l" and os.path.normpath(os.path.join(os.path.dirname(p), v)) in gone:
        gone.add(p)


def prune(tree, drop):
    """tree without drop, and without the directories that are left empty only because of it"""
    keep = {p: v for p, v in tree.items() if p not in drop}
    while True:
        dirs = {p for p, v in keep.items() if v[0] == "d"}
        held = {os.path.dirname(p) for p in keep}
        empty_before = {p for p in dirs if not any(q.startswith(p + "/") for q in tree)}
        stale = {p for p in dirs if p not in held and p not in empty_before}
        if not stale:
            return keep
        for p in stale:
            del keep[p]


T2 = prune(T, gone)
statedirs = set()
for s in state:
    while s not in ("/", "") and s not in T:
        statedirs.add(s)
        s = os.path.dirname(s)
O2 = {p: v for p, v in prune(O, records).items() if p not in statedirs}
for p in sorted(set(T2) - set(O2)):
    bad.append(f"{p}: the template installs it, make install does not")
for p in sorted(set(O2) - set(T2)):
    bad.append(f"{p}: make install puts it down, the template does not")
for p in sorted(set(T2) & set(O2)):
    if T2[p] != O2[p]:
        bad.append(f"{p}: template {T2[p]}, make install {O2[p]}")
    elif T2[p][0] == "f" and kinds.get(p) in ("files", "made"):
        if sha(tdest + p) != sha(ours + p):
            bad.append(f"{p}: the contents differ from the template's")
for b in bad:
    print("  FAIL " + b)
print(f"  compared {len(T2)} paths ({len(gone)} external or left out, {len(statedirs)} state directories)")
sys.exit(1 if bad else 0)
