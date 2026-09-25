# Rackmac roadmap

_Generated from `docs/roadmap.rktd` by `racket tools/roadmap.rkt`. Edit the data file, not this one._

Hierarchy: **epic > milestone > sub-milestone > issue**. Sizes: `S` under half a day, `M` one to two days, `L` three to five.
Issues are tracked on GitHub: <https://github.com/marctjones/rackmac/issues>. Issue N there is roadmap item RM-N, GitHub
milestones are the milestones below, and each epic has a tracking issue. **This file is the initial plan**, kept as an
overview; from the first filing onward, GitHub is the source of truth for status. Issues added after the first
filing (#240 onward: review findings, UI foundation) exist only on GitHub.

**Progress:** 27 of 217 active issues done (8 in the icebox).

## Releases

| Release | Theme | Epics | Done |
|---|---|---|---|
| v0.2 Friendly | Office vocabulary, toolbar, context menu, clickable status bar. | E0, E1, E2 | 27/72 |
| v0.3 Safe | Never lose work; settings you can click; calm errors. | E3, E4, E8 | 0/31 |
| v0.4 Welcome | Start screen, tutorial, better find, clipboard history, macros. | E5, E6, E7 | 0/31 |
| v0.5 Workspace | Split panes and sidebar. | E9 | 0/8 |
| v0.6 Open | Accessibility, extension platform and docs, Windows parity. | E10, E11 | 0/16 |
| v0.7 Backwards Compat | Optional Emacs preset: Emacs labels and shortcuts as surface preferences only. | E13 | 0/59 |

## Epics

| Epic | Title | Done |
|---|---|---|
| E0 | Foundation and verification | 11/19 |
| E1 | Vocabulary and discoverability | 16/22 |
| E2 | Toolbar and direct manipulation | 0/31 |
| E3 | Never lose work | 0/16 |
| E4 | Settings you can click | 0/9 |
| E5 | Start screen and learning | 0/8 |
| E6 | Find and replace 2.0 | 0/11 |
| E7 | Clipboard and actions | 0/12 |
| E8 | Friendly errors and activity | 0/6 |
| E9 | Panes and sidebar | 0/8 |
| E10 | Accessibility and internationalization | 0/8 |
| E11 | Extension platform | 0/8 |
| E13 | Emacs compatibility mode | 0/59 |
| E12 | Icebox: Rackorg and the legal workspace | 0/0 |

## E0: Foundation and verification

**Goal.** Delivered core, plus the open verification work that has been floating: real keys in the live window, Windows, CI.  
**Design.** README, DESIGN section 'Extension model'

### E0.M1: Delivered core (iteration 1)  (11/11)

#### E0.M1.S1: Editor core

- [x] **RM-001** Command registry with menus, palette and keys reading one source `M` — _accept:_ define-command registers name, title, doc, keys, menu; keys per platform (#:keys/mac, #:keys/windows).
- [x] **RM-002** Layered keymaps with key chords and per-platform Mod `M` — _accept:_ minor > major > global lookup; chords wait for the next key; Mod = Cmd on macOS, Ctrl on Windows.
- [x] **RM-003** Modes with inheritance, buffer-local variables, hooks `M` — _accept:_ define-mode with parent, locals, highlighter; failing hook is reported, not fatal.
- [x] **RM-004** Buffers on text% with tabs, CRLF-preserving file I/O, mode detection `M` — _accept:_ open/save round trip keeps CRLF; tab per buffer; unique names.
- [x] **RM-005** Find and replace bar `S` — _accept:_ live search, case option, replace one/all.
- [x] **RM-006** Command palette and picker with fuzzy matching `M` — _accept:_ Mod-Shift-P; Enter runs, Esc cancels; driven by a timer test.
- [x] **RM-007** Line and selection commands `M` — _accept:_ comment, duplicate, delete, move, indent, word/line/doc motion with Shift-extend.
- [x] **RM-008** Racket and Markdown syntax coloring, light/dark theme `M` — _accept:_ colors applied outside undo history; follows system appearance on macOS.

#### E0.M1.S2: Extension model

- [x] **RM-009** Init file, live eval, shared namespace `M` — _accept:_ a command defined in init.rkt lands in the running registry.
- [x] **RM-010** #lang rackmac with ownership, unloading and public-API restriction `L` — _accept:_ compile-time key and API-version checks; reload replaces, never duplicates; private core modules refused.
- [x] **RM-011** Automated test suite `M` — _accept:_ 47 tests: core, editing, init, lang, picker, startup.

### E0.M2: Verify real input  (0/6)

#### E0.M2.S1: Live key dispatch (blocks calling the editor verified)

- [ ] **RM-012** Verify real keystrokes reach the buffer in the live macOS window `M` — _accept:_ Cmd+Shift+P opens the palette; Cmd+= zooms; typing inserts text; result recorded in README.
- [ ] **RM-013** Opt-in RACKMAC_KEYLOG=1 key event log `S` — _accept:_ logs code and modifiers and the dispatch result to stderr; documented.
- [ ] **RM-014** Automated in-process smoke: deliver key events through the frame, not the buffer `M` — _accept:_ test builds the frame and sends events via the eventspace; asserts before-command hook. _Depends on: RM-013._

#### E0.M2.S2: Windows

- [ ] **RM-015** Run and verify on a real Windows machine `L` — _accept:_ launch, palette, Ctrl combos, AltGr typing, file dialogs; notes added to README.
- [ ] **RM-016** Windows key-normalization checks on real hardware `M` — _accept:_ Ctrl/Alt/AltGr behavior matches unit tests; international layouts tried. _Depends on: RM-015._
- [ ] **RM-017** CI matrix for macOS and Windows running raco test `M` — _accept:_ both platforms green on every change.

### E0.M3: Distribution  (0/3)

#### E0.M3.S1: Packages

- [ ] **RM-018** macOS app bundle via raco distribute `L` — _accept:_ double-clickable .app; runs without Racket installed.
- [ ] **RM-019** Windows executable and installer `L` — _accept:_ runs without Racket installed.
- [ ] **RM-020** Code signing and notarization `M` _(icebox)_ — _accept:_ macOS notarized; Windows signed. _Depends on: RM-018, RM-019._

## E1: Vocabulary and discoverability

**Goal.** The same commands under office-friendly names, findable by their Emacs names too.  
**Design.** DESIGN section 14.1 and 14.2

### E1.M1: Command metadata  (7/7)

#### E1.M1.S1: define-command fields

- [x] **RM-021** Add #:aliases (search synonyms) to define-command `S` — _accept:_ optional keyword; stored on the command; existing #lang rackmac extensions still compile.
- [x] **RM-022** Add #:help (one plain sentence) alongside #:doc `S` — _accept:_ optional keyword; shown by Describe and the palette.
- [x] **RM-023** Add #:when (context predicate) to define-command `S` — _accept:_ command-enabled? honors it; used later by menus and the toolbar.
- [x] **RM-024** Add #:icon (icon name) to define-command `S` — _accept:_ stored for the toolbar and menus.

#### E1.M1.S2: Built-in coverage

- [x] **RM-025** Emacs-name aliases for every built-in command `M` — _accept:_ backward-word, kill-line, yank, find-file, M-x and the rest resolve in the palette. _Depends on: RM-021._
- [x] **RM-026** A help sentence for every built-in command `M` — _accept:_ test fails if any built-in lacks #:help. _Depends on: RM-022._

#### E1.M1.S3: Modes

- [x] **RM-027** Add #:label to define-mode (display name) `S` — _accept:_ racket-mode shows as Racket, text-mode as Plain Text.

### E1.M2: Palette and Describe  (4/6)

#### E1.M2.S1: Palette

- [x] **RM-028** Palette searches title, aliases and name `S` — _accept:_ typing yank finds Paste; typing kill-line finds Delete Line. _Depends on: RM-021._
- [x] **RM-029** Recently used commands first when the box is empty `S` — _accept:_ last 8 distinct commands, most recent first.
- [ ] **RM-030** Show category and help in the palette `S` — _accept:_ third column; hint text for the highlighted row. _Depends on: RM-022._
- [ ] **RM-031** Helpful no-results state `S` — _accept:_ suggests checking spelling or opening Help.

#### E1.M2.S2: Describe

- [x] **RM-032** Describe shows both names and aliases `S` — _accept:_ Title, internal name, Also known as, shortcut, help, doc. _Depends on: RM-021, RM-022._
- [x] **RM-033** Rename Describe Key to What Does This Key Do? `S` — _accept:_ alias describe-key kept.

### E1.M3: Apply the vocabulary  (5/5)

#### E1.M3.S1: Display names

- [x] **RM-034** Rename built-in titles per the vocabulary table `M` — _accept:_ Run Selection, Show Activity Log, Set Language, Customize with Code, Reload Extensions; no command name symbol changes.
- [x] **RM-035** Scratch Pad and Activity replace *scratch* and *Messages* `S` — _accept:_ display names only; tests updated.
- [x] **RM-036** Status bar shows Language labels not mode symbols `S` — _accept:_ uses mode-label. _Depends on: RM-027._
- [x] **RM-037** Glossary page mapping Emacs terms to Rackmac terms `S` — _accept:_ in README and Help.
- [x] **RM-038** Test that every command name still resolves after relabeling `S` — _accept:_ init.rkt files referencing names keep working. _Depends on: RM-034._

### E1.M4: Shortcut discoverability  (0/4)

#### E1.M4.S1: Cheat sheet and hints

- [ ] **RM-039** Searchable shortcut cheat sheet `M` — _accept:_ per platform; grouped by category; opens from Help.
- [ ] **RM-040** Which-key popup after the first key of a chord `M` — _accept:_ lists valid next keys; disappears on completion or Esc.
- [ ] **RM-041** Show a command's shortcut once after using it from a menu or palette `S` — _accept:_ setting to turn off; never repeats for the same command in a session.
- [ ] **RM-042** Warn at load about bindings that shadow OS-reserved shortcuts `M` — _accept:_ per platform list; warning in Activity.

## E2: Toolbar and direct manipulation

**Goal.** Buttons, right-click menus, clickable status bar and mouse behavior, built only on the public API.  
**Design.** DESIGN section 14.3

### E2.M1: Toolbar as an extension  (0/8)

#### E2.M1.S1: Registry

- [ ] **RM-043** Toolbar item registry with layering by Language `M` — _accept:_ add-toolbar-item!; global then mode-chain items; pure module with tests.
- [ ] **RM-044** Toolbar items are unloaded with their extension `S` — _accept:_ reload does not duplicate buttons. _Depends on: RM-043._
- [ ] **RM-045** Export add-toolbar-item! and remove-toolbar-item! from rackmac/api `S` — _accept:_ usable from #lang rackmac. _Depends on: RM-043._

#### E2.M1.S2: Rendering

- [ ] **RM-046** Vector icon set drawn with racket/draw `M` — _accept:_ new, open, save, undo, redo, cut, copy, paste, find, run; crisp on HiDPI; follows theme.
- [ ] **RM-047** Flat icon button widget `M` — _accept:_ hover, pressed, disabled states; tooltip text in the status bar. _Depends on: RM-046._
- [ ] **RM-048** Toolbar panel in the main frame with a Show Toolbar command `M` — _accept:_ View > Show Toolbar; hidden state remembered for the session. _Depends on: RM-043, RM-047._
- [ ] **RM-049** Enabled state from #:when, refreshed by hooks `M` — _accept:_ Cut/Copy dim without a selection; Save dims when nothing to save. _Depends on: RM-023, RM-048._
- [ ] **RM-050** Toolbar tests `M` — _accept:_ registry layering; click runs the command; enable state changes with selection. _Depends on: RM-048._

### E2.M2: Toolbar customization  (0/4)

#### E2.M2.S1: User control

- [ ] **RM-051** Language-specific buttons `S` — _accept:_ Racket documents show Run Selection; Markdown does not. _Depends on: RM-043._
- [ ] **RM-052** Add to Toolbar from the palette `M` — _accept:_ any command with an icon or a generated letter icon. _Depends on: RM-048._
- [ ] **RM-053** Reorder and hide buttons `M` — _accept:_ persisted in settings. _Depends on: RM-052, RM-091._
- [ ] **RM-054** 2x rendering check on Retina and 200% Windows `S` — _accept:_ icons crisp. _Depends on: RM-046._

### E2.M3: Context menu  (0/4)

#### E2.M3.S1: Right-click

- [ ] **RM-055** Context menu item registry `S` — _accept:_ add-context-item!; ownership undo.
- [ ] **RM-056** Right-click shows Cut, Copy, Paste, Select All, Find `M` — _accept:_ items enabled per selection; Ctrl-click on macOS. _Depends on: RM-055, RM-023._
- [ ] **RM-057** Language-specific context items `S` — _accept:_ Racket adds Run Selection. _Depends on: RM-055._
- [ ] **RM-058** Right-click outside the selection selects the word under the pointer `S` — _accept:_ matches common editors. _Depends on: RM-056._

### E2.M4: Clickable status bar  (0/6)

#### E2.M4.S1: Segments

- [ ] **RM-059** Status segment widget `M` — _accept:_ hover underline; click runs a command; hint text.
- [ ] **RM-060** Line and column opens Go to Line `S` _Depends on: RM-059._
- [ ] **RM-061** Language opens a picker `S` — _accept:_ uses mode labels. _Depends on: RM-059, RM-027._
- [ ] **RM-062** Line ending segment (LF/CRLF) with a convert command `M` — _accept:_ toggling rewrites on save; undoable flag. _Depends on: RM-059._
- [ ] **RM-063** Zoom percentage resets on click `S` _Depends on: RM-059._
- [ ] **RM-064** Selection count and word count `S` — _accept:_ words for prose Languages.

### E2.M5: Menus and mouse  (0/9)

#### E2.M5.S1: Menus

- [ ] **RM-065** Menu items enable and disable from #:when `M` — _accept:_ menu on-demand refresh. _Depends on: RM-023._
- [ ] **RM-066** Open Recent submenu `M` — _accept:_ needs the recent files store. _Depends on: RM-083._
- [ ] **RM-067** Tabs listed in a Window menu `S`
- [ ] **RM-068** Verify shortcut hints render on macOS and Windows menus `S` — _accept:_ screenshot on both. _Depends on: RM-012._

#### E2.M5.S2: Mouse

- [ ] **RM-069** Verify double-click word and triple-click line `S` — _accept:_ documented result.
- [ ] **RM-070** Tab close button, middle-click close, drag to reorder `M`
- [ ] **RM-071** Tab context menu `S` — _accept:_ Close, Close Others, Reveal in Finder/Explorer, Copy Path. _Depends on: RM-055._
- [ ] **RM-072** Drag and drop text within a document `M`
- [ ] **RM-073** Pinch and Ctrl+wheel zoom `S`

## E3: Never lose work

**Goal.** Autosave, recovery, external-change handling, and safer file operations.  
**Design.** DESIGN section 14.4 item 1

### E3.M1: Autosave and recovery  (0/5)

#### E3.M1.S1: Recovery store

- [ ] **RM-074** Recovery store on disk (per document snapshot with metadata) `M` — _accept:_ atomic writes; outside the user's folders; encrypted-at-rest not required.
- [ ] **RM-075** Autosave timer `S` — _accept:_ interval setting; only when modified; debounced. _Depends on: RM-074._
- [ ] **RM-076** Delete snapshots on save and close `S` _Depends on: RM-074._

#### E3.M1.S2: Restore

- [ ] **RM-077** Restore unsaved changes on next launch `M` — _accept:_ list of recovered documents; Restore or Discard each. _Depends on: RM-074._
- [ ] **RM-078** Crash and kill test `S` — _accept:_ kill -9 then relaunch recovers the text. _Depends on: RM-077._

### E3.M2: External changes  (0/4)

#### E3.M2.S1: Detection and banner

- [ ] **RM-079** Detect a file changed on disk (check on focus) `M` — _accept:_ mtime and size.
- [ ] **RM-080** Non-modal banner: Reload, Keep mine, Compare `M` — _accept:_ auto-reload when unmodified; banner when modified. _Depends on: RM-079._
- [ ] **RM-081** Handle deleted and renamed files `S` — _accept:_ keeps the text, marks the tab. _Depends on: RM-079._
- [ ] **RM-082** Compare view for a changed file `L` — _accept:_ side-by-side or unified diff. _Depends on: RM-080._

### E3.M3: Files  (0/6)

#### E3.M3.S1: Operations

- [ ] **RM-083** Recent files and folders store `S` — _accept:_ persisted; Open Recent.
- [ ] **RM-084** Reload from Disk command `S` — _accept:_ asks if modified.
- [ ] **RM-085** Save All `S`
- [ ] **RM-086** Safe save: write a temp file then rename `M` — _accept:_ permissions preserved; failed save leaves the original.
- [ ] **RM-087** Encoding and BOM detection `M` — _accept:_ UTF-8, UTF-16; shown in the status bar. _Depends on: RM-059._
- [ ] **RM-088** Large file guard `S` — _accept:_ warn and disable highlighting over a size.

### E3.M4: Session  (0/1)

#### E3.M4.S1: Restore the workspace

- [ ] **RM-089** Reopen tabs and cursor positions on launch `M` — _accept:_ setting to turn off. _Depends on: RM-083._

## E4: Settings you can click

**Goal.** One registry of settings behind both a dialog and code.  
**Design.** DESIGN section 14.3

### E4.M1: Settings registry  (0/4)

#### E4.M1.S1: define-setting

- [ ] **RM-090** define-setting with name, type, default, doc, category `M` — _accept:_ usable from #lang rackmac; change hook.
- [ ] **RM-091** Persistence in settings.rktd `M` — _accept:_ atomic; survives restart. _Depends on: RM-090._
- [ ] **RM-092** Move font size, theme, wrap and toolbar visibility onto settings `M` _Depends on: RM-090._
- [ ] **RM-093** Settings declared by extensions are unloaded with them `S` _Depends on: RM-090._

### E4.M2: Settings dialog  (0/5)

#### E4.M2.S1: UI

- [ ] **RM-094** Dialog generated from the registry `L` — _accept:_ checkbox, choice, number, text; categories. _Depends on: RM-091._
- [ ] **RM-095** Search settings `S` _Depends on: RM-094._
- [ ] **RM-096** Edit as code opens the init file `S` _Depends on: RM-094._
- [ ] **RM-097** Per-Language overrides `M` — _accept:_ tab width, wrap. _Depends on: RM-094._
- [ ] **RM-098** Reset to default `S` _Depends on: RM-094._

## E5: Start screen and learning

**Goal.** First launch and the learning path, replacing the Lisp scratch buffer for newcomers.  
**Design.** DESIGN section 14.3 and 14.4 item 7

### E5.M1: Start screen  (0/3)

#### E5.M1.S1: Home

- [ ] **RM-099** Start screen: New, Open, Recent, Get Started `M` — _accept:_ shown when no files are given. _Depends on: RM-083._
- [ ] **RM-100** Setting to show or hide it at launch `S` _Depends on: RM-091._
- [ ] **RM-101** Scratch Pad remains available for Racket users `S`

### E5.M2: Get Started tutorial  (0/3)

#### E5.M2.S1: Interactive practice document

- [ ] **RM-102** Practice document format with task check-offs `M` — _accept:_ tasks complete when the matching command runs.
- [ ] **RM-103** Tutorial content mapped from the Emacs tutorial `L` — _accept:_ cursor, select, cut/paste, undo, files, tabs, find, palette, settings. _Depends on: RM-102._
- [ ] **RM-104** Help > Get Started opens it `S` _Depends on: RM-102._

### E5.M3: Guides  (0/2)

#### E5.M3.S1: How do I

- [ ] **RM-105** Task-based guides with Emacs-term callouts `L`
- [ ] **RM-106** In-app help viewer `M` _Depends on: RM-105._

## E6: Find and replace 2.0

**Goal.** One find bar with Find All, Replace One by One, scope and regex under Advanced.  
**Design.** DESIGN section 14.4 item 2

### E6.M1: Find bar  (0/4)

#### E6.M1.S1: Matching

- [ ] **RM-107** Regex under Advanced `M` — _accept:_ errors shown inline.
- [ ] **RM-108** Whole word `S`
- [ ] **RM-109** Highlight all matches `M`
- [ ] **RM-110** Match count and wrap indicator `S`

### E6.M2: Find All  (0/2)

#### E6.M2.S1: Results

- [ ] **RM-111** Results list with context `M` — _accept:_ click jumps to the match. _Depends on: RM-109._
- [ ] **RM-112** Find within the selection `S`

### E6.M3: Replace  (0/3)

#### E6.M3.S1: Interactive

- [ ] **RM-113** Replace One by One `M` — _accept:_ Replace, Skip, Replace All, Stop; one undo step.
- [ ] **RM-114** Replace preview `M` _Depends on: RM-111._
- [ ] **RM-115** Scope: document, open tabs, folder `M` _Depends on: RM-116._

### E6.M4: Folder search  (0/2)

#### E6.M4.S1: Files

- [ ] **RM-116** Search a folder with ignore rules `L` — _accept:_ skips .git, compiled, node_modules.
- [ ] **RM-117** Grouped results `M` _Depends on: RM-116, RM-111._

## E7: Clipboard and actions

**Goal.** Clipboard History, Record Actions, and selection commands.  
**Design.** DESIGN section 14.4 items 3-5

### E7.M1: Clipboard History  (0/3)

#### E7.M1.S1: Kill ring

- [ ] **RM-118** Capture copies and cuts `S` — _accept:_ size limit.
- [ ] **RM-119** Cmd+Shift+V picker `M` _Depends on: RM-118._
- [ ] **RM-120** History is memory-only by default; setting to persist `S` — _accept:_ no passwords on disk. _Depends on: RM-118._

### E7.M2: Record Actions  (0/4)

#### E7.M2.S1: Macros

- [ ] **RM-121** Record and stop at the command level `M` — _accept:_ survives rebinding.
- [ ] **RM-122** Play N times `S` _Depends on: RM-121._
- [ ] **RM-123** Save as a named command with a shortcut `M` — _accept:_ becomes a normal command. _Depends on: RM-121._
- [ ] **RM-124** Record, Stop, Play buttons `S` _Depends on: RM-121, RM-048._

### E7.M3: Selection actions  (0/5)

#### E7.M3.S1: Text tools

- [ ] **RM-125** Change Case `S` — _accept:_ upper, lower, title.
- [ ] **RM-126** Sort Lines `S`
- [ ] **RM-127** Swap words and lines `S` — _accept:_ aliases transpose-*.
- [ ] **RM-128** Wrap Text to Width `M` — _accept:_ alias fill-paragraph.
- [ ] **RM-129** Trim trailing whitespace `S`

## E8: Friendly errors and activity

**Goal.** Calm, recoverable failures.  
**Design.** DESIGN section 14.3

### E8.M1: Activity panel  (0/3)

#### E8.M1.S1: Panel

- [ ] **RM-130** Severity levels and toasts `M` — _accept:_ info, warning, error.
- [ ] **RM-131** Activity panel with Details `M` — _accept:_ replaces the Messages buffer view. _Depends on: RM-130._
- [ ] **RM-132** Filter and clear `S` _Depends on: RM-131._

### E8.M2: Extension failures  (0/3)

#### E8.M2.S1: Recovery

- [ ] **RM-133** Disable this extension button `M` — _accept:_ unloads it and records the choice.
- [ ] **RM-134** Start in safe mode (no extensions) `S` — _accept:_ command line flag and menu item.
- [ ] **RM-135** Attribute errors to the extension that caused them `M`

## E9: Panes and sidebar

**Goal.** Split views and side panels.  
**Design.** DESIGN section 14.3

### E9.M1: Split panes  (0/3)

#### E9.M1.S1: Window tree

- [ ] **RM-136** Pane tree model with focus `L`
- [ ] **RM-137** Split right, split down, close pane `M` _Depends on: RM-136._
- [ ] **RM-138** Drag a tab to an edge to split `L` _Depends on: RM-136, RM-070._

### E9.M2: Sidebar  (0/4)

#### E9.M2.S1: Panels

- [ ] **RM-139** Sidebar container with Cmd+B `M`
- [ ] **RM-140** Files panel `L` _Depends on: RM-139._
- [ ] **RM-141** Outline panel for headings `M` _Depends on: RM-139._
- [ ] **RM-142** Find results panel `M` _Depends on: RM-139, RM-111._

### E9.M3: Folders  (0/1)

#### E9.M3.S1: Workspace

- [ ] **RM-143** Open Folder `M` _Depends on: RM-140._

## E10: Accessibility and internationalization

**Goal.** Usable without a mouse, at any size, in any layout.  
**Design.** DESIGN section 14.4 item 8

### E10.M1: Keyboard  (0/1)

#### E10.M1.S1: Audit

- [ ] **RM-144** Every surface reachable and operable by keyboard `L` — _accept:_ toolbar, status bar, dialogs, tabs. _Depends on: RM-048, RM-059._

### E10.M2: Visual  (0/3)

#### E10.M2.S1: Themes

- [ ] **RM-145** High-contrast themes `M`
- [ ] **RM-146** Text scaling `S`
- [ ] **RM-147** No information carried by color alone `S`

### E10.M3: Assistive technology  (0/1)

#### E10.M3.S1: Screen readers

- [ ] **RM-148** Investigate VoiceOver and Narrator with text% and custom widgets `L` — _accept:_ written plan.

### E10.M4: Layouts and language  (0/3)

#### E10.M4.S1: International

- [ ] **RM-149** IME composition tests `M`
- [ ] **RM-150** AltGr and non-US layouts `M` _Depends on: RM-015._
- [ ] **RM-151** String table for UI text `L`

## E11: Extension platform

**Goal.** Make the extension boundary a real product.  
**Design.** DESIGN section 'Extension model'

### E11.M1: Core and API  (0/2)

#### E11.M1.S1: Boundary

- [ ] **RM-152** Move private modules under core/ `M` — _accept:_ restriction rule updated.
- [ ] **RM-153** API version policy `S` — _accept:_ when to bump; changelog.

### E11.M2: Packaging  (0/3)

#### E11.M2.S1: Distribution

- [ ] **RM-154** raco package manifest keys for extensions `M`
- [ ] **RM-155** Enable and disable extensions `M` _Depends on: RM-133._
- [ ] **RM-156** Permissions for filesystem and network `L` _(icebox)_

### E11.M3: Build tooling  (0/2)

#### E11.M3.S1: Custom builds

- [ ] **RM-157** rackmac build --with ext... -o app using raco exe `L` — _accept:_ extensions compiled in. _Depends on: RM-018._
- [ ] **RM-158** Compilation cache for init and ext `S` — _accept:_ faster startup.

### E11.M4: Docs  (0/2)

#### E11.M4.S1: Reference

- [ ] **RM-159** API reference generated from define-command and define-setting docs `L`
- [ ] **RM-160** Extension author guide `M`

## E13: Emacs compatibility mode

**Goal.** An optional preset that lets an experienced Emacs user switch the labels and shortcuts to Emacs conventions, as close as possible, using surface preferences only. No architectural changes: the preset is a #lang rackmac extension that loads and unloads through the existing ownership machinery.  
**Design.** DESIGN section 14 (the vocabulary layer in reverse) and 'Extension model'

### E13.M1: Preset mechanism (surface only)  (0/9)

#### E13.M1.S1: Presets as reversible extensions

- [ ] **RM-161** define-preset: a named bundle of key bindings, title overrides, menu layout and setting overrides `M` — _accept:_ declared in #lang rackmac; uses only the public API; no change to the core registry.
- [ ] **RM-162** Activate and deactivate a preset by loading it as a built-in extension `M` — _accept:_ registrations go through the ownership machinery so deactivation restores exactly; activating then deactivating leaves keymaps, titles and menus identical to the start. _Depends on: RM-161._
- [ ] **RM-163** Setting: Interface style (Standard or Emacs) `S` — _accept:_ in the settings dialog; persisted; applied at startup. _Depends on: RM-162, RM-091._
- [ ] **RM-164** Switch Interface Style command `S` — _accept:_ palette entry with aliases emacs mode and emacs keys; takes effect without a restart. _Depends on: RM-162._
- [ ] **RM-165** First-run choice: Standard or Emacs `S` — _accept:_ offered on the start screen; skippable; reversible any time. _Depends on: RM-099, RM-163._

#### E13.M1.S2: Display-name and layout overrides

- [ ] **RM-166** relabel-command! and relabel-mode!: display-title overrides with ownership undo `M` — _accept:_ titles change in menus, palette and tooltips; name symbols never change; undone on deactivation.
- [ ] **RM-167** Palette matches both the standard and the Emacs title `S` — _accept:_ typing Paste or Yank finds it in either style. _Depends on: RM-166._
- [ ] **RM-168** relocate-command-menu!: move a command to another menu with ownership undo `M` — _accept:_ makes an Emacs-style menu layout possible.
- [ ] **RM-169** Key bindings that apply only while a command's #:when is true `M` — _accept:_ input dispatch consults #:when; needed for CUA-style Ctrl+C/X/V; small and contained in input.rkt; review whether it counts as architectural before starting. _Depends on: RM-023._

### E13.M2: Emacs key bindings  (0/24)

#### E13.M2.S1: Movement

- [ ] **RM-170** C-f, C-b, C-n, C-p, C-a, C-e `S` — _accept:_ character, line, line start and end; Shift extends the selection. _Depends on: RM-162._
- [ ] **RM-171** M-f, M-b, M-<, M->, C-v, M-v `M` — _accept:_ word, document start and end, page up and down. _Depends on: RM-162._
- [ ] **RM-172** Meta key options `M` — _accept:_ Option as Meta or Esc as a prefix on macOS, Alt on Windows; Esc prefix implemented as chords; setting documents that Option-as-Meta stops accented typing. _Depends on: RM-162._
- [ ] **RM-173** M-g g and M-g M-g go to line `S` _Depends on: RM-162._

#### E13.M2.S2: Editing

- [ ] **RM-174** C-k kills to the end of the line `S` — _accept:_ at the end of a line it kills the newline; consecutive kills append to one clipboard entry. _Depends on: RM-194, RM-118._
- [ ] **RM-175** C-w, M-w, C-y and M-y `M` — _accept:_ cut, copy, paste, paste from history. _Depends on: RM-119._
- [ ] **RM-176** C-/, C-_ and C-x u undo `S` _Depends on: RM-162._
- [ ] **RM-177** C-d, M-d and M-Backspace `S` — _accept:_ delete char, word forward, word back. _Depends on: RM-162._
- [ ] **RM-178** C-SPC sets the mark; motion extends the selection; C-x C-x exchanges; C-x h selects all `L` — _accept:_ built on the existing selection-extension parameter; no mark ring. _Depends on: RM-162._

#### E13.M2.S3: Files, buffers, windows, help

- [ ] **RM-179** C-x C-f, C-x C-s, C-x C-w, C-x C-c `M` — _accept:_ open, save, save as, quit. _Depends on: RM-162._
- [ ] **RM-180** C-x b, C-x k, C-x C-b, C-x left and right `M` — _accept:_ switch buffer picker, kill buffer, list buffers, previous and next. _Depends on: RM-162._
- [ ] **RM-181** C-x 0, C-x 1, C-x 2, C-x 3, C-x o `L` — _accept:_ needs split panes. _Depends on: RM-162, RM-137._
- [ ] **RM-182** C-h k, C-h f, C-h b, C-h t, C-h a, C-h ? `M` — _accept:_ describe key, describe command, list bindings, tutorial, palette search. _Depends on: RM-162, RM-102._
- [ ] **RM-183** M-x opens the command palette `S` — _accept:_ Alt-x on Windows and Option-x on macOS. _Depends on: RM-162, RM-172._
- [ ] **RM-184** C-s and C-r incremental search in the find bar `M` — _accept:_ repeat to advance; Enter stops; C-g cancels and returns to the start. _Depends on: RM-162._
- [ ] **RM-185** M-% query-replace and C-M-% with regex `M` _Depends on: RM-162, RM-113, RM-107._
- [ ] **RM-186** C-g quits: closes the palette and find bar, cancels a chord, clears the mark `S` _Depends on: RM-162, RM-178._
- [ ] **RM-187** C-u numeric prefix for repeatable commands (limited) `M` — _accept:_ repeat count for motion, deletion and insertion; documented as limited, not a general prefix-argument system, so no architectural change. _Depends on: RM-162._
- [ ] **RM-188** C-x C-e and C-M-x evaluate `S` _Depends on: RM-162._
- [ ] **RM-189** C-x (, C-x ) and C-x e `S` _Depends on: RM-162, RM-121._

#### E13.M2.S4: Coexisting with platform shortcuts

- [ ] **RM-190** Setting: keep platform shortcuts alongside Emacs keys `M` — _accept:_ defaults on for Cmd on macOS, off for Ctrl on Windows where C-x and C-c conflict. _Depends on: RM-162, RM-091._
- [ ] **RM-191** CUA behavior: Ctrl+C, X, V copy, cut and paste while text is selected, prefix keys otherwise `M` — _accept:_ same idea as Emacs cua-mode. _Depends on: RM-169, RM-190._
- [ ] **RM-192** Report which platform shortcuts the active preset shadows `S` — _accept:_ shown when switching style. _Depends on: RM-162, RM-042._
- [ ] **RM-193** macOS Option-as-Meta via special-option-key `S` — _accept:_ warns that accented characters need another method. _Depends on: RM-172._

### E13.M3: Commands Emacs users expect  (0/11)

#### E13.M3.S1: New editing commands (added like any other command)

- [ ] **RM-194** kill-line `S` — _accept:_ usable from the palette in any style.
- [ ] **RM-195** open-line (C-o) `S`
- [ ] **RM-196** transpose-chars, transpose-words, transpose-lines `M` — _accept:_ keys C-t, M-t, C-x C-t. _Depends on: RM-127._
- [ ] **RM-197** upcase-word, downcase-word, capitalize-word `S` — _accept:_ keys M-u, M-l, M-c. _Depends on: RM-125._
- [ ] **RM-198** delete-indentation (M-^) `S`
- [ ] **RM-199** delete-blank-lines and just-one-space `S` — _accept:_ keys C-x C-o and M-SPC.
- [ ] **RM-200** fill-paragraph (M-q) `M` _Depends on: RM-128._
- [ ] **RM-201** zap-to-char (M-z) `S`
- [ ] **RM-202** recenter-top-bottom (C-l) `S` — _accept:_ cycles center, top, bottom.
- [ ] **RM-203** comment-dwim (M-;) `S` — _accept:_ reuses toggle-comment.
- [ ] **RM-204** forward-sexp and backward-sexp for Racket `M` — _accept:_ keys C-M-f and C-M-b.

### E13.M4: Emacs vocabulary and layout  (0/8)

#### E13.M4.S1: Labels

- [ ] **RM-205** Emacs terms replace the office terms in the UI `M` — _accept:_ buffer, window, frame, region, kill and yank, minibuffer, mode line, major and minor mode. _Depends on: RM-166._
- [ ] **RM-206** Emacs command titles `M` — _accept:_ Find File, Save Buffer, Kill Buffer, Yank. _Depends on: RM-166._
- [ ] **RM-207** Scratch Pad and Activity display as *scratch* and *Messages* `S` — _accept:_ display names only. _Depends on: RM-166._
- [ ] **RM-208** Tab bar labeled as buffers, with an option to hide it `S` _Depends on: RM-166._
- [ ] **RM-209** Emacs-style menu bar: File, Edit, Options, Buffers, Tools, Help and a mode menu `L` _Depends on: RM-168._

#### E13.M4.S2: Mode line and echo area

- [ ] **RM-210** Optional text mode line `M` — _accept:_ for example -:**-  name  L12  (Racket). _Depends on: RM-059._
- [ ] **RM-211** Echo-area style messages and an M-x prompt label on the command bar `S` _Depends on: RM-166._
- [ ] **RM-212** Setting to hide the toolbar in Emacs style `S` _Depends on: RM-048._

### E13.M5: Guardrails, docs and onboarding  (0/7)

#### E13.M5.S1: Safety

- [ ] **RM-213** Reversibility test for every preset `M` — _accept:_ activate then deactivate leaves keymaps, titles and menus identical. _Depends on: RM-162._
- [ ] **RM-214** Preset code may only require the public API `S` — _accept:_ a test scans the preset file's requires. _Depends on: RM-161._
- [ ] **RM-215** Documented list of what cannot be emulated, with the Rackmac alternative `S` — _accept:_ general prefix arguments, recursive edit, most of Emacs Lisp.

#### E13.M5.S2: Learning

- [ ] **RM-216** Emacs-key cheat sheet generated from the active preset `S` _Depends on: RM-039._
- [ ] **RM-217** Emacs-key variant of the Get Started tutorial `L` _Depends on: RM-102, RM-103._
- [ ] **RM-218** Emacs to Rackmac mapping table for experienced users `S`
- [ ] **RM-219** which-key popup for the C-x and C-c prefixes in Emacs style `S` _Depends on: RM-040._

## E12: Icebox: Rackorg and the legal workspace

**Goal.** Parked by request. See DESIGN sections 9 and 10.  
**Design.** DESIGN sections 9, 10

### E12.M1: Rackorg  (0/3)

#### E12.M1.S1: Org-compatible mode

- [ ] **RM-220** Org parser with incremental section reparse `L` _(icebox)_
- [ ] **RM-221** Outline folding and structure editing `L` _(icebox)_ _Depends on: RM-220._
- [ ] **RM-222** Agenda index `L` _(icebox)_ _Depends on: RM-220._

### E12.M2: Legal workspace  (0/3)

#### E12.M2.S1: Integrations

- [ ] **RM-223** Matter model and switcher `L` _(icebox)_
- [ ] **RM-224** Read-only PDF viewer on PDFium `L` _(icebox)_
- [ ] **RM-225** Word read, index, compare `L` _(icebox)_
