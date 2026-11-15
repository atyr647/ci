# unix_extra: a TEA-lite build. Tcl's settings come from tclConfig.sh.
#   make [O=builddir] [TCL_CONFIG=/usr/lib/tclConfig.sh]
#   make test          (needs tclsh; TESTFLAGS="-tmpdir DIR" for the sockets)
#   make install DESTDIR=...
VERSION = 0.3
PREFIX ?= /usr
LIBDIR ?= $(PREFIX)/lib
O ?= .
CC ?= cc
CFLAGS ?= -O2 -g
TCLSH ?= tclsh
TCL_CONFIG ?= $(firstword $(wildcard /usr/lib/tclConfig.sh /usr/lib64/tclConfig.sh \
	/usr/lib/tcl8.6/tclConfig.sh /usr/lib/$(shell $(CC) -dumpmachine)/tcl8.6/tclConfig.sh))
TCL_CFLAGS ?= $(shell . $(TCL_CONFIG) && echo "$$TCL_INCLUDE_SPEC")
TCL_LIBS ?= $(shell . $(TCL_CONFIG) && echo "$$TCL_STUB_LIB_SPEC")

LIB = libunix_extra$(VERSION).so
PKGDIR = $(LIBDIR)/unix_extra$(VERSION)

all: $(O)/$(LIB) $(O)/pkgIndex.tcl

$(O)/$(LIB): unix_extra.c
	$(CC) $(CFLAGS) -std=c11 -Wall -Wextra -fPIC -shared -DUSE_TCL_STUBS $(TCL_CFLAGS) \
		-o $@ unix_extra.c $(LDFLAGS) $(TCL_LIBS)

$(O)/pkgIndex.tcl: pkgIndex.tcl
	[ "$(O)" = . ] || cp pkgIndex.tcl $@

test: all
	UNIX_EXTRA_DIR=$(abspath $(O)) $(TCLSH) tests/unix_extra.test $(TESTFLAGS)

install: all
	install -Dm755 $(O)/$(LIB) $(DESTDIR)$(PKGDIR)/$(LIB)
	install -Dm644 pkgIndex.tcl $(DESTDIR)$(PKGDIR)/pkgIndex.tcl

clean:
	rm -f $(O)/$(LIB)
	[ "$(O)" = . ] || rm -f $(O)/pkgIndex.tcl

.PHONY: all test install clean
