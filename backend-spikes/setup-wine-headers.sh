#!/bin/sh
# usage: setup-wine-headers.sh <dir>   -> <dir>/x/usr/include/wine/wine/{windows,...}
set -e
mkdir -p "$1" && cd "$1"
apt-get download libwine-dev >/dev/null 2>&1 || { echo "needs apt sources with the libwine-dev package"; exit 1; }
dpkg-deb -x libwine-dev_*.deb x
ls x/usr/include/wine/wine/windows | head -3
