#!/bin/sh
# local-deps.sh - build, on a development machine, the outside pieces the kit tests need, from sources put in the local
# repository (out/src, git-ignored): Mk4tcl, mkkitfs and unix_extra (Ribbon's own), and unix_sockets when its tarball is
# given. It uses the same scripts and checks as CI (build/ci/build-mk4tcl.sh, srcpkgs/mkkitfs's Makefile) and writes
# out/env.sh, which you source before running tests/steps.d by hand.
#
#   build/local-deps.sh                       build what is in out/src
#   UNIX_SOCKETS_TARBALL=FILE build/local-deps.sh   and unix_sockets from the template's distfile
#
# out/src/metakit must be a checkout of atyr647/metakit at the commit srcpkgs/mkkitfs/template names (the script checks it).
# Getting it there is the owner's rule for outside sources: pull the public repository into out/src (a clone, the session's
# add_repo, a release download the network allows), never around a refusal. Nothing here is committed: out/ is ignored.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
die() { echo "local-deps: $*" >&2; exit 1; }
MK=out/src/metakit
[ -d "$MK" ] || die "no $MK: put atyr647/metakit there first"
want=$(sed -n 's/^_mkcommit=//p' srcpkgs/mkkitfs/template)
have=$(git -C "$MK" rev-parse HEAD 2>/dev/null) || die "$MK is not a git checkout"
[ "$have" = "$want" ] || die "$MK is at $have, the templates name $want"
mkdir -p out/build

sh build/ci/build-mk4tcl.sh "$MK" out/build/mk4tcl
rm -rf out/build/mkkitfs
mkdir -p out/build/mkkitfs
make -s -C srcpkgs/mkkitfs/files METAKIT="$ROOT/$MK" O="$ROOT/out/build/mkkitfs" CXXFLAGS="-O2 -Werror"
rm -rf out/build/tcl-unix-extra
mkdir -p out/build/tcl-unix-extra
make -s -C srcpkgs/tcl-unix-extra/files O="$ROOT/out/build/tcl-unix-extra"
us=
if [ -z "${UNIX_SOCKETS_TARBALL:-}" ] && [ -d out/build/unix-sockets ]; then us="\$R/out/build/unix-sockets "; fi
if [ -n "${UNIX_SOCKETS_TARBALL:-}" ]; then
	sh build/ci/build-unix-sockets.sh "$UNIX_SOCKETS_TARBALL" out/build/unix-sockets
	us="\$R/out/build/unix-sockets "
fi
cat > out/env.sh <<ENV
# the local builds of outside sources (out/ is git-ignored): source this before running kit tests by hand
R=$ROOT
export KITFMT_MK4TCL=\$R/out/build/mk4tcl
export TCLLIBPATH="\$R/out/build/tcl-unix-extra ${us}\$R/out/build/mk4tcl \${TCLLIBPATH:-}"
export PATH=\$R/out/build/mkkitfs:\$PATH
ENV
# shellcheck disable=SC2016
[ -z "$us" ] || echo 'export UNIX_SOCKETS_DIR=$R/out/build/unix-sockets' >> out/env.sh
echo "local-deps: built; now: . out/env.sh"
