#!/bin/sh
# The icon rasteriser (shell/raster.tcl): its SVG path reader (S/s against the same curves spelt with C), and its
# cache without raster::init (under $XDG_CACHE_HOME/ribbon/raster, never in the working directory).
set -u
cd "$(dirname "$0")/../.." || exit 1
command -v tclsh8.6 >/dev/null 2>&1 || { echo "  skip raster (no tclsh8.6)"; exit 0; }
command -v xvfb-run >/dev/null 2>&1 || { echo "  skip raster (no xvfb-run)"; exit 0; }
xvfb-run -a tclsh8.6 tests/raster-path.tcl srcpkgs/ribbon-desktop/files/shell/raster.tcl
