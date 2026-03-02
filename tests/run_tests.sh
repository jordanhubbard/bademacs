#!/bin/bash
# Run all expect-based integration tests for em
# Usage: ./tests/run_tests.sh [bash|zsh|scm|all]
# Requires: expect, bash 4+, zsh 5+ (for zsh tests), sheme (for scm tests)

set -euo pipefail

cd "$(dirname "$0")/.."

FILTER="${1:-all}"
SCM_AVAILABLE=0
bash -c 'source ~/.bs.sh 2>/dev/null && type bs &>/dev/null' 2>/dev/null && SCM_AVAILABLE=1 || true
PASS=0
FAIL=0
ERRORS=()

run_test() {
    local name="$1" script="$2"
    printf "  %-40s " "$name"
    if output=$(expect "$script" 2>&1); then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        ERRORS+=("$name: $output")
        FAIL=$((FAIL + 1))
    fi
}

echo "=== em integration tests ==="
echo ""

# Syntax checks
echo "Syntax checks:"
printf "  %-40s " "bash syntax (bash -n em.sh)"
if bash -n em.sh 2>&1; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    FAIL=$((FAIL + 1))
fi

if command -v zsh >/dev/null 2>&1; then
    printf "  %-40s " "zsh syntax (zsh -n em.zsh)"
    if zsh -n em.zsh 2>&1; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        FAIL=$((FAIL + 1))
    fi
fi
printf "  %-40s " "bash syntax (bash -n em.scm.sh)"
if bash -n em.scm.sh 2>&1; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    FAIL=$((FAIL + 1))
fi

echo ""

# Check if expect is available for interactive tests
if ! command -v expect >/dev/null 2>&1; then
    echo "Interactive tests: SKIPPED (expect not installed)"
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit $((FAIL > 0 ? 1 : 0))
fi

# Bash tests
if [[ "$FILTER" == "all" || "$FILTER" == "bash" ]]; then
    echo "Bash tests:"
    run_test "start and quit" tests/test_bash_start_quit.exp
    run_test "open file" tests/test_bash_open_file.exp
    run_test "save file" tests/test_bash_save_file.exp
    run_test "upcase word (M-u)" tests/test_bash_upcase.exp
    run_test "isearch highlight" tests/test_bash_isearch.exp
    run_test "tab completion" tests/test_bash_tab_complete.exp
    run_test "rectangle kill/yank" tests/test_bash_rectangle.exp
    echo ""
fi

# Zsh tests
if [[ "$FILTER" == "all" || "$FILTER" == "zsh" ]]; then
    if command -v zsh >/dev/null 2>&1; then
        echo "Zsh tests:"
        run_test "start and quit" tests/test_zsh_start_quit.exp
        run_test "open file" tests/test_zsh_open_file.exp
        run_test "save file" tests/test_zsh_save_file.exp
        run_test "upcase word (M-u)" tests/test_zsh_upcase.exp
        run_test "isearch highlight" tests/test_zsh_isearch.exp
        run_test "tab completion" tests/test_zsh_tab_complete.exp
        run_test "rectangle kill/yank" tests/test_zsh_rectangle.exp
        echo ""
    else
        echo "Zsh tests: SKIPPED (zsh not found)"
        echo ""
    fi
fi

# Scheme editor tests
if [[ "$FILTER" == "all" || "$FILTER" == "scm" ]]; then
    if ((SCM_AVAILABLE)); then
        echo "Scheme (em.scm) tests:"
        run_test "start and quit" tests/test_scm_start_quit.exp
        run_test "open file" tests/test_scm_open_file.exp
        run_test "save file" tests/test_scm_save_file.exp
        run_test "upcase word (M-u)" tests/test_scm_upcase.exp
        run_test "isearch highlight" tests/test_scm_isearch.exp
        run_test "cache round-trip" tests/test_scm_cache.exp
        echo ""
    else
        echo "Scheme tests: SKIPPED (sheme/bs.sh not found — run 'make install' in sheme repo)"
        echo ""
    fi
fi

# Summary
echo "=== Results: $PASS passed, $FAIL failed ==="

if ((FAIL > 0)); then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  - $err" | head -3
    done
    exit 1
fi
