# Contributing to shemacs

## Filing Bugs

Open a GitHub issue. Include:
- Your shell and version (`bash --version` or `zsh --version`)
- OS and terminal emulator
- Which implementation (`em.sh`, `em.zsh`, or `em.scm`) — for `em.scm`,
  also include your sheme version (`source ~/.bs.sh && bs-eval '"version"'`)
- Steps to reproduce
- Expected vs actual behaviour

## Submitting Pull Requests

1. Fork the repo and create a feature branch from `main`.
2. Make your changes.
3. Verify all tests pass: `make test`
4. Open a PR against `main` with a clear description of what changed and why.

### PR Checklist

- [ ] `make test` passes (bash and zsh integration tests)
- [ ] `make check` passes (syntax validation)
- [ ] No regressions in existing keybindings
- [ ] README updated if keybindings or install steps changed
- [ ] If `em.scm` was changed: Scheme editor tests pass (see below)

## Running Tests

```bash
make check          # syntax validation only (fast)
make test           # bash and zsh integration tests (requires expect)
make test SCM=1     # also run Scheme editor tests (requires expect + sheme)
```

Tests are driven by `expect` scripts under `tests/`. Each file exercises a
specific editing operation across the bash, zsh, and Scheme implementations.

To run the Scheme editor tests locally, install sheme first:

```bash
git clone https://github.com/jordanhubbard/sheme.git ~/sheme
cd ~/sheme && make install    # puts ~/.bs.sh in place
cd /path/to/shemacs
make test                     # run_tests.sh auto-detects sheme and includes scm tests
```

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/) — the release
script uses these to categorize changelog entries automatically:

```
feat: add M-d delete-word keybinding
fix: correct C-v scroll when buffer is shorter than screen
docs: update keybinding table in README
refactor: extract render loop into _em_render helper
chore: update CI to use actions/checkout@v4
```

## Code Conventions

- **bash version (`em.sh`)**: requires bash 4.3+; use `[[ ]]`, `local`, arrays.
  Avoid bashisms that fail under `bash -n`.
- **zsh version (`em.zsh`)**: use native zsh syntax; keep parallel with `em.sh`.
- Both files are sourced into the user's shell — keep the global namespace clean.
  All internal names are prefixed `_em_`.
- No external dependencies beyond the standard POSIX utilities.
- **Scheme version (`em.scm`)**: pure R5RS-compatible Scheme; no bash/zsh-specific
  code. All I/O goes through sheme builtins. Requires sheme ≥ v1.0.0.
  Keep in sync with `em.sh` for feature parity.

## Release Process

Maintainers only:

```bash
make release           # patch bump (default)
make release BUMP=minor
make release BUMP=major
```

This runs tests, updates `CHANGELOG.md`, tags, and creates a GitHub release.
