# AGENTS.md — bad-emacs (`em`)

## Project Summary

`em` is a self-contained Emacs/mg-compatible text editor implemented as a
**single shell function** (~2080 lines). It has zero dependencies beyond
bash 4+ (or zsh 5+) and a POSIX `/usr/bin`. The editor ships in two
versions — `em` for bash and `em.zsh` for zsh — and is designed to be
sourced into a user's shell rc file so it starts instantly with no
fork/exec overhead.

License: BSD 2-Clause. Author: Jordan Hubbard.

## Repository Layout

```
em              — The editor, bash version (single file defining the em() function)
em.zsh          — The editor, zsh version (same functionality, zsh-native idioms)
Makefile        — install/uninstall/check targets (auto-detects bash vs zsh)
README.md       — User-facing documentation and keybinding reference
LICENSE         — BSD 2-Clause
AGENTS.md       — This file (LLM-oriented project documentation)
.github/        — Issue templates (bug_report.md, feature_request.md)
```

There are **two source files**: `em` (bash) and `em.zsh` (zsh). They
implement identical functionality. Everything else is project metadata.

## Architecture

### Single-Function Design

The editor is a single bash function `em()` (line 35). All state is held in
`local` variables and all sub-routines are inner functions (nested
`_em_*()` definitions). On exit, `_em_cleanup` unsets every `_em_*` function
and restores terminal state. This means the editor leaves no persistent
shell pollution after quitting.

### State Model

All editor state is local to `em()`:

| Variable(s) | Purpose |
|---|---|
| `_em_lines[]` | Buffer content — indexed array of strings, one per line |
| `_em_cy`, `_em_cx` | Cursor position (0-indexed line, 0-indexed column) |
| `_em_top` | First visible line (scroll offset) |
| `_em_rows`, `_em_cols` | Terminal dimensions |
| `_em_mark_y`, `_em_mark_x` | Mark position (-1 = unset) |
| `_em_modified` | Dirty flag for current buffer |
| `_em_filename` | File path of current buffer |
| `_em_bufname` | Display name of current buffer |
| `_em_message` | Minibuffer/echo-area message |
| `_em_kill_ring[]` | Kill ring (max 60 entries) |
| `_em_undo[]` | Undo stack (max 200 entries, auto-trimmed) |
| `_em_bufs` (assoc array) | Multi-buffer storage (all per-buffer state keyed by buffer id) |
| `_em_buf_ids[]` | Ordered list of buffer IDs |
| `_em_macro_keys[]` | Keyboard macro recording |
| `_em_goal_col` | Sticky column for vertical movement |

Delimiter constants for serialization:
- `US` (0x1F) — separates fields within an undo record
- `RS` (0x1E) — separates lines within a replace_region undo record
- `GS` (0x1D) — separates undo records when serializing to buffer storage

### Subsystems (in source order)

1. **Terminal Setup / Cleanup** (`_em_init`, `_em_cleanup`, lines ~84–128)
   - Saves/restores stty settings and traps (INT, TERM, HUP, WINCH)
   - Enters raw mode (`stty raw -echo -isig ...`)
   - Uses the alternate screen buffer (`\e[?1049h`)
   - Disables INTR/QUIT/SUSP so Ctrl-C reaches the editor on macOS

2. **Undo System** (`_em_undo_push`, `_em_undo`, lines ~148–214)
   - Record types: `insert_char`, `delete_char`, `join_lines`, `split_line`, `replace_line`, `replace_region`
   - Each record packs type + args with US delimiter
   - `replace_region` is the general case used by yank, fill-paragraph, kill-region, and insert-file

3. **Rendering** (`_em_render`, `_em_expand_tabs`, `_em_col_to_display`, lines ~216–347)
   - Full-screen redraw on every keystroke (no partial update / dirty tracking)
   - Tab expansion to configurable width (default 8)
   - Region highlighting via ANSI reverse video (`\e[7m`)
   - Status line: mode line in Emacs format (`-UUU:**-- bufname (Fundamental) L## %%`)
   - Message/echo area on the last terminal row

4. **Input / Key Reading** (`_em_read_key`, lines ~349–438)
   - Reads raw bytes from stdin with `read -rsn1`
   - Decodes: control chars → `C-x`, ESC sequences → arrow/page/home/end/delete keys, ESC+char → `M-x`, printable → `SELF:x`
   - Handles bare ESC (50ms timeout) for two-key Meta sequences
   - EOF detection for disconnected terminals

5. **Movement** (lines ~457–555)
   - Character, word, line, page, and buffer-level movement
   - Goal-column tracking for vertical movement (sticky column)
   - `_em_ensure_visible` scrolls the viewport to keep cursor on-screen

6. **Editing** (lines ~557–624)
   - Self-insert, newline, open-line, delete-char, backward-delete-char
   - Every mutation pushes an undo record

7. **Kill/Yank** (lines ~626–705)
   - Kill ring with 60-entry cap
   - Consecutive `C-k` appends to kill ring head (emacs behavior)
   - Yank handles multi-line text with line splitting

8. **Mark/Region** (lines ~707–809)
   - Set mark, exchange point/mark, mark whole buffer
   - Kill region, copy region — both support multi-line regions

9. **Incremental Search** (`_em_isearch`, `_em_isearch_next`, `_em_strstr`, lines ~811–970)
   - Forward and backward incremental search
   - Uses pure bash string matching (no external grep)
   - `_em_strstr` — custom substring search with start offset

10. **Minibuffer** (`_em_minibuffer_read`, lines ~972–1031)
    - Line editor with cursor movement, delete, backspace, kill-to-end
    - Used for all prompts: find-file, save-as, switch-buffer, goto-line, etc.
    - Returns result via `_em_mb_result`; returns 1 on C-g cancel

11. **File I/O** (lines ~1033–1140)
    - `_em_save_buffer` — atomic write via temp file + mv
    - `_em_load_file` — reads file line-by-line
    - `_em_find_file` — opens file or switches to existing buffer
    - `_em_write_file` — save-as with prompt
    - `_em_insert_file` — inserts file content at point

12. **Buffer Management** (lines ~1142–1370)
    - Multiple buffers stored in associative array `_em_bufs`
    - State save/restore serializes lines, undo stack, cursor, mark, etc.
    - Switch buffer, kill buffer (with modified-buffer prompt), list buffers
    - Buffer list is a read-only pseudo-buffer with navigation

13. **Word Operations** (lines ~1423–1504)
    - Forward/backward word movement (`[A-Za-z0-9_]` is word-constituent)
    - Kill word forward/backward (uses set-mark + word-move + kill-region)

14. **Transpose** (`_em_transpose_chars`, lines ~1506–1523)

15. **Universal Argument** (`_em_universal_argument`, lines ~1525–1556)
    - `C-u` prefix: digits accumulate, additional `C-u` multiplies by 4

16. **Quoted Insert** (`_em_quoted_insert`, lines ~1558–1584)

17. **Query Replace** (`_em_query_replace`, lines ~1586–1642)
    - Interactive y/n/!/q/. replacement (emacs-compatible)

18. **M-x Extended Commands** (`_em_execute_extended`, lines ~1644–1706)
    - Dispatches named commands: goto-line, what-line, query-replace, etc.

19. **Help / Describe Bindings** (`_em_show_bindings`, lines ~1708–1798)
    - Read-only pseudo-buffer showing all keybindings

20. **Case Conversion** (lines ~1800–1868)
    - capitalize-word, upcase-word, downcase-word

21. **Fill Paragraph** (`_em_fill_paragraph`, lines ~1870–1924)
    - Finds paragraph boundaries (blank-line delimited)
    - Joins and re-wraps at `_em_fill_column` (default 72)

22. **Keyboard Macros** (lines ~1926–1952)
    - Record/playback via `_em_macro_keys[]`

23. **Key Dispatch** (`_em_dispatch`, `_em_read_cx_key`, `_em_read_meta_key`, lines ~1954–2063)
    - Two-level dispatch: bare keys in `_em_dispatch`, C-x prefix in `_em_read_cx_key`
    - ESC handled as a two-key sequence (ESC → read next → translate to M-*)
    - Macro recording hooks into dispatch

24. **Main Loop** (lines ~2066–2079)
    - `_em_init` → render/read/dispatch loop → `_em_cleanup`

## Key Design Decisions & Constraints

- **Pure shell**: No external commands for editing operations. `stty` and
  `tput` are used only at startup/shutdown for terminal setup. All text
  manipulation, searching, and rendering is done with shell builtins and
  string operations.
- **No EXIT trap**: Shell functions that set EXIT traps are dangerous because
  the trap lingers after the function returns. Instead, cleanup is called
  explicitly and via INT/TERM/HUP traps.
- **errexit safety**: The function saves and disables `set -e` on entry
  because bash arithmetic expressions like `((0))` return status 1 which
  would kill the shell.
- **Full redraw**: Every keystroke triggers a complete screen redraw. There
  is no dirty-line tracking. This is acceptable for terminal editors at
  interactive typing speeds.
- **Atomic saves**: File writes go to a temporary file first, then `mv` to
  the target. This prevents data loss on write errors.
- **Function cleanup**: On exit, all `_em_*` functions are unset via
  `declare -F` (bash) or `${(k)functions}` (zsh) enumeration, leaving
  no namespace pollution.

## Naming Conventions

- All functions: `_em_<name>` (underscore prefix prevents collision with user functions)
- All state variables: `_em_<name>`
- Key names: `C-x` (control), `M-x` (meta/alt), `SELF:x` (printable self-insert)
- Undo record fields separated by US (0x1F)

## Keybindings

The editor aims for mg/emacs compatibility. All bindings are documented in
the header comment of `em` (lines 6–33) and in `README.md`. The dispatch
table is in `_em_dispatch` (line ~2011) and `_em_read_cx_key` (line ~1983).

## Building and Testing

```bash
make check                       # syntax-check both bash and zsh versions
make install                     # auto-detect shell, install to correct rc file
make install SHELL_TYPE=zsh      # force zsh install to ~/.zshrc
make uninstall                   # remove source line from rc file
```

The editor can also be run standalone: `chmod +x em && ./em file.txt`

## Common Modification Patterns

**Adding a new keybinding**: Add a case to `_em_dispatch` (or `_em_read_cx_key`
for C-x prefix bindings). Write the handler as a new `_em_*` function.
Remember to push undo records for any buffer mutations.

**Adding an M-x command**: Add a case to the `case` block in
`_em_execute_extended`.

**Adding a new undo type**: Add a case to `_em_undo` and call
`_em_undo_push` with the new type name from the mutation function. Existing
types cover most needs — `replace_region` is the most general.

**Modifying buffer state**: Always push an undo record *before* mutating
`_em_lines`. Set `_em_modified=1`. Call `_em_ensure_visible` if the cursor
moved. Reset `_em_goal_col=-1` if horizontal position changed.

## Zsh Version (`em.zsh`)

The zsh version is a targeted port of the bash version. Both files
implement identical functionality and share the same architecture.

### Differences from the bash version

| Area | Bash (`em`) | Zsh (`em.zsh`) |
|------|-------------|----------------|
| Option scoping | Manual errexit save/restore | `emulate -L zsh` + `setopt KSH_ARRAYS` |
| Array indexing | Native 0-based | 0-based via `KSH_ARRAYS` |
| Single-char read | `read -rsn1 -d ''` | `read -rk1` |
| Case conversion | `${ch^}` / `${ch,}` / `${ch^^}` / `${ch,,}` | `${(U)ch}` / `${(L)ch}` |
| Function cleanup | `declare -F` + process substitution | `${(k)functions}` iteration |
| Last-element access | `${arr[-1]}` / `unset 'arr[-1]'` | `${arr[${#arr[@]}-1]}` / array slice |

### Why `KSH_ARRAYS`?

The entire codebase uses 0-based indices for cursor positions, line
numbers, and array slicing (~50+ direct accesses, ~15 slice operations).
`setopt KSH_ARRAYS` makes zsh arrays 0-indexed, preserving all existing
math unchanged. This is scoped to the function via `emulate -L zsh`.

### Keeping the versions in sync

When modifying editor logic, **apply the same change to both `em` and
`em.zsh`**. The only lines that differ are the ones listed in the table
above. A `diff em em.zsh` should show only ~25 changed lines.

## Gotchas

- Arrays are 0-indexed in both versions (zsh uses `KSH_ARRAYS`), but
  line numbers displayed to the user are 1-indexed.
- `_em_lines` always has at least one element (empty string for empty buffer).
- The undo stack auto-trims at 200 entries (drops oldest 100).
- The kill ring caps at 60 entries.
- `_em_strstr` is a pure-shell substring finder; it doesn't use regex.
- Tab characters are expanded for *display* only — stored as literal `\t` in the buffer.
- Multi-buffer state is serialized into the `_em_bufs` associative array using
  keys like `${bid}_line_${i}`. This is a flat namespace — there are no nested
  data structures.
- In the zsh version, avoid `${arr[-1]}` for last-element access — use
  `${arr[${#arr[@]}-1]}` for KSH_ARRAYS compatibility.
