# Rackmac re-plan: notes and documents first (2026-09-25)

_Status: proposal for the owner. It re-cuts the roadmap around the owner's direction of 2026-09-25 (see
[PRODUCT.md](PRODUCT.md)) and replaces the release table in `ROADMAP.md` / `docs/roadmap.rktd`, which still
describe the epics and the issue text. GitHub issues stay the source of truth for status; this document says where
each open issue goes. Nothing here has been applied to GitHub or to `roadmap.rktd` yet: the owner (or the
maintainer, after the owner's decisions in §7) files the new issues, relabels the moved ones, and regenerates
`ROADMAP.md`. New issue keys below are proposals in `roadmap.rktd` shape._

**Numbering.** The current `main` (commit `38592ee`: toolbar, tabs, status bar, context menus, palette, find row,
251 tests) is tagged **v0.2.0** as a checkpoint _before_ this re-plan. The first notes release is therefore
**v0.3**, and the Emacs-compatibility preset moves from v0.7 to **v0.8**. Versions are v0.x only, in this plan and
in any later one.

**Standing rules** (unchanged, from `docs/DEVELOPMENT.md`): macOS first (Windows deferred, label `platform:windows`);
native `racket/gui` controls with modern layout and color (skiaracket iceboxed); modern shortcuts only; users never
meet Emacs in the default product (names, vocabulary, glossary and keys return only with the v0.8 preset, epic E13);
no new dependencies beyond the standard Racket distribution without asking; every change adds tests.

## 1. Phases and tags

Each phase ends in an annotated tag `v0.N.0` on `main`, cut by the maintainer after a review, with the tests green
and CI (from v0.3) green. One line says what the tag means.

| Tag | Theme (one line) | Epics that land |
|---|---|---|
| **v0.2.0** (tagged) | Editor chrome checkpoint: office vocabulary, toolbar, tabs, status bar, context menus, palette, find row. | E0 (part), E1, E2 (part), E6.M1 |
| **v0.3.0 First notes** | Write Markdown notes in a Library on macOS; they read like a document, not code; send them to Word or PDF. | E14 Writing, E15 Library (part), E18 Office (part), E4.M1, E5.M1, E0 (CI, bundle) |
| **v0.4.0 Tasks and links** | Checkboxes, states, tags and dates on notes; wiki links and backlinks; Library search; never lose a note; paste from Word. | E17 Outline & tasks, E16 Linking, E15 (search), E18 (clipboard), E3, E4 (rest) |
| **v0.5.0 Code review** | Read and review Python and Racket scripts: coloring, gutter, read-only review, compare; calm errors and a real Settings dialog. | E19 Code review, E6 (Find All, folder search), E8, E4.M2 |
| **v0.6.0 Workspace** | Split panes, session restore, record actions, clipboard history, toolbar customization, a notes tutorial. | E9, E7, E5.M2–M3, E2.M2 |
| **v0.7.0 Open** | Accessibility and the extension platform: API 2, packaging, enable/disable, docs. | E10, E11, E20 (rest) |
| **v0.8.0 Emacs preset** | Opt-in Emacs names, keys and layout as a preset built only on the public API. | E13 |

New epics introduced by this plan (tracking issues to be filed): **E14 Writing** (Markdown WYSIWYM), **E15 Library &
search**, **E16 Linking & backlinks**, **E17 Outline & tasks** (Org ideas on Markdown), **E18 Working with Office**,
**E19 Code review**, **E20 Racket-native internals**. E12 (Rackorg / legal workspace) stays a tracking issue for the
integrations that remain iceboxed; its Org items move into E14/E17 (§5).

Sizes as before: `S` under half a day, `M` one to two days, `L` three to five. Compact issue form:
`key | title | size | acceptance criteria | depends on`.

## 2. v0.3 First notes (macOS)

**Goal.** A lawyer can install a double-clickable app, add a Notes folder (a OneDrive- or SharePoint-synced folder
is just a folder), write Markdown notes that look like a document while editing, find them again from the sidebar,
and hand one to a colleague as `.docx` or PDF. No Emacs anywhere. Everything below reuses what v0.2 built: the
command registry with metadata, the toolbar registry with `#:mode` scoping (that is how Run already appears only for
Racket), tokens and layout (`prose-measure`), the status-bar and context-menu registries, the find row, the palette,
`#lang rackmac` ownership and unload, and the CRLF-preserving file I/O.

**Size.** About 32 issues, roughly seven weeks for one maintainer. The **cut line** in each table separates what
the tag needs from what may slip to v0.4 without changing the story. The owner's requirement that a Markdown
document can be switched between a **Formatted view and a Markdown Source view** per document is in this release
(`md-view-toggle`, `md-view-source-copy`); the design is UI-DESIGN §2.2.1.

### E14.M1 Markdown that reads like a document

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| `md-parser` | In-house Markdown scanner: blocks (ATX headings, paragraphs, bullet/numbered/task lists, block quotes, fenced code, thematic break, pipe tables, YAML front matter) and inline spans (emphasis, strong, code, links, autolinks, images, `[[wiki links]]`, `#tags`, ISO dates), each with buffer positions | M | pure `racket/base` module, no GUI; every span carries start/end; a 5,000-line note scans in under 50 ms; corpus tests incl. CommonMark edge cases we care about (nested lists, fences inside quotes) | — (owner decision §7.1) |
| `md-restyle-region` (absorbs #244) | Restyle only the paragraphs an edit touched (plus the enclosing fenced block); styles from other sources (find matches) survive | M | typing in a 5,000-line note restyles under 10 ms; find highlights persist across edits; whole-buffer restyle only on open and Language change; test counts restyled paragraphs | `md-parser` |
| `prose-font` | Proportional prose font and page-like measure for prose Languages: `style-delta%` `set-family 'system` 15 pt (verify SF Pro results), `set-line-spacing`, text centered at a 6.5 in measure via paragraph margins recomputed in `on-display-size`; code Languages keep the mono face | S | Markdown and Plain Text render proportional and centered; Racket unchanged; zoom scales both; fenced code inside a note is mono | — |
| `md-render` | **Formatted view** styling from `md-parser` spans: heading sizes (H1 1.6×, H2 1.35×, H3 1.15×, bold), strong/emphasis/code faces, quotes indented in `text-2`, hanging indents for list items via `set-paragraph-margins`, link text in `accent` underlined, **markup characters de-emphasized** (`text-2`, 0.8×) but never hidden; the default view for `.md` | M | golden bitmap of a sample note at 1× and 2×; `get-text` is byte-identical to the file after styling; undo history untouched (styles applied outside it, as `highlight.rkt` does) | `md-parser`, `md-restyle-region`, `prose-font` |
| `md-view-toggle` | **Formatted / Markdown Source** per document (UI-DESIGN §2.2.1): one command `toggle-markdown-view` reached from View > Show Markdown Source (`checkable-menu-item%`), the Format group's last button (icon and title swap), a clickable status segment "Formatted"/"Markdown", and **⌥⌘U** (Chrome/Safari View Source); Source view = today's Markdown look (mono, colored headings); setting `markdown-default-view`; the choice is remembered per document in `recents.rktd`; documents over the large-file guard open in Source | M | all four entry points stay in sync; cursor and scroll kept; a 5,000-line note switches under 1 s; formatting commands work identically in both views; `shortcuts-test` passes; tests through the command and the segment | `md-render`, `recent-files`, `menu-checked` |
| `menu-checked` | `define-command` gains `#:checked` (a thunk); `rebuild-menus!` makes a `checkable-menu-item%` for such commands and refreshes the check in the menu's demand callback; the toolbar swaps icon/title from the same thunk | S | Show Markdown Source and Show Library show their state; test through `menu-item-for` | — |
| `md-view-source-copy` | `copy`/`cut` read `document-text` (source Markdown) in both views so the clipboard never carries rendering; paste re-renders | S | copy across a bold run and a heading yields the source; test | `md-render` |
| `md-format-commands` | Formatting commands with Office shortcuts (table in UI-DESIGN §2.4): Bold ⌘B, Italic ⌘I, Inline Code ⇧⌘C, Link ⌘K, Heading 1–3 ⌥⌘1–3, Body Text ⌥⌘0, Bulleted ⇧⌘8, Numbered ⇧⌘7, Checklist ⇧⌘L, Quote ⇧⌘9; toggle semantics on the selection or the word at the caret | M | each command wraps/unwraps correctly incl. across existing markup; `#:when` prose Language; passes `shortcuts-test`; menu **Format** appears only for prose Languages | `md-parser` |
| `md-toolbar-group` | Toolbar `format` group for prose via `add-toolbar-item! #:mode 'markdown-mode`: Bold, Italic, Link · Heading▾ (popup-menu%), Bullets, Numbered, Checklist · Export▾ | S | group shows for Markdown, not for Racket; buttons dim from `#:when`; icons added to `icons.rkt` | `md-format-commands` |
| `md-lists-enter` | Enter continues a list (`- `, `1. `, `- [ ] `), Enter on an empty item ends it; Tab/Shift+Tab indent/outdent the item | S | numbered lists renumber the continued item; works inside quotes; tests | `md-parser` |
| `md-links-click` | Links are `set-clickback` spans: ⌘-click (Word convention) opens http(s) in the browser, `.md` paths in Rackmac, other files with the default app; hover shows the target in the status message | S | plain click still places the caret; relative paths resolve against the note; tests through the clickback | `md-render` |
| — cut line — | | | | |
| `status-prose` | Status bar for prose: words (and selection) and Language; Ln/Col, encoding, line ending hidden unless the Language is code | S | segments return `#f` for prose; code unchanged | — |

### E15.M1 Library (folders, recent, new note)

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| `settings-core` (#90 moved) | `define-setting` with name, contract, default, doc, category and **scope**; `setting-ref` resolves document → Language → global; `register-undo!` | M | contract violations report to Activity; per-Language override API; tests | — |
| `settings-store` (#91 moved) | Persist settings and recents with `put-preferences`/`get-preference` using their optional filename argument, files under the config dir (`settings.rktd`, `recents.rktd`) | S | survives restart; corrupt file is renamed aside and reported, never fatal | `settings-core` |
| `lib-folders` | Library = ordered list of folders (setting `library-folders`); **Add Folder…** (`get-directory`) suggests `~/Documents`, `~/Library/CloudStorage/OneDrive-*` and `OneDrive-SharedLibraries-*` (SharePoint), `~/Library/Mobile Documents/com~apple~CloudDocs`; Remove Folder | S | a synced folder appears like any folder; missing folder shows dimmed with a hint | `settings-core` |
| `lib-sidebar` (absorbs #139, #140) | Sidebar `vertical-panel%` 240 px in a `horizontal-panel%` with the editor; sections **Recent**, **Folders** (`mrlib/hierlist` tree of `.md`/`.txt`/`.rkt`/`.py` files), a filter `text-field%`; toggle **Show Library** ⌥⌘S (Apple Notes); click opens; right-click: New Note Here, Rename, Reveal in Finder, Move to Trash (Finder trash via `osascript`, verify; else confirm-then-delete) | L | hidden state persists; keyboard reachable (Tab into the tree, arrows, Enter); unshown frame test drives it | `lib-folders`, `recent-files` |
| `recent-files` (#83 moved) | Recent files store (paths, last opened, cursor) in `recents.rktd`, capped at 50 | S | feeds sidebar Recent, start screen and Open Recent | `settings-store` |
| `open-recent` (#66 moved) | File > Open Recent submenu with Clear | S | rebuilt from the store on demand | `recent-files` |
| `lib-new-note` | **New Note** ⌘N creates `Untitled N.md` in the selected Library folder (asks to add one if none); on first save proposes the first heading as the file name; "New Code File…" under Tools keeps the old New Document behavior | S | new note opens in Markdown with the prose look; test | `lib-folders` |
| `start-view` (absorbs #260, #99, #100) | Start screen when nothing is open: **New Note**, **Add Folder…**, **Open…**, Recent list, and **Get Started** (opens a bundled `Getting started.md` note that teaches the basics); setting to skip it; no Scratch Pad | M | shown with no file arguments; leaves when a document opens; command reopens it; keyboard reachable | `lib-folders`, `recent-files` |
| — cut line — | | | | |
| `lib-quick-open` | Quick Open ⇧⌘O searches Library titles and paths (reuses `quick-open` + `fuzzy.rkt`) | S | ranks title matches first; opens on Enter | `lib-folders` |
| `settings-dialog-min` (#94 moved) | Settings… ⌘, dialog generated from `define-setting`: rows of `check-box%`/`choice%`/`text-field%` grouped by category, **Edit as code** button (the old Customize with Code) | M | every registered setting has a row; changes apply live; test builds it unshown | `settings-core` |

### E18.M1 To and from Word and PDF

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| `pandoc-detect` | Find pandoc at `/opt/homebrew/bin/pandoc`, `/usr/local/bin/pandoc`, then `PATH` (an app bundle does not inherit the shell PATH); require ≥ 3.0; cache; Export/Import items `#:when` pandoc; status hint "Install pandoc to export to Word" with a Help page | S | works from a `raco distribute` bundle; absence never errors | — |
| `export-pdf-native` | **Export as PDF…** renders the styled document with `print-to-dc` on a `pdf-dc%` (Letter or A4 from the locale, 1 in margins, page numbers); ⌘P keeps the native print dialog, whose "Save as PDF" also works | M | headings, lists and links look like the editor; 40-page note under 3 s; file opens in Preview; test writes a PDF headless and checks page count | `md-render` |
| `export-docx` | **Export to Word…** `pandoc -f gfm+wikilinks_title_after_pipe -t docx [--reference-doc=<template>]` (pandoc 3.10 parses `[[Title\|text]]` with that extension; targets are still mapped to plain text or relative links by a setting); firm template setting; "Reveal in Finder" after | S | round-trips headings, lists, task lists, tables, links; error text from pandoc shown plainly | `pandoc-detect` |
| `import-docx` | **Import Word Document…** `pandoc -f docx -t gfm --wrap=none --extract-media=<name>_files`, saved next to the source or into the current Library folder, then opened | S | headings/lists/tables/images arrive; tracked changes are accepted (documented); comments dropped (documented) | `pandoc-detect` |
| `clipboard-spike` | Spike: can `clipboard-client%`/`get-clipboard-data` on Cocoa carry `public.html`/`public.rtf` (or Word's `HTML Format`) besides `TEXT`? Result written into UI-DESIGN §2.6 | S | maintainer visual session with Word; documented yes/no per type; decides the shape of `paste-from-word` and `copy-rich` | — |
| — cut line — | | | | |

### Defaults that stop looking like a code editor

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| `default-no-emacs` | Remove from the default product: Help > Glossary: Emacs Terms, the palette footer "Emacs: …" line, "Emacs-style" in About; the glossary command and footer return only with the v0.8 preset (done: data moved to `rackmac/presets/emacs-names.rktd` and `docs/emacs-glossary.md`) | S | `vocab-test` extended: no visible string contains "Emacs" outside E13 code | — |
| `run-code-only` (absorbs #101) | Run Selection/Run Document bound in code Languages' keymaps only (⌘↩ free in prose), Tools menu items `#:when` code; Scratch Pad no longer the fallback document (empty state is the start screen) and is reachable from Tools > Scratch Pad; Toggle Comment, Indent/Outdent Lines `#:when` code (Tab in prose goes to `md-lists-enter`) | S | opening the app with no files shows the start screen, not Racket; ⌘↩ in a note does nothing; tests | `start-view` |
| `menu-tools` | Menus: **Format** (prose), **Tools** holds Run, Scratch Pad, Extensions (Customize with Code, Reload, List) ; ⌘, goes to Settings… | S | menu snapshot test; cheat sheet regenerates | `settings-dialog-min` |

### E0 verification and distribution

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| #12 `verify-keys` (absorbs #54, #68) | Live macOS check: typing, ⌘B on a note, palette, zoom, Retina rendering, menu shortcut hints; recorded in README by the maintainer | M | checklist in the issue ticked; unresolved items filed | `md-format-commands` |
| #17 `ci` | GitHub Actions on macOS running `raco test tests` | M | green on every push; badge | — |
| #246 `pkg-hygiene` | Single `rackmac` collection; tests/tools/docs not installed as collections; no runtime collection-path patch | S | `raco pkg install` works in a clean Racket | — |
| #18 `pkg-mac` | Double-clickable `Rackmac.app` via `raco exe --gui` + `raco distribute`, with the icon set and the bundled Getting Started note; pandoc probed by absolute path | L | runs on a Mac without Racket; opens `.md` from Finder (`application-file-handler`); unsigned (signing stays #20 icebox) | #246, `pandoc-detect` |
| #254 `ui-appearance` (macOS part) | Re-check dark mode on activate; Windows registry part deferred | S | switching appearance restyles editor, sidebar tree and status bar once | — |

## 3. v0.4 Tasks and links

**Goal.** Notes become a working system: checkboxes and states, tags and dates, a Today view over all notes, wiki
links with completion and a backlinks panel, full-text Library search, autosave and recovery, and a clipboard that
speaks Word. The Org ideas land here, on Markdown files.

### E17.M1 Tasks, states, dates, tags

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| `doc-text` | Snip-aware document text: `document-text` walks snips and uses each markup snip's `get-text` (its source markup) so saving, searching and export never see decorations; all save/export paths use it | S | round-trip test with checkbox snips present; `image-snip%`'s "." never reaches a file | `md-render` |
| `task-checkbox` | `- [ ]`, `- [x]`, `- [-]` rendered in Formatted view as a checkbox `snip%` whose `get-text` is the source and whose **count equals the source length** (3), with the atomic-caret policy of UI-DESIGN §5.3 (arrow keys step over it, Backspace removes the whole marker); click toggles; **Mark Done** ⇧⌘U (Apple Notes) toggles the current item in either view; `[-]` = cancelled, struck through by drawing (style-delta has no strikethrough) | M | undo works across toggles; copy to another app yields `- [x] text`; positions equal source offsets after rendering; partial deletion inside the snip is unreachable (test walks the line key by key) | `doc-text` |
| `task-heading-states` | Heading keywords (default `TODO WAITING DONE`, setting) colored; ⇧⌘U cycles them on a heading line | S | keyword list per Library; export keeps the word | `md-parser` |
| `task-dates` | ISO dates recognized anywhere; `due 2026-09-30` on a task or heading is its due date; overdue in `error`, today in `accent`; Insert Date pops a small `dialog%` calendar (verify: no native date picker in racket/gui) | M | index stores dates; tests on parsing and coloring | `md-parser`, `lib-index` |
| `tags` | `#tag` inline and front-matter `tags:`; **Tags** section in the sidebar; click filters Recent/Folders to that tag | M | index; case-insensitive; `#` inside code spans ignored | `lib-index` |
| `today-view` (absorbs #222) | **Today** (sidebar entry; ⌃⌘T, since ⇧⌘T is Reopen Closed Tab): a read-only document generated from the index: overdue, due today, this week, open tasks by note; each row a clickback to the source line; toggling a checkbox there edits the source note | M | refreshes on save; 1,000 tasks render under 200 ms | `lib-index`, `task-checkbox`, `task-dates` |

### E17.M2 Outline

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| `outline-panel` (#141 moved) | Outline of headings in the sidebar's lower half (`list-box%` with indentation); click jumps; follows the caret | M | updates from `md-restyle-region`; keyboard reachable | `md-parser`, `lib-sidebar` |
| `outline-structure` (absorbs #221 part) | Promote/Demote heading ⌘[ / ⌘] on a heading line; Move Section Up/Down ⌥↑/⌥↓ when the caret is on a heading moves the whole section | S | undo as one step; tests | `md-parser` |
| `outline-fold` (absorbs #221 part; experiment) | Collapse/Expand section ⌥⌘[ / ⌥⌘] (Collapse All ⌃⌥⌘[; ⌥⌘−/= avoided because macOS Accessibility Zoom reserves them): the folded body is replaced, outside undo, by a fold `snip%` whose `get-text` is the hidden source and which draws "…"; unfold restores; save/search read through `doc-text`; **verify** `find-string` sees snip text and caret behavior at the fold | M | round-trip identical; find inside a fold reports and unfolds; if verification fails, ships as "Focus on Section" (outline navigation only) and folding is re-planned | `doc-text`, `outline-panel` |
| `md-hide-markup` (experiment) | Setting "Hide markup on lines you are not editing" (Formatted view only): `**`, `_`, `` ` ``, `[`, `](url)` become zero-width, count-preserving snips (`get-text` = the characters) on inactive paragraphs; the caret's paragraph always shows its markers (live-preview behavior); arrow keys step over a marker, Backspace at its edge removes it whole; a selection across hidden markers copies the source | M | caret walk test; undo test (edit → render → undo → source unchanged); default stays de-emphasized unless the owner flips it (§9.2); only after `task-checkbox` has proven the snip policy | `doc-text`, `task-checkbox` |

### E16.M1 Linking and backlinks

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| `lib-index` | SQLite index (`db`, system libsqlite3) of every Library file: path, title, headings, tags, links, tasks, dates, mtime; full-text via FTS5 (verify on the system library); built in a thread, updated on save and on watch events | L | 5,000 notes indexed under 30 s cold, incremental under 100 ms; corruption → rebuild | `lib-folders`, `lib-watch` |
| `lib-watch` | `filesystem-change-evt` per Library folder (thread), refreshing the tree and the index; fallback rescan on activate | S | external add/rename/delete shows within 1 s | `lib-sidebar` |
| `wiki-links` | `[[Title]]` and `[[Title\|shown text]]` resolve by title or file name across the Library; typing `[[` opens a completion picker; ⌘-click opens or offers to create the note | M | ambiguous titles ask; export rewrites to plain text or relative links (setting) | `lib-index`, `md-links-click` |
| `backlinks-panel` | **Backlinks** below the outline: notes that link to this one, with the linking line; click opens at that line; "Unlinked mentions" of the title | M | live after save; test over a small Library | `lib-index` |
| `lib-search` (absorbs #142; notes side of #116/#117) | **Search Library** ⇧⌘F: FTS query with `tag:` `folder:` `due:` filters; results grouped by note with context in a sidebar panel; Enter opens at the match | M | 5,000 notes under 200 ms; keyboard reachable | `lib-index` |

### E18.M2 Clipboard with Word

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| `paste-from-word` | Paste with HTML (or RTF) on the pasteboard converts through `pandoc -f html -t gfm --wrap=none`; falls back to plain text; **Paste as Plain Text** ⇧⌥⌘V (Chrome/Word) | M | bold, lists, headings and tables from Word arrive as Markdown; without pandoc, plain text | `clipboard-spike`, `pandoc-detect` |
| `copy-rich` | **Copy as Rich Text** puts HTML (from `pandoc -t html`) and plain Markdown on the pasteboard; ⌘C stays plain Markdown | M | pastes into Word/Outlook with headings and lists intact | `clipboard-spike` |

### E3 Never lose work (moved from v0.3)

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| #74–#78 | Recovery store, autosave timer, delete on save/close, restore on launch, crash test | M+S+S+M+S | as filed; the store lives in the config dir, never next to notes (synced folders would sync it) | `settings-store` |
| #79 (via `filesystem-change-evt`), #80, #81, #259 | Detect external change, InfoBar banner Reload/Keep mine/Compare (Compare enabled in v0.5), deleted/renamed files | M+M+S+M | as filed; #79 uses the watcher plus a check on activate | `lib-watch` |

### E4 Settings (rest) and E20 internals in v0.4

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| #92, #93 | Move font size, theme, wrap, toolbar visibility and Library onto settings; extension settings unload | M+S | as filed | `settings-core` |
| `settings-locals` | `#:locals` and `local-ref`/`local-set!` re-expressed as document-scoped settings (`wrap-lines`, `measure`, `indent-string`, `comment-start`); old names kept as aliases until API 2 | M | modes.rkt declares settings; tests unchanged | `settings-core` |
| `hooks-registry` (#247 moved) | `define-hook` with a contract on its arguments; `add-hook!` on an unknown name warns to Activity; the API exports the hook values, symbols stay accepted | M | every built-in hook declared; contract violation reported not raised | — |
| #109, #255, #256 | Highlight all matches (now that restyle is region-limited), headless UI harness, toolbar overflow | M+S+S | as filed | `md-restyle-region` |

## 4. v0.5 Code review

**Goal.** Open a Python or Racket script someone else wrote, read it comfortably (coloring, gutter, no wrapping),
mark it read-only while reviewing, jot a note that links to a line, compare two versions, and run only what you meant to.

| Key | Title | Size | Acceptance | Depends |
|---|---|---|---|---|
| `lang-python` | Python Language: `*.py`, small lexer (keywords, strings incl. triple-quoted, comments, numbers, decorators), 4-space indent, `#` comments | M | coloring test corpus; Toggle Comment works | — |
| `lang-racket-lexer` | Racket coloring via `syntax-color/module-lexer` (honors `#lang` lines and each language's `color-lexer` through `get-info`); indentation from `drracket:indentation` when a language provides it | M | `#lang scribble/manual` and `#lang rackmac` color correctly; `highlight.rkt`'s keyword list retired | `md-restyle-region` |
| `lang-more` | JSON, YAML, shell, plain `.txt`/`.csv` as Languages with minimal coloring | S | file patterns and labels | — |
| `review-mode` | **Review (read-only)** toggle for code documents: locks the text, shows a "Reviewing" badge in the status bar, ⌘S disabled; **Add Note About This Line** creates or appends to a note with a `file:` link `path#L12` that `md-links-click` follows | M | link opens the file at the line; tests | `md-links-click` |
| #261 `ui-gutter` | Line-number gutter for code Languages | M | as filed | — |
| #82 `compare-view` | Compare two documents (or a document with its saved file) side by side with line diffs, using a pure diff module; two `editor-canvas%` in a `horizontal-panel%`, so it does not need E9 panes | L | also serves the InfoBar Compare button (#80) | `md-restyle-region` |
| `run-scoped` | Run Selection/Document only for Racket documents (Python scripts get **Run in Terminal**, which opens Terminal.app with `python3 file`; no embedded terminal) | S | `#:when`; documented | `run-code-only` |
| #111, #113, #114, #115, #116, #117 | Find All results, Replace One by One, preview, scope, folder search with ignore rules (code side), grouped results | as filed | reuse `lib-search`'s results panel | `lib-search` |
| #130, #131, #132, #133, #134, #135 + `loggers` | Activity through Racket loggers: `define-logger rackmac`; `message`/`log-message` write `log-rackmac-*` with topics per extension; a log receiver feeds the Activity panel with level filter, Details, Disable this extension, safe mode | M+M+S+M+S+M | severity comes from the logger level; extension attribution from the topic | `hooks-registry` |
| #95, #97, #98 | Settings dialog: search, per-Language overrides, reset | S+M+S | as filed | `settings-dialog-min` |
| #41, #42, #67, #73, #87, #245 | Shortcut tip after menu use, shadow warnings, Window menu, pinch zoom, encoding/BOM, native menu shortcuts | as filed | | |
| `md-images`, `md-tables` | Image preview snip under an `![]()` line (`get-text` = source); pipe-table alignment on Tab | M+M | round-trip; export unchanged | `doc-text` |

## 5. v0.6 Workspace, v0.7 Open, v0.8 Emacs preset

**v0.6 Workspace.** _Goal:_ work on two notes side by side and pick up where you left off; the small productivity
tools Word users expect. E9.M1 panes (#136, #137, #138, #262, #243) with the `current-document` parameter (§6);
#89 session restore; E7 clipboard history, record actions, selection actions (#118–#129); toolbar customization
(#52, #53); #72 drag text; E5.M2–M3 tutorial and guides (#102, #104, #105, #106) rewritten around notes, with
`Getting started.md` as the practice document.

**v0.7 Open.** _Goal:_ usable by everyone and safe to extend: accessibility, the extension platform and API 2.
E10 (#144–#149, #151); E11 (#152–#155, #157–#160, #242) with `ext-custodian` (§6); API 2: hook values, settings
and `current-document` become the only spellings; #153 policy.

**v0.8 Emacs preset.** _Goal:_ an Emacs user can switch the whole surface (names, keys, layout) on and off again
without touching the default product. E13 unchanged in content (#161–#219), plus #263 `#:emacs` names and #40
which-key (chords exist only in the preset). Also brings back, as part of the preset: Help > Glossary, the
palette's "Emacs:" footer line, Scratch Pad as the fallback document.

## 6. Racket-native internals (E20): what to adopt and when

| Proposal | Decision | Release | Size | Why now / why not |
|---|---|---|---|---|
| Known hooks with contracts; first-class hook values instead of free symbols | **Adopt.** `define-hook` produces a hook value with a contract; symbols remain accepted (looked up in the registry) until API 2 | v0.4 (`hooks-registry`), API 2 in v0.7 | M | Backlinks, index and autosave all subscribe to hooks; a typo'd name silently doing nothing is the bug we cannot afford there |
| Racket loggers for the Activity log | **Adopt.** `define-logger rackmac`, per-extension topics, a receiver thread feeding Activity; `message` keeps its API | v0.5 (`loggers`, with E8) | M | Gives levels, filtering and attribution for free and removes the `Activity` buffer as a pseudo-document |
| One settings system: `define-setting` with contracts, resolved document → Language → global, replacing `#:locals` | **Adopt first.** It is the first thing v0.3 needs (Library folders, prose font, pandoc path) | v0.3 core; `#:locals` migration v0.4 | M + M | Cannot wait for the "Settings dialog" release; it is a prerequisite of the notes release |
| `current-document` parameter instead of a global current buffer | **Adopt with panes.** `current-buffer` stays a function; internally a parameter that panes, the sidebar and Today rows `parameterize` | v0.6 | M | No pane yet needs it; changing it earlier is churn |
| A custodian per extension | **Adopt with enable/disable.** Timers and threads an extension starts die on unload | v0.7 (#155) | M | Today extensions register only registry entries; the watcher and index threads in v0.4 are core, not extensions |
| `filesystem-change-evt` for external changes | **Adopt.** Library watcher and file-changed detection | v0.4 (`lib-watch`, #79) | S | Standard library, macOS supported; keep the on-activate check as fallback |
| `get-preference`/`put-preferences` or `.rktd` for settings and recents | **Adopt.** `put-preferences` with its filename argument pointing into the config dir | v0.3 (`settings-store`) | S | Zero code to write; human-readable; matches `roadmap.rktd` habits |
| `syntax-color/module-lexer` and `#lang` `get-info` for Racket coloring and indentation | **Adopt.** | v0.5 (`lang-racket-lexer`) | M | Correct for every `#lang`; retires the hand-kept keyword list |
| Registries computed from loaded extensions | **Defer (icebox note, no issue).** | — | — | Explicit registries with `register-undo!` already unload cleanly; revisit at API 2 if the bookkeeping becomes the bug source |
| Region-limited restyle (#244) | **Adopt as prerequisite.** | v0.3 (`md-restyle-region`) | M | WYSIWYM restyling the whole note 120 ms after each keystroke would flicker and slow |
| Snip-aware document text | **Adopt as prerequisite.** | v0.4 (`doc-text`) | S | Checkboxes, folds and image previews are snips; files must never contain their placeholders |

## 7. Mapping of every open GitHub issue

Dispositions: **keep** (stays as filed, in the release given), **move** (new release), **merge into** (closed as a
duplicate of the new key when that key is filed), **close** (obsolete, with the reason), **icebox**. Issues labeled
`release:v0.2` that are still open get a new target here: #12, #17, #18, #54, #68, #254, #255, #256.

### Epic tracking issues

| # | Epic | Disposition |
|---|---|---|
| #226 | E0 Foundation and verification | keep; v0.3 (CI, bundle, live check); Windows items icebox |
| #227 | E1 Vocabulary and discoverability | keep; remaining items v0.5; `default-no-emacs` added |
| #228 | E2 Toolbar and direct manipulation | keep; remaining items v0.4–v0.6 |
| #229 | E3 Never lose work | move v0.3 → v0.4 |
| #230 | E4 Settings you can click | keep; registry v0.3, dialog v0.3 (min) / v0.5 (rest) |
| #231 | E5 Start screen and learning | keep; start screen v0.3, tutorial v0.6 (rewritten for notes) |
| #232 | E6 Find and replace 2.0 | keep; #109 v0.4, rest v0.5 |
| #233 | E7 Clipboard and actions | move v0.4 → v0.6 |
| #234 | E8 Friendly errors and activity | move v0.3 → v0.5 (on loggers); #259 InfoBar v0.4 |
| #235 | E9 Panes and sidebar | keep; sidebar items merge into E15 (v0.3/v0.4); panes v0.6 |
| #236 | E10 Accessibility and internationalization | move v0.6 → v0.7 |
| #237 | E11 Extension platform | move v0.6 → v0.7 |
| #238 | E13 Emacs compatibility mode | move v0.7 → v0.8 |
| #239 | E12 Icebox: Rackorg and legal workspace | keep as icebox tracking for #223–#225 only; #220–#222 merge into E14/E17 keys |

### E0, E1, E2

| # | Title (short) | Disposition |
|---|---|---|
| #12 | Verify real keystrokes in the live macOS window | keep v0.3 (absorbs #54, #68) |
| #15, #16 | Windows run, Windows key checks | icebox (`platform:windows`) |
| #17 | CI on macOS | keep v0.3 |
| #18 | macOS app bundle | keep v0.3 (last item; shippable means double-clickable) |
| #19 | Windows installer | icebox |
| #40 | Which-key popup for chords | move v0.8 (chords exist only in the preset; merges with #219's mechanism) |
| #41 | Show shortcut once after menu/palette use | move v0.5 |
| #42 | Warn about OS-reserved bindings at load | move v0.5 |
| #52, #53 | Add to Toolbar, reorder/hide buttons | move v0.6 |
| #54 | 2× rendering check | merge into #12 |
| #66 | Open Recent submenu | move v0.3 (`open-recent`) |
| #67 | Tabs in a Window menu | move v0.5 |
| #68 | Verify menu shortcut hints | merge into #12 |
| #72 | Drag and drop text | move v0.6 |
| #73 | Pinch and ⌘-wheel zoom | move v0.5 |
| #242 | Small UI API for extensions | move v0.7 (E11, API 2) |
| #245 | Native menu shortcuts | move v0.5 |
| #246 | Packaging hygiene | move v0.3 (needed by #18) |
| #248 | Re-cut the roadmap | close: superseded by this document |
| #249 | skiaracket backend | icebox (unchanged) |
| #254 | Appearance detection | keep v0.3 for the macOS part; Windows part deferred inside the issue |
| #255 | Headless UI test harness | move v0.4 |
| #256 | Toolbar overflow | move v0.4 |
| #261 | Line-number gutter | move v0.5 (code documents only) |
| #262 | Pane splitter | move v0.6 |

### E3, E4, E5, E6, E7, E8

| # | Title (short) | Disposition |
|---|---|---|
| #74, #75, #76, #77, #78 | Autosave and recovery | move v0.4 |
| #79, #80, #81 | External changes (detect via `filesystem-change-evt`, banner, deleted/renamed) | move v0.4 |
| #82 | Compare view | move v0.5 (`compare-view`) |
| #83 | Recent files store | move v0.3 (`recent-files`) |
| #87 | Encoding and BOM detection | move v0.5 |
| #89 | Reopen tabs and cursors on launch | move v0.6 |
| #90 | `define-setting` | keep v0.3 (`settings-core`, gains contracts and scope) |
| #91 | Persistence in `settings.rktd` | keep v0.3 (`settings-store`, via `put-preferences`) |
| #92, #93 | Move built-in options onto settings; extension settings unload | move v0.4 |
| #94 | Settings dialog generated from the registry | keep v0.3 (`settings-dialog-min`, below the cut line) |
| #96 | Edit as code opens the init file | merge into `settings-dialog-min` (v0.3); it is that dialog's "Edit as code" button |
| #95, #97, #98 | Settings search, per-Language overrides, reset | move v0.5 |
| #99 | Start screen: New, Open, Recent, Get Started | merge into `start-view` (#260) |
| #100 | Setting to show or hide the start screen | merge into `start-view` |
| #101 | Scratch Pad remains available for Racket users | merge into `run-code-only` (Tools > Scratch Pad) |
| #102 | Practice document with task check-offs | move v0.6 (the practice document is a note with checkboxes) |
| #103 | Tutorial content mapped from the Emacs tutorial | close: Emacs-derived content does not fit the default product; replaced by `Getting started.md` (v0.3) and #102/#105 |
| #104 | Help > Get Started | move v0.6 (v0.3's start screen opens the bundled note directly) |
| #105 | Task-based guides with Emacs-term callouts | move v0.6; drop the Emacs callouts (they return in v0.8) |
| #106 | In-app help viewer | move v0.6 (guides are Markdown notes shown read-only) |
| #109 | Highlight all matches | move v0.4 (after `md-restyle-region`) |
| #111, #113, #114, #115 | Find All results, Replace One by One, preview, scope | move v0.5 |
| #116, #117 | Folder search with ignore rules, grouped results | move v0.5 for code folders; notes are covered by `lib-search` (v0.4) |
| #118, #119, #120 | Clipboard History | move v0.6 |
| #121, #122, #123, #124 | Record Actions | move v0.6 |
| #125, #126, #127, #128, #129 | Change Case, Sort Lines, Swap, Wrap to Width, Trim | move v0.6 |
| #130, #131, #132 | Severity levels, Activity panel, filter | move v0.5 (on Racket loggers; "toasts" in #130 become status message + InfoBar) |
| #133, #134, #135 | Disable extension, safe mode, attribute errors | move v0.5 |
| #259 | InfoBar row | move v0.4 (needed by #80) |
| #260 | Start view | keep v0.3, rewritten as `start-view` (New Note, Add Folder, Recent, Get Started; no Scratch Pad) |

### E9, E10, E11, E12

| # | Title (short) | Disposition |
|---|---|---|
| #136, #137, #138 | Pane tree, split commands, drag tab to split | move v0.6 |
| #139 | Sidebar container with ⌘B | merge into `lib-sidebar` (v0.3); shortcut becomes ⌥⌘S because ⌘B is Bold |
| #140 | Files panel | merge into `lib-sidebar` |
| #141 | Outline panel | move v0.4 (`outline-panel`) |
| #142 | Find results panel | merge into `lib-search` (v0.4) and its reuse by Find All (v0.5) |
| #143 | Open Folder | merge into `lib-folders` (v0.3) |
| #243 | Panes share one caret | move v0.6 (decide in #136) |
| #244 | Highlighting re-lexes the whole buffer and resets styles | merge into `md-restyle-region` (v0.3): a prerequisite of the formatted view, not a review nit |
| #144–#149, #151 | Accessibility and internationalization | move v0.7 |
| #150 | AltGr and non-US layouts | icebox (`platform:windows`, unchanged) |
| #152, #153, #154, #155, #157, #158, #159, #160 | Extension platform | move v0.7 |
| #156 | Permissions for filesystem and network | icebox (unchanged) |
| #247 | Known hook names and contracts | move v0.4 (`hooks-registry`) |
| #220 | Org parser with incremental reparse | merge into `md-parser` + `md-restyle-region` (v0.3): the same ideas, on Markdown |
| #221 | Outline folding and structure editing | merge into `outline-structure` + `outline-fold` (v0.4) |
| #222 | Agenda index | merge into `lib-index` + `today-view` (v0.4) |
| #223 | Matter model and switcher | icebox (integration set aside by the owner; folders + tags cover the near-term need) |
| #224 | Read-only PDF viewer on PDFium | icebox (set aside; PDFs open in Preview from links) |
| #225 | Word read, index, compare | icebox as filed; the import/export half is delivered by `import-docx`/`export-docx` |

### E13 (all move v0.7 → v0.8, content unchanged)

| # | Milestone | Disposition |
|---|---|---|
| #161–#169 | E13.M1 Preset mechanism | move v0.8 |
| #170–#193 | E13.M2 Emacs key bindings | move v0.8 |
| #194–#204 | E13.M3 Commands Emacs users expect | move v0.8; #200 fill-paragraph and #196 transpose may be delivered earlier by #128/#127 (v0.6) and only bound here |
| #205–#212 | E13.M4 Emacs vocabulary and layout | move v0.8; #207 also restores Scratch Pad as the fallback document and Help > Glossary |
| #213–#219 | E13.M5 Guardrails, docs and onboarding | move v0.8 |
| #263 | `#:emacs` names for the palette footer and the preset | move v0.8 (the footer line itself leaves the default product in v0.3 `default-no-emacs`) |

## 8. Built features that no longer fit the default experience

These are done and stay in the code; each moves behind a code Language, the Tools menu, a setting, or the v0.8 preset.

| Built feature | Where it goes | Issue |
|---|---|---|
| Run Selection ⌘↩ and Run Document ⇧⌘↩ bound globally; Tools menu items always enabled | Bound in code Languages' keymaps only; `#:when` code; Python gets Run in Terminal later | `run-code-only`, `run-scoped` |
| Run on the toolbar | Already `#:mode 'racket-mode`; unchanged, and Export▾ takes its place for notes | `md-toolbar-group` |
| Scratch Pad (Racket) as the document shown when nothing is open | Start screen; Scratch Pad under Tools | `run-code-only`, `start-view` |
| Help > Glossary: Emacs Terms; palette footer "Emacs: yank"; About "an Emacs-style editor" | Removed from the default; returned by the v0.8 preset | `default-no-emacs` |
| ⌘, = Customize with Code (init file) | ⌘, = Settings…; Customize with Code moves to Tools > Extensions and the Settings dialog's "Edit as code" | `settings-dialog-min`, `menu-tools` |
| Reload Extensions and List Extensions in File and Help | Tools > Extensions submenu | `menu-tools` |
| Monospace default font and 80-column wrap for prose | Proportional prose font, 6.5 in centered measure; mono stays for code | `prose-font` |
| Ln/Col, encoding, line-ending status segments for every document | Prose shows words and Language only | `status-prose` |
| Toggle Comment, Indent/Outdent Lines, Newline and Indent in Edit for prose | `#:when` code; Tab and Enter in prose serve lists | `run-code-only`, `md-lists-enter` |
| Emacs aliases (`yank`, `find-file`) as palette search terms | Kept: invisible unless typed, and they help people who know them | — |

Follow-ups outside this document's file scope (for the maintainer): README's first line ("An Emacs-style editor") and
its "Emacs ideas" and "Glossary" sections should be rewritten for the notes product; `roadmap.rktd`'s release table
and the GitHub `release:` labels need the new numbers; DESIGN §9–§10 should gain a pointer to this plan.

## 9. Decisions for the owner

**Answered 2026-09-25:** (2) markup: **hidden in the Formatted view once it works** — v0.3 ships markup
de-emphasized, the v0.4 experiment builds hiding, and hiding becomes the default when it passes its tests;
(3) shortcuts: **both accepted** (⌘, = Settings…, ⌥⌘S = Show Library); (4) metadata: recommended convention
taken by default (front matter + inline tokens). (1) parser: open — the owner asked about licenses and
leveraging/forking the `commonmark` package; see the maintainer's analysis in the conversation / issue.

1. **Markdown parser.** Write the scanner in-house (`racket/base`, roughly 400 lines, positions for every span,
   exactly the constructs the UI needs; recommended, no new dependency), or add the `markdown` or `commonmark`
   package from the catalog (full CommonMark, but a dependency `DEVELOPMENT.md` says to ask about, and neither
   exposes source positions the way styling needs)? Pandoc remains the conversion engine either way.
2. **Markup treatment by default.** Ship v0.3 with markup always visible but de-emphasized (recommended: predictable
   caret, zero risk), and offer "hide markup on inactive lines" as a setting after the v0.4 experiment; or make hiding
   the default once it works?
3. **Two shortcut reassignments.** ⌘, opens Settings… (Customize with Code loses the key and moves to Tools >
   Extensions), and ⌥⌘S shows the Library (Apple Notes' Show Folders; Save All keeps its menu item but loses the key).
   Recommended: both.
4. **Metadata convention.** Recognize both YAML front matter (`title:`, `tags:`, `due:`) and inline tokens (`#tag`,
   `due 2026-09-30`, heading keywords `TODO WAITING DONE`), with the UI writing front matter for tags and inline
   tokens for dates on tasks (recommended); or front matter only (cleaner export, more typing)?
