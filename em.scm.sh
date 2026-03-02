#!/usr/bin/env bash
# em.scm.sh - Launcher for the Scheme-powered shemacs editor
#
# Source this file in your .bashrc:  source /path/to/em.scm.sh
# Then run:  em [filename]
# Or run standalone:  bash em.scm.sh [filename]
#
# All editor logic and I/O is in em.scm (Scheme).
# This file loads the sheme interpreter (bs.sh) and calls em-main.
#
# Requires sheme to be installed: https://github.com/jordanhubbard/sheme
#   Install:  cd ~/src/sheme && make install   (puts ~/.bs.sh in place)
#   Or dev layout: shemacs/ and sheme/ are siblings on the filesystem.

# Require bash 4+
if [[ "${BASH_VERSINFO:-0}" -lt 4 ]]; then
    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
        for _em_try_bash in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash; do
            if [[ -x "$_em_try_bash" ]] && "$_em_try_bash" -c '[[ ${BASH_VERSINFO[0]} -ge 4 ]]' 2>/dev/null; then
                exec "$_em_try_bash" "$0" "$@"
            fi
        done
    fi
    echo "em requires Bash 4+. Install via: brew install bash" >&2
    return 2>/dev/null || exit 1
fi

# --- Cache helpers for Scheme interpreter state ---

_em_save_cache() {
    local cache_file="$1" source_file="$2"
    local tmp_file="${cache_file}.tmp.$$"
    {
        printf '# shemacs cache -- %s\n' "$source_file"
        # Associative arrays: declare -A → declare -gA (global scope)
        declare -p __bs_car __bs_cdr \
            __bs_closure_params __bs_closure_body __bs_closure_env \
            __bs_env __bs_env_parent | sed 's/^declare -A /declare -gA /'
        # Scalars: declare -- → declare -g --
        declare -p __bs_heap_next __bs_env_next | sed 's/^declare -- /declare -g -- /'
        # Re-export top-level defines as bash globals (replicates define side-effect)
        local key name
        for key in "${!__bs_env[@]}"; do
            [[ "$key" == 0:* ]] || continue
            name="${key#0:}"
            [[ "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue
            printf 'declare -g %s=%q\n' "$name" "${__bs_env[$key]}"
        done
    } > "$tmp_file"
    mv -f "$tmp_file" "$cache_file" 2>/dev/null || { rm -f "$tmp_file"; return 1; }
}

_em_load_cache() {
    source "$1" || return 1
    # Validate: counters must exist and env 0 must have bindings
    [[ -n "${__bs_heap_next:-}" && -n "${__bs_env_next:-}" ]] || return 1
    local key; for key in "${!__bs_env[@]}"; do
        [[ "$key" == 0:* ]] && return 0
    done
    return 1
}

em() {
    local _em_script_dir
    _em_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _em_script_dir=""

    # Source the sheme interpreter if not already loaded.
    # Search order: installed ~/.bs.sh, sibling sheme/ repo, common prefixes.
    local _em_bs_path=""
    if ! type bs &>/dev/null; then
        local _bs_found=""
        for _bs_candidate in \
                "$HOME/.bs.sh" \
                "${_em_script_dir:+$_em_script_dir/../sheme/bs.sh}" \
                /usr/local/lib/sheme/bs.sh \
                /opt/sheme/bs.sh; do
            [[ -n "$_bs_candidate" && -f "$_bs_candidate" ]] || continue
            # shellcheck source=/dev/null
            source "$_bs_candidate" && _bs_found="$_bs_candidate" && break
        done
        if [[ -z "$_bs_found" ]]; then
            echo "em: cannot find bs.sh — install sheme: https://github.com/jordanhubbard/sheme" >&2
            return 1
        fi
        _em_bs_path="$_bs_found"
    else
        _em_bs_path="$HOME/.bs.sh"
    fi
    bs-reset

    # Find em.scm: prefer ~/.em.scm (user override), then alongside this script.
    local _em_scm_file
    if [[ -f "$HOME/.em.scm" ]]; then
        _em_scm_file="$HOME/.em.scm"
    elif [[ -n "$_em_script_dir" && -f "$_em_script_dir/em.scm" ]]; then
        _em_scm_file="$_em_script_dir/em.scm"
    else
        echo "em: cannot find em.scm" >&2
        return 1
    fi

    # Load from cache if valid, otherwise evaluate Scheme and save cache.
    local _em_cache_file="${_em_scm_file}.cache"
    if [[ -f "$_em_cache_file" \
          && "$_em_cache_file" -nt "$_em_scm_file" \
          && ( ! -f "${_em_bs_path:-}" || "$_em_cache_file" -nt "$_em_bs_path" ) ]] \
       && _em_load_cache "$_em_cache_file"; then
        : # cached state restored
    else
        bs "$(cat "$_em_scm_file")"
        _em_save_cache "$_em_cache_file" "$_em_scm_file" 2>/dev/null || true
    fi

    # Safety-net trap: restore terminal if killed unexpectedly
    local _em_saved_traps
    _em_saved_traps=$(trap -p INT TERM HUP 2>/dev/null)
    trap 'printf "\e[0m\e[?25h\e[?1049l"; [[ -n "$__bs_stty_saved" ]] && stty "$__bs_stty_saved" 2>/dev/null; __bs_stty_saved=""; trap - INT TERM HUP; return 130' INT
    trap 'printf "\e[0m\e[?25h\e[?1049l"; [[ -n "$__bs_stty_saved" ]] && stty "$__bs_stty_saved" 2>/dev/null; __bs_stty_saved=""; trap - INT TERM HUP; return 143' TERM
    trap 'printf "\e[0m\e[?25h\e[?1049l"; [[ -n "$__bs_stty_saved" ]] && stty "$__bs_stty_saved" 2>/dev/null; __bs_stty_saved=""; trap - INT TERM HUP; return 129' HUP

    # Warn before loading very large files (>= 10MB)
    if [[ -n "${1:-}" && -f "$1" ]]; then
        local _em_fsize
        _em_fsize=$(stat -f%z "$1" 2>/dev/null) || _em_fsize=$(stat --format=%s "$1" 2>/dev/null) || _em_fsize=0
        if (( _em_fsize >= 10485760 )); then
            local _em_mb=$(( _em_fsize / 1048576 ))
            printf "Warning: %s is %d MB.\n" "$1" "$_em_mb" >&2
            case "$1" in
                *.json)       printf "  Hint: consider 'jq' for JSON files.\n" >&2 ;;
                *.html|*.htm) printf "  Hint: consider 'tidy' for HTML files.\n" >&2 ;;
                *.xml)        printf "  Hint: consider 'xmllint' for XML files.\n" >&2 ;;
                *.csv)        printf "  Hint: consider a spreadsheet or 'csvtool'.\n" >&2 ;;
                *.log)        printf "  Hint: consider 'less' or 'tail' for logs.\n" >&2 ;;
            esac
            printf "Press Enter to continue or Ctrl-C to abort: " >&2
            read -r || { trap - INT TERM HUP; [[ -n "$_em_saved_traps" ]] && eval "$_em_saved_traps"; return 130; }
        fi
    fi

    # Escape filename for Scheme and run the editor
    local _em_escaped="${1:-}"
    _em_escaped="${_em_escaped//\\/\\\\}"
    _em_escaped="${_em_escaped//\"/\\\"}"
    bs "(em-main \"$_em_escaped\")"

    # Restore traps
    trap - INT TERM HUP
    [[ -n "$_em_saved_traps" ]] && eval "$_em_saved_traps"
    return 0
}

# Standalone execution: bash em.scm.sh [filename]
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    em "$@"
fi
