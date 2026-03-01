#!/usr/bin/env bash
# scripts/release.sh — Automated release for bad-emacs
# Usage: bash scripts/release.sh [patch|minor|major]
# Called by: make release [BUMP=patch|minor|major]

set -euo pipefail

BUMP="${1:-patch}"
DATE=$(date +%Y-%m-%d)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Preflight checks ─────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
    echo "Error: gh CLI is required. Install from https://cli.github.com" >&2
    exit 1
fi

if [[ "$BUMP" != "patch" && "$BUMP" != "minor" && "$BUMP" != "major" ]]; then
    echo "Error: BUMP must be patch, minor, or major (got: $BUMP)" >&2
    exit 1
fi

# Check for uncommitted changes (before we touch CHANGELOG)
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: working tree is dirty. Commit or stash changes first." >&2
    git status --short >&2
    exit 1
fi

# ── Determine versions ───────────────────────────────────────────────
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

if [[ -z "$LAST_TAG" ]]; then
    # First release ever
    NEW_VERSION="v1.0.0"
    COMMIT_RANGE=""
    echo "First release: $NEW_VERSION"
else
    # Parse current version
    VER="${LAST_TAG#v}"
    IFS='.' read -r MAJOR MINOR PATCH <<< "$VER"

    case "$BUMP" in
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
        minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
        patch) PATCH=$((PATCH + 1)) ;;
    esac

    NEW_VERSION="v${MAJOR}.${MINOR}.${PATCH}"
    COMMIT_RANGE="${LAST_TAG}..HEAD"
    echo "Bumping $LAST_TAG -> $NEW_VERSION ($BUMP)"
fi

# ── Check for new commits ────────────────────────────────────────────
if [[ -n "$COMMIT_RANGE" ]]; then
    COMMIT_COUNT=$(git rev-list --count "$COMMIT_RANGE")
else
    COMMIT_COUNT=$(git rev-list --count HEAD)
fi

if (( COMMIT_COUNT == 0 )); then
    echo "Error: no new commits since $LAST_TAG. Nothing to release." >&2
    exit 1
fi

echo "  $COMMIT_COUNT commit(s) to include"

# ── Generate CHANGELOG entry ─────────────────────────────────────────
if [[ -n "$COMMIT_RANGE" ]]; then
    LOG=$(git log "$COMMIT_RANGE" --pretty=format:"- %s (%h)" --reverse)
else
    LOG=$(git log --pretty=format:"- %s (%h)" --reverse)
fi

ENTRY="## $NEW_VERSION — $DATE

$LOG"

if [[ -f CHANGELOG.md ]]; then
    # Prepend new entry after the first line (header)
    EXISTING=$(cat CHANGELOG.md)
    HEADER=$(head -1 CHANGELOG.md)
    REST=$(tail -n +2 CHANGELOG.md)
    printf '%s\n\n%s\n%s\n' "$HEADER" "$ENTRY" "$REST" > CHANGELOG.md
else
    printf '# Changelog\n\n%s\n' "$ENTRY" > CHANGELOG.md
fi

echo "  Updated CHANGELOG.md"

# ── Commit CHANGELOG ─────────────────────────────────────────────────
git add CHANGELOG.md
git commit -m "Update CHANGELOG for $NEW_VERSION"
echo "  Committed CHANGELOG"

# ── Run tests ────────────────────────────────────────────────────────
echo ""
echo "Running test suite..."
if ! make test; then
    echo "" >&2
    echo "Error: tests failed. Release aborted." >&2
    echo "The CHANGELOG commit remains — fix tests and re-run make release." >&2
    exit 1
fi
echo ""
echo "  All tests passed"

# ── Verify clean tree ────────────────────────────────────────────────
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: working tree is dirty after tests. Aborting." >&2
    git status --short >&2
    exit 1
fi

# ── Push commits ─────────────────────────────────────────────────────
echo "  Pushing commits..."
git push

# ── Tag and push tag ─────────────────────────────────────────────────
git tag -a "$NEW_VERSION" -m "Release $NEW_VERSION"
git push origin "$NEW_VERSION"
echo "  Tagged $NEW_VERSION"

# ── Create GitHub release ────────────────────────────────────────────
# Use the changelog entry as release notes
NOTES="$ENTRY"

gh release create "$NEW_VERSION" \
    --title "$NEW_VERSION" \
    --notes "$NOTES"

echo ""
echo "Released $NEW_VERSION"
