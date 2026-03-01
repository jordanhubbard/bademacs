#!/usr/bin/env bash
# scripts/release.sh — Automated release for shemacs
# Usage: bash scripts/release.sh [patch|minor|major]
# Called by: make release [BUMP=patch|minor|major]
# Batch mode: BATCH=yes make release [BUMP=...]

set -euo pipefail

BUMP="${1:-patch}"
BATCH_MODE="${BATCH:-no}"
DATE=$(date +%Y-%m-%d)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Preflight checks ─────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
    echo "Error: gh CLI is required. Install from https://cli.github.com" >&2
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "Error: gh CLI is not authenticated. Run: gh auth login" >&2
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

# Enforce main branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    if [[ "$BATCH_MODE" == "yes" ]]; then
        echo "Error: not on main branch (on: $CURRENT_BRANCH). Aborting in batch mode." >&2
        exit 1
    fi
    echo "Warning: not on main branch (currently on: $CURRENT_BRANCH)"
    read -r -p "Continue anyway? (y/n) " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || exit 0
fi

# ── Determine versions ───────────────────────────────────────────────
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

if [[ -z "$LAST_TAG" ]]; then
    NEW_TAG="v1.0.0"
    NEW_VER="1.0.0"
    COMMIT_RANGE=""
    echo "First release: $NEW_TAG"
else
    VER="${LAST_TAG#v}"
    IFS='.' read -r MAJOR MINOR PATCH <<< "$VER"
    case "$BUMP" in
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
        minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
        patch) PATCH=$((PATCH + 1)) ;;
    esac
    NEW_TAG="v${MAJOR}.${MINOR}.${PATCH}"
    NEW_VER="${MAJOR}.${MINOR}.${PATCH}"
    COMMIT_RANGE="${LAST_TAG}..HEAD"
    echo "Bumping $LAST_TAG -> $NEW_TAG ($BUMP)"
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

# ── Generate CHANGELOG entry (Keep a Changelog format) ───────────────
if [[ -n "$COMMIT_RANGE" ]]; then
    COMMITS=$(git log "$COMMIT_RANGE" --pretty=format:"%h %s" --no-merges --reverse)
else
    COMMITS=$(git log --pretty=format:"%h %s" --no-merges --reverse)
fi

# Regex patterns assigned to variables — bash [[ =~ ]] handles complex
# patterns reliably when they come from a variable rather than a literal.
re_feat='^[a-f0-9]+ feat'
re_fix='^[a-f0-9]+ fix'
re_refactor='^[a-f0-9]+ refactor'
re_skip='^[a-f0-9]+ (chore|docs|ci)'

added=""; fixed=""; changed=""; other=""
while IFS= read -r line; do
    msg=$(echo "$line" | cut -d' ' -f2-)
    clean=$(echo "$msg" | sed 's/^[^:]*: //')   # strip "type: " prefix
    if   [[ "$line" =~ $re_feat ]];     then added+="- $clean"$'\n'
    elif [[ "$line" =~ $re_fix ]];      then fixed+="- $clean"$'\n'
    elif [[ "$line" =~ $re_refactor ]]; then changed+="- $clean"$'\n'
    elif [[ "$line" =~ $re_skip ]];     then : # skip housekeeping commits
    else other+="- $msg"$'\n'
    fi
done <<< "$COMMITS"

ENTRY="## [$NEW_VER] - $DATE"$'\n'
[[ -n "$added"   ]] && ENTRY+=$'\n'"### Added"$'\n'"$added"
[[ -n "$changed" ]] && ENTRY+=$'\n'"### Changed"$'\n'"$changed"
[[ -n "$fixed"   ]] && ENTRY+=$'\n'"### Fixed"$'\n'"$fixed"
[[ -n "$other"   ]] && ENTRY+=$'\n'"### Other"$'\n'"$other"

# ── Update CHANGELOG.md ──────────────────────────────────────────────
if [[ -f CHANGELOG.md ]]; then
    # Insert new entry after the ## [Unreleased] section header
    awk -v entry="$ENTRY" '
        /^## \[Unreleased\]/ { print; print ""; print entry; next }
        { print }
    ' CHANGELOG.md > CHANGELOG.md.tmp
    mv CHANGELOG.md.tmp CHANGELOG.md
else
    printf '# Changelog\n\nAll notable changes are documented here.\nFormat follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).\n\n## [Unreleased]\n\n%s\n' "$ENTRY" > CHANGELOG.md
fi
echo "  Updated CHANGELOG.md"

# ── Commit CHANGELOG ─────────────────────────────────────────────────
git add CHANGELOG.md
git commit -m "docs: update CHANGELOG for $NEW_TAG"
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
echo "  All tests passed"

# ── Verify clean tree ────────────────────────────────────────────────
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: working tree is dirty after tests. Aborting." >&2
    git status --short >&2
    exit 1
fi

# ── Push, tag, and release ───────────────────────────────────────────
REPO_URL=$(gh repo view --json url -q .url 2>/dev/null || echo "")

echo "  Pushing commits..."
git push

git tag -a "$NEW_TAG" -m "Release $NEW_TAG"
git push origin "$NEW_TAG"
echo "  Tagged $NEW_TAG"

NOTES="$ENTRY"
[[ -n "$REPO_URL" && -n "$LAST_TAG" ]] && \
    NOTES+=$'\n\n'"**Full Changelog**: ${REPO_URL}/compare/${LAST_TAG}...${NEW_TAG}"

gh release create "$NEW_TAG" \
    --title "$NEW_TAG" \
    --notes "$NOTES"

echo ""
echo "Released $NEW_TAG"
