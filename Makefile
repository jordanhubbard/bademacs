SHELL := /bin/bash
PREFIX ?= $(HOME)/.local/bin
BASHRC ?= $(HOME)/.bashrc
SCRIPT := em

.PHONY: install uninstall check

install:
	@mkdir -p "$(PREFIX)"
	@cp "$(SCRIPT)" "$(PREFIX)/$(SCRIPT)"
	@chmod +x "$(PREFIX)/$(SCRIPT)"
	@if ! grep -q 'source.*[/ ]em' "$(BASHRC)" 2>/dev/null; then \
		echo '' >> "$(BASHRC)"; \
		echo '# em - micro emacs clone (shell function)' >> "$(BASHRC)"; \
		echo 'source "$(PREFIX)/$(SCRIPT)"' >> "$(BASHRC)"; \
		echo "Added source line to $(BASHRC)"; \
	else \
		echo "$(BASHRC) already sources em"; \
	fi
	@echo "Installed. Open a new shell or: source $(BASHRC)"

uninstall:
	@rm -f "$(PREFIX)/$(SCRIPT)"
	@if [ -f "$(BASHRC)" ]; then \
		sed -i '' '/# em - micro emacs/d; /source.*[/ ]em[" ]*$$/d' "$(BASHRC)"; \
		echo "Removed from $(BASHRC)"; \
	fi
	@echo "Uninstalled."

check:
	@bash -n "$(SCRIPT)" && echo "Syntax OK"
