#!/bin/sh
# Ribbon's C extensions for Tcl (unix_extra, rbnalpha) against Tcl 9's size types, without a Tcl 9 install: gcc
# -fsyntax-only with tests/tcl9-shim.h (Tcl_Size wide, the size-through-a-pointer functions redeclared as Tcl 9 has
# them) turns an `int *` given to one of them into an error. The shim is proven first on a file that does it wrong.
# Skips without gcc and Tcl's headers (rbnalpha: Tk's too).
set -u
cd "$(dirname "$0")/../.." || exit 1
inc=
for d in /usr/include/tcl8.6 /usr/include; do [ -f "$d/tcl.h" ] && { inc=$d; break; }; done
if ! command -v gcc >/dev/null 2>&1 || [ -z "$inc" ]; then echo "  skip Tcl 9 C API check (no gcc or Tcl headers)"; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT INT TERM
cc() { gcc -fsyntax-only -D_GNU_SOURCE -include tests/tcl9-shim.h -I"$inc" -Wno-deprecated-declarations -Werror=incompatible-pointer-types -Werror=int-conversion "$@"; }
printf '#include <tcl.h>\nint f(Tcl_Interp *i, Tcl_Obj *o){ int n; Tcl_Obj **e; return Tcl_ListObjGetElements(i,o,&n,&e); }\n' > "$T/wrong.c"
if cc "$T/wrong.c" 2>/dev/null; then echo "  FAIL the Tcl 9 shim accepts an int * where Tcl 9 wants a Tcl_Size * (it checks nothing)"; exit 1; fi
echo "  ok   the shim rejects an int * given to Tcl_ListObjGetElements (it does check)"
status=0
for f in srcpkgs/tcl-unix-extra/files/unix_extra.c srcpkgs/ribbon-desktop/files/rbnalpha/rbnalpha.c; do
	case $f in *rbnalpha*) [ -f "$inc/tk.h" ] || [ -f /usr/include/tk.h ] || { echo "  skip $f (no Tk headers)"; continue; } ;; esac
	if cc -Wall "$f" 2>"$T/err"; then echo "  ok   $(basename "$f") passes sizes to Tcl as Tcl_Size (Tcl 9's API)"
	else sed 's/^/    /' "$T/err" | head -20; echo "  FAIL $f gives Tcl a size through an int *"; status=1; fi
done
exit $status
