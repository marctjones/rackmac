# Rackmac

[![test](https://github.com/marctjones/rackmac/actions/workflows/test.yml/badge.svg)](https://github.com/marctjones/rackmac/actions/workflows/test.yml)

A modern, native notes and documents editor for the desktop — macOS first, Windows next —
that you can program in Racket. Native shortcuts (Cmd on macOS, Ctrl on Windows), a command
palette, tabs, and a live, redefinable core: extend or reshape the app with ordinary Racket
code, no plugin API to learn beyond `#lang rackmac`. See [DESIGN.md](DESIGN.md) for the full
design, [docs/UI-DESIGN.md](docs/UI-DESIGN.md) for the visual design and
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for how to contribute. This file covers what is built.

## Run

    racket main.rkt [file ...]
    raco test tests            # 266 tests

Needs Racket 9.x with the GUI libraries (the standard distribution).

To build a double-clickable `Rackmac.app` that runs on a Mac without Racket (macOS only):

    racket tools/build-mac-app.rkt --smoke     # writes dist/Rackmac.app (about 92 MB), then tests it

It installs the app and Markdown packages into a private directory under `dist/build` (never
into your own Racket), runs `raco exe --gui` and `raco distribute`, and sets the app's name,
icon, version and document types (`.md`, `.markdown` and `.txt` files list Rackmac under Finder's
Open With). `--smoke` then starts the built app headless (`RACKMAC_SMOKE=1`: it loads everything,
prints one line per check and quits without showing a window) with no Racket or Homebrew on
`PATH`. The app is not signed (#20): a copy built on this Mac opens normally, but one downloaded from
elsewhere is refused at first launch until allowed in System Settings > Privacy & Security
("Open Anyway"). Pandoc (Word import and export) is found in `/opt/homebrew/bin` or `/usr/local/bin` even
when the app is started from Finder. Inside the app, extensions may require `rackmac/api` and the
libraries the app itself contains (`racket/base`, `racket/list`, `racket/string`, `racket/date`,
`racket/gui/base`, ...), not other installed collections.

What is verified: the 266 automated tests (commands, keymaps, key-event normalization, the picker
dialog driven by timers, startup, the extension loader, find/replace matching), and a launch on macOS (Apple Silicon)
that renders correctly. **What is not verified:** that real keystrokes in the live window reach the
buffer and run commands (one attempt with synthetic OS-level keystrokes produced no dispatch, and the
cause is unresolved), and anything on a real Windows machine (the Windows key mapping is unit-tested
with a simulated platform only).

The command palette (`rackmac/ui/palette.rkt`) sits over the top third of the main window with
Command, Category and Shortcut columns, a footer showing the highlighted command's help text,
and a helpful empty state. Help > Keyboard Shortcuts opens the same kind of picker over every
default shortcut on both platforms, grouped by category and filterable by typing; Enter runs
the selected command. "Shortcuts as Text" keeps the plain-text list.

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
`RACKMAC_NO_FRONT=1` to open the window without taking keyboard focus, and
`RACKMAC_KEYLOG=1` to log every key event the editor receives (and what it dispatched) to stderr, which helps debug shortcuts.

### Command metadata

`define-command` takes optional metadata that the menus, palette and Describe screens read:
`#:title` (the name people see), `#:aliases` (extra search terms — plain words people might type),
`#:help` (one plain sentence), `#:icon` (for the toolbar), `#:when` (a thunk: does the command apply
right now?), plus `#:doc`, `#:keys`, `#:menu`. A command's symbol name never changes when its title
does, so `bind-key!` and `run-command` in your init file keep working. `define-mode` takes `#:label`
(what people see, e.g. "Plain Text"). Typing `paste` in the palette finds Paste, and Describe shows
every alias.

### Toolbar

The toolbar is built from a registry that extensions use too:

```racket
(add-toolbar-item! 'shout #:group 'text)                 ; a button for your command (#:icon on the command)
(add-toolbar-item! 'run-selection #:mode 'racket-mode)  ; only for Racket documents
(remove-toolbar-item! 'find)
```

Buttons dim when a command's `#:when` says it does not apply, hovering shows the name and shortcut in the
status bar, and View → Show Toolbar hides the row. Items are removed when their extension unloads.

### Context menus

Right-click in the editor (or Ctrl-click on macOS) for a native menu built from a registry, same shape as
the toolbar's:

```racket
(add-context-item! 'shout #:group 'text)                 ; adds "Shout" to the menu
(add-context-item! 'run-selection #:mode 'racket-mode)  ; only for Racket documents
```

The default menu is Cut, Copy, Paste, Select All and Find; Racket documents add Run Selection, and any
code Language adds Toggle Comment. Items are enabled from `#:when`, just like the menu bar and toolbar; a
click outside the current selection first selects the word under the pointer. Right-click a tab for Close,
Close Other Tabs, Close Tabs to the Right, Copy Path and Reveal in Finder/File Explorer.

### Status bar

Left, the message segment (the same text `message`/`log-message` write to the echo area). Right, segments
from a registry extensions use too:

```racket
(add-status-segment! 'shout-count (lambda () (format "~a shouts" (shout-count))) #:command 'shout)
(remove-status-segment! 'shout-count)
```

The built-ins are position (opens Go to Line), word or selection count (words only for prose Languages),
encoding, line ending (LF/CRLF, opens Line Endings…), Language (opens the Language picker) and zoom
percentage (click to reset). A segment hides itself by having its thunk return `#f` (that is how the word
count disappears for code Languages); hovering a clickable one underlines it and shows a hint in the message
area. Segments are dropped, lowest `#:priority` first, when the window is too narrow for all of them, and
they are removed when their extension unloads.

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

## Architecture (for developers)

Rackmac's core borrows a handful of proven editor ideas — implemented fresh in Racket, not
inherited code:

| Idea | Where |
|---|---|
| Everything is a command; menus, palette and keys all read one registry | `rackmac/command.rkt` |
| Layered keymaps: minor mode → major mode → global; key chords | `rackmac/keymap.rkt`, `rackmac/input.rkt` |
| Major/minor modes with inheritance, buffer-local variables, hooks | `rackmac/mode.rkt`, `rackmac/hook.rkt`, `rackmac/buffer.rkt` |
| A live extension language, with ownership and unloading | `rackmac/eval.rkt`, `rackmac/api.rkt`, `rackmac/owner.rkt`, `rackmac/lang/` |
| Self-documenting: describe key, describe command, a searchable shortcut cheat sheet | `rackmac/commands.rkt`, `rackmac/ui/palette.rkt` |

Storage, rendering, selection and undo come from Racket's `text%`. Several of these ideas —
the command registry, layered keymaps, buffer-local state, a live extension language — trace
back to Emacs, reimplemented here for a native desktop UI with office-style vocabulary and
shortcuts throughout; nothing in the default product names Emacs or uses its terms. An
opt-in preset (v0.8, epic E13, tracked in #263) will let people who know Emacs bring its
names and key bindings back: see `rackmac/presets/emacs-names.rktd` (the preserved alias
data, not loaded by default) and `docs/emacs-glossary.md` (the term mapping).

## Shortcuts

Defaults follow macOS, Windows, Microsoft Office and Chrome conventions (see `tests/shortcuts-test.rkt`,
which also rejects Emacs-style key sequences, Option+letter on macOS, Ctrl+Alt+letter on Windows and
OS-reserved keys). This table is generated from the command registry; the command palette lists
everything, including commands without a shortcut.

| Menu | Command | macOS | Windows |
|---|---|---|---|
| File | New Note | ⌘N, ⌘T | Ctrl+N, Ctrl+T |
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
| File | Settings… | ⌘, | Ctrl+, |
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
| Edit | Insert Date | ⌃⇧D | Alt+Shift+D |
| View | Zoom In | ⌘=, ⇧⌘= | Ctrl+=, Ctrl+Shift+= |
| View | Zoom Out | ⌘- | Ctrl+- |
| View | Actual Size | ⌘0 | Ctrl+0 |
| View | Toggle Word Wrap | — | Alt+Z |
| View | Toggle Full Screen | ⌃⌘F | F11 |
| View | Show Markdown Source | ⌥⌘U | — |
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
light/dark theme, zoom, CRLF-preserving file I/O, describe-key and keybinding listings, a clickable
status bar (position, word/selection count, encoding, line ending, Language, zoom).

Deferred (in DESIGN.md, not built): Rackorg (Org-compatible mode), multiple cursors, splits,
a piece-tree text store and custom renderer, undo tree, tree-sitter, LSP, session restore,
line-number gutter, and everything in the legal-workspace section (PDF/Word/Outlook integrations).

## Third-party material

- `rackmac-markdown/tests/spec/spec-0.31.2.json`: the CommonMark specification's examples (0.31.2), used only as
  test data; CC BY-SA 4.0, attributed in `rackmac-markdown/tests/spec/LICENSE.md`.
- `rackmac-markdown/entities.rktd`: the WHATWG HTML named-character-reference table (`entities.json`), reformatted;
  the WHATWG HTML Living Standard is licensed CC BY 4.0.
- `rackmac/ui/workbench-icons.rktd`: icons from the Skeptical Engineering Workbench set
  (`skepticalengineering-design`, vendored by `tools/workbench-icons.rkt`).
- IBM Plex is used when installed and is not bundled (#330); if it is bundled, its SIL OFL 1.1 license files ship with it.
