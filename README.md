# em

A micro GNU Emacs (mg) compatible text editor implemented as a single bash
shell function. No compiled languages, no dependencies beyond a standard
Linux install -- just bash and `/usr/bin`.

Features include multiple buffers, undo, a 60-entry kill ring, incremental
search, query replace, keyboard macros, region highlighting, fill paragraph,
and universal argument -- all in ~1950 lines of pure bash.

## Install

### Quick Setup (source from .bashrc)

Clone the repo (or just grab the `em` file) and add one line to
your `~/.bashrc`:

```bash
# Clone it somewhere permanent
git clone https://github.com/jordanhubbard/bad-emacs.git ~/em

# Add this line to the end of your ~/.bashrc
echo 'source ~/em/em' >> ~/.bashrc
```

Now reload your shell and `em` is available as a command:

```bash
source ~/.bashrc       # reload in current shell, or just open a new terminal
em myfile.txt          # edit a file
em                     # open a *scratch* buffer
```

Because `em` is a shell function (not a subprocess), it starts
instantly -- there is no fork/exec overhead.

### Using the Makefile

If you prefer, the included Makefile copies the script to
`~/.local/bin/` and appends the source line to `~/.bashrc` for you:

```bash
make install           # install and add to .bashrc
make uninstall         # remove from .bashrc and delete the copy
make check             # syntax-check the script
```

You can override the install location and target rc file:

```bash
make install PREFIX=/usr/local/bin BASHRC=~/.bash_profile
```

### Standalone (no sourcing)

It also works as a plain executable if you just want to run it without
adding anything to your `.bashrc`:

```bash
chmod +x em
./em myfile.txt
```

In this mode it runs as a script in a subshell rather than a shell
function, but the behavior is identical.

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

Because every Linux box has bash, and sometimes you just need a quick
editor that feels like emacs without installing anything.
