PREFIX ?= $(HOME)/.local
LIBDIR := $(PREFIX)/lib/tmux-manager
BINDIR := $(PREFIX)/bin
APPDIR := $(PREFIX)/share/applications

.PHONY: test install uninstall run

test:
	PYTHONPATH=. python3 -m unittest discover -s tests -v

install:
	@mkdir -p "$(LIBDIR)/tmux_manager" "$(LIBDIR)/resources" "$(BINDIR)" "$(APPDIR)"
	@rm -rf "$(LIBDIR)/tmux_manager" "$(LIBDIR)/resources"
	@cp -R tmux_manager resources "$(LIBDIR)/"
	@install -m 755 tmux-manager "$(LIBDIR)/tmux-manager"
	@ln -sf "$(LIBDIR)/tmux-manager" "$(BINDIR)/tmux-manager"
	@printf '%s\n' \
		'[Desktop Entry]' \
		'Type=Application' \
		'Name=TmuxManager' \
		'Comment=Floating X11 bar for remote tmux sessions in WezTerm' \
		"Exec=$(BINDIR)/tmux-manager" \
		'Terminal=false' \
		'Categories=System;TerminalEmulator;Utility;' \
		> "$(APPDIR)/tmux-manager.desktop"
	@chmod 644 "$(APPDIR)/tmux-manager.desktop"
	@echo "Installed to $(BINDIR)/tmux-manager"

uninstall:
	@rm -f "$(BINDIR)/tmux-manager" "$(APPDIR)/tmux-manager.desktop"
	@rm -rf "$(LIBDIR)"
	@echo "Uninstalled TmuxManager"

run:
	./tmux-manager
