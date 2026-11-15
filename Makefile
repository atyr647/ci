# Ribbon OS build entry points.
#
# Any base (docs/BUILDING.md, "Build and install on any base"):
#   make build                                 Ribbon's own native pieces and generated files, into O
#   make install DESTDIR=... PREFIX=/usr       every package, to the paths the srcpkgs templates install them to
#   make install-ribbon-desktop DESTDIR=...    one package (any name in build/install/manifests)
#   make uninstall DESTDIR=...                 remove what install recorded (uninstall-PACKAGE for one)
#   make dependencies                          O/dependencies.txt: what each package needs, in base-neutral names
#   make check                                 the test suite
# Void (needs a Void Linux host or container, see .github/workflows/build.yml):
#   make packages                              xbps packages with xbps-src
#   make iso                                   the live ISO
.PHONY: all check packages iso clean build install uninstall dependencies

O ?= out/build
DISTDIR ?= out/distfiles
PREFIX ?= /usr
DESTDIR ?=
PACKAGES := $(sort $(basename $(notdir $(wildcard build/install/manifests/*.manifest))))
INSTALL_ENV = O="$(O)" DISTDIR="$(DISTDIR)" DESTDIR="$(DESTDIR)" PREFIX="$(PREFIX)"

all: packages iso

check:
	tests/run.sh

packages:
	build/build-packages.sh

iso:
	sudo build/build-iso.sh

build:
	O="$(O)" DISTDIR="$(DISTDIR)" METAKIT="$(METAKIT)" sh build/install/build.sh

dependencies:
	mkdir -p "$(O)"
	sh build/install/deps.sh > "$(O)/dependencies.txt"

# every package; one that could not be built (mkkitfs without METAKIT) is skipped and said
install:
	@for p in $(PACKAGES); do $(INSTALL_ENV) sh build/install/install.sh install $$p --if-built || exit 1; done

uninstall:
	@for p in $(PACKAGES); do if [ -f "$(O)/installed/$$p.files" ]; then \
		$(INSTALL_ENV) sh build/install/install.sh uninstall $$p || exit 1; fi; done

install-%:
	$(INSTALL_ENV) sh build/install/install.sh install $*

uninstall-%:
	$(INSTALL_ENV) sh build/install/install.sh uninstall $*

clean:
	rm -rf out/iso out/repo out/build
