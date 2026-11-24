PREFIX ?= /usr
O ?= .
CC ?= cc
CFLAGS ?= -O2 -g
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner

PROTO = wlr-foreign-toplevel-management-unstable-v1
WS = ext-workspace-v1
WL_CFLAGS = $(shell $(PKG_CONFIG) --cflags wayland-client)
WL_LIBS = $(shell $(PKG_CONFIG) --libs wayland-client)

# ribbon-shell-switch (the Alt+Tab keyboard, stills and window copies): more protocols, and xkbcommon for the keys
LAYER = ../ribbon-wall/wlr-layer-shell-unstable-v1.xml
XDG = $(shell $(PKG_CONFIG) --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml
SW = wlr-screencopy-unstable-v1 ext-foreign-toplevel-list-v1 ext-image-capture-source-v1 ext-image-copy-capture-v1
SW_H = $(patsubst %,$(O)/%-client-protocol.h,$(SW)) $(O)/wlr-layer-shell-unstable-v1-client-protocol.h $(O)/xdg-shell-client-protocol.h
SW_C = $(patsubst %,$(O)/%-protocol.c,$(SW)) $(O)/wlr-layer-shell-unstable-v1-protocol.c $(O)/xdg-shell-protocol.c
XKB_CFLAGS = $(shell $(PKG_CONFIG) --cflags xkbcommon)
XKB_LIBS = $(shell $(PKG_CONFIG) --libs xkbcommon)

all: ribbon-shell-watch ribbon-shell-switch

ribbon-shell-watch: $(O)/ribbon-shell-watch
ribbon-shell-switch: $(O)/ribbon-shell-switch

$(O)/$(PROTO)-client-protocol.h: $(PROTO).xml
	$(WAYLAND_SCANNER) client-header $< $@

$(O)/$(PROTO)-protocol.c: $(PROTO).xml
	$(WAYLAND_SCANNER) private-code $< $@

$(O)/$(WS)-client-protocol.h: $(WS).xml
	$(WAYLAND_SCANNER) client-header $< $@

$(O)/$(WS)-protocol.c: $(WS).xml
	$(WAYLAND_SCANNER) private-code $< $@

# the `key` command: a resident virtual keyboard (xkbcommon for the keymap and the key codes)
VK = virtual-keyboard-unstable-v1
$(O)/ribbon-shell-watch: ribbon-shell-watch.c $(O)/$(PROTO)-protocol.c $(O)/$(PROTO)-client-protocol.h $(O)/$(WS)-protocol.c $(O)/$(WS)-client-protocol.h $(O)/$(VK)-protocol.c $(O)/$(VK)-client-protocol.h
	$(CC) $(CFLAGS) -std=gnu11 -Wall -Wextra -I$(O) $(WL_CFLAGS) $(XKB_CFLAGS) -o $@ ribbon-shell-watch.c $(O)/$(PROTO)-protocol.c $(O)/$(WS)-protocol.c $(O)/$(VK)-protocol.c $(LDFLAGS) $(WL_LIBS) $(XKB_LIBS)

$(O)/%-client-protocol.h: %.xml
	$(WAYLAND_SCANNER) client-header $< $@
$(O)/%-protocol.c: %.xml
	$(WAYLAND_SCANNER) private-code $< $@
$(O)/wlr-layer-shell-unstable-v1-client-protocol.h: $(LAYER)
	$(WAYLAND_SCANNER) client-header $< $@
$(O)/wlr-layer-shell-unstable-v1-protocol.c: $(LAYER)
	$(WAYLAND_SCANNER) private-code $< $@
# the layer-shell XML refers to xdg_popup
$(O)/xdg-shell-client-protocol.h: $(XDG)
	$(WAYLAND_SCANNER) client-header $< $@
$(O)/xdg-shell-protocol.c: $(XDG)
	$(WAYLAND_SCANNER) private-code $< $@

$(O)/ribbon-shell-switch: switch.c $(SW_H) $(SW_C)
	$(CC) $(CFLAGS) -std=gnu11 -Wall -Wextra -I$(O) $(WL_CFLAGS) $(XKB_CFLAGS) -o $@ switch.c $(SW_C) $(LDFLAGS) $(WL_LIBS) $(XKB_LIBS)

install: $(O)/ribbon-shell-watch $(O)/ribbon-shell-switch
	install -Dm755 $(O)/ribbon-shell-watch $(DESTDIR)$(PREFIX)/bin/ribbon-shell-watch
	install -Dm755 $(O)/ribbon-shell-switch $(DESTDIR)$(PREFIX)/bin/ribbon-shell-switch

clean:
	rm -f $(O)/ribbon-shell-watch $(O)/ribbon-shell-switch $(O)/*-client-protocol.h $(O)/*-protocol.c

.PHONY: all ribbon-shell-watch ribbon-shell-switch install clean
