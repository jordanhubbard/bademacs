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

## The Totally True and Not At All Embellished History of shemacs

It began, as so many catastrophic ideas do, with a small act of stubbornness.

The programmer had been using a server — a perfectly nice server, by server standards — that had no text editor installed beyond `vi`.  The programmer would like to be clear that this is not a moral failing on the server's part.  The server did not choose to be born editorless.  Nevertheless, the programmer typed `:q!` for the forty-seventh time, missed, and found himself staring at the bottom of a shell prompt with a half-edited configuration file and a deep, smoldering grievance.

"I could install nano," he said.

Sir Reginald von Fluffington III, who had accompanied the programmer on what the programmer had described as "a quick server-room visit" and Sir Reginald had accurately described as "inexplicable," looked up from the keyboard cable he had been attempting to eat.  He blinked once.

"I could also," the programmer continued, "write my own editor.  In bash.  It would start instantly, require no installation, and would travel with me wherever my `.bashrc` goes."  He paused.  "Like a friend.  But reliable."

Sir Reginald returned to the cable.

This was the moment.  This was the seed.  Historians, had they been present, would have quietly left the room.

What followed was six weeks that the programmer later referred to as "rapid prototyping" and his colleagues referred to as "that thing you did instead of reviewing my PR."  A terminal went raw.  Escape sequences were learned, forgotten, relearned, and in one memorable case, accidentally sent to a production server.  The kill ring emerged on a Tuesday, motivated by the discovery that bash arrays could hold arbitrary strings, and grew to sixty entries by Wednesday for reasons that remain unclear to this day.

"It's just a function," the programmer explained to no one in particular.  "A shell function.  Sourced into the shell.  Zero latency.  Like... like Emacs, but if Emacs were a perfectly reasonable person who doesn't require three separate config files to open a file."

Sir Reginald knocked a mug off the desk.  He had been building up to this for some time.

By the time the function grew past a thousand lines, it had undo.  By fifteen hundred, it had incremental search — real incremental search, with highlighting, which required the programmer to learn approximately fourteen ANSI escape codes he hadn't needed since 1993 and one he's still not entirely sure is valid.  By two thousand lines, it had multiple buffers, because of course it did.

"Keyboard macros?" said the programmer, at two thousand and three hundred lines, to Sir Reginald, who had retreated to the top of the monitor to judge from elevation.  "Obviously keyboard macros.  What is an Emacs-compatible editor without keyboard macros?  I ask you, Reggie.  I ask you rhetorically."

Sir Reginald declined to engage.  He had declined to engage for six weeks.

The finished function — approximately 2,451 lines of pure bash that functioned as a full-featured terminal text editor with multiple buffers, a kill ring, undo, incremental search, query-replace, keyboard macros, region highlighting, fill-paragraph, and universal argument — was named `em`, because `emacs` was already taken and `shemacs` was what it became when the programmer realized it needed a repository name and all the good ones were gone.

"It's elegant," the programmer told Sir Reginald, who was at this point sitting directly on top of the laptop that contained the file that contained the main rendering function.  "It sources into your shell in milliseconds.  It has no external dependencies.  It is, in a very real sense, the purest possible text editor."

Sir Reginald yawned.  He had six teeth and used all of them.

"I should port it to zsh," the programmer said.  "For the other people."

He did.  It worked.  He was unreasonably surprised.

Then, one dark and stormy evening, the programmer sat hunched over the 2,451-line mass of tangled bash functions that shemacs had become, and he had a thought.  Not about shemacs, exactly.  About something worse.

"What if I wrote a Scheme interpreter," he whispered, "in bash?"

Sir Reginald left the room.  He had seen this look before.  He didn't like where it went.

The rest of that story is documented in the [sheme repository](https://github.com/jordanhubbard/sheme), where Sir Reginald continues to withhold his endorsement, and the programmer continues to be unreasonably proud of things that arguably should not exist.
