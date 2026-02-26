SHELL := /bin/bash
BASHRC ?= $(HOME)/.bashrc
SCRIPT := $(abspath em)

.PHONY: install uninstall check

install:
	@if ! grep -q 'source.*[/ ]em' "$(BASHRC)" 2>/dev/null; then \
		echo '' >> "$(BASHRC)"; \
		echo '# em - bad emacs clone (shell function)' >> "$(BASHRC)"; \
		echo 'source "$(SCRIPT)"' >> "$(BASHRC)"; \
		echo "Added source line to $(BASHRC)"; \
	else \
		echo "$(BASHRC) already sources em"; \
	fi
	@echo "Installed. Open a new shell or: source $(BASHRC)"

uninstall:
	@if [ -f "$(BASHRC)" ]; then \
		sed -i '' '/# em - bad emacs/d; /source.*[/ ]em[" ]*$$/d' "$(BASHRC)"; \
		echo "Removed from $(BASHRC)"; \
	fi
	@echo "Uninstalled."

check:
	@bash -n em && echo "Syntax OK"
