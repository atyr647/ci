#!/usr/bin/env python3
"""Static checks for dinit service descriptions (Ribbon's and generated ones).

- every setting name exists in dinit 0.22's dinit-service(5)
- type and option values are valid
- every dependency names a service that exists in the given directories
Usage: lint-dinit.py [--known NAME ...] DIR [DIR ...]
"""
import os, re, sys

SETTINGS = set("""after before capabilities chain-to command consumer-of depends-ms depends-ms.d
depends-on depends-on.d env-file inittab-id inittab-line ioprio load-options log-buffer-size
log-type logfile logfile-gid logfile-permissions logfile-uid nice oom-score-adj options pid-file
ready-notification restart restart-delay restart-limit-count restart-limit-interval
rlimit-addrspace rlimit-core rlimit-data rlimit-nofile run-as run-in-cgroup secure-bits securebits
smooth-recovery socket-gid socket-listen socket-permissions socket-uid start-timeout stop-command
stop-timeout term-signal type waits-for waits-for.d working-dir""".split())
OPTIONS = set("""always-chain kill-all-on-stop no-new-privs pass-cs-fd runs-on-console shares-console
signal-process-only skippable start-interruptible starts-log starts-on-console starts-rwfs
unmask-intr""".split())
TYPES = {"process", "bgprocess", "scripted", "internal", "triggered"}
DEPS = {"depends-on", "depends-ms", "waits-for", "after", "before", "chain-to"}
CONSOLE_START_TYPES = {"scripted", "bgprocess"}

def parse(path):
    out = []
    for n, line in enumerate(open(path), 1):
        s = line.split("#", 1)[0].strip() if not line.lstrip().startswith("command") else line.strip()
        if not s or s.startswith("#") or s.startswith("@"):
            continue
        m = re.match(r"^([a-z][a-z.-]*)\s*(\+?=|:)\s*(.*)$", s)
        if not m:
            out.append((n, None, s))
            continue
        out.append((n, m.group(1), m.group(3).split(" #")[0].strip()))
    return out

def main(argv):
    known = set()
    dirs = []
    i = 0
    while i < len(argv):
        if argv[i] == "--known":
            known.add(argv[i + 1]); i += 2
        else:
            dirs.append(argv[i]); i += 1
    services = {}
    for d in dirs:
        for f in sorted(os.listdir(d)):
            p = os.path.join(d, f)
            if os.path.isfile(p) and not f.startswith(".") and not f.endswith(".md"):
                services.setdefault(f, p)
    names = set(services) | known
    errors = 0
    def err(p, n, msg):
        nonlocal errors
        errors += 1
        print(f"{p}:{n}: {msg}")
    for name, p in services.items():
        kv = parse(p)
        stype = next((v for _, k, v in kv if k == "type"), None)
        if stype not in TYPES:
            err(p, 1, f"missing/invalid type '{stype}'")
        if stype in ("process", "bgprocess", "scripted") and not any(k == "command" for _, k, _ in kv):
            err(p, 1, "no command")
        for n, k, v in kv:
            if k is None:
                err(p, n, f"unparseable line: {v}"); continue
            if k not in SETTINGS:
                err(p, n, f"unknown setting '{k}'")
            if k == "options":
                for o in v.split():
                    if o not in OPTIONS:
                        err(p, n, f"unknown option '{o}'")
                    if o == "starts-on-console" and stype not in CONSOLE_START_TYPES:
                        err(p, n, "starts-on-console only applies to scripted/bgprocess")
            if k in DEPS:
                base = v.split("@", 1)[0]
                if v not in names and base not in names and v.split("@")[0] + "" not in names:
                    err(p, n, f"{k} '{v}': no such service")
            if k.endswith(".d") and not v.startswith("/"):
                err(p, n, f"{k} should be an absolute path")
    print(f"lint-dinit: {len(services)} services, {errors} problem(s)")
    return 1 if errors else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
