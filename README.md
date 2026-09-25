# Rackmac

An Emacs-style editor for the desktop, scripted in Racket instead of Emacs Lisp.
Modern shortcuts (Cmd on macOS, Ctrl on Windows), a command palette, tabs, and a live,
redefinable core. See [DESIGN.md](DESIGN.md) for the full design; this file covers what is built.

## Run

    racket main.rkt [file ...]
    raco test tests            # 61 tests

Needs Racket 9.x with the GUI libraries (the standard distribution).

What is verified: the 61 automated tests (commands, keymaps, key-event normalization, the picker
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
Set `RACKMAC_HOME` to use a different config directory, `RACKMAC_THEME=dark|light` to force a theme.

### Command metadata

`define-command` takes optional metadata that the menus, palette and Describe screens read:
`#:title` (the name people see), `#:aliases` (extra search terms, e.g. the Emacs name), `#:help` (one plain
sentence), `#:icon` (for the toolbar), `#:when` (a thunk: does the command apply right now?),
plus `#:doc`, `#:keys`, `#:menu`. A command's symbol name never changes when its title does, so
`bind-key!` and `run-command` in your init file keep working. `define-mode` takes `#:label`
(what people see, e.g. "Plain Text"). Typing `yank` in the palette finds Paste, and Describe shows both names.

### How extensions work

- **Files.** `init.rkt` loads first, then every `ext/*.rkt` next to it in name order. Each file is its
  own extension; one that fails is reported in `*Messages*` and skipped, and the others still load.
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
  is refused with an error naming the module.
- **Quiet modules.** Module-level values are not printed (plain `#lang racket/base` would print them).
- **Plain Racket works too.** `#lang racket/base` with `(require rackmac/api)` is loaded the same way;
  `#lang rackmac` adds the conveniences above.

Known limits: `unbind-key!` is not undone on unload, live-evaluated code (`Mod-Enter`) is not tracked
as an extension, and the API restriction applies at load time only.

## Shortcuts

`Mod` = Cmd (macOS) / Ctrl (Windows). The command palette lists everything with its binding.

| Action | macOS | Windows |
|---|---|---|
| Command palette / Quick open | Cmd+Shift+P / Cmd+P | Ctrl+Shift+P / Ctrl+P |
| New / Open / Save / Save As / Close tab | Cmd+N / O / S / Shift+S / W | Ctrl+N / O / S / Shift+S / W |
| Next / previous tab | Ctrl+Tab, Ctrl+Shift+Tab, Cmd+Opt+→/← | Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+PgDn/PgUp |
| Undo / Redo | Cmd+Z / Cmd+Shift+Z | Ctrl+Z / Ctrl+Y |
| Cut / Copy / Paste / Select all | Cmd+X / C / V / A | Ctrl+X / C / V / A |
| Find / Replace / Next / Previous | Cmd+F / Cmd+Opt+F / Cmd+G / Cmd+Shift+G | Ctrl+F / Ctrl+H / F3 / Shift+F3 |
| Go to line | Ctrl+G | Ctrl+G |
| Toggle comment | Cmd+/ | Ctrl+/ |
| Duplicate / delete line | Cmd+Shift+D / Cmd+Shift+K | Ctrl+Shift+D / Ctrl+Shift+K |
| Move line up / down | Opt+↑ / Opt+↓ | Alt+↑ / Alt+↓ |
| Indent / outdent | Tab, Cmd+] / Shift+Tab, Cmd+[ | Tab, Ctrl+] / Shift+Tab, Ctrl+[ |
| Word left / right (Shift selects) | Opt+←/→ | Ctrl+←/→ |
| Line start / end | Cmd+←/→, Home/End | Home/End |
| Document start / end | Cmd+↑/↓ | Ctrl+Home/End |
| Delete word back / forward | Opt+Backspace / Opt+Delete | Ctrl+Backspace / Ctrl+Delete |
| Zoom in / out / reset | Cmd+= / Cmd+- / Cmd+0 | Ctrl+= / Ctrl+- / Ctrl+0 |
| Word wrap | Opt+Z | Alt+Z |
| Evaluate selection / buffer | Cmd+Enter / Cmd+Shift+Enter | Ctrl+Enter / Ctrl+Shift+Enter |
| Quit | Cmd+Q | Ctrl+Q |

Native macOS text navigation (Ctrl+A/E/K/F/B/N/P) is left alone on Mac. On Windows, unbound
Ctrl/Alt combinations do nothing rather than falling into Racket's built-in Emacs bindings.

## Built vs. deferred

Built: buffers, tabs, find/replace bar, command palette, quick open, menus generated from command
metadata, modes (text, prog, Racket, Markdown) with syntax coloring, hooks, init file, live eval,
light/dark theme, zoom, CRLF-preserving file I/O, describe-key and keybinding listings.

Deferred (in DESIGN.md, not built): Rackorg (Org-compatible mode), multiple cursors, splits,
a piece-tree text store and custom renderer, undo tree, tree-sitter, LSP, session restore,
line-number gutter, and everything in the legal-workspace section (PDF/Word/Outlook integrations).
