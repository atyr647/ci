# ribbon-wall: make O=builddir [LIBDIR=/usr/lib/ribbon/wall]
PREFIX ?= /usr
LIBDIR ?= $(PREFIX)/lib/ribbon/wall
O ?= .
CC ?= cc
CFLAGS ?= -O2 -g
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
WP = $(shell $(PKG_CONFIG) --variable=pkgdatadir wayland-protocols)
TCL_PC = $(shell $(PKG_CONFIG) --exists tcl8.6 && echo tcl8.6 || echo tcl)
VA_PC = $(shell $(PKG_CONFIG) --exists libva && echo libva)
LIBS = wayland-client wayland-egl egl glesv2 libavformat libavcodec libavutil libswscale $(TCL_PC) $(VA_PC)
PC_CFLAGS = $(shell $(PKG_CONFIG) --cflags $(LIBS)) $(if $(VA_PC),-DHAVE_VA)
PC_LIBS = $(shell $(PKG_CONFIG) --libs $(LIBS))

# protocol name -> its XML
XML_wlr-layer-shell-unstable-v1 = wlr-layer-shell-unstable-v1.xml
XML_wlr-foreign-toplevel-management-unstable-v1 = ../shell-watch/wlr-foreign-toplevel-management-unstable-v1.xml
XML_presentation-time = $(WP)/stable/presentation-time/presentation-time.xml
XML_viewporter = $(WP)/stable/viewporter/viewporter.xml
XML_xdg-shell = $(WP)/stable/xdg-shell/xdg-shell.xml
XML_fractional-scale-v1 = $(WP)/staging/fractional-scale/fractional-scale-v1.xml
PROTOS = wlr-layer-shell-unstable-v1 wlr-foreign-toplevel-management-unstable-v1 presentation-time viewporter fractional-scale-v1 xdg-shell
HDRS = $(PROTOS:%=$(O)/%-client-protocol.h)
PSRCS = $(PROTOS:%=$(O)/%-protocol.c)
SRCS = main.c video.c gl.c shm.c

all: $(O)/ribbon-wall

.SECONDEXPANSION:
$(O)/%-client-protocol.h: $$(XML_$$*)
	$(WAYLAND_SCANNER) client-header $< $@
$(O)/%-protocol.c: $$(XML_$$*)
	$(WAYLAND_SCANNER) private-code $< $@

$(O)/ribbon-wall: $(SRCS) rw.h $(HDRS) $(PSRCS)
	$(CC) $(CFLAGS) -std=c11 -Wall -Wextra -I$(O) -I. $(PC_CFLAGS) -DRW_LIBDIR='"$(LIBDIR)"' -o $@ $(SRCS) $(PSRCS) \
		$(LDFLAGS) $(PC_LIBS) -lpthread -lm

install: $(O)/ribbon-wall
	install -Dm755 $(O)/ribbon-wall $(DESTDIR)$(PREFIX)/bin/ribbon-wall
	install -Dm644 wall.tcl $(DESTDIR)$(LIBDIR)/wall.tcl
	install -Dm644 look.tcl $(DESTDIR)$(LIBDIR)/look.tcl

clean:
	rm -f $(O)/ribbon-wall $(HDRS) $(PSRCS)

.PHONY: all install clean
