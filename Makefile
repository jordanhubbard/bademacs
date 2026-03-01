SHELL := /bin/bash
SRCDIR := $(abspath .)
BUMP ?= patch

.PHONY: install uninstall check test release

install:
	@echo "Installing bad-emacs to home directory..."
	@cp "$(SRCDIR)/em.sh" "$(HOME)/.em.sh"
	@cp "$(SRCDIR)/em.zsh" "$(HOME)/.em.zsh"
	@echo "Installed ~/.em.sh and ~/.em.zsh"
	@if ! grep -q 'source.*\.em\.sh' "$(HOME)/.bashrc" 2>/dev/null; then \
		echo '' >> "$(HOME)/.bashrc"; \
		echo '# em - bad emacs clone (shell function)' >> "$(HOME)/.bashrc"; \
		echo 'source "$(HOME)/.em.sh"' >> "$(HOME)/.bashrc"; \
		echo "Added source line to ~/.bashrc"; \
	else \
		echo "~/.bashrc already sources ~/.em.sh"; \
	fi
	@if ! grep -q 'source.*\.em\.zsh' "$(HOME)/.zshrc" 2>/dev/null; then \
		echo '' >> "$(HOME)/.zshrc"; \
		echo '# em - bad emacs clone (shell function)' >> "$(HOME)/.zshrc"; \
		echo 'source "$(HOME)/.em.zsh"' >> "$(HOME)/.zshrc"; \
		echo "Added source line to ~/.zshrc"; \
	else \
		echo "~/.zshrc already sources ~/.em.zsh"; \
	fi
	@echo "Installed. Open a new shell or source your rc file."

uninstall:
	@rm -f "$(HOME)/.em.sh" "$(HOME)/.em.zsh"
	@[ -f "$(HOME)/.bashrc" ] && sed -i '' '/# em - bad emacs/d; /source.*\.em\.\(sh\|zsh\)/d' "$(HOME)/.bashrc" || true
	@[ -f "$(HOME)/.zshrc" ] && sed -i '' '/# em - bad emacs/d; /source.*\.em\.\(sh\|zsh\)/d' "$(HOME)/.zshrc" || true
	@echo "Uninstalled bad-emacs."

check:
	@echo "Checking bash version..."
	@bash -n em.sh && echo "  em.sh: Syntax OK"
	@echo "Checking zsh version..."
	@zsh -n em.zsh && echo "  em.zsh: Syntax OK"

test: check
	@./tests/run_tests.sh

release:
	@bash scripts/release.sh $(BUMP)
