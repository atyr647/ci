# ribbon-polkit-keys: make O=builddir (the ribbon-desktop template builds it next to ribbon-wall)
O ?= .
CC ?= cc
CFLAGS ?= -O2
PKG_CONFIG ?= pkg-config
WL = ../../../ribbon-wall
LIBS = wayland-client xkbcommon
$(O)/ribbon-polkit-keys: rpk-keys.c $(O)/wlr-layer-shell-unstable-v1-client-protocol.h $(O)/wlr-layer-shell-unstable-v1-protocol.c $(O)/xdg-shell-protocol.c $(O)/xdg-shell-client-protocol.h
	$(CC) $(CFLAGS) -std=gnu11 -Wall -Wextra -I$(O) $(shell $(PKG_CONFIG) --cflags $(LIBS)) -o $@ rpk-keys.c \
		$(O)/wlr-layer-shell-unstable-v1-protocol.c $(O)/xdg-shell-protocol.c $(LDFLAGS) $(shell $(PKG_CONFIG) --libs $(LIBS))
$(O)/wlr-layer-shell-unstable-v1-client-protocol.h: $(WL)/wlr-layer-shell-unstable-v1.xml
	wayland-scanner client-header $< $@
$(O)/wlr-layer-shell-unstable-v1-protocol.c: $(WL)/wlr-layer-shell-unstable-v1.xml
	wayland-scanner private-code $< $@
# the layer-shell XML refers to xdg_popup
XDG = $(shell $(PKG_CONFIG) --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml
$(O)/xdg-shell-client-protocol.h: $(XDG)
	wayland-scanner client-header $< $@
$(O)/xdg-shell-protocol.c: $(XDG)
	wayland-scanner private-code $< $@
