#!/bin/bash
# Run all expect-based integration tests for em
# Usage: ./tests/run_tests.sh [bash|zsh|all]
# Requires: expect, bash 4+, zsh 5+ (for zsh tests)

set -euo pipefail

cd "$(dirname "$0")/.."

FILTER="${1:-all}"
PASS=0
FAIL=0
ERRORS=()

run_test() {
    local name="$1" script="$2"
    printf "  %-40s " "$name"
    if output=$(expect "$script" 2>&1); then
        echo "PASS"
        ((PASS++))
    else
        echo "FAIL"
        ERRORS+=("$name: $output")
        ((FAIL++))
    fi
}

echo "=== em integration tests ==="
echo ""

# Syntax checks
echo "Syntax checks:"
printf "  %-40s " "bash syntax (bash -n em)"
if bash -n em 2>&1; then
    echo "PASS"
    ((PASS++))
else
    echo "FAIL"
    ((FAIL++))
fi

if command -v zsh >/dev/null 2>&1; then
    printf "  %-40s " "zsh syntax (zsh -n em.zsh)"
    if zsh -n em.zsh 2>&1; then
        echo "PASS"
        ((PASS++))
    else
        echo "FAIL"
        ((FAIL++))
    fi
fi

echo ""

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
