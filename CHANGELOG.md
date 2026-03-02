# Changelog

All notable changes to shemacs are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0.5] - 2026-03-01


## [1.0.4] - 2026-03-01


## [1.0.3] - 2026-03-01

### Fixed
- increase Scheme editor test timeouts for CI
- raise Scheme test timeouts for slow CI keystroke processing


## [1.0.2] - 2026-03-01

### Fixed
- split stty to isolate macOS-only dsusp option


## [1.0.1] - 2026-03-01

### Fixed
- correct bash regex patterns in changelog categorizer
- correct ((PASS++)) arithmetic under set -e, skip expect when absent

### Other
- Rename bad-emacs → shemacs
- Address issue #2 feedback: dsusp, rect r/d, minibuffer display, help trim
- Move Scheme editor into shemacs; add em.scm.sh launcher
- Bring em.scm to feature parity with em.sh; update docs for 3 implementations


## [1.0.1] - 2026-03-01

### Fixed
- correct bash regex patterns in changelog categorizer

### Other
- Rename bad-emacs → shemacs
- Address issue #2 feedback: dsusp, rect r/d, minibuffer display, help trim
- Move Scheme editor into shemacs; add em.scm.sh launcher
- Bring em.scm to feature parity with em.sh; update docs for 3 implementations


## [1.0.0] - 2026-02-28

### Added
- Emacs-like editor (`em`) as a sourceable shell function for bash and zsh
- Multiple buffer support, undo history, and keyboard macros
- Isearch with highlight, tab completion, clipboard integration, and rectangle
  operations
- Zsh-native implementation (`em.zsh`) with full keybinding parity
- Scheme backend (`em.scm`) powered by sheme for extended scripting
- Horizontal scrolling, standalone mode, and stdin pipe support
- Mark-preserving indent and bash 4+/5+ version guard
- CI/CD pipeline with GitHub Actions (Ubuntu and macOS matrix)
- Integration test suite using `expect` (bash and zsh)
- `make release` target for automated versioning and GitHub releases

### Fixed
- Terminal handling, Enter key, and file I/O robustness
- C-x C-c terminal corruption on exit
- C-v pagination and lnext-character interception
- ESC as Meta prefix and terminal cleanup on exit
- Return key, minibuffer input, and rendering corruption
- Ctrl-C handling on macOS (undefine intr/quit/susp)
- Large file performance (#5)
- Printf status-line rendering artifact in CI
