# Detect user's shell before overriding SHELL for Make recipes
USER_SHELL := $(shell echo $$SHELL)
SHELL_TYPE ?= $(if $(findstring zsh,$(USER_SHELL)),zsh,bash)

ifeq ($(SHELL_TYPE),zsh)
  RCFILE ?= $(HOME)/.zshrc
  SCRIPT := $(abspath em.zsh)
  EM_FILE := em.zsh
else
  RCFILE ?= $(HOME)/.bashrc
  SCRIPT := $(abspath em)
  EM_FILE := em
endif

SHELL := /bin/bash

.PHONY: install uninstall check

install:
	@echo "Detected shell: $(SHELL_TYPE) (override with SHELL_TYPE=bash|zsh)"
	@if ! grep -q 'source.*[/ ]em' "$(RCFILE)" 2>/dev/null; then \
		echo '' >> "$(RCFILE)"; \
		echo '# em - bad emacs clone (shell function)' >> "$(RCFILE)"; \
		echo 'source "$(SCRIPT)"' >> "$(RCFILE)"; \
		echo "Added source line to $(RCFILE)"; \
	else \
		echo "$(RCFILE) already sources em"; \
	fi
	@echo "Installed. Open a new shell or: source $(RCFILE)"

uninstall:
	@if [ -f "$(RCFILE)" ]; then \
		sed -i '' '/# em - bad emacs/d; /source.*[/ ]em[" ]*$$/d' "$(RCFILE)"; \
		echo "Removed from $(RCFILE)"; \
	fi
	@echo "Uninstalled."

check:
	@echo "Checking bash version..."
	@bash -n em && echo "  em: Syntax OK"
	@echo "Checking zsh version..."
	@zsh -n em.zsh && echo "  em.zsh: Syntax OK"
