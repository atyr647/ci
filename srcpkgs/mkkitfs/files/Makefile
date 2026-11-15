# mkkitfs: the FUSE server for .kit files (docs/MKKITFS.md): mkkitfs (C++, the data path) and
# mkkitfsd + the Tcl package mkkitfs (the session server's socket and policy, the client).
#
#   make METAKIT=<metakit source, branch kit-fixes> [O=builddir]      build $(O)/mkkitfs and $(O)/kit-swapmount
#   make METAKIT=... O=... check                                      the test suite (tests/run.sh)
#   make METAKIT=... O=... fuzz [FUZZ=N] [SEED=S]                     $(O)/sanitize/mkkitfs, built with ASan and
#                                                                     UBSan (Metakit too), and the fuzz pass on it
#   make O=... DESTDIR=... install
#
# kit-swapmount (src/swapmount.c, plain C, no libraries) is ribbon-kit's: kit's lib/mount.tcl switches
# the merged /usr view with it.  It is installed next to kit's library.
#
# Needs libfuse3, libdeflate and libcrypto (pkg-config names fuse3, libdeflate, libcrypto) and a
# C++17 compiler.  Metakit's C++ library is compiled from METAKIT/src into the binary (statically):
# Void has no Metakit package, and only the kit-fixes branch of the fork has the fixes kits need.
O ?= .
METAKIT ?=
PREFIX ?= /usr
CXX ?= c++
CXXFLAGS ?= -O2 -g
override CXXFLAGS += -std=c++17 -Wall -Wextra -Wno-unused-parameter
MKFLAGS = -O2 -g -w -fno-strict-aliasing
PKG_CONFIG ?= pkg-config
FUSE_CFLAGS := $(shell $(PKG_CONFIG) --cflags fuse3)
LIBS := $(shell $(PKG_CONFIG) --libs fuse3) -ldeflate -lcrypto -lpthread
HERE := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

MKSRC = column custom derived fileio field format handler persist remap std store string table univ view viewx
MKOBJ = $(MKSRC:%=$(O)/mk/%.o)
OBJ = $(O)/obj/kit.o $(O)/obj/server.o $(O)/obj/main.o $(O)/obj/confine.o

CC ?= cc
CFLAGS ?= -O2 -g
SANFLAGS = -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer
FUZZ ?= 2000
SEED ?= 1

all: $(O)/mkkitfs $(O)/kit-swapmount

$(O)/mk/config.h: $(HERE)metakit-config.h
	@test -n "$(METAKIT)" -a -f "$(METAKIT)/src/persist.cpp" || { echo "set METAKIT to the Metakit fork's source (branch kit-fixes)"; exit 1; }
	@mkdir -p $(O)/mk
	cp $< $@

$(O)/mk/%.o: $(METAKIT)/src/%.cpp $(O)/mk/config.h
	$(CXX) $(MKFLAGS) $(EXTRA_CXXFLAGS) -I$(O)/mk -I$(METAKIT)/include -c -o $@ $<

$(O)/obj/%.o: $(HERE)src/%.cpp $(HERE)src/kit.h $(HERE)src/server.h $(HERE)src/confine.h $(O)/mk/config.h
	@mkdir -p $(O)/obj
	$(CXX) $(CXXFLAGS) $(EXTRA_CXXFLAGS) $(FUSE_CFLAGS) -isystem $(METAKIT)/include -c -o $@ $<

$(O)/mkkitfs: $(OBJ) $(MKOBJ)
	$(CXX) $(CXXFLAGS) $(EXTRA_CXXFLAGS) $(LDFLAGS) -o $@ $(OBJ) $(MKOBJ) $(LIBS)

$(O)/kit-swapmount: $(HERE)src/swapmount.c
	@mkdir -p $(O)
	$(CC) $(CFLAGS) -Wall -Wextra $(LDFLAGS) -o $@ $<

# src/confine.cpp alone (no Metakit, no FUSE): tests/run.sh builds and runs it too
$(O)/confine-test: $(HERE)tests/confine-test.cpp $(HERE)src/confine.cpp $(HERE)src/confine.h
	@mkdir -p $(O)
	$(CXX) $(CXXFLAGS) $(EXTRA_CXXFLAGS) $(LDFLAGS) -o $@ $(HERE)tests/confine-test.cpp $(HERE)src/confine.cpp -lpthread

check: $(O)/mkkitfs $(O)/kit-swapmount
	MKKITFS=$(abspath $(O)/mkkitfs) KIT_SWAPMOUNT=$(abspath $(O)/kit-swapmount) sh $(HERE)tests/run.sh

# the reader under AddressSanitizer and UndefinedBehaviorSanitizer (MKKITFS_SANITIZE lets the leak pass
# run unconfined: LeakSanitizer needs ptrace, which the confinement takes away)
fuzz:
	@test -n "$(METAKIT)" || { echo "set METAKIT to the Metakit fork's source (branch kit-fixes)"; exit 1; }
	$(MAKE) -f $(HERE)Makefile METAKIT="$(METAKIT)" O="$(O)/sanitize" CXXFLAGS="-O1 -g" \
		EXTRA_CXXFLAGS="$(SANFLAGS) -DMKKITFS_SANITIZE" LDFLAGS="$(SANFLAGS)" "$(O)/sanitize/mkkitfs"
	sh $(HERE)tests/fuzz-sanitize.sh "$(O)/sanitize/mkkitfs" "$(FUZZ)" "$(SEED)"

install: $(O)/mkkitfs $(O)/kit-swapmount
	install -Dm755 $(O)/mkkitfs $(DESTDIR)$(PREFIX)/bin/mkkitfs
	install -Dm755 $(O)/kit-swapmount $(DESTDIR)$(PREFIX)/lib/ribbon/kit/kit-swapmount
	install -Dm755 $(HERE)tcl/mkkitfsd $(DESTDIR)$(PREFIX)/bin/mkkitfsd
	install -Dm644 $(HERE)tcl/mkkitfs.tcl $(DESTDIR)$(PREFIX)/lib/mkkitfs1.0/mkkitfs.tcl
	install -Dm644 $(HERE)tcl/pkgIndex.tcl $(DESTDIR)$(PREFIX)/lib/mkkitfs1.0/pkgIndex.tcl
	install -Dm644 $(HERE)services/mkkitfs $(DESTDIR)$(PREFIX)/lib/dinit.d/user/mkkitfs

clean:
	rm -rf $(O)/mk $(O)/obj $(O)/mkkitfs $(O)/kit-swapmount $(O)/confine-test $(O)/sanitize

.PHONY: all check fuzz install clean
