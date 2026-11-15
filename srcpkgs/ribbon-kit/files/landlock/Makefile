# kit-landlock: make O=builddir (the ribbon-kit template builds it and installs it as
# usr/lib/ribbon/kit/kit-landlock, next to kit's Tcl library, where kit run finds it)
O ?= .
CC ?= cc
CFLAGS ?= -O2
$(O)/kit-landlock: kit-landlock.c
	$(CC) $(CFLAGS) -std=gnu11 -Wall -Wextra -o $@ kit-landlock.c $(LDFLAGS)
