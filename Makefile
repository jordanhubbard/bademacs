SHELL      := /bin/bash
SRCDIR     := $(abspath .)
BUMP       ?= patch

.DEFAULT_GOAL := help

.PHONY: install install-scm uninstall uninstall-scm check test release help

help: ## Show available make targets
	@awk 'BEGIN {FS = ":.*##"}; /^[a-zA-Z_-]+:.*##/ { printf "  %-20s %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)

install: ## Install em.sh and em.zsh to home directory
	@echo "Installing shemacs to home directory..."
	@cp "$(SRCDIR)/em.sh" "$(HOME)/.em.sh"
	@cp "$(SRCDIR)/em.zsh" "$(HOME)/.em.zsh"
	@echo "Installed ~/.em.sh and ~/.em.zsh"
	@if ! grep -q 'source.*\.em\.sh' "$(HOME)/.bashrc" 2>/dev/null; then \
		echo '' >> "$(HOME)/.bashrc"; \
		echo '# em - shemacs (shell function)' >> "$(HOME)/.bashrc"; \
		echo 'source "$(HOME)/.em.sh"' >> "$(HOME)/.bashrc"; \
		echo "Added source line to ~/.bashrc"; \
	else \
		echo "~/.bashrc already sources ~/.em.sh"; \
	fi
	@if ! grep -q 'source.*\.em\.zsh' "$(HOME)/.zshrc" 2>/dev/null; then \
		echo '' >> "$(HOME)/.zshrc"; \
		echo '# em - shemacs (shell function)' >> "$(HOME)/.zshrc"; \
		echo 'source "$(HOME)/.em.zsh"' >> "$(HOME)/.zshrc"; \
		echo "Added source line to ~/.zshrc"; \
	else \
		echo "~/.zshrc already sources ~/.em.zsh"; \
	fi
	@echo "Installed. Open a new shell or source your rc file."

install-scm: install ## Install Scheme-powered em (requires sheme)
	@echo ""
	@echo "Installing Scheme-powered em (requires sheme: https://github.com/jordanhubbard/sheme)..."
	@cp "$(SRCDIR)/em.scm.sh" "$(HOME)/.em.scm.sh"
	@cp "$(SRCDIR)/em.scm" "$(HOME)/.em.scm"
	@echo "Installed ~/.em.scm.sh and ~/.em.scm"
	@if ! grep -q 'source.*\.em\.scm\.sh' "$(HOME)/.bashrc" 2>/dev/null; then \
		echo '' >> "$(HOME)/.bashrc"; \
		echo '# em - shemacs Scheme backend (requires sheme)' >> "$(HOME)/.bashrc"; \
		echo 'source "$(HOME)/.em.scm.sh"' >> "$(HOME)/.bashrc"; \
		echo "Added source line to ~/.bashrc"; \
	else \
		echo "~/.bashrc already sources ~/.em.scm.sh"; \
	fi
	@echo "Source ~/.em.scm.sh (instead of ~/.em.sh) to use the Scheme backend."

uninstall: ## Remove shemacs from home directory
	@rm -f "$(HOME)/.em.sh" "$(HOME)/.em.zsh"
	@[ -f "$(HOME)/.bashrc" ] && sed -i '' '/# em - bad emacs/d; /# em - shemacs/d; /source.*\.em\.\(sh\|zsh\)/d' "$(HOME)/.bashrc" 2>/dev/null || \
		sed -i '/# em - bad emacs/d; /# em - shemacs/d; /source.*\.em\.\(sh\|zsh\)/d' "$(HOME)/.bashrc" 2>/dev/null || true
	@[ -f "$(HOME)/.zshrc" ] && sed -i '' '/# em - bad emacs/d; /# em - shemacs/d; /source.*\.em\.\(sh\|zsh\)/d' "$(HOME)/.zshrc" 2>/dev/null || \
		sed -i '/# em - bad emacs/d; /# em - shemacs/d; /source.*\.em\.\(sh\|zsh\)/d' "$(HOME)/.zshrc" 2>/dev/null || true
	@echo "Uninstalled shemacs."

uninstall-scm: ## Remove Scheme-powered em from home directory
	@rm -f "$(HOME)/.em.scm.sh" "$(HOME)/.em.scm"
	@[ -f "$(HOME)/.bashrc" ] && sed -i '' '/# em - shemacs Scheme/d; /source.*\.em\.scm\.sh/d' "$(HOME)/.bashrc" 2>/dev/null || \
		sed -i '/# em - shemacs Scheme/d; /source.*\.em\.scm\.sh/d' "$(HOME)/.bashrc" 2>/dev/null || true
	@echo "Uninstalled Scheme-backed em."

check: ## Validate shell syntax without running tests
	@echo "Checking bash version..."
	@bash -n em.sh && echo "  em.sh:      Syntax OK"
	@echo "Checking zsh version..."
	@zsh -n em.zsh && echo "  em.zsh:     Syntax OK"
	@echo "Checking Scheme launcher..."
	@bash -n em.scm.sh && echo "  em.scm.sh:  Syntax OK"

test: check ## Run full integration test suite (requires expect)
	@./tests/run_tests.sh

release: ## Create a release: make release BUMP=patch|minor|major
	@bash scripts/release.sh $(BUMP)
