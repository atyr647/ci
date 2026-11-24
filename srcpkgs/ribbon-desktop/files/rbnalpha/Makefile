# rbnalpha: make O=builddir  (Tk stubs; libX11, libXext, libXrender)
#   make [TK_CONFIG=/usr/lib/tkConfig.sh] [TCL_CONFIG=/usr/lib/tclConfig.sh] [CONFIG_DIRS="/usr/lib ..."]
# Tcl's and Tk's settings come from their tkConfig.sh and tclConfig.sh in CONFIG_DIRS: the system's own
# (DIR/tkConfig.sh) first, else the newest versioned one (DIR/tk9.1, DIR/tk9.0, DIR/tk8.6), and then the Tcl
# of that Tk's version. The two must be of one version (Tk 8.6 with Tcl 8.6, Tk 9.x with Tcl 9.x).
PREFIX ?= /usr
LIBDIR ?= $(PREFIX)/lib/ribbon/rbnalpha
O ?= .
CC ?= cc
CFLAGS ?= -O2 -g
PKG_CONFIG ?= pkg-config
CONFIG_DIRS ?= /usr/lib /usr/lib64 /usr/lib/$(shell $(CC) -dumpmachine 2>/dev/null)
# $(call newest,NAME): DIR/NAMEx.y/NAMEConfig.sh of every DIR in CONFIG_DIRS, the highest x.y first
newest = $(shell for d in $(CONFIG_DIRS); do for f in $$d/$(1)[0-9]*/$(1)Config.sh; do [ -f "$$f" ] && echo "$$f"; done; done | \
	sed -n 's|.*/$(1)\([0-9][0-9.]*\)/$(1)Config\.sh$$|\1 &|p' | sort -rV | cut -d' ' -f2)
ifndef TK_CONFIG
TK_CONFIG := $(firstword $(wildcard $(addsuffix /tkConfig.sh,$(CONFIG_DIRS))) $(call newest,tk))
endif
TK_VERSION := $(shell . $(TK_CONFIG) 2>/dev/null && echo "$$TK_VERSION")
ifndef TCL_CONFIG
# the first tclConfig.sh of the Tk's version (else the first one, which the build then refuses)
TCL_CONFIGS := $(wildcard $(addsuffix /tclConfig.sh,$(CONFIG_DIRS)) $(addsuffix /tcl$(TK_VERSION)/tclConfig.sh,$(CONFIG_DIRS)))
TCL_CONFIG := $(firstword $(shell for f in $(TCL_CONFIGS); do [ "$$(. $$f 2>/dev/null && echo "$$TCL_VERSION")" = "$(TK_VERSION)" ] && \
	echo $$f && break; done) $(TCL_CONFIGS))
endif
TCL_VERSION := $(shell . $(TCL_CONFIG) 2>/dev/null && echo "$$TCL_VERSION")
TK_CFLAGS ?= $(shell . $(TCL_CONFIG) && . $(TK_CONFIG) && echo "$$TCL_INCLUDE_SPEC $$TK_INCLUDE_SPEC $$TK_XINCLUDES")
STUBS ?= $(shell . $(TCL_CONFIG) && . $(TK_CONFIG) && echo "$$TK_STUB_LIB_SPEC $$TCL_STUB_LIB_SPEC")
X_LIBS = $(shell $(PKG_CONFIG) --libs xext xrender x11 2>/dev/null || echo -lXext -lXrender -lX11)

all: $(O)/librbnalpha.so

$(O)/librbnalpha.so: rbnalpha.c
	@[ -n "$(TK_VERSION)" ] || { echo "rbnalpha: no tkConfig.sh in $(CONFIG_DIRS) (TK_CONFIG=$(TK_CONFIG))" >&2; exit 1; }
	@[ "$(TCL_VERSION)" = "$(TK_VERSION)" ] || \
		{ echo "rbnalpha: Tk $(TK_VERSION) ($(TK_CONFIG)) needs Tcl $(TK_VERSION), not '$(TCL_VERSION)' ($(TCL_CONFIG))" >&2; exit 1; }
	$(CC) $(CFLAGS) -std=c11 -Wall -Wextra -shared -fPIC -DUSE_TCL_STUBS -DUSE_TK_STUBS \
		$(TK_CFLAGS) -o $@ rbnalpha.c $(LDFLAGS) $(STUBS) $(X_LIBS) -lm

install: $(O)/librbnalpha.so
	install -Dm755 $(O)/librbnalpha.so $(DESTDIR)$(LIBDIR)/librbnalpha.so
	install -Dm644 rbnalpha.tcl $(DESTDIR)$(LIBDIR)/rbnalpha.tcl
	install -Dm644 pkgIndex.tcl $(DESTDIR)$(LIBDIR)/pkgIndex.tcl

clean:
	rm -f $(O)/librbnalpha.so

.PHONY: all install clean
