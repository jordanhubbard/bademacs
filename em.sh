# em - A bad emacs clone (mg-compatible) as a single shell function
#
# Source this file in your .bashrc:  source /path/to/em
# Then run:  em [filename]
#
# Keybindings (mg/emacs compatible):
#   C-x C-c    quit              C-x C-s    save
#   C-x C-f    find file         C-x C-w    write file (save as)
#   C-x C-x    exchange pt/mark  C-x =      cursor position
#   C-x b      switch buffer     C-x k      kill buffer
#   C-x C-b    list buffers      C-x h      mark whole buffer
#   C-x i      insert file       C-x u      undo
#   C-x (      start macro       C-x )      end macro
#   C-x e      run macro
#   C-f/Right  forward char      C-b/Left   backward char
#   C-n/Down   next line         C-p/Up     previous line
#   C-a/Home   begin of line     C-e/End    end of line
#   M-f        forward word      M-b        backward word
#   C-v/PgDn   page down         M-v/PgUp   page up
#   M-<        begin of buffer   M->        end of buffer
#   C-d/Del    delete char       Bksp       delete backward
#   C-k        kill line         C-y        yank
#   C-w        kill region       M-w        copy region
#   C-SPC      set mark          C-t        transpose chars
#   C-o        open line         C-l        recenter
#   M-d        kill word         M-DEL      kill word backward
#   M-u        upcase word       M-l        downcase word
#   M-c        capitalize word   M-%        query replace
#   C-s        search forward    C-r        search backward
#   C-u N      universal arg     C-q        quoted insert
#   M-q        fill paragraph    M-x        extended command
#   C-_ / C-x u  undo            C-g        cancel
#   C-z        suspend           C-h b      describe bindings
#   C-i/TAB    indent line       Shift-TAB  dedent line

em() {
    # Disable errexit — arithmetic expressions like ((0)) return status 1
    # which kills the shell under set -e. Save and restore on exit.
    local _em_had_errexit=""
    [[ "$-" == *e* ]] && { _em_had_errexit=1; set +e; }

    # ===== LOCAL STATE =====
    local -a _em_lines=()
    local -i _em_cy=0 _em_cx=0
    local -i _em_top=0
    local -i _em_rows=24 _em_cols=80
    local -i _em_mark_y=-1 _em_mark_x=-1
    local -i _em_modified=0
    local _em_filename=""
    local _em_bufname="*scratch*"
    local _em_message=""
    local -i _em_msg_persist=0
    local -a _em_kill_ring=()
    local -a _em_undo=()
    local _em_last_cmd=""
    local _em_key=""
    local _em_char=""
    local -i _em_arg=0 _em_arg_active=0
    local _em_stty_saved=""
    local -i _em_running=1
    local _em_search_str=""
    local -i _em_search_dir=1
    local -i _em_goal_col=-1
    local _em_mb_result=""
    local _em_found_pos=0
    local _em_found_buf=0
    local US=$'\x1f'
    local RS=$'\x1e'
    local GS=$'\x1d'
    local ESC=$'\x1b'
    local _em_abc="abcdefghijklmnopqrstuvwxyz"
    local -i _em_tab_width=8
    local -i _em_cleaned_up=0
    local _em_saved_traps=""
    local -i _em_fill_column=72
    local -i _em_isearch_active=0
    local -i _em_isearch_y=-1 _em_isearch_x=-1 _em_isearch_len=0
    local -i _em_recording=0
    local -a _em_macro_keys=()
    local _em_clip_copy="" _em_clip_paste=""
    local -a _em_rect_kill=()
    local _em_comp_result=""
    local -A _em_bufs=()
    local -a _em_buf_ids=()
    local -i _em_cur_buf=0
    local -i _em_buf_count=0

    # ===== INNER FUNCTIONS =====

    _em_cleanup() {
        ((_em_cleaned_up)) && return
        _em_cleaned_up=1
        # Reset attributes, show cursor, exit alternate screen
        printf '%s' $'\x1b[0m\x1b[?25h\x1b[?1049l'
        stty "$_em_stty_saved" 2>/dev/null || stty sane 2>/dev/null
        # Restore original traps before unsetting functions
        trap - INT TERM HUP WINCH
        [[ -n "$_em_saved_traps" ]] && eval "$_em_saved_traps"
        local fn
        while IFS= read -r fn; do
            unset -f "$fn" 2>/dev/null
        done < <(declare -F | while read -r _ _ name; do
            [[ "$name" == _em_* ]] && printf '%s\n' "$name"
        done)
    }

    _em_suspend() {
        # Restore terminal to normal state, suspend, reinit on resume
        printf '%s' $'\x1b[0m\x1b[?25h\x1b[?1049l'
        stty "$_em_stty_saved" 2>/dev/null || stty sane 2>/dev/null
        kill -TSTP $$
        # Resumed (SIGCONT received) — reinitialize terminal
        stty raw -echo -isig -ixon -ixoff -icrnl intr undef quit undef susp undef lnext undef 2>/dev/null
        printf '%s' "${ESC}[?1049h${ESC}[?25l"
        _em_handle_resize
        _em_message="Resumed"
    }

    _em_handle_resize() {
        if [[ -n "$LINES" && -n "$COLUMNS" ]]; then
            _em_rows=$LINES; _em_cols=$COLUMNS
        else
            _em_rows=$(tput lines 2>/dev/null) || _em_rows=24
            _em_cols=$(tput cols 2>/dev/null) || _em_cols=80
        fi
    }

    _em_init() {
        _em_stty_saved=$(stty -g 2>/dev/null)
        _em_saved_traps=$(trap -p INT TERM HUP WINCH 2>/dev/null)
        stty raw -echo -isig -ixon -ixoff -icrnl intr undef quit undef susp undef lnext undef 2>/dev/null
        # No EXIT trap — dangerous for shell functions (lingers after return)
        trap '_em_cleanup; return 130' INT
        trap '_em_cleanup; return 143' TERM
        trap '_em_cleanup; return 129' HUP
        trap '_em_handle_resize' WINCH
        printf '%s' "${ESC}[?1049h${ESC}[?25h"
        _em_handle_resize
        if [[ -n "$1" ]]; then
            _em_new_buffer "$(basename "$1")" "$1"
            _em_load_file "$1"
        else
            _em_new_buffer "*scratch*" ""
        fi
        _em_message="em: bad emacs (C-x C-c to quit, C-h b for help)"
        # Detect system clipboard tool
        if command -v pbcopy >/dev/null 2>&1; then
            _em_clip_copy="pbcopy"; _em_clip_paste="pbpaste"
        elif command -v xclip >/dev/null 2>&1; then
            _em_clip_copy="xclip -selection clipboard"; _em_clip_paste="xclip -selection clipboard -o"
        elif command -v xsel >/dev/null 2>&1; then
            _em_clip_copy="xsel --clipboard --input"; _em_clip_paste="xsel --clipboard --output"
        fi
    }

    _em_load_file() {
        local file="$1" line
        _em_lines=()
        if [[ -f "$file" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                _em_lines+=("$line")
            done < "$file"
        fi
        [[ ${#_em_lines[@]} -eq 0 ]] && _em_lines=("")
        _em_filename="$file"
        _em_bufname=$(basename "$file")
        _em_modified=0
        _em_cy=0
        _em_cx=0
        _em_top=0
        _em_undo=()
    }

    # ===== ARRAY HELPERS (avoid O(N) full-array splices) =====

    _em_insert_line_at() {
        local -i pos=$1
        local -i len=${#_em_lines[@]}
        local -i i
        for ((i = len; i > pos; i--)); do
            _em_lines[i]="${_em_lines[i-1]}"
        done
        _em_lines[pos]="$2"
    }

    _em_delete_line_at() {
        local -i pos=$1
        local -i len=${#_em_lines[@]}
        local -i last=$((len - 1))
        local -i i
        for ((i = pos; i < last; i++)); do
            _em_lines[i]="${_em_lines[i+1]}"
        done
        unset "_em_lines[$last]"
    }

    _em_delete_lines_at() {
        local -i pos=$1 count=$2
        local -i len=${#_em_lines[@]}
        local -i new_len=$((len - count))
        local -i i
        for ((i = pos; i < new_len; i++)); do
            _em_lines[i]="${_em_lines[i+count]}"
        done
        for ((i = new_len; i < len; i++)); do
            unset "_em_lines[$i]"
        done
    }

    _em_splice_lines() {
        local -i start=$1 del_count=$2
        local -i new_count=${#_em_splice_new[@]}
        local -i len=${#_em_lines[@]}
        local -i diff=$((new_count - del_count))
        local -i i
        if ((diff > 0)); then
            for ((i = len + diff - 1; i >= start + new_count; i--)); do
                _em_lines[i]="${_em_lines[i-diff]}"
            done
        elif ((diff < 0)); then
            local -i new_len=$((len + diff))
            for ((i = start + new_count; i < new_len; i++)); do
                _em_lines[i]="${_em_lines[i-diff]}"
            done
            for ((i = new_len; i < len; i++)); do
                unset "_em_lines[$i]"
            done
        fi
        for ((i = 0; i < new_count; i++)); do
            _em_lines[start + i]="${_em_splice_new[i]}"
        done
    }

    # ===== UNDO SYSTEM =====

    _em_undo_push() {
        local record="$1${US}$2${US}$3"
        [[ -n "${4+x}" ]] && record+="${US}$4"
        _em_undo+=("$record")
        local -i _undo_max=200 _undo_trim=100
        if (( ${#_em_lines[@]} > 3000 )); then
            _undo_max=50; _undo_trim=25
        elif (( ${#_em_lines[@]} > 1000 )); then
            _undo_max=100; _undo_trim=50
        fi
        (( ${#_em_undo[@]} > _undo_max )) && _em_undo=("${_em_undo[@]:_undo_trim}")
    }

    _em_undo() {
        if [[ ${#_em_undo[@]} -eq 0 ]]; then
            _em_message="No further undo information"
            return
        fi
        local record="${_em_undo[-1]}"
        unset '_em_undo[-1]'
        local type arg1 arg2 arg3
        IFS="$US" read -r type arg1 arg2 arg3 <<< "$record"
        case "$type" in
            insert_char)
                local line="${_em_lines[arg1]}"
                _em_lines[arg1]="${line:0:arg2}${arg3}${line:arg2}"
                _em_cy=$arg1; _em_cx=$arg2
                ;;
            delete_char)
                local line="${_em_lines[arg1]}"
                _em_lines[arg1]="${line:0:arg2}${line:arg2+1}"
                _em_cy=$arg1; _em_cx=$arg2
                ;;
            join_lines)
                local line="${_em_lines[arg1]}"
                _em_lines[arg1]="${line:0:arg2}"
                _em_insert_line_at "$((arg1 + 1))" "${line:arg2}"
                _em_cy=$arg1; _em_cx=$arg2
                ;;
            split_line)
                local line="${_em_lines[arg1]}"
                local next="${_em_lines[arg1+1]}"
                _em_lines[arg1]="${line}${next}"
                _em_delete_line_at "$((arg1 + 1))"
                _em_cy=$arg1; _em_cx=$arg2
                ;;
            replace_line)
                _em_lines[arg1]="$arg3"
                _em_cy=$arg1; _em_cx=$arg2
                ;;
            replace_region)
                # arg1=start, arg2=new_count, arg3=packed (cy RS cx RS line0 RS line1 ...)
                local packed="$arg3"
                local -a rr_parts=()
                while [[ "$packed" == *"${RS}"* ]]; do
                    rr_parts+=("${packed%%"${RS}"*}")
                    packed="${packed#*"${RS}"}"
                done
                rr_parts+=("$packed")
                local -i rr_cy=${rr_parts[0]} rr_cx=${rr_parts[1]}
                local -a _em_splice_new=("${rr_parts[@]:2}")
                _em_splice_lines "$arg1" "$arg2"
                _em_cy=$rr_cy; _em_cx=$rr_cx
                ;;
        esac
        _em_modified=1
        _em_ensure_visible
        _em_message="Undo!"
    }

    _em_expand_tabs() {
        local line="$1"
        if [[ "$line" != *$'\t'* ]]; then
            _em_expanded_line="$line"
            return
        fi
        local result="" i ch col=0
        local -i len=${#line}
        for ((i = 0; i < len; i++)); do
            ch="${line:i:1}"
            if [[ "$ch" == $'\t' ]]; then
                local -i spaces=$((_em_tab_width - (col % _em_tab_width)))
                local pad=""
                printf -v pad '%*s' "$spaces" ''
                result+="$pad"
                ((col += spaces))
            else
                result+="$ch"
                ((col++))
            fi
        done
        _em_expanded_line="$result"
    }

    _em_col_to_display() {
        local line="$1"
        local -i target_col="$2"
        if [[ "$line" != *$'\t'* ]]; then
            _em_display_col=$target_col
            return
        fi
        local -i col=0 i len=${#line}
        for ((i = 0; i < len && i < target_col; i++)); do
            if [[ "${line:i:1}" == $'\t' ]]; then
                ((col += _em_tab_width - (col % _em_tab_width)))
            else
                ((col++))
            fi
        done
        _em_display_col=$col
    }

    _em_render() {
        local output=""
        local -i visible_rows=$((_em_rows - 2))
        local -i i screen_row

        output+="${ESC}[?25l"

        # Compute region bounds for highlighting
        local -i reg_active=0 reg_sy=-1 reg_sx=-1 reg_ey=-1 reg_ex=-1
        if ((_em_mark_y >= 0 && (_em_mark_y != _em_cy || _em_mark_x != _em_cx))); then
            reg_active=1
            reg_sy=$_em_mark_y; reg_sx=$_em_mark_x
            reg_ey=$_em_cy; reg_ex=$_em_cx
            if ((reg_sy > reg_ey || (reg_sy == reg_ey && reg_sx > reg_ex))); then
                local -i rt; rt=$reg_sy; reg_sy=$reg_ey; reg_ey=$rt
                rt=$reg_sx; reg_sx=$reg_ex; reg_ex=$rt
            fi
        fi

        for ((screen_row = 1; screen_row <= visible_rows; screen_row++)); do
            i=$((_em_top + screen_row - 1))
            output+="${ESC}[${screen_row};1H"
            if ((i < ${#_em_lines[@]})); then
                local line="${_em_lines[i]}"
                _em_expand_tabs "$line"
                local display="${_em_expanded_line}"
                if ((${#display} > _em_cols)); then
                    display="${display:0:_em_cols}"
                fi
                # Pad to full width to avoid ESC[K flicker
                local -i dlen=${#display}
                if ((dlen < _em_cols)); then
                    local pad=""
                    printf -v pad '%*s' "$((_em_cols - dlen))" ''
                    display+="$pad"
                fi
                # Isearch match highlighting (takes priority over region)
                if ((_em_isearch_active && _em_isearch_y >= 0 && i == _em_isearch_y)); then
                    _em_col_to_display "$line" "$_em_isearch_x"
                    local -i mhs=$_em_display_col
                    _em_col_to_display "$line" "$((_em_isearch_x + _em_isearch_len))"
                    local -i mhe=$_em_display_col
                    ((mhs > ${#display})) && mhs=${#display}
                    ((mhe > ${#display})) && mhe=${#display}
                    if ((mhs < mhe)); then
                        output+="${display:0:mhs}${ESC}[1;7m${display:mhs:mhe-mhs}${ESC}[0m${display:mhe}"
                    else
                        output+="$display"
                    fi
                # Region highlighting
                elif ((reg_active && i >= reg_sy && i <= reg_ey)); then
                    local -i hs=0 he=${#display}
                    if ((i == reg_sy)); then
                        _em_col_to_display "$line" "$reg_sx"
                        hs=$_em_display_col
                    fi
                    if ((i == reg_ey)); then
                        _em_col_to_display "$line" "$reg_ex"
                        he=$_em_display_col
                    fi
                    ((hs > ${#display})) && hs=${#display}
                    ((he > ${#display})) && he=${#display}
                    if ((hs < he)); then
                        output+="${display:0:hs}${ESC}[7m${display:hs:he-hs}${ESC}[0m${display:he}"
                    else
                        output+="$display"
                    fi
                else
                    output+="$display"
                fi
            else
                output+="${ESC}[K"
            fi
        done

        # Status line
        local -i status_row=$((_em_rows - 1))
        local mod_flag="--"
        ((_em_modified)) && mod_flag="**"
        local -i total=${#_em_lines[@]}
        local pct="All"
        if ((total > visible_rows)); then
            if ((_em_top == 0)); then
                pct="Top"
            elif ((_em_top + visible_rows >= total)); then
                pct="Bot"
            else
                pct="$(( (_em_top * 100) / (total - visible_rows) ))%"
            fi
        fi
        local status
        printf -v status '%s%s%s  %-20s  (Fundamental) L%-6d %s' \
            "-UUU:" "$mod_flag" "-" "$_em_bufname" "$((_em_cy + 1))" "$pct"
        local -i slen=${#status}
        if ((slen < _em_cols)); then
            local spad=""
            printf -v spad '%*s' "$((_em_cols - slen))" ''
            status+="${spad// /-}"
        fi
        status="${status:0:_em_cols}"
        output+="${ESC}[${status_row};1H${ESC}[7m${status}${ESC}[0m"

        # Message line
        local -i msg_row=$_em_rows
        output+="${ESC}[${msg_row};1H${ESC}[K"
        if [[ -n "$_em_message" ]]; then
            output+="${_em_message:0:_em_cols}"
            if ((!_em_msg_persist)); then
                _em_message=""
            fi
        fi

        # Position cursor
        local -i screen_cy=$((_em_cy - _em_top + 1))
        _em_col_to_display "${_em_lines[_em_cy]}" "$_em_cx"
        local -i screen_cx=$((_em_display_col + 1))
        output+="${ESC}[${screen_cy};${screen_cx}H"
        output+="${ESC}[?25h"

        printf '%s' "$output"
    }

    _em_read_key() {
        local char="" char2="" char3="" char4=""
        local -i rc ord

        IFS= read -rsn1 -d '' char
        rc=$?

        # Retry once on transient error (EAGAIN on some systems/PTYs)
        if ((rc != 0)) && [[ -z "$char" ]]; then
            IFS= read -rsn1 -d '' char
            rc=$?
        fi

        if [[ -z "$char" ]]; then
            if ((rc != 0)); then
                # EOF or error (disconnected terminal) — stop the editor
                _em_running=0
                _em_key="UNKNOWN"
                return
            fi
            # NUL byte — Ctrl-Space
            _em_key="C-SPC"
            return
        fi

        printf -v ord '%d' "'$char" 2>/dev/null || ord=0

        if ((ord == 27)); then
            IFS= read -rsn1 -d '' -t 0.05 char2
            if [[ -z "$char2" ]]; then
                # Bare ESC — return to dispatch, which routes to _em_read_meta_key
                # (shows "ESC-" feedback, reads next key, translates to M-*)
                _em_key="ESC"
                return
            fi
            if [[ "$char2" == "[" ]]; then
                IFS= read -rsn1 -d '' -t 0.05 char3
                case "$char3" in
                    A) _em_key="UP"; return;;
                    B) _em_key="DOWN"; return;;
                    C) _em_key="RIGHT"; return;;
                    D) _em_key="LEFT"; return;;
                    H) _em_key="HOME"; return;;
                    F) _em_key="END"; return;;
                    [0-9])
                        local seq="$char3"
                        while IFS= read -rsn1 -d '' -t 0.05 char4; do
                            seq+="$char4"
                            [[ "$char4" == "~" || "$char4" == [A-Za-z] ]] && break
                        done
                        case "$seq" in
                            3~) _em_key="DEL"; return;;
                            5~) _em_key="PGUP"; return;;
                            6~) _em_key="PGDN"; return;;
                            2~) _em_key="INS"; return;;
                            1~) _em_key="HOME"; return;;
                            4~) _em_key="END"; return;;
                            *) _em_key="UNKNOWN"; return;;
                        esac
                        ;;
                    Z) _em_key="SHIFT-TAB"; return;;
                    *) _em_key="UNKNOWN"; return;;
                esac
            elif [[ "$char2" == "O" ]]; then
                IFS= read -rsn1 -d '' -t 0.05 char3
                case "$char3" in
                    A) _em_key="UP";; B) _em_key="DOWN";;
                    C) _em_key="RIGHT";; D) _em_key="LEFT";;
                    H) _em_key="HOME";; F) _em_key="END";;
                    *) _em_key="UNKNOWN";;
                esac
                return
            else
                local -i ord2
                printf -v ord2 '%d' "'$char2" 2>/dev/null || ord2=0
                if ((ord2 == 127 || ord2 == 8)); then
                    _em_key="M-DEL"
                else
                    _em_key="M-${char2}"
                fi
                return
            fi
        elif ((ord >= 1 && ord <= 26)); then
            local letter="${_em_abc:ord-1:1}"
            _em_key="C-${letter}"
            return
        elif ((ord == 31)); then
            _em_key="C-_"
            return
        elif ((ord == 127 || ord == 8)); then
            _em_key="BACKSPACE"
            return
        elif ((ord == 0)); then
            _em_key="C-SPC"
            return
        else
            _em_key="SELF:${char}"
            return
        fi
    }

    _em_ensure_visible() {
        local -i total=${#_em_lines[@]}
        local -i visible=$((_em_rows - 2))
        local -i margin=$((_em_rows / 5))
        ((margin < 2)) && margin=2
        ((_em_cy < 0)) && _em_cy=0
        ((_em_cy >= total)) && _em_cy=$((total - 1))
        ((_em_cx < 0)) && _em_cx=0
        local -i line_len=${#_em_lines[_em_cy]}
        ((_em_cx > line_len)) && _em_cx=$line_len
        if ((_em_cy < _em_top + margin)); then
            _em_top=$((_em_cy - margin))
        fi
        if ((_em_cy >= _em_top + visible - margin)); then
            _em_top=$((_em_cy - visible + margin + 1))
        fi
        ((_em_top < 0)) && _em_top=0
    }

    # ===== MOVEMENT =====

    _em_forward_char() {
        local -i line_len=${#_em_lines[_em_cy]}
        if ((_em_cx < line_len)); then
            ((_em_cx++))
        elif ((_em_cy < ${#_em_lines[@]} - 1)); then
            ((_em_cy++))
            _em_cx=0
        fi
        _em_goal_col=-1
        _em_ensure_visible
    }

    _em_backward_char() {
        if ((_em_cx > 0)); then
            ((_em_cx--))
        elif ((_em_cy > 0)); then
            ((_em_cy--))
            _em_cx=${#_em_lines[_em_cy]}
        fi
        _em_goal_col=-1
        _em_ensure_visible
    }

    _em_next_line() {
        if ((_em_cy < ${#_em_lines[@]} - 1)); then
            ((_em_goal_col < 0)) && _em_goal_col=$_em_cx
            ((_em_cy++))
            local -i line_len=${#_em_lines[_em_cy]}
            _em_cx=$_em_goal_col
            ((_em_cx > line_len)) && _em_cx=$line_len
        fi
        _em_ensure_visible
    }

    _em_previous_line() {
        if ((_em_cy > 0)); then
            ((_em_goal_col < 0)) && _em_goal_col=$_em_cx
            ((_em_cy--))
            local -i line_len=${#_em_lines[_em_cy]}
            _em_cx=$_em_goal_col
            ((_em_cx > line_len)) && _em_cx=$line_len
        fi
        _em_ensure_visible
    }

    _em_beginning_of_line() {
        _em_cx=0
        _em_goal_col=-1
        _em_ensure_visible
    }

    _em_end_of_line() {
        _em_cx=${#_em_lines[_em_cy]}
        _em_goal_col=-1
        _em_ensure_visible
    }

    _em_beginning_of_buffer() {
        _em_cy=0
        _em_cx=0
        _em_goal_col=-1
        _em_ensure_visible
    }

    _em_end_of_buffer() {
        _em_cy=$((${#_em_lines[@]} - 1))
        _em_cx=${#_em_lines[_em_cy]}
        _em_goal_col=-1
        _em_ensure_visible
    }

    _em_scroll_down() {
        local -i visible=$((_em_rows - 2))
        local -i page=$((visible - 2))
        ((page < 1)) && page=1
        ((_em_top += page))
        ((_em_cy += page))
        _em_goal_col=-1
        _em_ensure_visible
    }

    _em_scroll_up() {
        local -i visible=$((_em_rows - 2))
        local -i page=$((visible - 2))
        ((page < 1)) && page=1
        ((_em_top -= page))
        ((_em_top < 0)) && _em_top=0
        ((_em_cy -= page))
        _em_goal_col=-1
        _em_ensure_visible
    }

    _em_recenter() {
        local -i visible=$((_em_rows - 2))
        _em_top=$((_em_cy - visible / 2))
        ((_em_top < 0)) && _em_top=0
    }

    _em_indent_line() {
        local -i sy ey
        if ((_em_mark_y >= 0)); then
            sy=$_em_mark_y; ey=$_em_cy
            ((sy > ey)) && { local -i t=$sy; sy=$ey; ey=$t; }
        else
            sy=$_em_cy; ey=$_em_cy
        fi
        local packed="${_em_cy}${RS}${_em_cx}"
        local -i j
        for ((j = sy; j <= ey; j++)); do
            packed+="${RS}${_em_lines[j]}"
        done
        _em_undo_push "replace_region" "$sy" "$((ey - sy + 1))" "$packed"
        for ((j = sy; j <= ey; j++)); do
            _em_lines[j]="  ${_em_lines[j]}"
        done
        ((_em_cx += 2))
        _em_mark_y=-1; _em_mark_x=-1
        _em_modified=1
        _em_goal_col=-1
    }

    _em_dedent_line() {
        local -i sy ey
        if ((_em_mark_y >= 0)); then
            sy=$_em_mark_y; ey=$_em_cy
            ((sy > ey)) && { local -i t=$sy; sy=$ey; ey=$t; }
        else
            sy=$_em_cy; ey=$_em_cy
        fi
        # First pass: compute new lines and track changes
        local -i cx_adj=0 changed=0
        local -a dl_new=()
        local -i j
        for ((j = sy; j <= ey; j++)); do
            local dl="${_em_lines[j]}"
            local -i dr=0
            if [[ "$dl" == "  "* ]]; then
                dl_new+=("${dl:2}"); dr=2
            elif [[ "$dl" == " "* ]]; then
                dl_new+=("${dl:1}"); dr=1
            else
                dl_new+=("$dl")
            fi
            ((dr > 0)) && ((changed++))
            ((j == _em_cy)) && cx_adj=$dr
        done
        if ((changed > 0)); then
            local packed="${_em_cy}${RS}${_em_cx}"
            for ((j = sy; j <= ey; j++)); do
                packed+="${RS}${_em_lines[j]}"
            done
            _em_undo_push "replace_region" "$sy" "$((ey - sy + 1))" "$packed"
            for ((j = sy; j <= ey; j++)); do
                _em_lines[j]="${dl_new[j - sy]}"
            done
            ((_em_cx -= cx_adj))
            ((_em_cx < 0)) && _em_cx=0
            _em_modified=1
        fi
        _em_mark_y=-1; _em_mark_x=-1
        _em_goal_col=-1
    }

    # ===== BASIC EDITING =====

    _em_self_insert() {
        local ch="$1"
        local line="${_em_lines[_em_cy]}"
        _em_undo_push "delete_char" "$_em_cy" "$_em_cx"
        _em_lines[_em_cy]="${line:0:_em_cx}${ch}${line:_em_cx}"
        ((_em_cx++))
        _em_modified=1
        _em_goal_col=-1
    }

    _em_newline() {
        local line="${_em_lines[_em_cy]}"
        local before="${line:0:_em_cx}"
        local after="${line:_em_cx}"
        _em_undo_push "split_line" "$_em_cy" "$_em_cx"
        _em_lines[_em_cy]="$before"
        _em_insert_line_at "$((_em_cy + 1))" "$after"
        ((_em_cy++))
        _em_cx=0
        _em_modified=1
        _em_goal_col=-1
        _em_ensure_visible
    }

    _em_open_line() {
        local line="${_em_lines[_em_cy]}"
        local before="${line:0:_em_cx}"
        local after="${line:_em_cx}"
        _em_undo_push "split_line" "$_em_cy" "$_em_cx"
        _em_lines[_em_cy]="$before"
        _em_insert_line_at "$((_em_cy + 1))" "$after"
        _em_modified=1
    }

    _em_delete_char() {
        local line="${_em_lines[_em_cy]}"
        local -i line_len=${#line}
        if ((_em_cx < line_len)); then
            local deleted="${line:_em_cx:1}"
            _em_undo_push "insert_char" "$_em_cy" "$_em_cx" "$deleted"
            _em_lines[_em_cy]="${line:0:_em_cx}${line:_em_cx+1}"
            _em_modified=1
        elif ((_em_cy < ${#_em_lines[@]} - 1)); then
            _em_undo_push "join_lines" "$_em_cy" "$_em_cx"
            _em_lines[_em_cy]="${line}${_em_lines[_em_cy+1]}"
            _em_delete_line_at "$((_em_cy + 1))"
            _em_modified=1
        fi
        _em_goal_col=-1
    }

    _em_backward_delete_char() {
        if ((_em_cx > 0)); then
            ((_em_cx--))
            _em_delete_char
        elif ((_em_cy > 0)); then
            ((_em_cy--))
            _em_cx=${#_em_lines[_em_cy]}
            _em_delete_char
        fi
        _em_goal_col=-1
        _em_ensure_visible
    }

    # ===== CLIPBOARD =====

    _em_clipboard_copy() {
        [[ -n "$_em_clip_copy" ]] && printf '%s' "$1" | eval "$_em_clip_copy" 2>/dev/null
    }

    _em_clipboard_paste() {
        [[ -n "$_em_clip_paste" ]] && eval "$_em_clip_paste" 2>/dev/null
    }

    # ===== KILL / YANK (basic) =====

    _em_kill_line() {
        local line="${_em_lines[_em_cy]}"
        local -i line_len=${#line}
        if ((_em_cx < line_len)); then
            local killed="${line:_em_cx}"
            _em_undo_push "replace_line" "$_em_cy" "$_em_cx" "$line"
            _em_lines[_em_cy]="${line:0:_em_cx}"
            if [[ "$_em_last_cmd" == "C-k" ]]; then
                _em_kill_ring[0]+="$killed"
            else
                _em_kill_ring=("$killed" "${_em_kill_ring[@]}")
            fi
        else
            if ((_em_cy < ${#_em_lines[@]} - 1)); then
                local next="${_em_lines[_em_cy+1]}"
                _em_undo_push "join_lines" "$_em_cy" "$_em_cx"
                _em_lines[_em_cy]="${line}${next}"
                _em_delete_line_at "$((_em_cy + 1))"
                local killed=$'\n'
                if [[ "$_em_last_cmd" == "C-k" ]]; then
                    _em_kill_ring[0]+="$killed"
                else
                    _em_kill_ring=("$killed" "${_em_kill_ring[@]}")
                fi
            fi
        fi
        (( ${#_em_kill_ring[@]} > 60 )) && _em_kill_ring=("${_em_kill_ring[@]:0:60}")
        _em_clipboard_copy "${_em_kill_ring[0]}"
        _em_modified=1
        _em_goal_col=-1
    }

    _em_yank() {
        if [[ ${#_em_kill_ring[@]} -eq 0 ]]; then
            _em_message="Kill ring is empty"
            return
        fi
        local text="${_em_kill_ring[0]}"
        # Save state for undo
        local -i save_cy=$_em_cy save_cx=$_em_cx
        local save_line="${_em_lines[_em_cy]}"
        _em_mark_y=$_em_cy
        _em_mark_x=$_em_cx
        # Insert text which may contain newlines
        local -a parts=()
        local tmp="$text"
        while [[ "$tmp" == *$'\n'* ]]; do
            parts+=("${tmp%%$'\n'*}")
            tmp="${tmp#*$'\n'}"
        done
        parts+=("$tmp")
        if [[ ${#parts[@]} -eq 1 ]]; then
            local line="${_em_lines[_em_cy]}"
            _em_lines[_em_cy]="${line:0:_em_cx}${parts[0]}${line:_em_cx}"
            ((_em_cx += ${#parts[0]}))
            _em_undo_push "replace_region" "$save_cy" "1" "${save_cy}${RS}${save_cx}${RS}${save_line}"
        else
            local line="${_em_lines[_em_cy]}"
            local before="${line:0:_em_cx}"
            local after="${line:_em_cx}"
            _em_lines[_em_cy]="${before}${parts[0]}"
            local -i j
            local -a new_lines=()
            for ((j = 1; j < ${#parts[@]} - 1; j++)); do
                new_lines+=("${parts[j]}")
            done
            local last_part="${parts[-1]}"
            new_lines+=("${last_part}${after}")
            local -a _em_splice_new=("${new_lines[@]}")
            _em_splice_lines "$((_em_cy + 1))" 0
            _em_cy=$((_em_cy + ${#parts[@]} - 1))
            _em_cx=${#last_part}
            _em_undo_push "replace_region" "$save_cy" "${#parts[@]}" "${save_cy}${RS}${save_cx}${RS}${save_line}"
        fi
        _em_modified=1
        _em_goal_col=-1
        _em_ensure_visible
    }

    # ===== MARK / REGION =====

    _em_set_mark() {
        _em_mark_y=$_em_cy
        _em_mark_x=$_em_cx
        _em_message="Mark set"
    }

    _em_mark_whole_buffer() {
        _em_mark_y=0
        _em_mark_x=0
        _em_cy=$(( ${#_em_lines[@]} - 1 ))
        _em_cx=${#_em_lines[$_em_cy]}
        _em_goal_col=-1
        _em_ensure_visible
        _em_message="Mark set"
    }

    _em_exchange_point_and_mark() {
        if ((_em_mark_y >= 0)); then
            local -i ty=$_em_cy tx=$_em_cx
            _em_cy=$_em_mark_y
            _em_cx=$_em_mark_x
            _em_mark_y=$ty
            _em_mark_x=$tx
            _em_goal_col=-1
            _em_ensure_visible
        else
            _em_message="No mark set in this buffer"
        fi
    }

    _em_kill_region() {
        if ((_em_mark_y < 0)); then
            _em_message="The mark is not set now"
            return
        fi
        local -i sy=$_em_mark_y sx=$_em_mark_x ey=$_em_cy ex=$_em_cx
        if ((sy > ey || (sy == ey && sx > ex))); then
            local -i t; t=$sy; sy=$ey; ey=$t; t=$sx; sx=$ex; ex=$t
        fi
        # Save original lines for undo before modifying
        local packed="${_em_cy}${RS}${_em_cx}"
        local -i j
        for ((j = sy; j <= ey; j++)); do
            packed+="${RS}${_em_lines[j]}"
        done
        local killed=""
        if ((sy == ey)); then
            killed="${_em_lines[sy]:sx:ex-sx}"
            local line="${_em_lines[sy]}"
            _em_lines[sy]="${line:0:sx}${line:ex}"
        else
            killed="${_em_lines[sy]:sx}"
            for ((j = sy + 1; j < ey; j++)); do
                killed+=$'\n'"${_em_lines[j]}"
            done
            killed+=$'\n'"${_em_lines[ey]:0:ex}"
            local first_part="${_em_lines[sy]:0:sx}"
            local last_part="${_em_lines[ey]:ex}"
            _em_lines[sy]="${first_part}${last_part}"
            if ((ey > sy)); then
                _em_delete_lines_at "$((sy + 1))" "$((ey - sy))"
            fi
        fi
        # After kill, 1 line at sy holds the merged result
        _em_undo_push "replace_region" "$sy" "1" "$packed"
        _em_kill_ring=("$killed" "${_em_kill_ring[@]}")
        (( ${#_em_kill_ring[@]} > 60 )) && _em_kill_ring=("${_em_kill_ring[@]:0:60}")
        _em_clipboard_copy "$killed"
        _em_cy=$sy
        _em_cx=$sx
        _em_mark_y=-1
        _em_mark_x=-1
        _em_modified=1
        _em_goal_col=-1
        _em_ensure_visible
    }

    _em_copy_region() {
        if ((_em_mark_y < 0)); then
            _em_message="The mark is not set now"
            return
        fi
        local -i sy=$_em_mark_y sx=$_em_mark_x ey=$_em_cy ex=$_em_cx
        if ((sy > ey || (sy == ey && sx > ex))); then
            local -i t; t=$sy; sy=$ey; ey=$t; t=$sx; sx=$ex; ex=$t
        fi
        local copied=""
        if ((sy == ey)); then
            copied="${_em_lines[sy]:sx:ex-sx}"
        else
            copied="${_em_lines[sy]:sx}"
            local -i j
            for ((j = sy + 1; j < ey; j++)); do
                copied+=$'\n'"${_em_lines[j]}"
            done
            copied+=$'\n'"${_em_lines[ey]:0:ex}"
        fi
        _em_kill_ring=("$copied" "${_em_kill_ring[@]}")
        (( ${#_em_kill_ring[@]} > 60 )) && _em_kill_ring=("${_em_kill_ring[@]:0:60}")
        _em_clipboard_copy "$copied"
        _em_message="Region copied"
    }

    # ===== RECTANGLE COMMANDS =====

    _em_rect_bounds() {
        # Normalize mark/point into top-left (sy,sx) and bottom-right (ey,ex) columns
        _em_rect_sy=$_em_mark_y; _em_rect_sx=$_em_mark_x
        _em_rect_ey=$_em_cy; _em_rect_ex=$_em_cx
        if ((_em_rect_sy > _em_rect_ey)); then
            local -i t=$_em_rect_sy; _em_rect_sy=$_em_rect_ey; _em_rect_ey=$t
        fi
        if ((_em_rect_sx > _em_rect_ex)); then
            local -i t=$_em_rect_sx; _em_rect_sx=$_em_rect_ex; _em_rect_ex=$t
        fi
    }

    _em_kill_rectangle() {
        if ((_em_mark_y < 0)); then
            _em_message="The mark is not set now"
            return
        fi
        local -i _em_rect_sy _em_rect_sx _em_rect_ey _em_rect_ex
        _em_rect_bounds
        # Save for undo
        local packed="${_em_cy}${RS}${_em_cx}"
        local -i j
        for ((j = _em_rect_sy; j <= _em_rect_ey; j++)); do
            packed+="${RS}${_em_lines[j]}"
        done
        _em_rect_kill=()
        for ((j = _em_rect_sy; j <= _em_rect_ey; j++)); do
            local line="${_em_lines[j]}"
            local -i ll=${#line}
            local -i sx=$_em_rect_sx ex=$_em_rect_ex
            ((sx > ll)) && sx=$ll
            ((ex > ll)) && ex=$ll
            _em_rect_kill+=("${line:sx:ex-sx}")
            _em_lines[j]="${line:0:sx}${line:ex}"
        done
        local -i nlines=$((_em_rect_ey - _em_rect_sy + 1))
        _em_undo_push "replace_region" "$_em_rect_sy" "$nlines" "$packed"
        _em_clipboard_copy "$(printf '%s\n' "${_em_rect_kill[@]}")"
        _em_cy=$_em_rect_sy; _em_cx=$_em_rect_sx
        _em_mark_y=-1; _em_mark_x=-1
        _em_modified=1
        _em_message="Rectangle killed"
    }

    _em_yank_rectangle() {
        if [[ ${#_em_rect_kill[@]} -eq 0 ]]; then
            _em_message="No rectangle to yank"
            return
        fi
        # Save for undo
        local packed="${_em_cy}${RS}${_em_cx}"
        local -i nrect=${#_em_rect_kill[@]}
        local -i j
        # Ensure enough lines exist
        while (( ${#_em_lines[@]} < _em_cy + nrect )); do
            _em_lines+=("")
        done
        for ((j = 0; j < nrect; j++)); do
            packed+="${RS}${_em_lines[_em_cy + j]}"
        done
        for ((j = 0; j < nrect; j++)); do
            local line="${_em_lines[_em_cy + j]}"
            local rect_str="${_em_rect_kill[j]}"
            local -i ll=${#line}
            # Pad with spaces if line is shorter than cursor column
            if ((ll < _em_cx)); then
                local pad=""
                printf -v pad '%*s' "$((_em_cx - ll))" ''
                line+="$pad"
            fi
            _em_lines[_em_cy + j]="${line:0:_em_cx}${rect_str}${line:_em_cx}"
        done
        _em_undo_push "replace_region" "$_em_cy" "$nrect" "$packed"
        _em_modified=1
        _em_message="Rectangle yanked"
    }

    _em_string_rectangle() {
        if ((_em_mark_y < 0)); then
            _em_message="The mark is not set now"
            return
        fi
        _em_minibuffer_read "String rectangle: " "" || return
        local str="$_em_mb_result"
        local -i _em_rect_sy _em_rect_sx _em_rect_ey _em_rect_ex
        _em_rect_bounds
        # Save for undo
        local packed="${_em_cy}${RS}${_em_cx}"
        local -i j
        for ((j = _em_rect_sy; j <= _em_rect_ey; j++)); do
            packed+="${RS}${_em_lines[j]}"
        done
        for ((j = _em_rect_sy; j <= _em_rect_ey; j++)); do
            local line="${_em_lines[j]}"
            local -i ll=${#line}
            local -i sx=$_em_rect_sx ex=$_em_rect_ex
            ((sx > ll)) && sx=$ll
            ((ex > ll)) && ex=$ll
            _em_lines[j]="${line:0:sx}${str}${line:ex}"
        done
        local -i nlines=$((_em_rect_ey - _em_rect_sy + 1))
        _em_undo_push "replace_region" "$_em_rect_sy" "$nlines" "$packed"
        _em_mark_y=-1; _em_mark_x=-1
        _em_modified=1
        _em_message="String rectangle done"
    }

    _em_open_rectangle() {
        if ((_em_mark_y < 0)); then
            _em_message="The mark is not set now"
            return
        fi
        local -i _em_rect_sy _em_rect_sx _em_rect_ey _em_rect_ex
        _em_rect_bounds
        local -i width=$((_em_rect_ex - _em_rect_sx))
        ((width <= 0)) && return
        # Save for undo
        local packed="${_em_cy}${RS}${_em_cx}"
        local pad=""
        printf -v pad '%*s' "$width" ''
        local -i j
        for ((j = _em_rect_sy; j <= _em_rect_ey; j++)); do
            packed+="${RS}${_em_lines[j]}"
        done
        for ((j = _em_rect_sy; j <= _em_rect_ey; j++)); do
            local line="${_em_lines[j]}"
            local -i ll=${#line}
            local -i sx=$_em_rect_sx
            ((sx > ll)) && sx=$ll
            _em_lines[j]="${line:0:sx}${pad}${line:sx}"
        done
        local -i nlines=$((_em_rect_ey - _em_rect_sy + 1))
        _em_undo_push "replace_region" "$_em_rect_sy" "$nlines" "$packed"
        _em_mark_y=-1; _em_mark_x=-1
        _em_modified=1
        _em_message="Open rectangle done"
    }

    _em_read_cx_r_key() {
        _em_message="C-x r-"
        _em_render
        _em_read_key
        # Record for macros
        if ((_em_recording)); then
            _em_macro_keys+=("$_em_key")
        fi
        case "$_em_key" in
            "k"|"SELF:k") _em_kill_rectangle;;
            "y"|"SELF:y") _em_yank_rectangle;;
            "t"|"SELF:t") _em_string_rectangle;;
            "o"|"SELF:o") _em_open_rectangle;;
            *)     _em_message="C-x r ${_em_key} is undefined";;
        esac
    }

    # ===== SEARCH (basic) =====

    _em_isearch_forward() {
        _em_isearch 1
    }

    _em_isearch_backward() {
        _em_isearch -1
    }

    _em_strstr() {
        local haystack="$1" needle="$2"
        local -i start="${3:-0}"
        if [[ -z "$needle" ]]; then
            _em_found_pos=$start
            return 0
        fi
        local sub="${haystack:start}"
        # Use [[ ]] — quoted $needle is treated as literal, unlike case patterns
        if [[ "$sub" == *"$needle"* ]]; then
            local prefix="${sub%%"$needle"*}"
            _em_found_pos=$((start + ${#prefix}))
            return 0
        fi
        return 1
    }

    _em_isearch() {
        local -i dir="$1"
        local search=""
        local -i orig_y=$_em_cy orig_x=$_em_cx orig_top=$_em_top
        local -i found_y=$_em_cy found_x=$_em_cx
        local -i isearch_running=1
        _em_isearch_active=1
        _em_isearch_y=-1; _em_isearch_x=-1; _em_isearch_len=0

        while ((isearch_running)); do
            local prompt
            if ((dir == 1)); then
                prompt="I-search: ${search}"
            else
                prompt="I-search backward: ${search}"
            fi
            printf '%s' "${ESC}[${_em_rows};1H${ESC}[K${prompt:0:_em_cols}"
            printf '%s' "${ESC}[${_em_rows};$((${#prompt} + 1))H"

            _em_read_key
            case "$_em_key" in
                "C-g")
                    _em_cy=$orig_y; _em_cx=$orig_x; _em_top=$orig_top
                    _em_message="Quit"
                    _em_isearch_active=0
                    isearch_running=0
                    ;;
                "C-s")
                    dir=1
                    if [[ -n "$search" ]]; then
                        _em_isearch_next "$search" 1 "$found_y" "$((found_x + 1))"
                        if (($?)); then
                            _em_message="Failing I-search: ${search}"
                            _em_isearch_y=-1
                        else
                            found_y=$_em_cy; found_x=$_em_cx
                            _em_isearch_y=$found_y; _em_isearch_x=$found_x; _em_isearch_len=${#search}
                            _em_ensure_visible
                            _em_render
                        fi
                    fi
                    ;;
                "C-r")
                    dir=-1
                    if [[ -n "$search" ]]; then
                        _em_isearch_next "$search" -1 "$found_y" "$((found_x - 1))"
                        if (($?)); then
                            _em_message="Failing I-search backward: ${search}"
                            _em_isearch_y=-1
                        else
                            found_y=$_em_cy; found_x=$_em_cx
                            _em_isearch_y=$found_y; _em_isearch_x=$found_x; _em_isearch_len=${#search}
                            _em_ensure_visible
                            _em_render
                        fi
                    fi
                    ;;
                "C-m"|"C-j"|"ESC")
                    _em_search_str="$search"
                    _em_isearch_active=0
                    isearch_running=0
                    ;;
                "BACKSPACE")
                    if [[ -n "$search" ]]; then
                        search="${search:0:${#search}-1}"
                        _em_cy=$orig_y; _em_cx=$orig_x
                        if [[ -n "$search" ]]; then
                            _em_isearch_next "$search" "$dir" "$orig_y" "$orig_x"
                            if ((!$?)); then
                                found_y=$_em_cy; found_x=$_em_cx
                                _em_isearch_y=$found_y; _em_isearch_x=$found_x; _em_isearch_len=${#search}
                                _em_ensure_visible
                                _em_render
                            else
                                _em_isearch_y=-1
                            fi
                        else
                            found_y=$orig_y; found_x=$orig_x
                            _em_isearch_y=-1
                            _em_ensure_visible
                            _em_render
                        fi
                    fi
                    ;;
                SELF:*)
                    search+="${_em_key#SELF:}"
                    _em_isearch_next "$search" "$dir" "$found_y" "$found_x"
                    if (($?)); then
                        _em_message="Failing I-search: ${search}"
                        _em_isearch_y=-1
                    else
                        found_y=$_em_cy; found_x=$_em_cx
                        _em_isearch_y=$found_y; _em_isearch_x=$found_x; _em_isearch_len=${#search}
                        _em_ensure_visible
                        _em_render
                    fi
                    ;;
                *)
                    _em_search_str="$search"
                    _em_isearch_active=0
                    isearch_running=0
                    _em_dispatch
                    return
                    ;;
            esac
        done
    }

    _em_isearch_next() {
        local needle="$1"
        local -i dir="$2" start_y="$3" start_x="$4"
        local -i i total=${#_em_lines[@]}

        if ((dir == 1)); then
            for ((i = start_y; i < total; i++)); do
                local -i from=0
                ((i == start_y)) && from=$start_x
                if _em_strstr "${_em_lines[i]}" "$needle" "$from"; then
                    _em_cy=$i; _em_cx=$_em_found_pos
                    return 0
                fi
            done
        else
            for ((i = start_y; i >= 0; i--)); do
                local line="${_em_lines[i]}"
                local -i max_start
                if ((i == start_y)); then
                    max_start=$start_x
                else
                    max_start=${#line}
                fi
                local -i last_found=-1 pos=0
                while _em_strstr "$line" "$needle" "$pos"; do
                    if ((_em_found_pos <= max_start)); then
                        last_found=$_em_found_pos
                        ((pos = _em_found_pos + 1))
                    else
                        break
                    fi
                done
                if ((last_found >= 0)); then
                    _em_cy=$i; _em_cx=$last_found
                    return 0
                fi
            done
        fi
        return 1
    }

    # ===== MINIBUFFER =====

    _em_minibuffer_read() {
        local prompt="$1" input="${2:-}" comp_type="${3:-}"
        local -i cursor=${#input}
        local -i mb_running=1

        while ((mb_running)); do
            local display="${prompt}${input}"
            printf '%s' "${ESC}[${_em_rows};1H${ESC}[K${display:0:_em_cols}"
            local -i cpos=$((${#prompt} + cursor + 1))
            printf '%s' "${ESC}[${_em_rows};${cpos}H"

            _em_read_key
            case "$_em_key" in
                "C-g")
                    _em_mb_result=""
                    _em_message="Quit"
                    return 1
                    ;;
                "C-m"|"C-j")
                    mb_running=0
                    ;;
                "C-a"|"HOME")
                    cursor=0
                    ;;
                "C-e"|"END")
                    cursor=${#input}
                    ;;
                "C-f"|"RIGHT")
                    ((cursor < ${#input})) && ((cursor++))
                    ;;
                "C-b"|"LEFT")
                    ((cursor > 0)) && ((cursor--))
                    ;;
                "C-d"|"DEL")
                    if ((cursor < ${#input})); then
                        input="${input:0:cursor}${input:cursor+1}"
                    fi
                    ;;
                "BACKSPACE")
                    if ((cursor > 0)); then
                        ((cursor--))
                        input="${input:0:cursor}${input:cursor+1}"
                    fi
                    ;;
                "C-k")
                    input="${input:0:cursor}"
                    ;;
                "C-i")
                    if [[ -n "$comp_type" ]]; then
                        _em_complete "$input" "$comp_type"
                        if [[ -n "$_em_comp_result" ]]; then
                            input="$_em_comp_result"
                            cursor=${#input}
                        fi
                    fi
                    ;;
                SELF:*)
                    local ch="${_em_key#SELF:}"
                    input="${input:0:cursor}${ch}${input:cursor}"
                    ((cursor++))
                    ;;
            esac
        done

        _em_mb_result="$input"
        return 0
    }

    _em_complete() {
        local input="$1" type="$2"
        _em_comp_result=""
        case "$type" in
            file)    _em_complete_file "$input";;
            buffer)  _em_complete_buffer "$input";;
            command) _em_complete_command "$input";;
        esac
    }

    _em_complete_file() {
        local input="$1"
        local expanded="${input/#\~/$HOME}"
        local -a matches=()
        local f
        for f in ${expanded}*; do
            [[ -e "$f" ]] || continue
            matches+=("$f")
        done
        if [[ ${#matches[@]} -eq 0 ]]; then
            _em_message="[No match]"
            return
        fi
        if [[ ${#matches[@]} -eq 1 ]]; then
            local result="${matches[0]}"
            [[ "$result" == "$HOME"/* && "$input" == "~"* ]] && result="~${result#$HOME}"
            [[ -d "${matches[0]}" ]] && result+="/"
            _em_comp_result="$result"
            return
        fi
        # Multiple matches: find common prefix
        local prefix="${matches[0]}"
        local m
        for m in "${matches[@]:1}"; do
            while [[ ${#prefix} -gt 0 && "$m" != "$prefix"* ]]; do
                prefix="${prefix:0:${#prefix}-1}"
            done
        done
        [[ "$prefix" == "$HOME"/* && "$input" == "~"* ]] && prefix="~${prefix#$HOME}"
        _em_comp_result="$prefix"
        # Show matches if no progress
        if [[ "$input" == "$_em_comp_result" ]]; then
            local display="" base
            for m in "${matches[@]}"; do
                base=$(basename "$m")
                [[ -d "$m" ]] && base+="/"
                [[ -n "$display" ]] && display+="  "
                display+="$base"
            done
            _em_message="{${display}}"
        fi
    }

    _em_complete_buffer() {
        local input="$1"
        local -a matches=()
        local bid name
        for bid in "${_em_buf_ids[@]}"; do
            name="${_em_bufs["${bid}_name"]}"
            [[ "$name" == "$input"* ]] && matches+=("$name")
        done
        if [[ ${#matches[@]} -eq 0 ]]; then
            _em_message="[No match]"
            return
        fi
        if [[ ${#matches[@]} -eq 1 ]]; then
            _em_comp_result="${matches[0]}"
            return
        fi
        local prefix="${matches[0]}"
        local m
        for m in "${matches[@]:1}"; do
            while [[ ${#prefix} -gt 0 && "$m" != "$prefix"* ]]; do
                prefix="${prefix:0:${#prefix}-1}"
            done
        done
        _em_comp_result="$prefix"
        if [[ "$input" == "$_em_comp_result" ]]; then
            _em_message="{$(printf '%s  ' "${matches[@]}")}"
        fi
    }

    _em_complete_command() {
        local input="$1"
        local -a commands=(
            "goto-line" "what-line" "set-fill-column" "query-replace"
            "save-buffer" "find-file" "write-file" "insert-file"
            "kill-buffer" "switch-to-buffer" "list-buffers"
            "save-buffers-kill-emacs" "describe-bindings" "help"
            "clipboard-yank" "what-cursor-position"
        )
        local -a matches=()
        local cmd
        for cmd in "${commands[@]}"; do
            [[ "$cmd" == "$input"* ]] && matches+=("$cmd")
        done
        if [[ ${#matches[@]} -eq 0 ]]; then
            _em_message="[No match]"
            return
        fi
        if [[ ${#matches[@]} -eq 1 ]]; then
            _em_comp_result="${matches[0]}"
            return
        fi
        local prefix="${matches[0]}"
        local m
        for m in "${matches[@]:1}"; do
            while [[ ${#prefix} -gt 0 && "$m" != "$prefix"* ]]; do
                prefix="${prefix:0:${#prefix}-1}"
            done
        done
        _em_comp_result="$prefix"
        if [[ "$input" == "$_em_comp_result" ]]; then
            _em_message="{$(printf '%s  ' "${matches[@]}")}"
        fi
    }

    # ===== FILE I/O =====

    _em_save_buffer() {
        if [[ -z "$_em_filename" ]]; then
            _em_write_file
            return
        fi
        local tmpfile="${_em_filename}.em$$"
        {
            local -i i
            for ((i = 0; i < ${#_em_lines[@]}; i++)); do
                ((i > 0)) && printf '\n'
                printf '%s' "${_em_lines[i]}"
            done
            printf '\n'
        } > "$tmpfile" 2>/dev/null
        if [[ $? -ne 0 ]]; then
            rm -f "$tmpfile" 2>/dev/null
            _em_message="Error writing to ${_em_filename}"
            return
        fi
        mv "$tmpfile" "$_em_filename" 2>/dev/null
        if [[ $? -ne 0 ]]; then
            rm -f "$tmpfile" 2>/dev/null
            _em_message="Error saving ${_em_filename}"
            return
        fi
        _em_modified=0
        _em_message="Wrote ${#_em_lines[@]} lines to ${_em_filename}"
    }

    _em_find_file() {
        local default="${_em_filename:-$PWD/}"
        [[ -n "$_em_filename" ]] && default="$(dirname "$_em_filename")/"
        _em_minibuffer_read "Find file: " "$default" "file" || return
        local path="$_em_mb_result"
        [[ -z "$path" ]] && return
        path="${path/#\~/$HOME}"
        # Check if already open in a buffer
        if _em_find_buf_by_filename "$path"; then
            _em_save_buffer_state
            _em_restore_buffer_state "$_em_found_buf"
            _em_message="$_em_bufname"
            return
        fi
        # Save current buffer, create new one
        _em_save_buffer_state
        _em_new_buffer "$(basename "$path")" "$path"
        _em_load_file "$path"
        _em_message="$_em_bufname"
    }

    _em_write_file() {
        local default="${_em_filename:-$PWD/}"
        _em_minibuffer_read "Write file: " "$default" "file" || return
        local path="$_em_mb_result"
        [[ -z "$path" ]] && return
        path="${path/#\~/$HOME}"
        _em_filename="$path"
        _em_bufname=$(basename "$path")
        _em_save_buffer
    }

    _em_insert_file() {
        _em_minibuffer_read "Insert file: " "$PWD/" "file" || return
        local path="$_em_mb_result"
        [[ -z "$path" ]] && return
        path="${path/#\~/$HOME}"
        if [[ ! -f "$path" ]]; then
            _em_message="File not found: $path"
            return
        fi
        local -a flines=()
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do
            flines+=("$line")
        done < "$path"
        [[ ${#flines[@]} -eq 0 ]] && return
        # Save state for undo
        local -i save_cy=$_em_cy save_cx=$_em_cx
        local save_line="${_em_lines[_em_cy]}"
        # Insert at cursor position
        local cur_line="${_em_lines[_em_cy]}"
        local before="${cur_line:0:_em_cx}"
        local after="${cur_line:_em_cx}"
        if [[ ${#flines[@]} -eq 1 ]]; then
            _em_lines[_em_cy]="${before}${flines[0]}${after}"
            ((_em_cx += ${#flines[0]}))
            _em_undo_push "replace_region" "$save_cy" "1" "${save_cy}${RS}${save_cx}${RS}${save_line}"
        else
            _em_lines[_em_cy]="${before}${flines[0]}"
            local -i insert_at=$((_em_cy + 1))
            local -a mid=()
            local -i j
            for ((j = 1; j < ${#flines[@]} - 1; j++)); do
                mid+=("${flines[j]}")
            done
            local last="${flines[-1]}${after}"
            mid+=("$last")
            local -a _em_splice_new=("${mid[@]}")
            _em_splice_lines "$insert_at" 0
            _em_cy=$((_em_cy + ${#flines[@]} - 1))
            _em_cx=${#flines[-1]}
            _em_undo_push "replace_region" "$save_cy" "${#flines[@]}" "${save_cy}${RS}${save_cx}${RS}${save_line}"
        fi
        _em_modified=1
        _em_message="Inserted file: $(basename "$path")"
        _em_ensure_visible
    }

    # ===== BUFFER MANAGEMENT =====

    _em_save_buffer_state() {
        local bid=$_em_cur_buf
        _em_bufs["${bid}_cy"]=$_em_cy
        _em_bufs["${bid}_cx"]=$_em_cx
        _em_bufs["${bid}_top"]=$_em_top
        _em_bufs["${bid}_mark_y"]=$_em_mark_y
        _em_bufs["${bid}_mark_x"]=$_em_mark_x
        _em_bufs["${bid}_modified"]=$_em_modified
        _em_bufs["${bid}_filename"]=$_em_filename
        _em_bufs["${bid}_name"]=$_em_bufname
        _em_bufs["${bid}_goal_col"]=$_em_goal_col
        local -i nlines=${#_em_lines[@]}
        _em_bufs["${bid}_nlines"]=$nlines
        local -i i
        # Clear old lines that may be stale if buffer shrank
        local -i old_n=${_em_bufs["${bid}_old_nlines"]:-0}
        for ((i = nlines; i < old_n; i++)); do
            unset "_em_bufs[${bid}_line_${i}]" 2>/dev/null
        done
        _em_bufs["${bid}_old_nlines"]=$nlines
        for ((i = 0; i < nlines; i++)); do
            _em_bufs["${bid}_line_${i}"]="${_em_lines[i]}"
        done
        # Serialize undo stack (GS separates records; RS is used within replace_region)
        local undo_str="" record
        for record in "${_em_undo[@]}"; do
            [[ -n "$undo_str" ]] && undo_str+="$GS"
            undo_str+="$record"
        done
        _em_bufs["${bid}_undo"]="$undo_str"
    }

    _em_restore_buffer_state() {
        local bid=$1
        _em_cur_buf=$bid
        _em_cy=${_em_bufs["${bid}_cy"]:-0}
        _em_cx=${_em_bufs["${bid}_cx"]:-0}
        _em_top=${_em_bufs["${bid}_top"]:-0}
        _em_mark_y=${_em_bufs["${bid}_mark_y"]:-"-1"}
        _em_mark_x=${_em_bufs["${bid}_mark_x"]:-"-1"}
        _em_modified=${_em_bufs["${bid}_modified"]:-0}
        _em_filename="${_em_bufs["${bid}_filename"]}"
        _em_bufname="${_em_bufs["${bid}_name"]}"
        _em_goal_col=${_em_bufs["${bid}_goal_col"]:-"-1"}
        local -i nlines=${_em_bufs["${bid}_nlines"]:-1}
        _em_lines=()
        local -i i
        for ((i = 0; i < nlines; i++)); do
            _em_lines+=("${_em_bufs["${bid}_line_${i}"]}")
        done
        [[ ${#_em_lines[@]} -eq 0 ]] && _em_lines=("")
        # Restore undo stack (GS separates records)
        _em_undo=()
        local undo_str="${_em_bufs["${bid}_undo"]}" record
        if [[ -n "$undo_str" ]]; then
            while IFS= read -r -d "$GS" record; do
                _em_undo+=("$record")
            done <<< "${undo_str}${GS}"
        fi
    }

    _em_new_buffer() {
        local name="${1:-*scratch*}"
        local file="${2:-}"
        local bid=$_em_buf_count
        ((_em_buf_count++))
        _em_buf_ids+=("$bid")
        _em_bufs["${bid}_name"]="$name"
        _em_bufs["${bid}_filename"]="$file"
        _em_bufs["${bid}_cy"]=0
        _em_bufs["${bid}_cx"]=0
        _em_bufs["${bid}_top"]=0
        _em_bufs["${bid}_mark_y"]=-1
        _em_bufs["${bid}_mark_x"]=-1
        _em_bufs["${bid}_modified"]=0
        _em_bufs["${bid}_goal_col"]=-1
        _em_bufs["${bid}_nlines"]=1
        _em_bufs["${bid}_old_nlines"]=1
        _em_bufs["${bid}_line_0"]=""
        _em_bufs["${bid}_undo"]=""
        _em_cur_buf=$bid
        _em_bufname="$name"
        _em_filename="$file"
        _em_cy=0; _em_cx=0; _em_top=0
        _em_mark_y=-1; _em_mark_x=-1
        _em_modified=0; _em_goal_col=-1
        _em_lines=("")
        _em_undo=()
    }

    _em_find_buf_by_filename() {
        local file="$1"
        local bid
        for bid in "${_em_buf_ids[@]}"; do
            if [[ "${_em_bufs["${bid}_filename"]}" == "$file" ]]; then
                _em_found_buf=$bid
                return 0
            fi
        done
        return 1
    }

    _em_switch_buffer() {
        if [[ ${#_em_buf_ids[@]} -lt 2 ]]; then
            _em_message="Only one buffer"
            return
        fi
        # Build buffer name list for prompt
        local names=""
        local bid default_name=""
        for bid in "${_em_buf_ids[@]}"; do
            ((bid == _em_cur_buf)) && continue
            [[ -n "$names" ]] && names+=", "
            names+="${_em_bufs["${bid}_name"]}"
            [[ -z "$default_name" ]] && default_name="${_em_bufs["${bid}_name"]}"
        done
        _em_minibuffer_read "Switch to buffer (${names}): " "" "buffer" || return
        local target="${_em_mb_result:-$default_name}"
        [[ -z "$target" ]] && return
        for bid in "${_em_buf_ids[@]}"; do
            if [[ "${_em_bufs["${bid}_name"]}" == "$target" ]]; then
                _em_save_buffer_state
                _em_restore_buffer_state "$bid"
                return
            fi
        done
        _em_message="No buffer named '${target}'"
    }

    _em_kill_buffer() {
        if [[ ${#_em_buf_ids[@]} -le 1 ]]; then
            _em_message="Cannot kill the only buffer"
            return
        fi
        _em_minibuffer_read "Kill buffer (default ${_em_bufname}): " "" "buffer" || return
        local target="${_em_mb_result:-$_em_bufname}"
        local -i target_bid=-1
        local bid
        for bid in "${_em_buf_ids[@]}"; do
            if [[ "${_em_bufs["${bid}_name"]}" == "$target" ]]; then
                target_bid=$bid
                break
            fi
        done
        if ((target_bid < 0)); then
            _em_message="No buffer named '${target}'"
            return
        fi
        # Check if modified
        local -i is_mod
        if ((target_bid == _em_cur_buf)); then
            is_mod=$_em_modified
        else
            is_mod=${_em_bufs["${target_bid}_modified"]:-0}
        fi
        if ((is_mod)) && [[ "${_em_bufs["${target_bid}_name"]}" != "*scratch*" ]]; then
            _em_minibuffer_read "Buffer ${target} modified; kill anyway? (yes or no) " || return
            [[ "$_em_mb_result" != "yes" ]] && { _em_message="Cancelled"; return; }
        fi
        # Remove from buf_ids
        local -a new_ids=()
        for bid in "${_em_buf_ids[@]}"; do
            ((bid != target_bid)) && new_ids+=("$bid")
        done
        _em_buf_ids=("${new_ids[@]}")
        # Clean up assoc array keys
        local -i n=${_em_bufs["${target_bid}_nlines"]:-0}
        local -i i
        for ((i = 0; i < n; i++)); do
            unset "_em_bufs[${target_bid}_line_${i}]" 2>/dev/null
        done
        local k
        for k in cy cx top mark_y mark_x modified filename name goal_col nlines old_nlines undo; do
            unset "_em_bufs[${target_bid}_${k}]" 2>/dev/null
        done
        # Switch to another buffer if we killed the current one
        if ((target_bid == _em_cur_buf)); then
            _em_restore_buffer_state "${_em_buf_ids[0]}"
        fi
        _em_message="Killed buffer '${target}'"
    }

    _em_list_buffers() {
        _em_save_buffer_state
        _em_lines=()
        local header
        printf -v header ' %-3s %-20s %8s  %s' "MR" "Buffer" "Size" "File"
        _em_lines+=("$header")
        printf -v header ' %-3s %-20s %8s  %s' "---" "--------------------" "--------" "----"
        _em_lines+=("$header")
        local bid
        for bid in "${_em_buf_ids[@]}"; do
            local bname="${_em_bufs["${bid}_name"]}"
            local bfile="${_em_bufs["${bid}_filename"]}"
            local -i bmod=${_em_bufs["${bid}_modified"]:-0}
            local -i bnlines=${_em_bufs["${bid}_nlines"]:-0}
            local mod_ch=" "
            ((bmod)) && mod_ch="*"
            local cur_ch=" "
            ((bid == _em_cur_buf)) && cur_ch="."
            local entry
            printf -v entry ' %s%s  %-20s %8d  %s' "$cur_ch" "$mod_ch" "$bname" "$bnlines" "$bfile"
            _em_lines+=("$entry")
        done
        _em_lines+=("")
        _em_lines+=("[Press C-g or q to return]")
        _em_cy=0; _em_cx=0; _em_top=0
        _em_bufname="*Buffer List*"
        _em_filename=""
        _em_modified=0
        _em_message=""
        local -i list_running=1
        while ((list_running)); do
            _em_render
            _em_read_key
            case "$_em_key" in
                "C-g"|"SELF:q") list_running=0;;
                "C-n"|"DOWN") _em_next_line;;
                "C-p"|"UP") _em_previous_line;;
                "C-v"|"PGDN") _em_scroll_down;;
                "M-v"|"PGUP") _em_scroll_up;;
            esac
        done
        # Restore
        _em_restore_buffer_state "$_em_cur_buf"
        _em_message=""
    }

    # ===== QUIT =====

    _em_quit() {
        # Save current state so we can check all buffers
        _em_save_buffer_state
        local -i unsaved=0
        local bid
        for bid in "${_em_buf_ids[@]}"; do
            local bname="${_em_bufs["${bid}_name"]}"
            local -i bmod=${_em_bufs["${bid}_modified"]:-0}
            if ((bmod)) && [[ "$bname" != "*scratch*" ]]; then
                ((unsaved++))
            fi
        done
        if ((unsaved > 0)); then
            _em_minibuffer_read "${unsaved} modified buffer(s) not saved; exit anyway? (yes or no) " || return
            if [[ "$_em_mb_result" != "yes" ]]; then
                _em_message="Cancelled"
                return
            fi
        fi
        _em_running=0
    }

    # ===== CURSOR POSITION =====

    _em_what_cursor_position() {
        local -i line_num=$((_em_cy + 1))
        local -i col_num=$((_em_cx + 1))
        local -i total=${#_em_lines[@]}
        local ch_info=""
        local line="${_em_lines[_em_cy]}"
        if ((_em_cx < ${#line})); then
            local ch="${line:_em_cx:1}"
            local -i ord
            printf -v ord '%d' "'$ch" 2>/dev/null || ord=0
            printf -v ch_info "Char: %s (%d, #o%o, #x%x)" "$ch" "$ord" "$ord" "$ord"
        else
            ch_info="Char: EOL"
        fi
        _em_message="Line ${line_num}/${total}, Column ${col_num} -- ${ch_info}"
    }

    _em_keyboard_quit() {
        _em_mark_y=-1
        _em_mark_x=-1
        _em_arg=0
        _em_arg_active=0
        _em_message="Quit"
    }

    # ===== WORD OPERATIONS =====

    _em_is_word_char() {
        [[ "$1" == [A-Za-z0-9_] ]]
    }

    _em_forward_word() {
        local -i cy=$_em_cy cx=$_em_cx
        local -i total=${#_em_lines[@]}
        local line
        # Skip non-word chars first
        while true; do
            line="${_em_lines[cy]}"
            while ((cx < ${#line})) && ! _em_is_word_char "${line:cx:1}"; do
                ((cx++))
            done
            if ((cx < ${#line})); then break; fi
            if ((cy >= total - 1)); then break; fi
            ((cy++)); cx=0
        done
        # Skip word chars
        while true; do
            line="${_em_lines[cy]}"
            while ((cx < ${#line})) && _em_is_word_char "${line:cx:1}"; do
                ((cx++))
            done
            break
        done
        _em_cy=$cy; _em_cx=$cx
        _em_goal_col=-1
        _em_ensure_visible
    }

    _em_backward_word() {
        local -i cy=$_em_cy cx=$_em_cx
        local line
        # Move back one to start examining
        if ((cx > 0)); then
            ((cx--))
        elif ((cy > 0)); then
            ((cy--)); cx=${#_em_lines[cy]}
            ((cx > 0)) && ((cx--))
        else
            return
        fi
        # Skip non-word chars backward
        while true; do
            line="${_em_lines[cy]}"
            while ((cx >= 0)) && ((cx < ${#line})) && ! _em_is_word_char "${line:cx:1}"; do
                ((cx--))
            done
            if ((cx >= 0)) && ((cx < ${#line})); then break; fi
            if ((cy <= 0)); then cx=0; break; fi
            ((cy--)); cx=$((${#_em_lines[cy]} - 1))
        done
        # Skip word chars backward
        line="${_em_lines[cy]}"
        while ((cx > 0)) && _em_is_word_char "${line:cx-1:1}"; do
            ((cx--))
        done
        _em_cy=$cy; _em_cx=$cx
        _em_goal_col=-1
        _em_ensure_visible
    }

    _em_kill_word() {
        local -i sy=$_em_cy sx=$_em_cx
        _em_set_mark
        _em_forward_word
        if ((_em_cy != sy || _em_cx != sx)); then
            _em_kill_region
        fi
    }

    _em_backward_kill_word() {
        local -i sy=$_em_cy sx=$_em_cx
        _em_set_mark
        _em_backward_word
        if ((_em_cy != sy || _em_cx != sx)); then
            _em_kill_region
        fi
    }

    # ===== TRANSPOSE =====

    _em_transpose_chars() {
        local line="${_em_lines[_em_cy]}"
        local -i len=${#line}
        if ((len < 2)); then return; fi
        # At end of line, transpose the two chars before cursor
        local -i p=$_em_cx
        if ((p >= len)); then p=$((len - 1)); fi
        if ((p < 1)); then return; fi
        local a="${line:p-1:1}" b="${line:p:1}"
        _em_undo_push "replace_line" "$_em_cy" "$_em_cx" "$line"
        _em_lines[_em_cy]="${line:0:p-1}${b}${a}${line:p+1}"
        _em_cx=$((p + 1))
        ((_em_cx > len)) && _em_cx=$len
        _em_modified=1
        _em_goal_col=-1
    }

    # ===== UNIVERSAL ARGUMENT =====

    _em_universal_argument() {
        local -i arg=4 multiplied=0
        _em_message="C-u-"
        _em_render
        _em_read_key
        # Check for digits
        local -i has_digits=0
        while [[ "$_em_key" == SELF:[0-9] ]]; do
            if ((!has_digits)); then
                arg=0
                has_digits=1
            fi
            arg=$((arg * 10 + ${_em_key#SELF:}))
            _em_message="C-u ${arg}-"
            _em_render
            _em_read_key
        done
        # Check for additional C-u (multiply by 4)
        while [[ "$_em_key" == "C-u" ]]; do
            arg=$((arg * 4))
            _em_message="C-u ${arg}-"
            _em_render
            _em_read_key
        done
        # Execute the final key arg times
        local -i i
        for ((i = 0; i < arg; i++)); do
            _em_dispatch
        done
    }

    # ===== QUOTED INSERT =====

    _em_quoted_insert() {
        _em_message="C-q-"
        _em_render
        _em_read_key
        if [[ "$_em_key" == SELF:* ]]; then
            _em_self_insert "${_em_key#SELF:}"
        elif [[ "$_em_key" == "C-j" ]]; then
            _em_newline
        elif [[ "$_em_key" == "C-i" ]]; then
            _em_self_insert $'\t'
        else
            # Insert the control char literally
            local ch
            case "$_em_key" in
                C-?) ch="${_em_key#C-}"
                     local -i ord
                     ord=$(printf '%d' "'$ch" 2>/dev/null) || ord=0
                     ((ord >= 97 && ord <= 122)) && ord=$((ord - 96))
                     printf -v ch "\\x$(printf '%02x' "$ord")"
                     _em_self_insert "$ch"
                     ;;
                *) _em_message="Cannot insert: $_em_key";;
            esac
        fi
    }

    # ===== QUERY REPLACE =====

    _em_query_replace() {
        _em_minibuffer_read "Query replace: " "" || return
        local from="$_em_mb_result"
        [[ -z "$from" ]] && return
        _em_minibuffer_read "Query replace ${from} with: " "" || return
        local to="$_em_mb_result"
        local -i count=0
        while _em_isearch_next "$from" 1 "$_em_cy" "$_em_cx"; do
            _em_ensure_visible
            _em_render
            printf '%s' "${ESC}[${_em_rows};1H${ESC}[KQuery replacing ${from} with ${to}: (y/n/!/q/.) "
            _em_read_key
            case "$_em_key" in
                "SELF:y"|"C-m")
                    local line="${_em_lines[_em_cy]}"
                    _em_undo_push "replace_line" "$_em_cy" "$_em_cx" "$line"
                    _em_lines[_em_cy]="${line:0:_em_cx}${to}${line:_em_cx+${#from}}"
                    ((_em_cx += ${#to}))
                    ((count++))
                    _em_modified=1
                    ;;
                "SELF:n"|"BACKSPACE")
                    ((_em_cx++))
                    ;;
                "SELF:!")
                    local line="${_em_lines[_em_cy]}"
                    _em_undo_push "replace_line" "$_em_cy" "$_em_cx" "$line"
                    _em_lines[_em_cy]="${line:0:_em_cx}${to}${line:_em_cx+${#from}}"
                    ((_em_cx += ${#to}))
                    ((count++))
                    _em_modified=1
                    while _em_isearch_next "$from" 1 "$_em_cy" "$_em_cx"; do
                        line="${_em_lines[_em_cy]}"
                        _em_undo_push "replace_line" "$_em_cy" "$_em_cx" "$line"
                        _em_lines[_em_cy]="${line:0:_em_cx}${to}${line:_em_cx+${#from}}"
                        ((_em_cx += ${#to}))
                        ((count++))
                        _em_modified=1
                    done
                    break
                    ;;
                "SELF:q"|"C-g"|"SELF:.")
                    [[ "$_em_key" == "SELF:." ]] && {
                        local line="${_em_lines[_em_cy]}"
                        _em_undo_push "replace_line" "$_em_cy" "$_em_cx" "$line"
                        _em_lines[_em_cy]="${line:0:_em_cx}${to}${line:_em_cx+${#from}}"
                        ((count++))
                        _em_modified=1
                    }
                    break
                    ;;
            esac
        done
        _em_message="Replaced ${count} occurrence$( ((count != 1)) && echo s)"
    }

    # ===== M-x EXTENDED COMMANDS =====

    _em_execute_extended() {
        _em_minibuffer_read "M-x " "" "command" || return
        local cmd="$_em_mb_result"
        [[ -z "$cmd" ]] && return
        case "$cmd" in
            goto-line)
                _em_minibuffer_read "Goto line: " "" || return
                local n="$_em_mb_result"
                if [[ "$n" =~ ^[0-9]+$ ]]; then
                    _em_cy=$((n - 1))
                    _em_cx=0
                    _em_ensure_visible
                else
                    _em_message="Invalid line number"
                fi
                ;;
            what-line)
                _em_message="Line $((_em_cy + 1))"
                ;;
            set-fill-column)
                _em_minibuffer_read "Set fill column to: " "$_em_fill_column" || return
                if [[ "$_em_mb_result" =~ ^[0-9]+$ ]]; then
                    _em_fill_column=$_em_mb_result
                    _em_message="Fill column set to $_em_fill_column"
                fi
                ;;
            query-replace)
                _em_query_replace
                ;;
            save-buffer)
                _em_save_buffer
                ;;
            find-file)
                _em_find_file
                ;;
            write-file)
                _em_write_file
                ;;
            insert-file)
                _em_insert_file
                ;;
            kill-buffer)
                _em_kill_buffer
                ;;
            switch-to-buffer)
                _em_switch_buffer
                ;;
            list-buffers)
                _em_list_buffers
                ;;
            save-buffers-kill-emacs)
                _em_quit
                ;;
            describe-bindings|help)
                _em_show_bindings
                ;;
            clipboard-yank)
                local clip_text
                clip_text=$(_em_clipboard_paste)
                if [[ -n "$clip_text" ]]; then
                    _em_kill_ring=("$clip_text" "${_em_kill_ring[@]}")
                    (( ${#_em_kill_ring[@]} > 60 )) && _em_kill_ring=("${_em_kill_ring[@]:0:60}")
                    _em_yank
                else
                    _em_message="System clipboard is empty"
                fi
                ;;
            *)
                _em_message="Unknown command: $cmd"
                ;;
        esac
    }

    _em_show_bindings() {
        local -a saved_lines=("${_em_lines[@]}")
        local -i saved_cy=$_em_cy saved_cx=$_em_cx saved_top=$_em_top
        local -i saved_mod=$_em_modified
        local saved_name="$_em_bufname" saved_file="$_em_filename"
        local row=""
        _em_lines=()
        _em_lines+=("em keybindings")
        _em_lines+=("==============")
        _em_lines+=("")
        printf -v row '%-38s  %s' "FILE / BUFFER" "EDITING"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x C-c   Quit" "C-d / DEL   Delete char fwd"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x C-s   Save buffer" "BACKSPACE   Delete char bkwd"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x C-f   Find (open) file" "C-k         Kill to end of line"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x C-w   Write file (save as)" "C-y         Yank (paste)"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x i     Insert file" "C-w         Kill region"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x b     Switch buffer" "M-w         Copy region"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x k     Kill buffer" "C-SPC / M-SPC  Set mark"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x C-b   List buffers" "C-t         Transpose chars"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x h     Mark whole buffer" "M-d / M-DEL Kill word fwd/bkwd"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x =     What cursor position" "M-c/l/u     Cap/down/upcase word"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x C-x   Exchange pt/mark" "C-i / TAB   Indent line (+2 sp)"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x u / C-_   Undo" "SHIFT-TAB   Dedent line (-2 sp)"
        _em_lines+=("$row")
        _em_lines+=("")
        printf -v row '%-38s  %s' "MOVEMENT" "SEARCH"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-f / RIGHT   Forward char" "C-s         Isearch forward"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-b / LEFT    Backward char" "C-r         Isearch backward"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-n / DOWN    Next line" "M-%         Query replace"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-p / UP      Previous line" ""
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-a / HOME    Beginning of line" "MISC"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-e / END     End of line" "C-o         Open line"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "M-f / M-b     Fwd/bkwd word" "C-u N       Universal argument"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "M-< / M->     Beg/end of buffer" "C-q         Quoted insert"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-v / PGDN    Page down" "M-q         Fill paragraph"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "M-v / PGUP    Page up" "M-x         Extended command"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-l           Recenter" "C-g         Cancel"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-z           Suspend" "C-h b       Describe bindings"
        _em_lines+=("$row")
        _em_lines+=("")
        printf -v row '%-38s  %s' "RECTANGLES (C-x r)" "MACROS (C-x)"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x r k   Kill rectangle" "C-x (       Start macro"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x r y   Yank rectangle" "C-x )       Stop macro"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x r t   String rectangle" "C-x e       Execute macro"
        _em_lines+=("$row")
        printf -v row '%-38s  %s' "C-x r o   Open rectangle" ""
        _em_lines+=("$row")
        _em_lines+=("")
        _em_lines+=("TAB   Complete in minibuffer (file/buffer/command)")
        _em_lines+=("M-x goto-line           Go to line number")
        _em_lines+=("M-x clipboard-yank      Paste from OS clipboard")
        _em_lines+=("M-x describe-bindings   Show this help")
        _em_lines+=("")
        _em_lines+=("[Press C-g or q to return]")
        _em_cy=0; _em_cx=0; _em_top=0
        _em_bufname="*Help*"
        _em_filename=""
        _em_modified=0
        _em_message="Press C-g or q to return"
        local -i help_running=1
        while ((help_running)); do
            _em_render
            _em_read_key
            case "$_em_key" in
                "C-g"|"SELF:q") help_running=0;;
                "C-n"|"DOWN") _em_next_line;;
                "C-p"|"UP") _em_previous_line;;
                "C-v"|"PGDN") _em_scroll_down;;
                "M-v"|"PGUP") _em_scroll_up;;
                "M-<") _em_beginning_of_buffer;;
                "M->") _em_end_of_buffer;;
            esac
        done
        _em_lines=("${saved_lines[@]}")
        _em_cy=$saved_cy; _em_cx=$saved_cx; _em_top=$saved_top
        _em_modified=$saved_mod
        _em_bufname="$saved_name"; _em_filename="$saved_file"
        _em_message=""
    }

    # ===== CASE CONVERSION =====

    _em_capitalize_word() {
        local line="${_em_lines[_em_cy]}"
        local -i cx=$_em_cx len=${#line}
        if ((cx >= len)); then return; fi
        _em_undo_push "replace_line" "$_em_cy" "$_em_cx" "$line"
        # Skip non-word chars
        while ((cx < len)) && ! _em_is_word_char "${line:cx:1}"; do
            ((cx++))
        done
        # Capitalize first word char, lowercase rest
        local -i first=1
        while ((cx < len)) && _em_is_word_char "${line:cx:1}"; do
            local ch="${line:cx:1}"
            if ((first)); then
                ch="${ch^}"
                first=0
            else
                ch="${ch,}"
            fi
            line="${line:0:cx}${ch}${line:cx+1}"
            ((cx++))
        done
        _em_lines[_em_cy]="$line"
        _em_cx=$cx
        _em_modified=1
        _em_goal_col=-1
    }

    _em_upcase_word() {
        local line="${_em_lines[_em_cy]}"
        local -i cx=$_em_cx len=${#line}
        if ((cx >= len)); then return; fi
        _em_undo_push "replace_line" "$_em_cy" "$_em_cx" "$line"
        while ((cx < len)) && ! _em_is_word_char "${line:cx:1}"; do
            ((cx++))
        done
        while ((cx < len)) && _em_is_word_char "${line:cx:1}"; do
            local ch="${line:cx:1}"
            ch="${ch^^}"
            line="${line:0:cx}${ch}${line:cx+1}"
            ((cx++))
        done
        _em_lines[_em_cy]="$line"
        _em_cx=$cx
        _em_modified=1
        _em_goal_col=-1
    }

    _em_downcase_word() {
        local line="${_em_lines[_em_cy]}"
        local -i cx=$_em_cx len=${#line}
        if ((cx >= len)); then return; fi
        _em_undo_push "replace_line" "$_em_cy" "$_em_cx" "$line"
        while ((cx < len)) && ! _em_is_word_char "${line:cx:1}"; do
            ((cx++))
        done
        while ((cx < len)) && _em_is_word_char "${line:cx:1}"; do
            local ch="${line:cx:1}"
            ch="${ch,,}"
            line="${line:0:cx}${ch}${line:cx+1}"
            ((cx++))
        done
        _em_lines[_em_cy]="$line"
        _em_cx=$cx
        _em_modified=1
        _em_goal_col=-1
    }

    # ===== FILL PARAGRAPH =====

    _em_fill_paragraph() {
        # Find paragraph boundaries (blank lines)
        local -i start=$_em_cy end=$_em_cy
        local -i total=${#_em_lines[@]}
        while ((start > 0)) && [[ -n "${_em_lines[start-1]}" ]] && \
              [[ "${_em_lines[start-1]}" =~ [^[:space:]] ]]; do
            ((start--))
        done
        while ((end < total - 1)) && [[ -n "${_em_lines[end+1]}" ]] && \
              [[ "${_em_lines[end+1]}" =~ [^[:space:]] ]]; do
            ((end++))
        done
        # Join all paragraph lines
        local text=""
        local -i i
        for ((i = start; i <= end; i++)); do
            [[ -n "$text" ]] && text+=" "
            # Collapse whitespace
            local stripped="${_em_lines[i]}"
            stripped="${stripped#"${stripped%%[![:space:]]*}"}"
            text+="$stripped"
        done
        # Re-wrap at fill column
        local -a new_lines=()
        while [[ ${#text} -gt $_em_fill_column ]]; do
            local -i break_at=$_em_fill_column
            while ((break_at > 0)) && [[ "${text:break_at:1}" != " " ]]; do
                ((break_at--))
            done
            if ((break_at == 0)); then
                # No space found; break at fill column
                break_at=$_em_fill_column
            fi
            new_lines+=("${text:0:break_at}")
            text="${text:break_at}"
            text="${text# }"  # Remove leading space
        done
        [[ -n "$text" ]] && new_lines+=("$text")
        [[ ${#new_lines[@]} -eq 0 ]] && new_lines=("")
        # Push undo for original region
        local packed="${_em_cy}${RS}${_em_cx}"
        for ((i = start; i <= end; i++)); do
            packed+="${RS}${_em_lines[i]}"
        done
        # Replace lines
        local -a _em_splice_new=("${new_lines[@]}")
        _em_splice_lines "$start" "$((end - start + 1))"
        _em_undo_push "replace_region" "$start" "${#new_lines[@]}" "$packed"
        _em_cy=$start
        _em_cx=0
        _em_modified=1
        _em_ensure_visible
        _em_message="Filled paragraph"
    }

    # ===== KEYBOARD MACROS =====

    _em_start_macro() {
        _em_recording=1
        _em_macro_keys=()
        _em_message="Defining keyboard macro..."
    }

    _em_end_macro() {
        _em_recording=0
        _em_message="Keyboard macro defined"
    }

    _em_execute_macro() {
        if [[ ${#_em_macro_keys[@]} -eq 0 ]]; then
            _em_message="No keyboard macro defined"
            return
        fi
        local saved_recording=$_em_recording
        _em_recording=0
        local k
        for k in "${_em_macro_keys[@]}"; do
            _em_key="$k"
            _em_dispatch
        done
        _em_recording=$saved_recording
    }

    # ===== DISPATCH =====

    _em_read_help_key() {
        _em_message="C-h-"
        _em_render
        _em_read_key
        case "$_em_key" in
            "b"|"SELF:b") _em_show_bindings;;
            *) _em_message="C-h ${_em_key}: no help available";;
        esac
    }

    _em_read_meta_key() {
        _em_message="ESC-"
        _em_render
        _em_read_key
        # Translate the next key into its Meta equivalent
        case "$_em_key" in
            SELF:*) _em_key="M-${_em_key#SELF:}";;
            C-*)    _em_key="M-${_em_key}";;  # ESC C-x etc.
            *)      _em_key="M-${_em_key}";;
        esac
        # Record for macros
        if ((_em_recording)); then
            _em_macro_keys+=("ESC" "$_em_key")
        fi
        _em_dispatch
    }

    _em_read_cx_key() {
        _em_message="C-x-"
        _em_render
        _em_read_key
        # Record C-x + second key for macros (but not C-x ( or C-x ))
        if ((_em_recording)) && [[ "$_em_key" != "SELF:)" && "$_em_key" != ")" ]]; then
            _em_macro_keys+=("C-x" "$_em_key")
        fi
        case "$_em_key" in
            "C-c") _em_quit;;
            "C-s") _em_save_buffer;;
            "C-f") _em_find_file;;
            "C-w") _em_write_file;;
            "C-x") _em_exchange_point_and_mark;;
            "u"|"SELF:u") _em_undo;;
            "k"|"SELF:k") _em_kill_buffer;;
            "b"|"SELF:b") _em_switch_buffer;;
            "C-b") _em_list_buffers;;
            "h"|"SELF:h") _em_mark_whole_buffer;;
            "i"|"SELF:i") _em_insert_file;;
            "="|"SELF:=") _em_what_cursor_position;;
            "("|"SELF:(") _em_start_macro;;
            ")"|"SELF:)") _em_end_macro;;
            "e"|"SELF:e") _em_execute_macro;;
            "r"|"SELF:r") _em_read_cx_r_key;;
            *)     _em_message="C-x ${_em_key} is undefined";;
        esac
    }

    _em_dispatch() {
        # Record macro keys (skip C-x, it's handled in _em_read_cx_key)
        if ((_em_recording)) && [[ "$_em_key" != "C-x" && "$_em_key" != "ESC" ]]; then
            _em_macro_keys+=("$_em_key")
        fi
        case "$_em_key" in
            "C-x")    _em_read_cx_key;;
            "ESC")    _em_read_meta_key;;
            "C-f"|"RIGHT")  _em_forward_char;;
            "C-b"|"LEFT")   _em_backward_char;;
            "C-n"|"DOWN")   _em_next_line;;
            "C-p"|"UP")     _em_previous_line;;
            "C-a"|"HOME")   _em_beginning_of_line;;
            "C-e"|"END")    _em_end_of_line;;
            "C-v"|"PGDN")   _em_scroll_down;;
            "M-v"|"PGUP")   _em_scroll_up;;
            "M-<")          _em_beginning_of_buffer;;
            "M->")          _em_end_of_buffer;;
            "C-d"|"DEL")    _em_delete_char;;
            "BACKSPACE")    _em_backward_delete_char;;
            "C-k")          _em_kill_line;;
            "C-y")          _em_yank;;
            "C-w")          _em_kill_region;;
            "M-w")          _em_copy_region;;
            "C-SPC"|"M- ")  _em_set_mark;;
            "C-l")          _em_recenter;;
            "C-g")          _em_keyboard_quit;;
            "C-h")          _em_read_help_key;;
            "C-s")          _em_isearch_forward;;
            "C-r")          _em_isearch_backward;;
            "C-o")          _em_open_line;;
            "C-m")          _em_newline;;
            "C-j")          _em_newline;;
            "C-t")          _em_transpose_chars;;
            "C-u")          _em_universal_argument;;
            "C-q")          _em_quoted_insert;;

            "C-_")          _em_undo;;
            "C-z")          _em_suspend;;
            "C-i")          _em_indent_line;;
            "SHIFT-TAB")    _em_dedent_line;;
            "M-f")          _em_forward_word;;
            "M-b")          _em_backward_word;;
            "M-d")          _em_kill_word;;
            "M-DEL")        _em_backward_kill_word;;
            "M-%")          _em_query_replace;;
            "M-x")          _em_execute_extended;;
            "M-q")          _em_fill_paragraph;;
            "M-c")          _em_capitalize_word;;
            "M-l")          _em_downcase_word;;
            "M-u")          _em_upcase_word;;
            SELF:*)         _em_self_insert "${_em_key#SELF:}";;
            "UNKNOWN"|"INS") ;;
            *)              _em_message="${_em_key} is undefined";;
        esac
        _em_last_cmd="$_em_key"
    }

    # ===== MAIN =====

    _em_init "$@"

    while :; do
        ((_em_running)) || break
        _em_render
        _em_read_key
        _em_dispatch
    done

    _em_cleanup
    [[ -n "$_em_had_errexit" ]] && set -e
    return 0
}
