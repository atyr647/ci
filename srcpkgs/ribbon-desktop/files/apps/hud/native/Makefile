# ribbon-hud-surface: make O=builddir (the ribbon-desktop template builds it next to ribbon-wall)
# libribbon-hud-frames.so: make O=builddir layer (the Vulkan layer; needs only the Vulkan headers). Its manifest,
# ribbon-hud-frames.json, goes to usr/share/vulkan/implicit_layer.d; library_path there is the installed .so.
O ?= .
CC ?= cc
CFLAGS ?= -O2
PKG_CONFIG ?= pkg-config
WL = ../../../ribbon-wall
LIBS = wayland-client cairo
$(O)/ribbon-hud-surface: hud-surface.c $(O)/wlr-layer-shell-unstable-v1-client-protocol.h $(O)/wlr-layer-shell-unstable-v1-protocol.c $(O)/xdg-shell-protocol.c $(O)/xdg-shell-client-protocol.h
	$(CC) $(CFLAGS) -std=gnu11 -Wall -Wextra -I$(O) $(shell $(PKG_CONFIG) --cflags $(LIBS)) -o $@ hud-surface.c \
		$(O)/wlr-layer-shell-unstable-v1-protocol.c $(O)/xdg-shell-protocol.c $(LDFLAGS) $(shell $(PKG_CONFIG) --libs $(LIBS)) -lm
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

# VK_LAYER_RIBBON_hud_frames (hud-frames-layer.c): only vkNegotiateLoaderLayerInterfaceVersion is exported
layer: $(O)/libribbon-hud-frames.so
$(O)/libribbon-hud-frames.so: hud-frames-layer.c
	$(CC) $(CFLAGS) -std=gnu11 -Wall -Wextra -fPIC -shared -fvisibility=hidden -Wl,-z,defs -o $@ hud-frames-layer.c $(LDFLAGS) -lpthread
.PHONY: layer
