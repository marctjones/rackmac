# Rackmac

An Emacs-style editor for the desktop, scripted in Racket instead of Emacs Lisp.
Modern shortcuts (Cmd on macOS, Ctrl on Windows), a command palette, tabs, and a live,
redefinable core. See [DESIGN.md](DESIGN.md) for the full design; this file covers what is built.

## Run

    racket main.rkt [file ...]
    raco test tests            # 148 tests

Needs Racket 9.x with the GUI libraries (the standard distribution).

What is verified: the 148 automated tests (commands, keymaps, key-event normalization, the picker
dialog driven by timers, startup, the extension loader), and a launch on macOS (Apple Silicon)
that renders correctly. **What is not verified:** that real keystrokes in the live window reach the
buffer and run commands (one attempt with synthetic OS-level keystrokes produced no dispatch, and the
cause is unresolved), and anything on a real Windows machine (the Windows key mapping is unit-tested
with a simulated platform only). 
## The Emacs ideas, in Racket

| Idea | Where |
|---|---|
| Everything is a command; menus, palette and keys all read one registry | `rackmac/command.rkt` |
| Layered keymaps: minor mode → major mode → global; key chords | `rackmac/keymap.rkt`, `rackmac/input.rkt` |
| Major/minor modes with inheritance, buffer-local variables, hooks | `rackmac/mode.rkt`, `rackmac/hook.rkt`, `rackmac/buffer.rkt` |
| A live extension language, with ownership and unloading | `rackmac/eval.rkt`, `rackmac/api.rkt`, `rackmac/owner.rkt`, `rackmac/lang/` |
| Self-documenting: describe key, list keybindings, describe command | `rackmac/commands.rkt` |

Storage, rendering, selection and undo come from Racket's `text%`; the Emacs-style layer sits on top.

## Customize: `#lang rackmac`

`Cmd+,` (Mac) / `Ctrl+,` (Windows) opens `~/.config/rackmac/init.rkt` (`%APPDATA%\rackmac\init.rkt`
on Windows), creating it from a template. Extension files are ordinary Racket modules written in
the `rackmac` module language: `racket/base` plus the whole public API, with nothing to require.

```racket
#lang rackmac
(extension-info #:name "My init" #:requires-api 1 #:doc "Personal customizations.")

(define-command (shout)
  #:title "Shout" #:doc "Upper-case the selection." #:keys ("Mod-Shift-u")
  (replace-selection! (string-upcase (selection-string))))

(bind-key! "Mod-b" 'shout #:mode 'racket-mode)     ; per-mode binding
(add-hook! 'after-save (lambda (b) (message "saved ~a" (send b get-name))))
```

`Mod` means Cmd on macOS and Ctrl on Windows. Select code anywhere and press `Mod-Enter` to
evaluate it in the running editor; redefining a command takes effect immediately.
Set `RACKMAC_HOME` to use a different config directory, `RACKMAC_THEME=dark|light` to force a theme, and
`RACKMAC_KEYLOG=1` to log every key event the editor receives (and what it dispatched) to stderr, which helps debug shortcuts.

### Command metadata

`define-command` takes optional metadata that the menus, palette and Describe screens read:
`#:title` (the name people see), `#:aliases` (extra search terms, e.g. the Emacs name), `#:help` (one plain
sentence), `#:icon` (for the toolbar), `#:when` (a thunk: does the command apply right now?),
plus `#:doc`, `#:keys`, `#:menu`. A command's symbol name never changes when its title does, so
`bind-key!` and `run-command` in your init file keep working. `define-mode` takes `#:label`
(what people see, e.g. "Plain Text"). Typing `yank` in the palette finds Paste, and Describe shows both names.

### Toolbar

The toolbar is built from a registry that extensions use too:

```racket
(add-toolbar-item! 'shout #:group 'text)                 ; a button for your command (#:icon on the command)
(add-toolbar-item! 'eval-selection #:mode 'racket-mode)  ; only for Racket documents
(remove-toolbar-item! 'find)
```

Buttons dim when a command's `#:when` says it does not apply, hovering shows the name and shortcut in the
status bar, and View → Show Toolbar hides the row. Items are removed when their extension unloads.

### How extensions work

- **Files.** `init.rkt` loads first, then every `ext/*.rkt` next to it in name order. Each file is its
  own extension; one that fails is reported in the Activity log and skipped, and the others still load.
- **Ownership and reload.** Everything a file registers (commands, key bindings, hooks, modes) is
  recorded against it. **Reload Init File** unloads all of it first, so reloading replaces instead of
  duplicating. An extension that redefines a built-in command restores the original when unloaded,
  and a file that fails partway through leaves nothing behind. *List Extensions* (Help menu) shows
  what each file registered.
- **Compile-time checks.** Key strings in `define-command` are validated when the file is compiled, so
  `#:keys ("Mod-Bogus")` is a syntax error pointing at that string. `(extension-info #:requires-api N)`
  is checked against the API version (currently 1) at compile time as well.
- **Public API only.** While an extension loads, `require` is limited to `rackmac/api`, `rackmac/lang/*`
  and ordinary Racket libraries. Requiring a private core module (`rackmac/editor`, `rackmac/commands`, ...)
  is refused with an error naming the module, however the path is spelled (files are compared by identity).
  This keeps the API the contract; it is *not* a security sandbox. Extension code runs with the editor's
  full privileges, so only load extensions you trust.
- **Quiet modules.** Module-level values are not printed (plain `#lang racket/base` would print them).
- **Plain Racket works too.** `#lang racket/base` with `(require rackmac/api)` is loaded the same way;
  `#lang rackmac` adds the conveniences above.

Known limits: live-evaluated code (`Mod-Enter`) is not tracked as an extension, and the API restriction
applies to `require` at load time, not to code that runs later.

## Glossary: Emacs terms

Rackmac shows office-style names; the command palette also understands the Emacs ones.

| Emacs | Rackmac |
|---|---|
| buffer | Document, Tab |
| window / frame | Pane / Window |
| point, mark, region | Cursor, Selection |
| kill / yank | Cut / Paste |
| kill ring | Clipboard History |
| M-x | Command Palette |
| minibuffer, echo area | Command bar, Status message |
| mode line | Status bar |
| major mode | Language |
| minor mode | Option |
| keymap, key binding | Shortcut |
| hook | Trigger |
| init file | Customize with Code |
| evaluate | Run |
| *scratch* | Scratch Pad |
| *Messages* | Activity log |
| describe-key | What Does This Key Do? |
| describe-function | Explain a Command |
| package | Extension |

## Shortcuts

Defaults follow macOS, Windows, Microsoft Office and Chrome conventions (see `tests/shortcuts-test.rkt`,
which also rejects Emacs-style key sequences, Option+letter on macOS, Ctrl+Alt+letter on Windows and
OS-reserved keys). This table is generated from the command registry; the command palette lists
everything, including commands without a shortcut.

| Menu | Command | macOS | Windows |
|---|---|---|---|
| File | New Document | ⌘N, ⌘T | Ctrl+N, Ctrl+T |
| File | Open… | ⌘O | Ctrl+O |
| File | Quick Open… | ⇧⌘O | Ctrl+Shift+O |
| File | Save | ⌘S | Ctrl+S |
| File | Save As… | ⇧⌘S | Ctrl+Shift+S, F12 |
| File | Close Tab | ⌘W | Ctrl+W, Ctrl+F4 |
| File | Reopen Closed Tab | ⇧⌘T | Ctrl+Shift+T |
| File | Print… | ⌘P | Ctrl+P |
| File | Save All | ⌥⌘S | — |
| File | Next Tab | ⌃⇥, ⌥⌘→, ⇧⌘] | Ctrl+Tab, Ctrl+PgDn |
| File | Previous Tab | ⌃⇧⇥, ⌥⌘←, ⇧⌘[ | Ctrl+Shift+Tab, Ctrl+PgUp |
| File | Customize with Code | ⌘, | Ctrl+, |
| File | Quit | ⌘Q | Alt+F4 |
| Edit | Undo | ⌘Z | Ctrl+Z |
| Edit | Redo | ⇧⌘Z | Ctrl+Y, Ctrl+Shift+Z |
| Edit | Cut | ⌘X | Ctrl+X |
| Edit | Copy | ⌘C | Ctrl+C |
| Edit | Paste | ⌘V | Ctrl+V |
| Edit | Select All | ⌘A | Ctrl+A |
| Edit | Select Line | ⌘L | Ctrl+L |
| Edit | Find… | ⌘F | Ctrl+F |
| Edit | Find and Replace… | ⌥⌘F | Ctrl+H |
| Edit | Find Next | ⌘G | F3 |
| Edit | Find Previous | ⇧⌘G | Shift+F3 |
| Edit | Go to Line… | ⌃G | Ctrl+G |
| Edit | Toggle Comment | ⌘/ | Ctrl+/ |
| Edit | Duplicate Line | ⇧⌘D | Ctrl+Shift+D |
| Edit | Delete Line | ⇧⌘K | Ctrl+Shift+K |
| Edit | Move Line Up | ⌥↑ | Alt+Up |
| Edit | Move Line Down | ⌥↓ | Alt+Down |
| Edit | Indent Lines | ⌘] | Ctrl+] |
| Edit | Outdent Lines | ⌘[, ⇧⇥ | Ctrl+[, Shift+Tab |
| View | Zoom In | ⌘=, ⇧⌘= | Ctrl+=, Ctrl+Shift+= |
| View | Zoom Out | ⌘- | Ctrl+- |
| View | Actual Size | ⌘0 | Ctrl+0 |
| View | Toggle Word Wrap | — | Alt+Z |
| View | Toggle Full Screen | ⌃⌘F | F11 |
| View | Command Palette… | ⇧⌘P | Ctrl+Shift+P, Alt+Q |
| Tools | Run Selection | ⌘↩ | Ctrl+Enter |
| Tools | Run Document | ⇧⌘↩ | Ctrl+Shift+Enter |
| Help | Keyboard Shortcuts | — | F1 |
| Editing | Go to Tab 1 | ⌘1 | Ctrl+1 |
| Editing | Go to Tab 2 | ⌘2 | Ctrl+2 |
| Editing | Go to Tab 3 | ⌘3 | Ctrl+3 |
| Editing | Go to Tab 4 | ⌘4 | Ctrl+4 |
| Editing | Go to Tab 5 | ⌘5 | Ctrl+5 |
| Editing | Go to Tab 6 | ⌘6 | Ctrl+6 |
| Editing | Go to Tab 7 | ⌘7 | Ctrl+7 |
| Editing | Go to Tab 8 | ⌘8 | Ctrl+8 |
| Editing | Go to Last Tab | ⌘9 | Ctrl+9 |
| Editing | Insert Indent | ⇥ | Tab |
| Editing | Newline and Indent | ↩ | Enter |
| Editing | Word Left | ⌥← | Ctrl+Left |
| Editing | Word Right | ⌥→ | Ctrl+Right |
| Editing | Line Start | HOME, ⌘← | Home |
| Editing | Line End | END, ⌘→ | End |
| Editing | Document Start | ⌘↑ | Ctrl+Home |
| Editing | Document End | ⌘↓ | Ctrl+End |
| Editing | Page Up | PgUp | PgUp |
| Editing | Page Down | PgDn | PgDn |
| Editing | Delete Word Back | ⌥⌫ | Ctrl+Backspace |
| Editing | Delete Word Forward | ⌥⌦ | Ctrl+Delete |
| Editing | Delete to Line Start | ⌘⌫ | — |

Native macOS text navigation (Ctrl+A/E/K/F/B/N/P) is left alone on Mac. On Windows, unbound
Ctrl/Alt combinations do nothing rather than falling into Racket's built-in Emacs bindings.

## Built vs. deferred

Built: buffers, tabs, find/replace bar, command palette, quick open, menus generated from command
metadata, modes (text, prog, Racket, Markdown) with syntax coloring, hooks, init file, live eval,
light/dark theme, zoom, CRLF-preserving file I/O, describe-key and keybinding listings.

Deferred (in DESIGN.md, not built): Rackorg (Org-compatible mode), multiple cursors, splits,
a piece-tree text store and custom renderer, undo tree, tree-sitter, LSP, session restore,
line-number gutter, and everything in the legal-workspace section (PDF/Word/Outlook integrations).
