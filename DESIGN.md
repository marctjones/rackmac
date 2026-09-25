# Rackmac — an Emacs-inspired editor for the modern desktop, written in Racket

> **Status (read this first).** A first iteration is built and runs: see [README.md](README.md).
> It deliberately implements only the Emacs-style *layer* (command registry, layered keymaps, modes,
> hooks, init file, live eval, palette) on top of Racket's `text%`, which supplies storage, rendering,
> selection and undo. Everything below about a piece tree, a custom canvas renderer, an undo tree, multi-cursor,
> Rackorg, and the legal-workspace integrations (Word, PDF, Outlook, SharePoint) is **design, not implemented**,
> and §8's "text% is deliberately not the buffer" applies to the later rewrite that multi-cursor and overlays would need.
> The user redirected scope to the basic editor, so the legal-workspace sections are parked.
> Verified: 61 automated tests, plus a launch on macOS. Not verified: keys in the live window (OS-level keystrokes never produced a dispatch in my one attempt) and any real Windows run.

### Extension model (built)

Racket is used for both layers Emacs splits between C and Lisp: Racket's runtime and `racket/gui` play the
role of Emacs's C core, and the editor's own core and the user's extensions are both Racket. Every `.rkt` module
is compiled to machine code before it runs (cached in `compiled/` by `raco make`), so the line between "compiled"
and "scripted" is not the language but the **API contract**: extensions may depend only on `rackmac/api` and
`rackmac/lang/*`, which is enforced when an extension loads. Extensions use `#lang rackmac` (the same `.rkt` extension
as everything else; the `#lang` line and the directory signal the role), declare `(extension-info #:requires-api N)`, and
are tracked per file so they can be unloaded and reloaded. Still design-only: a `rackmac build` command that statically
links chosen extensions into a custom executable with `raco exe`, and moving the core into a `core/` directory.

Working name: **Rackmac**. Its Org-mode equivalent: **Rackorg** (`.org` compatible).

## 1. Vision

Emacs got the *architecture* right and the *surface* dated. The architecture is a small
core, a live extension language, buffers as the universal abstraction, and modes that
compose. The surface is `C-x C-s`, a modal minibuffer, and a UI that ignores platform
conventions.

Rackmac keeps the architecture and replaces the surface:

- **Architecture from Emacs:** everything is a command, everything is a buffer, modes
  compose, the running editor is scriptable and redefinable, documentation is built in.
- **Conventions from modern apps:** `Cmd/Ctrl+S`, `Cmd/Ctrl+Z`, `Cmd/Ctrl+P`, multi-cursor,
  command palette, native menus, tabs, dark mode, drag-and-drop, session restore.
- **Language:** Racket. It is the closest living relative of Lisp with the tools Emacs Lisp
  lacks: a real module system, hygienic macros, `#lang` for embedded languages, contracts,
  lexical scope by default, threads, and a GUI toolkit in the standard distribution.

### Design principles

1. **Small core, large library.** The core is buffers, keymaps, commands, and a redisplay
   loop. Everything else (file tree, git, Org, LSP) is a package written against the same public API.
2. **Live system.** You can `eval` a definition in the running editor and change behavior
   immediately. Users never need a restart to iterate.
3. **Modern conventions only, Emacs power underneath.** Every default shortcut follows
   current desktop conventions for the platform the user is on (macOS or Windows). There is no
   Emacs or Vim keymap preset; users who want one can write it as a package, but the project doesn't ship or maintain one.
4. **Nothing is privileged.** Org-style outlining, the file tree, git, and the terminal are all
   packages written in the Rackmac scripting language against the public API, the same API users get. Rackorg
   is one mode among many, not a special case in the core.
5. **One data model per concern.** One text model, one command model, one keymap model, one
   mode model. Packages extend them; they don't invent parallel ones.
6. **Discoverability.** Every command, variable, and mode has a docstring and shows up in the palette and help.

## 2. Why Racket fits

| Emacs mechanism | Emacs Lisp | Rackmac (Racket) |
|---|---|---|
| Extension language | Elisp, dynamic scope by default | Racket, lexical scope, modules |
| Packages | `require`/`provide` by convention, global namespace | `module`s and `raco pkg`; real namespaces |
| Buffer-local variables | `make-local-variable` | Parameters plus a per-buffer hash (`define-buffer-local`) |
| Hooks | `add-hook` | Typed hook objects with priorities |
| Advice | `advice-add` | `define-advisable` wrapper macro |
| Major/minor modes | `define-derived-mode` | `define-mode` macro producing a `mode` struct |
| Domain languages | Rarely | `#lang rackmac/keymap`, `#lang rackorg/template` |
| Sandboxing | None | `racket/sandbox`, custodians, security guards |
| Concurrency | Single thread plus process filters | Green threads, places, `subprocess`, events (`sync`) |
| Self-doc | Docstrings | Docstrings plus Scribble; `describe-*` commands read the same metadata |

Racket CS (Chez backend) gives fast native code. `racket/gui` (Cocoa, Win32, GTK) provides
menus, dialogs, canvases, and drag-and-drop from the standard distribution.

## 3. Architecture overview

```
┌───────────────────────────────────────────────────────────────┐
│ Frontend (racket/gui)                                           │
│  frame%, menu bar, tabs, splits, canvas% renderer, dialogs      │
├───────────────────────────────────────────────────────────────┤
│ Editor core                                                     │
│  Window tree · Buffers · Keymaps · Commands · Minibuffer        │
│  Modes · Hooks · Variables · Undo tree · Kill ring/clipboard    │
├───────────────────────────────────────────────────────────────┤
│ Services                                                        │
│  Syntax (tree-sitter FFI) · LSP client · Process mgr · Search   │
│  Project index · Git · Settings store · Package manager         │
├───────────────────────────────────────────────────────────────┤
│ Packages (all built on the public API)                          │
│  rackorg · file-tree · terminal · git · lsp · markdown · racket │
└───────────────────────────────────────────────────────────────┘
```

**Process model.** One main GUI thread runs the event loop. Editor state is mutated only
from a single *editor thread* that consumes an event queue (key events, timers, async
results). Blocking work (LSP, git, indexing, export) runs in Racket threads or places and
posts results back to the queue. This keeps buffer mutation single-writer and removes most locking.

**Frontend/core split.** The core never touches `racket/gui`. It talks to a `frontend`
interface (`draw!`, `measure-text`, `clipboard-get/set!`, `prompt-file`, ...). Rackmac is
**desktop-only** (macOS and Windows laptops/desktops), so the interface exists for testability (a headless
frontend drives the whole editor in CI), not to support other frontends. No terminal or web UI is planned.

## 4. Core data model

### 4.1 Text storage

- **Piece table over immutable chunks**, with a balanced tree of pieces (rope-like) for
  O(log n) edits and cheap structural sharing.
- Persistent structure makes **undo snapshots** and **async readers** (syntax, LSP, export)
  cheap: a reader takes a `buffer-snapshot` and works on it while the user keeps typing.
- Positions are **code-point offsets**; a grapheme-cluster index is layered on top for
  cursor motion and rendering (emoji, combining marks). Line index is a cached tree.

```racket
(struct buffer
  (id name [text #:mutable]          ; persistent piece tree
   [point-set #:mutable]             ; list of selections (multi-cursor)
   [markers #:mutable]               ; weak set of marker structs
   [props #:mutable]                 ; interval tree: face/invisible/display/keymap
   [modes #:mutable]                 ; major + list of minor modes
   locals                            ; buffer-local variable hash
   [undo #:mutable]                  ; undo tree
   [file #:mutable] [modified? #:mutable] [version #:mutable]))
```

### 4.2 Selections, not just point

Emacs has one point and one mark. Modern editors have many selections. Rackmac's primitive is
a **selection set**: a non-empty list of `(anchor . head)` ranges. All editing commands map
over the set. Single-cursor is the one-element case, and the Emacs "mark" is the anchor of a selection.

### 4.3 Markers and text properties

- **Markers** track a position through edits. They are weakly held, so unreferenced markers don't leak.
- **Properties/overlays** live in an interval tree keyed by range. Standard properties are
  `face`, `invisible`, `display`, `keymap`, `read-only`, and `help-echo`. Rackorg uses these
  heavily for folding, inline images, and rendered links.

### 4.4 Undo

An **undo tree** (as in `undo-tree`/Vim) rather than a linear stack. Edits are grouped into
transactions (`with-undo-group`) so that a multi-cursor edit or a command undoes as one unit.
`Cmd/Ctrl+Z` walks back; `Cmd/Ctrl+Shift+Z` walks forward; a visualizer buffer shows branches.

### 4.5 Kill ring and clipboard

The kill ring remains (it's a great idea), but it is **synchronized with the system
clipboard**. `Cmd+C/X` push both. `Cmd+V` pastes the newest entry; `Cmd+Shift+V` opens a
clipboard-history picker over the kill ring.

## 5. Commands, keymaps, and the command palette

### 5.1 Commands

A command is a function plus metadata. Metadata drives the palette, menus, help, and macro recording.

```racket
(define-command (buffer-save [buf (current-buffer)])
  #:title "Save"
  #:doc "Write the buffer to its file, prompting if it has none."
  #:category 'file
  #:default-keys '("Mod-s")
  #:menu '(File "Save")
  (unless (buffer-file buf) (buffer-set-file! buf (prompt-save-path)))
  (write-buffer-to-file! buf))
```

- `#:interactive` specs (like Emacs `interactive`) describe how to gather arguments from
  the minibuffer, the selection, or the prefix argument.
- Commands are **first-class values in a registry** keyed by symbol. Menus, the palette,
  keymaps, and the macro recorder all refer to them by name.
- **Keyboard macros** record command invocations (not keystrokes), so they survive rebinding.

### 5.2 Keymaps

Keymaps are layered and resolved most-specific first:

```
overlay/text-property keymap
  → minor-mode keymaps (most recently enabled first)
    → major-mode keymap
      → global keymap (active preset)
```

- **`Mod`** abstracts the platform primary modifier: `Cmd` on macOS, `Ctrl` on Windows/Linux.
- **Key sequences and chords** are supported (`Mod-k Mod-c`, VS Code style), with a
  **which-key popup** listing continuations after a prefix key.
- **Platform keymaps, not presets.** There is one logical keymap written against `Mod`,
  plus a small per-platform override layer (see 5.3) for the places where macOS and Windows
  conventions genuinely differ. Users can rebind anything, per platform or for both.
- A keymap DSL is a `#lang`, so `keys.rkt` can read declaratively:

```racket
#lang rackmac/keymap
(mode global
  ("Mod-s"       buffer-save)
  ("Mod-Shift-p" command-palette)
  ("Mod-p"       quick-open)
  ("Mod-f"       find-in-buffer)
  ("Mod-d"       select-next-occurrence))
(mode rackorg
  ("Tab"        outline-cycle-fold)
  ("Alt-Up"     outline-move-subtree-up)
  ("Mod-Return" outline-insert-heading))
```

### 5.3 Standard shortcut set (macOS and Windows)

| Action | macOS | Win/Linux |
|---|---|---|
| Save / Save As | Cmd+S / Cmd+Shift+S | Ctrl+S / Ctrl+Shift+S |
| Open / Quick open | Cmd+O / Cmd+P | Ctrl+O / Ctrl+P |
| Command palette | Cmd+Shift+P | Ctrl+Shift+P |
| Undo / Redo | Cmd+Z / Cmd+Shift+Z | Ctrl+Z / Ctrl+Y |
| Cut / Copy / Paste | Cmd+X / C / V | Ctrl+X / C / V |
| Select all | Cmd+A | Ctrl+A |
| Find / Replace | Cmd+F / Cmd+Opt+F | Ctrl+F / Ctrl+H |
| Find in project | Cmd+Shift+F | Ctrl+Shift+F |
| Go to line / symbol | Ctrl+G / Cmd+Shift+O | Ctrl+G / Ctrl+Shift+O |
| New tab / Close tab | Cmd+T / Cmd+W | Ctrl+T / Ctrl+W |
| Next / prev tab | Cmd+Opt+→/← | Ctrl+PgDn/PgUp |
| Split right / down | Cmd+\ / Cmd+Shift+\ | Ctrl+\ / Ctrl+Shift+\ |
| Toggle comment | Cmd+/ | Ctrl+/ |
| Add cursor above/below | Cmd+Opt+↑/↓ | Ctrl+Alt+↑/↓ |
| Select next occurrence | Cmd+D | Ctrl+D |
| Move line up/down | Opt+↑/↓ | Alt+↑/↓ |
| Toggle sidebar | Cmd+B | Ctrl+B |
| Toggle terminal | Ctrl+` | Ctrl+` |
| Eval selection / buffer | Cmd+Enter / Cmd+Shift+Enter | Ctrl+Enter / Ctrl+Shift+Enter |

**Where the platforms differ (per-platform override layer)**

| Action | macOS | Windows |
|---|---|---|
| Primary modifier (`Mod`) | Cmd | Ctrl |
| Redo | Cmd+Shift+Z | Ctrl+Y (also Ctrl+Shift+Z) |
| Word left/right | Opt+←/→ | Ctrl+←/→ |
| Delete word back/forward | Opt+Backspace / Opt+Fn+Delete | Ctrl+Backspace / Ctrl+Delete |
| Line start/end | Cmd+←/→ | Home/End |
| Document start/end | Cmd+↑/↓ | Ctrl+Home/End |
| Page up/down | Fn+↑/↓ (PgUp/PgDn) | PgUp/PgDn |
| Find next / previous | Cmd+G / Cmd+Shift+G | F3 / Shift+F3 (also Ctrl+G/Ctrl+Shift+G) |
| Preferences | Cmd+, | Ctrl+, |
| Quit / close window | Cmd+Q / Cmd+Shift+W | Alt+F4 / Ctrl+Shift+W |
| Move line up/down | Opt+↑/↓ | Alt+↑/↓ |
| Add cursor above/below | Cmd+Opt+↑/↓ | Ctrl+Shift+Alt+↑/↓ |
| Rename symbol | F2 (or Cmd+Shift+R) | F2 |
| Menu access | Menu bar | Alt-key mnemonics (`&File`) |
| Emoji / symbols | Ctrl+Cmd+Space | Win+. (OS-owned, not bound) |

**Rules that keep it working on laptops**

1. **Never rely on function keys, Home/End, or PgUp/PgDn alone.** Laptop keyboards hide these behind
   `Fn`. Every action bound to one gets a modifier+arrow alternative (as in the table).
2. **Avoid `Ctrl+Alt+<letter>` on Windows.** Many international layouts treat it as **AltGr**
   and use it to type characters (`@`, `€`, `{`, `[`). Windows multi-cursor and similar chords use `Ctrl+Shift+Alt` instead.
3. **Don't shadow OS-reserved shortcuts** (`Cmd+Space`, `Cmd+Tab`, `Win+…`, `Ctrl+Alt+Del`).
   A conflict checker runs at keymap load and warns.
4. **macOS native text navigation is honored.** macOS text fields treat `Ctrl+A/E/K/F/B/N/P/D/H`
   as line-start/end/kill/character/line motion system-wide. Rackmac keeps those on macOS only, because a Mac user's
   fingers already expect them; on Windows `Ctrl+A` is select-all and none of these apply.
5. **Layout-aware.** Bindings are on logical keys (`Mod-/`, `Mod-\`) but resolve through the active
   keyboard layout, with fallbacks for layouts where a symbol needs Shift or AltGr (German, French, Nordic).
6. **Touchpad gestures** are first-class on both: two-finger scroll and horizontal scroll, pinch to
   zoom text (`Mod+=` / `Mod+-` / `Mod+0` as equivalents), and three-finger swipe or two-finger swipe to move between tabs where the OS delivers it.

### 5.4 The command palette replaces `M-x`

`Mod-Shift-p` opens a fuzzy-matching picker over all commands, showing title, category, and
current binding. The same picker component (a **completing-read** with pluggable sources and
actions, like Vertico/Consult/Embark) powers quick-open, buffer switching, symbol search, and Org
capture. **One picker, many sources** is the modern replacement for the minibuffer zoo.

## 6. Modes

A mode bundles a keymap, hooks, syntax rules, variables, and enable/disable behavior.

```racket
(define-mode racket-mode
  #:kind 'major
  #:parent prog-mode
  #:file-patterns '("*.rkt" "*.scrbl")
  #:keymap (keymap ("Mod-Enter" racket-eval-region))
  #:syntax (tree-sitter-grammar 'racket)
  #:indent racket-indent-line
  #:locals ([tab-width 2] [comment-start ";"])
  #:on-enable  (λ (buf) (lsp-start buf 'racket-langserver))
  #:on-disable (λ (buf) (lsp-stop buf)))

(define-mode word-wrap-mode #:kind 'minor ...)
```

- **Derivation** (`#:parent`) inherits keymap, hooks, and locals, as with `define-derived-mode`.
- **Minor modes** toggle per buffer or globally and appear in a status-bar mode list you can click.
- **Hooks** are typed objects: `(add-hook! before-save-hook fmt-buffer #:priority 10)`.
- **Advice**: functions declared with `define-advisable` accept `:before`, `:after`, and
  `:around` wrappers. This preserves the Emacs monkey-patching culture without global mutation of module bindings.

### Syntax and language support

- **Tree-sitter via FFI** provides incremental parsing for highlighting, indentation,
  structural selection (expand/shrink), and code folding. A regex "font-lock" fallback covers languages without a grammar.
- **LSP client** (async, JSON-RPC over `subprocess`) provides diagnostics, completion,
  hover, go-to-definition, rename, and formatting. Results render as overlays and popups.

## 7. Extensibility and live programming

- **Config is code.** `~/.config/rackmac/init.rkt` is an ordinary Racket module in
  `#lang rackmac`, which is `racket/base` plus the editor API. A **Settings UI** edits a
  separate `settings.rktd` (data only) for people who never want to write code; the two never fight.
- **Live eval.** `Mod-Enter` evaluates the selection or top-level form in the editor's own
  namespace. Redefining a command takes effect on the next invocation. `dynamic-rerequire`
  hot-reloads modified packages.
- **Introspection.** `describe-key`, `describe-command`, `describe-variable`, and
  `find-definition` read metadata straight from the registries and jump to the source, keeping
  Emacs' "the editor explains itself" property.
- **Packages** are ordinary `raco pkg` packages exporting a `rackmac-package` manifest
  (name, version, provided modes/commands, required API version). Load order is by dependency, not by hand.
- **Safety.** Third-party packages run under a **capability object** for sensitive APIs
  (filesystem, network, subprocess) with an opt-in permission prompt on first use. Untrusted
  code, such as Org source blocks in a downloaded file, runs in `racket/sandbox` with memory and time limits.
- **Error isolation.** A command that raises is caught at the dispatch boundary, logged in
  `*Messages*`, and shown as a non-blocking notification with a "Show backtrace" action. One broken package must not take the editor down.

## 8. Rendering and UI

- **Renderer.** A custom `canvas%` draws text with `racket/draw` (Cairo/Pango). The editor
  owns layout: a line-layout cache keyed by `(buffer-version, width, font)` and dirty-region
  invalidation so only changed lines re-lay out. Virtualized scrolling means huge files stay smooth.
  (`racket/gui`'s built-in `text%` is deliberately *not* the buffer, since we need markers, multiple selections, and
  overlays that it can't express.)
- **Windows.** A binary tree of splits, each showing a buffer; tabs group window layouts.
  Panels (file tree, terminal, agenda, diagnostics) are ordinary buffers in dockable windows.
- **Native chrome.** Real menu bar built from command metadata (`#:menu`), native file
  dialogs, native clipboard, drag files to open, dark/light mode following the OS, HiDPI, system
  font fallback, and IME support for CJK input.
- **Status bar** shows major mode, minor-mode toggles, encoding, line ending, cursor count, diagnostics, and git branch.
- **Session restore.** Open buffers, unsaved edits (hot exit), window layout, and cursors persist across launches.
- **Themes** are data: a map from `face` names to colors and styles. Light and dark variants ship by default.

## 9. Rackorg: the Org-mode equivalent

**Rackorg is a package, written in the Rackmac scripting language.** It lives under
`packages/rackorg/`, is loaded through the same package mechanism as user packages, and uses only public APIs:
`define-mode`, `define-command`, text properties, the picker, the index service, and the sandbox. If Rackorg needs
something the core doesn't expose, the fix is to extend the public API for everyone, not to give Rackorg a back door.
This is the test of whether Rackmac is "as general as Emacs": a system as large as Org has to be buildable from the outside.

Rackorg is one **mode** (`rackorg-mode`, file pattern `*.org`) among many. It also ships an **outline-mode** core that
other modes reuse (Markdown headings, code folding by structure, log files), and its pieces are separable packages:
`rackorg-parser`, `rackorg-agenda`, `rackorg-babel`, `rackorg-export`, `rackorg-capture`. The Org AST and the agenda
index are ordinary Racket libraries that other packages, such as a notes app or a task dashboard, can `require`.

Goal: **read and write standard `.org` files** and cover the parts of Org people actually use
(outlines, TODOs, agenda, tables, capture, literate code, export), with a modern look.

### 9.1 Document model

Rackorg parses text to an **AST** following Org's element/object split:

- **Elements** (block-level): headline, section, paragraph, plain list, item, table, src
  block, example block, drawer, property drawer, planning line, keyword (`#+TITLE:`), comment, horizontal rule, footnote definition.
- **Objects** (inline): link, timestamp, emphasis (`*bold* /italic/ =verbatim= ~code~`), footnote reference, inline src, entity, target.

The parser is **incremental at section granularity**: an edit reparses only the enclosing
headline subtree (and its parents' cached metadata), keeping typing latency flat on large files.
The AST is immutable and produced from a buffer snapshot, so parsing runs off the editor thread.

```racket
(struct headline (level todo priority title tags planning props children ...))
(struct timestamp (kind start end repeater warning active?))
```

### 9.2 Editing features

| Feature | Behavior |
|---|---|
| Folding | `Tab` cycles a subtree (folded → children → all); `Shift+Tab` cycles the whole document. Implemented with `invisible` overlays. |
| Structure editing | `Alt+↑/↓` move subtree; `Alt+←/→` promote/demote; `Mod+Return` new heading/item, all with undo grouping. |
| TODO workflow | `Ctrl+Enter`/palette cycles states from `#+TODO: TODO NEXT | DONE`. State changes can log timestamps into a `:LOGBOOK:` drawer. |
| Tags and properties | `:tag1:tag2:`, `:PROPERTIES:` drawers, inherited tags, column view as a table panel. |
| Timestamps | `<2026-09-24 Thu +1w>`; a **date picker popup** (calendar widget) instead of the `C-c .` prompt. |
| Checkboxes and lists | `- [ ]`/`[X]` are click-toggleable, with `[2/5]` cookies auto-updating. |
| Tables | Pipe tables auto-align on `Tab`; spreadsheet formulas (`#+TBLFM:`) evaluated by a small Racket expression language; CSV paste-in. |
| Links | Pluggable link types (`file:`, `http:`, `id:`, `shell:`, `mail:`, `racket:`), completion on `[[`, backlinks panel, and `Cmd+Click` to follow. |
| Inline rendering | Optional "live preview": headings drawn with larger type, markers `*`/`=` hidden away from the cursor, images and LaTeX rendered inline, links shown as their descriptions. |

### 9.3 Agenda

- An **index** (SQLite via `db`) stores headlines, timestamps, tags, properties, and file
  mtimes for every file in `rackorg-directory`. It updates incrementally on save via the file watcher.
- The **agenda is a query over the index**, rendered into a normal buffer/panel:
  day/week/month views, `TODO` lists, tag/property searches, stuck projects, and habits.
- **Query DSL** (s-expression, also exposed as a `#+BEGIN: agenda` dynamic block):

```racket
(agenda-query
  (and (todo "NEXT") (tags "work") (not (scheduled-after (today))))
  #:sort '(priority deadline))
```

- Agenda rows act on the source headline in place (reschedule, change state, refile) without visiting the file.
- Recurring events, `SCHEDULED`/`DEADLINE` with warnings, and a system notification for upcoming items.

### 9.4 Capture and refile

- Global hotkey opens a small **capture window** (template picker → form) even when the main editor isn't focused.
- Templates are data with placeholders (`%t`, `%^{Prompt}`, `%a` for the link to where you were); refile is a picker over all headline paths.

### 9.5 Literate programming (Babel equivalent)

Source blocks execute through **evaluators**, small plugins with one function
`(eval-block lang code params session) → result`.

```org
#+begin_src racket :session main :results table
(for/list ([i 5]) (list i (* i i)))
#+end_src

#+RESULTS:
| 0 |  0 |
| 1 |  1 |
| 2 |  4 |
```

- The **Racket evaluator is native**: blocks run in a per-session `racket/sandbox`
  namespace and can share values across blocks, use `#lang` blocks, and return `pict`s that render inline as images.
- Other languages (shell, Python, SQL) use subprocess evaluators with the same interface.
- Header args: `:session`, `:results` (value/output/table/file/replace/silent), `:var`, `:tangle`, `:dir`, `:noweb`.
- `:tangle` extracts source into files; **noweb references** allow real literate programs.
  Execution requires an explicit per-file trust decision (a banner with "Trust this file"), because running code from a
  downloaded `.org` is a real security boundary.

### 9.6 Export

The AST feeds an **exporter pipeline**: transcoders (AST → target AST) plus backends.

- Built-ins: HTML, Markdown, plain text, and **PDF via Scribble/`pict`** rather than LaTeX (LaTeX backend optional).
- Because the AST is a Racket data structure, an export filter is just a function `AST → AST`, which makes custom export behavior trivial to write.
- Live **preview pane** renders HTML in a `racket/gui` web view or the native renderer, refreshed as you type.

### 9.7 Compatibility stance

Standard Org syntax round-trips **byte-for-byte** when unmodified (the parser keeps
source spans and the printer only re-emits edited nodes). Elisp-only features (`#+BEGIN_SRC emacs-lisp`
evaluation, custom Elisp agenda commands) are out of scope; the block is preserved, not executed.

## 10. Other bundled packages

- **File tree and quick-open**: project-aware (git root), `.gitignore` respected, fuzzy matching.
- **Search**: in-buffer incremental search (isearch's live feedback, `Cmd+F` UI), project-wide via ripgrep with an editable results buffer (wgrep-style: edit results and save back to files).
- **Terminal**: a PTY-backed terminal buffer (subprocess plus a VT100 parser).
- **Git**: status buffer, staged/unstaged hunks, blame gutter (Magit-inspired; the UI is a command-driven buffer with transient-style menus).
- **Dired equivalent**: a directory buffer that is editable text, with rename-by-editing.
- **Racket support**: eval in buffer, macro stepper, REPL buffer, `raco` integration, Scribble preview, and DrRacket-style arrows for binding info.

### 10.0 Primary use case: a legal-practice workspace

**Primary user: a practicing lawyer** managing many matters, taking meeting notes, and working
constantly with Word documents, PDFs, and web sources. This section supersedes the developer-oriented
priorities in 10.1. The general editor stays general; the legal workspace is a **distribution**, meaning a bundle of
packages plus defaults (`rackmac-legal`), built only on the public API, the same as Rackorg.

The organizing idea is that **a matter is a first-class object**, and every note, document, PDF, web capture, deadline,
contact, and time entry belongs to one.

#### Matters

- A matter is a folder plus an index file (`matter.org`) whose property drawer holds: client, matter number, matter
  name, responsible attorney, opposing party/counsel, court/tribunal and case number, status, opened/closed dates.
  Plain files on disk, so they work with backup, sync, and any document management a firm already uses.
- **New-matter command** scaffolds the folder from a template (Correspondence, Pleadings, Discovery, Research, Notes, Billing).
- A global **SQLite index** (see 9.3) spans all matters: cross-matter agenda, "everything for client X", conflict-style
  name lookups, and a **matter switcher** on `Mod-Shift-M` (same picker as everything else). The status bar shows the current matter.
- **Link types:** `matter:2026-0142`, `person:Jane Roe`, `pdf:`, `docx:`, `web:`, `email:`. Backlinks show every note that mentions
  a person, document, or authority.
- **Matter-scoped search** (`Mod-Shift-F`): one full-text index (SQLite FTS) over notes, extracted Word text, PDF text (with OCR
  for scans), web captures, and filed emails, with filters for matter, date, and document type.

#### Meeting notes

- **Meeting capture** (global hotkey, works when the main window isn't focused): choose the matter, and the template fills in
  date/time, attendees (from a people index with autocomplete), and, optionally, the calendar event's title and invitees via ICS/CalDAV.
- Structure: attendees, agenda, discussion, **decisions**, and **action items**. Action items are ordinary `TODO`
  headlines with an owner and due date, so they appear in the cross-matter agenda immediately.
- **Timekeeping built in:** `Mod-T` starts a clock on the current matter or headline; stopping it records a time entry with
  a narrative. Configurable billing increments (0.1 h), rounding rules, and export to CSV/LEDES for billing systems.
- **Privilege marking:** a configurable header/footer ("Privileged & Confidential / Attorney–Client Communication / Attorney Work
  Product") applied automatically to exports and prints, and shown as a banner in the buffer.
- **Follow-up:** one command turns action items into a draft email or a Word memo from a firm template.

#### Deadlines

- Dates are first-class (Org timestamps with repeaters and warnings), plus a **deadline calculator** that counts days from a
  trigger date using a **rules table you define** (calendar vs. court days, holiday lists, weekend roll-forward, service-method add-ons).
- Caveat by design: the tool ships **no built-in claim to be authoritative** about any jurisdiction's rules. Rule tables are
  user-editable data, shown with the computation, and the lawyer verifies. A wrong deadline is a malpractice-grade error.
- The agenda shows upcoming deadlines across matters with escalating warnings and system notifications; each deadline links to its trigger and source rule.

#### Word documents (`.docx`)

A `.docx` is a zip of XML, which Racket handles with its standard zip and XML libraries. The goal is not to reimplement Word.
Full-fidelity WYSIWYG editing is explicitly out of scope; Word remains the drafting tool. Rackmac wraps it with what Word does badly.

| Capability | What it does | Phase |
|---|---|---|
| **Read and index** | Open a `.docx` in a read view showing headings, text, comments, and tracked changes; contents feed matter search. | 1 |
| **Edit in Word for the web** | One key opens the document's SharePoint/OneDrive URL in the browser. Rackmac reads the synced copy (or fetches via Graph, see 10.3) and re-indexes after each save, including co-authors' changes. | 1 |
| **Extract to notes** | Pull comments, tracked changes, or a selected passage into a note, with a `docx:` link back to the location. | 1 |
| **Compare** | Two versions produce a **redline**: output is a `.docx` with real tracked changes, or a PDF. Word-level, with moved-text detection. | 2 |
| **Generate** | Build a `.docx` from a firm template plus a clause library and matter properties (party names, dates, court), or from a Rackorg note using the firm's styles. | 2 |
| **Metadata scrub** | Before sending: strip author names, comments, revision history, hidden text, and document properties, with a preview of what will be removed. | 2 |
| **In-app editing** | Not planned. Word for the web is the editor (decided). Rackmac never writes to a `.docx` you're editing, which also avoids clobbering co-authors. Generated documents are new files. | — |

#### SharePoint, OneDrive, and plain folders

A matter's files may live in a SharePoint library, a OneDrive folder, or an ordinary folder, and sometimes all three.
Rackmac treats them uniformly through a **document reference**: `{location, drive-id, item-id, web-url, local-path?, content-hash}`.

- **Synced folders first.** The OneDrive/SharePoint sync client makes files local, so Rackmac reads them like any file. This works
  with no IT approval, and it's the baseline everything else builds on.
- **Stable links.** A `docx:` or `pdf:` link stores the item ID and web URL, not just a path, so renaming or moving a file
  in SharePoint doesn't break your notes.
- **Graph API (optional, needs tenant approval):** lists version history for **compare against the prior turn**, resolves web URLs for "Edit in
  Word for the web," and reads comments. See 10.3.
- **Co-authoring safe:** Rackmac reads snapshots and never holds a file open for write.

#### Transactional workflows (priority practice area)

Transactional work is a lot of documents moving through turns with many parties. The package set therefore leans toward
tracking and comparison rather than litigation.

- **Deal workspace.** A matter of type "deal" holds parties, counsel, key dates, and a document list with a status for each
  (draft, with counterparty, agreed, signed).
- **Closing checklist.** An Org-style table or outline of every closing deliverable with responsible party, status, and due
  date. It's a live view over the same TODO/agenda machinery, so open items show up in the cross-matter agenda. Export to Word/PDF to circulate; import status updates from a marked-up copy.
- **Signature-packet tracker.** Per signatory: pages sent, received, and held in escrow, with a reminder when one is outstanding.
- **Turn comparison.** Compare v3 with v4 (or the latest against the last version *you* reviewed) and produce a redline. Keeps
  a per-document "turns" history with who sent what and when.
- **Clause library and precedent.** Tagged clauses with alternates (buyer-friendly, seller-friendly, fallback), inserted into generated documents with matter
  variables. Search across prior deals' documents for how a clause was handled.
- **Defined-terms and cross-reference checks.** Flag capitalized terms that are used but never defined (or defined but unused), and broken
  section cross-references. This is heuristic and reports suspects for you to review; it does not certify.
- **Issues list.** A per-deal table of open points (section, our position, their position, status), with links to the exact passage in each draft.
- Litigation features (transcript mode, `page:line` citations, exhibit builder, Bates) remain in the design but are **deprioritized** behind the above.

#### PDFs

**First iteration: read-only PDFs.** Viewing, search, OCR, quote-to-note links, and transcript citations. **Deferred:** writing annotations into the PDF,
page assembly, exhibit/Bates stamping, redaction, metadata scrubbing of PDFs, and any other PDF editing.

- **Viewer:** native-quality rendering (PDFium through the FFI; see 10.3), continuous
  scroll, thumbnails, bookmarks, text search, two-up view, and pinch-zoom on trackpads.
- **Scans:** OCR on import (the OS engines: Apple Vision on macOS, Windows OCR on Windows) writes a searchable text layer and feeds the index.
- **Annotate into notes:** select text and press `Mod-Shift-N` to create a quote note that stores the **page, the quoted
  text, and coordinates**. Following the link reopens the PDF at the highlight. In the first iteration highlights live in the note only; writing them back into the PDF as standard annotations is later.
- **Transcripts:** citations use `page:line` (`pdf:smith-depo.pdf::12:4–13:2`), and a **transcript mode** shows line numbers and
  builds testimony summaries and page/line indexes.
- **Assemble (later, not in the first iteration):** merge, split, reorder, and extract pages; **exhibit builder** applies stamps and Bates numbers, and generates the exhibit index.
- **Redaction (later, not in the first iteration):** real content removal (text, images, and underlying data, not black boxes), followed by a verification pass that
  re-extracts text to confirm nothing survived, plus metadata scrubbing. This is a feature where failure is embarrassing and sometimes sanctionable, so it gets its own test corpus.

#### Websites

- **Web clipper:** given a URL, capture (1) the readable text, (2) a full-page **PDF/HTML snapshot**, and (3) metadata: URL,
  page title, **retrieval date/time**, and a content hash. All are stored in the matter folder. Notes link to the archived copy and show the original URL.
- **Why:** pages change and vanish. A captured, time-stamped copy is the version you actually relied on. (Whether a capture suffices as
  evidence is a legal question for you; the tool records what it fetched, when.)
- **Send to Rackmac:** a `rackmac://clip?url=…` handler plus a small browser extension ("Clip to current matter") for Chrome, Edge, Safari, and Firefox.
- **Link-rot check:** a command re-checks a matter's `web:` links and flags dead or changed pages.
- **Viewing:** an embedded view through the OS web engine (WKWebView on macOS, WebView2 on Windows) is possible via FFI but
  is the riskiest integration in this document. The fallback is the reader-mode text view plus the snapshot PDF in the PDF viewer.

#### Email (stretch, but central to legal work)

Outlook is the target (decided; Apple Mail is not). Drag a message from Outlook (`.msg`/`.eml`) into a matter: it's stored with attachments, its text is indexed, and a
note is created with sender, recipients, date, and subject. Rackmac never touches your mail account; it only handles files you file.

#### Confidentiality by design

- **Local-first.** Everything lives in files on your machine. There is no cloud service, account, or telemetry; network features
  (web clip, CalDAV) are explicit, per-action, and logged.
- **Code execution off in the legal workspace.** Org source-block execution and package auto-install are disabled by
  default. Third-party packages can't read matter files or use the network without a per-package permission (see §7).
- **Encryption:** rely on OS full-disk encryption (FileVault / BitLocker) as the baseline. Optional per-matter encryption is on the roadmap, not assumed.
- **Local history:** automatic versioned snapshots of notes per matter (undo across sessions), plus an **activity log** you can export.
- **Firm policy:** confidentiality and technology-competence duties (e.g. ABA Model Rules 1.1 and 1.6) are the user's and the firm's
  call. The design provides the controls; it doesn't certify compliance. Have the firm's IT/security lead review before
  putting client data in it.

### 10.1 General Emacs-derived packages (developer-oriented; deferred behind 10.0)

The rule for inclusion is that a mode either (a) is why people stay in Emacs, or (b) stress-tests
the extension API in a way that Rackorg doesn't. Each is a package built only on the public API.

**Developer tier (build later, or only if wanted)**. For a legal user, the useful ones from this table are the shared
picker, transient menus, Dired-style file handling (for matter folders), and projects (which map onto matters). Git, LSP,
and TRAMP are not needed for the legal workspace.

| Emacs original | Rackmac version | What "modern" means here | Stress-tests |
|---|---|---|---|
| **Magit** | `rackmac-git` | Status buffer with stageable hunks and lines, inline diffs, interactive rebase as a drag-and-drop list, commit message buffer with conventional-commit completion, PR/CI status via forge APIs. Popup menus show the next available keys. | Interactive buffers, subprocess streams, text-property-driven actions |
| **Dired** (+ wdired) | `rackmac-files` | A directory is an editable text buffer: rename by editing, mark with the mouse or keyboard, bulk operations, previews, Finder/Explorer "reveal", drag-out to other apps. | Editing a buffer that maps to a non-text resource |
| **Helm/Ivy/Vertico + Consult + Embark** | The `picker` in core (§5.4) | Already central. Sources: buffers, files, symbols, commands, git refs, agenda items. **Actions on candidates** (Embark): press `Mod-.` on any candidate to see verbs (open, copy path, delete, open in split). | Composable UI, one abstraction shared by all packages |
| **which-key + transient** | `rackmac-menus` | Key-continuation popups plus **transient-style menus**: a persistent, discoverable command panel with toggles and switches. This is Magit's UI idea, generalized, with mouse support. | Ephemeral modal UI on the public API |
| **Eglot / lsp-mode** | `rackmac-lsp` | Diagnostics gutter, hover, code actions as a lightbulb menu, rename preview, inlay hints, call hierarchy. | Async protocol, overlays, popups |
| **TRAMP** | `rackmac-remote` | Open `ssh://host/path`, WSL paths, or containers as if local, including saving, search, and running the terminal there. Modern take: a small remote agent replaces shell-scraping, which is why TRAMP is slow. | Virtual filesystem abstraction |
| **Projectile / project.el** | `rackmac-projects` | Auto-detects projects (git root, `raco`/`package.json`/`Cargo.toml`), per-project settings, session, run/test/build tasks, and recent projects on the start screen. | Workspace state |
| **Flycheck / Flymake** | Part of `rackmac-lsp` and `rackmac-diagnostics` | Unified diagnostics model: linters, compilers, and LSP all publish to the same panel and gutter. | Multiple producers, one consumer |

**Tier 2: daily-driver productivity**

| Emacs original | Rackmac version | Notes |
|---|---|---|
| **Company / Corfu / Cape** | `rackmac-complete` | In-buffer completion popup with pluggable sources (LSP, words, paths, snippets, Org links). |
| **YASnippet / Tempo** | `rackmac-snippets` | Tab-stop snippets with mirrored fields; snippets written in the same `define-…` style as commands; Racket expressions inside placeholders. |
| **multiple-cursors / expand-region** | Core (multi-cursor) plus `rackmac-structure` | Multi-cursor is core. Structural expand/shrink selection uses tree-sitter. |
| **Paredit / lispy / smartparens** | `rackmac-structure` | Structural editing for Lisps and any tree-sitter language (slurp, barf, raise, splice). This matters especially for Racket. |
| **avy / ace-jump** | `rackmac-jump` | Type a few characters, get labels on all visible matches, jump or select. A big win with multi-cursor. |
| **undo-tree / vundo** | Core undo tree (§4.4) | Already designed in. |
| **Isearch + wgrep + rg.el + occur** | `rackmac-search` | Live incremental find, project search with an **editable results buffer** (edit results, save back to the source files), and "find all occurrences then multi-edit". |
| **ediff / smerge** | `rackmac-diff` | Side-by-side three-way merge with per-hunk accept, word-level diffs, and semantic diffs for structured files. |
| **Eshell / vterm** | `rackmac-terminal` | Real PTY terminal buffer, plus a **Racket-scripted shell** (Eshell's idea): pipe values, not just bytes, with `#lang`-style scripting at the prompt. |
| **compilation-mode / next-error** | `rackmac-tasks` | Run build/test commands, parse errors into clickable locations, and jump between them with one shared "next problem" command across compilers, linters, grep, and test failures. |
| **Bookmarks / registers / mark ring** | `rackmac-navigation` | Named locations, back/forward navigation history (`Mod-[` / `Mod-]`, as in an IDE), and saved-window layouts. |
| **Recentf / desktop-save / savehist** | Core session restore | Already in §8. |

**Tier 3: knowledge and communication (Emacs's "life in a text editor" side)**

| Emacs original | Rackmac version | Notes |
|---|---|---|
| **org-roam / Denote** | `rackorg-notes` | Zettelkasten on Rackorg's index: backlinks panel, graph view, daily notes, and transclusion. Belongs beside Rackorg because it reuses the AST and index libraries. |
| **Markdown-mode / Pandoc** | `rackmac-markdown` | Live preview, table editing, and **shared outline core with Rackorg**. Answers the open question about Markdown-style headings without changing Org. |
| **Calc / calc-mode** | `rackmac-calc` | Symbolic/RPN calculator dock using Racket's numeric tower, with exact rationals and bignums for free, plus units. |
| **Email (mu4e, notmuch, gnus)** | `rackmac-mail` | Optional. Search-first mail over IMAP/JMAP with Rackorg capture from messages. Large scope; treat as a stretch package. |
| **Elfeed / RSS, EWW** | `rackmac-reader` | Feed reader and a readable-text web viewer (article mode), with links into notes. |
| **Calendar / diary / appt** | `rackmac-calendar` | Month/week view over Rackorg's agenda index and (optionally) system calendars via CalDAV. |
| **Org-Babel-adjacent: Jupyter/EIN, ob-* REPLs** | `rackmac-notebook` | Notebook-style execution outside Org (literate `.rkt` with `#lang scribble` sections, cell results inline). |
| **Tab-bar / winner / perspective** | Core window model | Layout undo (`winner-mode`) and workspaces already fit the window tree. |
| **Games and toys** (Tetris, doctor, hanoi) | `rackmac-toys` | Yes, keep it. They're the cheapest proof that the API can build a full interactive app inside a buffer. |

**Deliberately *not* reinventing**

- **Gnus, ERC, Emacs-w3m and similar heavyweights** in the early releases: large surface, and better native apps exist.
- **CUA/Evil/god-mode-style keymap emulation**: out of scope for this project (see the modern-shortcuts decision).
- **Package.el-style archive plumbing**: `raco pkg` already does it.

### 10.2 What this list demands of the core

Reading down the table, five general capabilities recur across packages. If the core gets these right, most of
the list is straightforward:

1. **Buffers that aren't files.** Dired, Magit, agenda, terminal, and results buffers are *views onto some other
   state* with their own keymap and edit semantics (`buffer-backend` protocol: `read`, `apply-edit`, `save`).
2. **Actions attached to text.** Text properties carry a keymap and an action so any span can be clickable and keyboard-activatable (Magit hunks, Org links, Embark).
3. **A shared picker and popup/menu toolkit.** One UI component vocabulary, used by everything.
4. **Async job and stream API.** Structured process/network/LSP results flow into buffers without blocking (`spawn-job`, `job-output-port`, cancellation via custodians).
5. **A virtual-filesystem layer.** Local, remote, archive, and virtual paths share one interface, which is what makes TRAMP-style remote editing possible.

### 10.3 Integration decisions: PDF engine and Microsoft 365

#### One cross-platform PDF engine: PDFium (decided)

**Decision (final): use PDFium**, called through Racket's FFI from a dedicated worker place. It is the engine for rendering, text extraction,
on both macOS and Windows. The first iteration needs only rendering and text extraction with coordinates; annotations, forms, and page operations come later. One engine means identical rendering on both platforms and one binding to test.

| Engine | License (verify before distributing) | Verdict |
|---|---|---|
| **PDFium** (Chromium's engine) | Permissive (BSD/Apache-style) | **Chosen.** Chrome-grade rendering, one native library per platform. API covers render, text with coordinates, annotations, form fields, page import/merge/reorder, thumbnails. Prebuilt binaries exist for macOS and Windows on both x64 and ARM64 (confirm current builds). |
| **MuPDF** | AGPL, or paid commercial license | Excellent, with built-in redaction, but AGPL would force open-sourcing Rackmac or buying a license. |
| **Poppler / Xpdf** | GPL | Same distribution problem; weaker on editing. Existing Racket packages (`pdf-read`, `pdf-render`, `racket-poppler`) wrap Poppler. |
| **OS-native** (PDFKit / Windows PDF) | Platform | Two code paths, different features, and no shared behavior for tests. |

*(The licensing summary is from general knowledge. Get your own legal read before any distribution.)*

**Cost of the choice**
- **Binding size:** PDFium's C API is large but flat. Racket's `ffi/unsafe` handles it well, and Rackmac needs roughly the
  rendering, text, annotation, and page-manipulation subsets, not the whole API. Small compared with the editor itself.
- **Threading:** PDFium isn't thread-safe, and a Racket foreign call blocks the calling place. All calls go through one **dedicated worker place** with a
  request queue. Long calls are marked `#:blocking? #t` so other places aren't held up, and bitmaps come back through shared bytes without copying through messages.
- **Memory:** every PDFium handle is wrapped in a Racket object with a custodian/finalizer, so pages can't leak.
- **Hostile input:** counterparty PDFs are attacker-controlled input to a native parser. Keep the engine's API coarse-grained and handle-based so the same
  binding can later run in a small helper process for untrusted files if crash isolation is wanted. Session restore covers a crash in the meantime.
- **Gaps:** no OCR (use the OS engines, see 10.0) and no turnkey true redaction.

**Redaction (deferred, not in the first iteration).** Recorded so the engine choice isn't made blind: PDFium has no redact-apply call, so the plan when it's built is **flatten-and-OCR.** Rasterize the affected pages with the
redaction boxes burned in, rebuild the page from the image, and re-run OCR on it. The result contains no hidden text or objects
under the boxes by construction. It's simple and easy to verify (re-extract text and search for the redacted strings). The cost is that redacted pages lose
vector text and get larger. Optional later: object-level removal that deletes text and image objects intersecting the box, for
documents where flattening is unacceptable, always followed by the same verification pass. Metadata scrubbing (author, XMP, attachments, JavaScript) is a separate step
on the document structure.

Racket has no full PDF renderer of its own, and writing one is months of work for no benefit; PDFium already does it.

#### Microsoft 365: SharePoint, OneDrive, Outlook

- **Baseline needs no IT approval, and is now the plan of record:** synced folders plus links. Everything in 10.0 works this way.
  Graph app registration needs tenant approval that may not be available, so **the first releases do not use Graph** (any "Graph" mentions below describe a later option if that ever changes).
- **Would registering our own commercial app get around that? No.** Any app can be registered (a free Entra ID registration, multi-tenant), but
  *the tenant's admins* decide whether it can be used against a mailbox: user consent can be disabled, Conditional Access can block it, and unverified
  publishers are typically restricted (verify current rules). A vendor gets an organization to approve it through a security review, and that review is the same decision the tenant's admins would make.
  Registering an app to reach a work mailbox after the organization has declined it would work around a control the organization set; don't.
- **Email filing without Graph, in order of preference:**
  1. **Power Automate cloud flow using Microsoft's own Office 365 Outlook connector** (if the tenant allows Power Automate): a flow such as
     "when an email arrives or is flagged with category *File to matter*" saves the `.eml` and attachments into the matter's OneDrive/SharePoint folder.
     Rackmac reads the synced result. It runs server-side, so it works with classic Outlook, new Outlook, and Outlook for Mac, and no app of ours needs approval.
  2. **Drag and drop / Save As** from Outlook to the matter folder (`.msg` or `.eml`). Needs nothing from IT. A small Racket
     reader for the `.msg` compound-file format extracts sender, recipients, date, subject, body, and attachments.
  3. **Classic Outlook COM automation** (Windows only, via Racket's COM support): runs as you inside Outlook's own signed-in session and
     needs no registration, but only works with classic Outlook, which Microsoft is moving people off, and Outlook's programmatic-access security prompts may apply.
     New Outlook has no COM/VBA model. Confirm with IT that it's permitted.
- **Microsoft Graph (not available to you; parked):** one integration covers SharePoint/OneDrive files (item IDs, web URLs, version history, comments)
  and Outlook mail (message IDs, web links, folders). Sign-in is a standard OAuth flow in the system browser with delegated permissions,
  and tokens go in the OS keychain (Keychain / Credential Manager). Rackmac never sees your password. Least-privilege scopes (read-only
  files/mail) are the default. **Many firms require tenant-admin consent to register or approve an app**, so ask IT early.
- **Outlook on the web (OWA):** every Exchange Online tenant has it (admins can disable it per mailbox). It is a browser UI, so it
  is not automatable; Rackmac reaches the same mailbox through Graph instead.
- **Outlook for Mac:** three variants. Legacy Outlook for Mac supports AppleScript, but reports say it stops working against Exchange Online
  starting October 2026. New Outlook for Mac has **no AppleScript support** as of April 2026 (Microsoft's roadmap has promised it repeatedly;
  verify current status). Design rule: **don't build on Mac Outlook automation.** Use Graph, or drag-and-drop `.eml` files.
- **Power Automate:** desktop-flow Outlook actions work only with **classic Outlook for Windows**, not new Outlook. Cloud flows using the
  Office 365 Outlook connector work with both, because they talk to the mailbox and not the app. Classic-only automation is a shrinking asset.
- **Windows sign-in:** Exchange Online does not accept your Windows password directly (basic auth is gone). On an Entra-joined or hybrid-joined
  PC, MSAL with the Windows Web Account Manager gets tokens **silently from your Windows sign-in**, but only for an app the tenant has registered and approved.
  For **on-premises Exchange**, Windows integrated authentication (Kerberos/NTLM) works.
- **Do not build on EWS for Exchange Online:** Microsoft is blocking it starting **1 October 2026** (with an allow-list extension to April 2027 that tenant
  admins had to request earlier). Graph is the supported path. On-prem Exchange is unaffected.
- **Not a mail client replacement.** Rackmac reads, files, searches, links, and creates drafts (Graph creates the draft, Outlook opens it). Sending stays in Outlook.
- **Which Outlook:** classic Outlook for Windows, new Outlook, and Outlook for Mac behave differently for drag-and-drop and automation. Dragging out a message gives `.msg` or `.eml`
  depending on the client. Filing by Graph message ID avoids that variation, and works the same on Mac and Windows.
- **Word for the web edits:** Rackmac opens the item's web URL. Co-authoring changes arrive through the sync client (or Graph), and Rackmac re-indexes and,
  on request, diffs against the version you last reviewed.

## 11. Repository layout

```
rackmac/
  core/        buffer.rkt piece-tree.rkt marker.rkt props.rkt undo.rkt
               keymap.rkt command.rkt mode.rkt hook.rkt var.rkt window.rkt
               minibuffer.rkt picker.rkt event-loop.rkt frontend-iface.rkt
  frontend/    gui/ (racket/gui renderer, menus, mac/ and windows/ shims) headless/ (tests)
  services/    treesitter/ lsp/ process.rkt search.rkt index.rkt settings.rkt
  lang/        rackmac/ (module language) keymap/ (keymap DSL)
  packages/    standard-keys/ (mac + windows layers) file-tree/ terminal/ git/ racket/
               rackorg/ {parser.rkt agenda.rkt table.rkt babel.rkt export/ capture.rkt}
  docs/        scribblings/
  tests/
```

## 12. Roadmap

| Milestone | Scope | Exit criterion |
|---|---|---|
| **M0 Text core** | Piece tree, markers, undo tree, headless frontend, property tests | Fuzzed edit sequences match a reference string model |
| **M1 Usable editor** | Canvas renderer, single cursor, standard keymap, files, tabs/splits, find/replace | Edit its own source comfortably |
| **M2 Emacs core** | Command registry, palette, modes, hooks, advice, init file, live eval, help | Extend the editor from inside itself |
| **M3 Modern editing** | Multi-cursor, session restore, non-file buffer backend, unified full-text index (SQLite FTS) | Daily-driver for plain notes |
| **M4 Rackorg core** | Parser, folding, structure editing, TODO/tags/timestamps, tables | Round-trips a real-world Org corpus unchanged |
| **M5 Rackorg complete** | Agenda index, capture, Babel with Racket evaluator, export | Run a literate `.org` end to end |
| **L1 Matters and meeting notes** | Matter model and switcher, meeting capture, people index, clocking/time export, privilege banner, cross-matter agenda and search | Run one real matter's notes and time for a month |
| **L2 Documents** | `.docx` read/index/extract, PDF viewer, OCR, quote-to-note links, page:line citations, web clipper | Every source in a matter is linkable from notes |
| **L3 Document tools** | Redline compare, docx generation from templates, Word metadata scrub | Replace the manual Word compare and template-drafting workflows |
| **Later: PDF write features** | Annotation write-back, page assembly, Bates/exhibit builder, redaction, PDF metadata scrub | Not in the first iteration |
| **L4 Deadlines and email** | Deadline rules tables and calculator, email filing (`.eml`/`.msg`), CalDAV import | Deadlines and filed email shown in the cross-matter agenda |
| **D1 Developer pack (optional)** | tree-sitter, LSP, git, terminal | Only if wanted |
| **M6 Ecosystem** | Package manager, permission model, git, terminal | Third-party package published |

## 13. Risks and open questions

- **Text rendering performance in `racket/gui`.** Cairo/Pango drawing from Racket can be
  slower than native text engines. Mitigation: line-layout cache, virtualized viewport, and a
  spike in M1 to measure a 100k-line file. Fallback: a native rendering shim through the FFI.
- **Accessibility.** A custom canvas exposes nothing to screen readers by default. Needs a
  plan (platform accessibility tree via FFI) early, not after.
- **Startup time.** Racket load time for a large module graph. Mitigate with `raco demod`/`raco exe`, lazy `dynamic-require` for packages, and a warm daemon mode.
- **Unicode.** Grapheme-aware motion, bidirectional text, and IME composition are each
  their own project; scope them explicitly per milestone.
- **Tree-sitter FFI** requires shipping compiled grammars per platform.
- **Org compatibility depth.** Full Org is enormous. Publish an explicit supported-syntax matrix and a conformance corpus.
- **Single-writer model vs. long commands.** Commands must be short or yield; a
  `with-progress` helper moves long work off the editor thread and reports results as events.

**Decisions made**
1. Desktop only (macOS and Windows). No terminal or web frontend.
2. Modern shortcut conventions only, with a per-platform layer for Mac vs Windows laptops. No Emacs/Vim presets.
3. Org compatibility is one mode (`rackorg-mode`), built as a package in the Rackmac scripting language with no core privileges.

**Still open (legal workspace)**
*Decided:* storage is SharePoint, OneDrive, and plain folders; Word editing happens in Word for the web (no in-app docx editing);
email is Outlook; practice focus is transactional; PDF engine is one cross-platform engine, PDFium, called through the FFI in a worker place (10.3).

1. **Power Automate:** allowed (answered). Next: define the flow: trigger category, target folder, file naming, and what metadata to keep.
2. **Classic Outlook COM automation:** approved to try (answered). Next: a Windows-only spike; Outlook's programmatic-access security prompts are the main risk.
3. **PDFium binding spike:** first step is a thin Racket binding (open, render page to bitmap, extract text with coordinates) in a worker place, checked on a large scanned contract for scroll smoothness and memory.
*(PDF redaction and editing are deferred past the first iteration; no question open.)*

**Still open (general)**
1. Should Rackorg also accept Markdown-style headings (`#`) alongside Org's `*`, or stay strictly Org?
2. Linux: not a target now, but the per-platform layer makes it cheap. Explicitly out of scope, or "community-supported"?
3. Windows on ARM and Apple Silicon are both needed for laptops; is Racket CS's coverage of both enough, or do we budget for FFI (tree-sitter) builds on each?

## 14. Office-friendly vocabulary, interface and workflow

**Goal:** the same core, presented so that someone who lives in Word, Outlook and Excel can be productive in ten
minutes and still grow into the full power. Nothing here changes the command registry, keymaps, modes, hooks, undo or
`eval`. It changes (a) the **names users see**, (b) the **defaults**, and (c) the **surfaces** built on the registry.

**Principles**
1. *One object, two names.* The UI shows office vocabulary; the API, docs and Describe screens keep the Emacs term beside it
   ("Clipboard History — Emacs: kill ring"), and the palette matches both, so typing `yank` finds Paste.
2. *Select, then act.* Office workers select something and then choose a command. Emacs' verb-then-noun habit, prefix
   arguments and modal prompts are replaced by selection-first commands, dialogs and a "repeat N times" option.
3. *Everything is discoverable three ways:* a menu or toolbar path, a palette entry, and a shortcut shown next to both.
4. *Failure is calm and recoverable.* No Lisp backtraces, no lost work, no silent state.
5. *Progressive disclosure.* Simple surface first; the palette, settings-as-code and extensions are always one step away.

### 14.1 Vocabulary layer (display names only)

| Emacs term | Shown to users as | Notes |
|---|---|---|
| buffer | **Document** / **Tab** | `*scratch*` becomes **Scratch Pad**; `*Messages*` becomes **Activity** |
| window / frame | **Pane** (split view) / **Window** | |
| point, mark, region | **Cursor**, **Selection** | |
| kill / yank, kill ring | **Cut / Paste**, **Clipboard History** | "Paste from History" replaces `M-y` |
| minibuffer, echo area | **Command bar**, **Status message** | messages also appear as brief toasts |
| mode line | **Status bar** (clickable segments) | |
| `M-x` | **Command Palette** | plain-English titles, synonyms, recents |
| major mode / minor mode | **Language** (or Document type) / **Option** | no "-mode" suffix anywhere in the UI |
| keymap, binding, chord | **Shortcut**, **Shortcut sequence** | |
| hook | **Trigger** ("When a file is saved…") | code still says `add-hook!` |
| init file, Customize | **Settings** (dialog) and **Customize with code** | |
| evaluate | **Run** | "Run Selection" |
| narrowing, fill, transpose, occur | **Focus on Selection**, **Wrap Text to Width**, **Swap**, **Find All** | |
| query-replace | **Replace One by One** | |
| revert-buffer, kill-buffer | **Reload from Disk**, **Close Tab** | |
| register, bookmark | **Named Clipboard**, **Saved Location** | |
| package | **Extension** | already used |
| undo tree | **History** | |

**Mechanism (built).** Commands take optional metadata: `#:title` (the display name; it already existed, so there is no
separate `#:label`), `#:aliases` (search synonyms, including the Emacs name), `#:help` (one plain sentence), `#:icon`,
`#:when` (context predicate) and `#:category`. `define-mode` takes `#:label`. Menus, toolbar, context menus and the palette
read these; the internal `name` symbol never changes, and a test pins every built-in name. The palette scores each field
(title, name, each alias) separately, so an exact or prefix match on any one beats letters scattered through a long string.

### 14.2 Shortcuts

- Already modern and per-platform (Cmd/Ctrl); keep chords rare and for power users only, and never use Emacs-style
  `C-x` prefixes for common actions.
- **Show shortcuts everywhere:** menus, toolbar tooltips, palette rows, and a **Shortcut cheat sheet** (Help, or `Mod+/`).
- **Chord help:** after the first key of a sequence, a small popup lists what can follow (which-key).
- **Gentle teaching:** when someone runs a command from a menu or the palette, the status bar can show its shortcut
  once ("Tip: ⌘S"), with a setting to turn tips off.
- **The mouse is a first-class input:** click to place the cursor, drag to select, double-click a word, triple-click a line,
  right-click context menus, drag text, drag tabs, wheel and pinch. Today Rackmac has the basics from `text%` but no context menu.

### 14.3 Interface surfaces

| Surface | Change |
|---|---|
| **Start screen** | Replaces the Lisp scratch buffer on first launch: New, Open, Recent files and folders, **Get Started** tutorial. The Scratch Pad still exists for Racket users |
| **Toolbar** | Task icons (New, Open, Save, Undo, Redo, Cut, Copy, Paste, Find), contextual per Language, customizable by dragging a command from the palette ("Add to Toolbar"). An extension using only the public API |
| **Context menu** | Right-click: Cut, Copy, Paste, Select All, then contextual items from the Language |
| **Command Palette** | One box for commands, open tabs, files, settings and help; groups Recent first; plain-English labels ("Make Text Uppercase") |
| **Settings dialog** | Generated from `define-setting` (name, type, default, doc, category) so checkboxes, dropdowns and number fields exist for every option; "Edit settings as code" opens the init file |
| **Status bar** | Segments are clickable: line and column opens Go to Line; Language opens a picker; line-ending and encoding open converters; wrap and zoom toggle |
| **Activity panel** | Replaces `*Messages*`: severity, plain language, "Details" for the technical text, "Disable this extension" on failures |
| **Sidebar** | Panels for Files, Outline (headings), and Find results, built on the same buffer/panel machinery |
| **Split panes** | Drag a tab to an edge to split; "Pane" language, not "window" |

### 14.4 Workflow changes

1. **Never lose work.** Autosave with **Restore unsaved changes** on next launch (a hidden recovery store, replacing Emacs'
   visible `#file#` and `file~`). A non-modal banner when a file changes on disk: **Reload / Keep mine / Compare**.
2. **Find that works like an office app.** One Find bar with Find All (a results list), **Replace One by One**, scope
   (document, open tabs, folder) and a replace preview. Regex sits under "Advanced".
3. **Actions on selection.** Change Case, Sort Lines, Swap, Indent, Comment, Wrap Text: each shown under its category
   and acting on the selection. No prefix arguments; "Repeat…" asks for a number.
4. **Macros as "Record Actions".** Record, Stop, Play, and Save As Shortcut. Underneath it is the same command-level macro
   recorder the design already specifies, so recordings survive rebinding.
5. **Clipboard History.** `Cmd+Shift+V` opens a picker over the kill ring; ordinary `Cmd+V` is unchanged.
6. **Prose-friendly defaults.** Word wrap and a readable line width for text documents, word count in the status bar,
   headings outline for Markdown, soft-wrap indicators; code Languages keep monospaced, unwrapped defaults.
7. **Learning path.** *Help → Get Started* opens an interactive practice document with tasks and check-offs (the analog
   of `C-h t`), followed by short task-based guides written as "How do I…" with an "Emacs term" callout for each concept.
8. **Accessibility.** Keyboard-only operation of every surface, high-contrast themes, text scaling, target sizes, and no
   information carried by color alone. A custom-drawn editor would need a screen-reader plan; today the editor uses `text%`.

### 14.5 What to drop from the default experience (still available to power users)

Chord-heavy common commands, `C-g` as the universal cancel (Esc and a visible Cancel instead), prefix arguments,
minibuffer prompts for file names, buffer names in `*stars*`, `M-x` incantations, echo-area-only feedback, and Lisp errors
shown raw. These remain reachable through the palette and Customize with code.

### 14.6 Build order (impact over effort)

1. Vocabulary layer: `#:label`, `#:aliases`, `#:help` and synonym search in the palette. *Low effort, high impact.*
2. Toolbar, context menu, clickable status bar. *Low to medium.*
3. Autosave and recovery, file-changed banner. *Medium.*
4. `define-setting` and the Settings dialog. *Medium.*
5. Start screen and the Get Started tutorial. *Medium.*
6. Find All, Replace One by One, folder scope. *Medium.*
7. Clipboard History and Record Actions. *Low to medium.*
8. Activity panel with friendly errors. *Low.*
9. Split panes by dragging tabs. *Medium to high.*

**Already aligned in the current build:** menus generated from command metadata, the palette with shortcuts, tabs,
clickable-style status information, a find bar with live search, OS-native file dialogs, system dark mode, describe-key,
and an extension model that keeps power features one step away.
