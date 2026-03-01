# em

shemacs — an Emacs/mg-compatible editor implemented as a single shell
function. No compiled languages, no dependencies beyond a standard
Linux/macOS install -- just bash (or zsh) and `/usr/bin`.

Features include multiple buffers, undo, a 60-entry kill ring, incremental
search, query replace, keyboard macros, region highlighting, fill paragraph,
and universal argument -- all in ~2750 lines of pure shell script.

Three implementations are included:

- **`em.sh`** — bash implementation (the original)
- **`em.zsh`** — zsh implementation (zsh-native glob syntax for file completion)
- **`em.scm`** — Scheme implementation, launched via `em.scm.sh`; requires [sheme](https://github.com/jordanhubbard/sheme)

## Install

### Quick Setup (source from .bashrc / .zshrc)

Clone the repo and use `make install`:

```bash
git clone https://github.com/jordanhubbard/shemacs.git ~/em
cd ~/em
make install
```

This copies `em.sh` and `em.zsh` to your home directory and adds `source` lines to both `~/.bashrc` and `~/.zshrc`.

Now reload your shell and `em` is available as a command:

```bash
source ~/.bashrc       # reload in current shell, or just open a new terminal
em myfile.txt          # edit a file
em                     # open a *scratch* buffer
```

Because `em` is a shell function (not a subprocess), it starts
instantly -- there is no fork/exec overhead.

### Using the Makefile

```bash
make install           # copy em.sh/em.zsh to ~/ and add source lines to rc files
make uninstall         # remove copied files and source lines
make check             # syntax-check bash and zsh versions
```

### Standalone (no sourcing)

It also works as a plain executable if you just want to run it without
adding anything to your rc files:

```bash
chmod +x em.sh
./em.sh myfile.txt
```

In this mode it runs as a script in a subshell rather than a shell
function, but the behavior is identical.

## Scheme Implementation

`em.scm` is the editor rewritten in ~1300 lines of pure Scheme. It is
shell-neutral: all terminal I/O, key reading, and file operations go
through [sheme](https://github.com/jordanhubbard/sheme)'s built-in
primitives, so the Scheme source itself contains no bash- or zsh-specific
code.

`em.scm.sh` is the thin launcher that sources the sheme interpreter,
loads `em.scm`, and calls `(em-main)`.

### Installing the Scheme backend

`em.scm` requires **sheme v1.0.0 or later**.  It uses the terminal I/O
builtins introduced in that release: `read-byte`, `write-stdout`,
`terminal-raw!`, `terminal-restore!`, `terminal-size`, `terminal-suspend!`,
`file-read`, `file-write-atomic`, `file-glob`, `file-directory?`,
`eval-string`, and `shell-capture`.

1. Install [sheme](https://github.com/jordanhubbard/sheme) (`bs.sh`):

   ```bash
   git clone https://github.com/jordanhubbard/sheme.git ~/sheme
   cd ~/sheme && make install
   ```

2. Then run or source `em.scm.sh`:

   ```bash
   # Run standalone
   bash em.scm.sh myfile.txt

   # Or add to ~/.bashrc for instant startup as a shell function
   source /path/to/shemacs/em.scm.sh
   em myfile.txt
   ```

## Keybindings

### File Operations
| Key       | Action                    |
|-----------|---------------------------|
| C-x C-s   | Save buffer              |
| C-x C-c   | Quit (prompts to save)   |
| C-x C-f   | Find (open) file         |
| C-x C-w   | Write file (save as)     |
| C-x i     | Insert file at point     |

### Buffers
| Key       | Action                    |
|-----------|---------------------------|
| C-x b     | Switch buffer            |
| C-x k     | Kill buffer              |
| C-x C-b   | List buffers             |

### Movement
| Key            | Action              |
|----------------|----------------------|
| C-f / Right    | Forward char         |
| C-b / Left     | Backward char        |
| C-n / Down     | Next line            |
| C-p / Up       | Previous line        |
| C-a / Home     | Beginning of line    |
| C-e / End      | End of line          |
| M-f            | Forward word         |
| M-b            | Backward word        |
| C-v / PgDn     | Page down            |
| M-v / PgUp     | Page up              |
| M-<            | Beginning of buffer  |
| M->            | End of buffer        |
| C-l            | Recenter display     |

### Editing
| Key        | Action                    |
|------------|---------------------------|
| C-d / Del  | Delete char forward       |
| Backspace  | Delete char backward      |
| C-k        | Kill to end of line       |
| C-y        | Yank (paste)              |
| C-w        | Kill region               |
| M-w        | Copy region               |
| C-SPC      | Set mark                  |
| C-x C-x    | Exchange point and mark   |
| C-x h      | Mark whole buffer         |
| C-t        | Transpose characters      |
| C-o        | Open line                 |
| M-d        | Kill word forward         |
| M-DEL      | Kill word backward        |
| M-u        | Uppercase word            |
| M-l        | Lowercase word            |
| M-c        | Capitalize word           |

### Undo
| Key           | Action                 |
|---------------|------------------------|
| C-x u / C-_   | Undo last change      |

### Search & Replace
| Key       | Action                    |
|-----------|---------------------------|
| C-s       | Incremental search fwd    |
| C-r       | Incremental search bwd    |
| M-%       | Query replace             |

### Keyboard Macros
| Key       | Action                    |
|-----------|---------------------------|
| C-x (     | Start recording macro    |
| C-x )     | Stop recording macro     |
| C-x e     | Execute last macro       |

### Other
| Key       | Action                    |
|-----------|---------------------------|
| C-u N     | Universal argument (repeat N times) |
| C-q       | Quoted insert (literal control char) |
| M-q       | Fill paragraph            |
| C-g       | Cancel / keyboard quit    |
| C-x =     | Show cursor position info |
| C-h b     | Describe keybindings     |
| M-x       | Execute extended command  |

### Extended Commands (M-x)

`goto-line`, `what-line`, `query-replace`, `what-cursor-position`,
`save-buffer`, `find-file`, `write-file`, `insert-file`, `kill-buffer`,
`switch-to-buffer`, `list-buffers`, `set-fill-column`,
`describe-bindings`, `save-buffers-kill-emacs`

## Why?

Because every Linux and macOS box has bash or zsh, and sometimes you
just need a quick editor that feels like emacs without installing
anything.
