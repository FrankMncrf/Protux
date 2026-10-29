PREFIX     ?= /usr
BINDIR     ?= $(PREFIX)/bin
LIBDIR     ?= $(PREFIX)/lib/protux
USERUNITDIR ?= $(PREFIX)/lib/systemd/user
APPDIR     ?= $(PREFIX)/share/applications
DOCDIR     ?= $(PREFIX)/share/doc/protux
MANDIR     ?= $(PREFIX)/share/man/man1
LICENSEDIR ?= $(PREFIX)/share/licenses/protux
ICONDIR    ?= $(PREFIX)/share/icons/hicolor/scalable/apps

VERSION := $(shell sed -n 's/^PTX_VERSION=//p' lib/protux/common.sh)
UNITS   := protux.service protux-alert.service

all: $(addprefix build/,$(UNITS)) build/io.github.frankmncrf.protux.desktop

build/%.service: systemd/%.service.in
	@mkdir -p build
	sed 's|@BINDIR@|$(BINDIR)|g' $< > $@

build/%.desktop: data/%.desktop.in
	@mkdir -p build
	sed 's|@BINDIR@|$(BINDIR)|g' $< > $@

install: all
	install -Dm755 bin/protux                  $(DESTDIR)$(BINDIR)/protux
	install -Dm755 bin/protux-gui              $(DESTDIR)$(BINDIR)/protux-gui
	install -Dm644 lib/protux/common.sh        $(DESTDIR)$(LIBDIR)/common.sh
	install -Dm644 lib/protux/locale/es.sh     $(DESTDIR)$(LIBDIR)/locale/es.sh
	install -Dm644 lib/protux/i18n/es.json     $(DESTDIR)$(LIBDIR)/i18n/es.json
	install -Dm644 -t $(DESTDIR)$(USERUNITDIR)     $(addprefix build/,$(UNITS))
	install -Dm644 build/io.github.frankmncrf.protux.desktop $(DESTDIR)$(APPDIR)/io.github.frankmncrf.protux.desktop
	install -Dm644 data/protux.svg             $(DESTDIR)$(ICONDIR)/protux.svg
	install -Dm644 man/protux.1                $(DESTDIR)$(MANDIR)/protux.1
	install -Dm644 -t $(DESTDIR)$(DOCDIR)          README.md CHANGELOG.md data/config.example data/hook.example
	install -Dm644 LICENSE                         $(DESTDIR)$(LICENSEDIR)/LICENSE

uninstall:
	rm -f  $(DESTDIR)$(BINDIR)/protux $(DESTDIR)$(BINDIR)/protux-gui \
	       $(DESTDIR)$(ICONDIR)/protux.svg $(addprefix $(DESTDIR)$(USERUNITDIR)/,$(UNITS)) \
	       $(DESTDIR)$(APPDIR)/io.github.frankmncrf.protux.desktop $(DESTDIR)$(MANDIR)/protux.1
	rm -rf $(DESTDIR)$(LIBDIR) $(DESTDIR)$(DOCDIR) $(DESTDIR)$(LICENSEDIR)

check:
	bash -n bin/protux lib/protux/common.sh lib/protux/locale/es.sh
	python3 -m py_compile bin/protux-gui
	@if command -v shellcheck >/dev/null; then shellcheck -x bin/protux; else echo "shellcheck not installed, skipped"; fi
	systemd-analyze verify --user $(addprefix build/,$(UNITS)) || true

dist:
	git archive --prefix=protux-$(VERSION)/ -o protux-$(VERSION).tar.gz HEAD

clean:
	rm -rf build protux-*.tar.gz

.PHONY: all install uninstall check dist clean
