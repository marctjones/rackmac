# Rackmac UI design: an office-style notes and documents app on native controls

_Status: two layers. The **v0.2.0 layer** (proposed and built 2026-09-25, tagged as a checkpoint) gave Rackmac
its modern chrome on native `racket/gui` controls: tokens, layout grid, toolbar, tabs, status bar, find row,
palette, context menus. The **notes layer** (this revision, 2026-09-25, for the re-plan in
[REPLAN.md](REPLAN.md) and the product in [PRODUCT.md](PRODUCT.md)) turns the window into a document-first
notes app for people who live in Word, Pages and Outlook: a Library sidebar, Markdown that renders while you
edit, a formatting toolbar, outline and backlinks, and code documents that look like code only when a document
is code. Each section below is marked **_Unchanged_** (still applies as built or planned) or
**_Changed 2026-09-25_** (new or revised for the notes product). Scope rules are the owner's and unchanged: existing
`racket/gui` controls only; modern layout and color; no custom widget toolkit, no Skia, no custom title bar, no
restyled buttons. Custom painting stays limited to surfaces that are ours anyway (editor, gutter, status bar) and to
`snip%` objects inside the editor. macOS first; Windows notes are kept where they cost nothing. Nothing here
changes the core: command registry, keymaps, Languages, hooks, documents on `text%`, `#lang rackmac` with
ownership and unload. Every surface reads command metadata (`#:title #:help #:icon #:when #:aliases`, mode
`#:label`)._

## 0. The short version

_Changed 2026-09-25._

- **Layout:** title bar (native) → menu bar (native) → one-row toolbar of native icon buttons, with a
  **Format group that appears for notes** → **Library sidebar** (folders including OneDrive/SharePoint-synced
  folders, Recent, Tags, Outline, Backlinks; `⌥⌘S`) beside document tabs → optional InfoBar row → optional find row →
  **document area** → status bar. 4 px grid, real margins.
- **Two looks, one editor.** A Markdown note renders like a word-processor page: proportional font, centered
  6.5 in measure, headings sized and bold, lists indented, links clickable, checkboxes real, markup de-emphasized
  but never hidden in v0.3. A `.py` or `.rkt` file looks like code: monospace, unwrapped, gutter, Run. Both are the
  same `text%` with different styles, paragraph margins and snips (§5.3 says exactly what `text%` can and cannot do).
- **Formatted or Source, per document.** Any Markdown document switches between the formatted view and plain
  Markdown source (View menu, a Format-group button, a status segment, ⌥⌘U as in Chrome's View Source); the choice
  is remembered per document; the same formatting keys edit the same characters in both (§2.2.1).
- **Theme: Skeptical Engineering** (§1.0). Paper for documents, the dark bench for the Library, moss as the one
  accent, IBM Plex (Serif for notes, Mono for code, Sans for painted chrome text), Workbench drafting icons. Native
  controls stay native; the theme lives on the surfaces we paint.
- **Color:** the one token module for what we paint, light ("Paper") and dark ("Bench"). No new roles were needed
  for notes: headings use `heading`, markup `text-2`, links `accent`, overdue `error`.
- **UX:** discover by menu, toolbar, palette and shortcut hints; Office/Pages/Notes/Chrome shortcuts only; non-modal
  feedback; designed empty states (start screen, empty Library, no backlinks yet); keyboard everything.
- **Not in the default:** anything named after Emacs, Run for prose, a Racket scratch pad at startup. Those return
  only with the v0.8 preset or under Tools.
- **racket-skia:** out of scope (§5.1).

## 1. Visual language

### 1.0 The Skeptical Engineering theme

_Changed 2026-09-25 (new)._ Rackmac takes its look from the Skeptical Engineering design system
(`skepticalengineering-design`: `docs/brand-book.md`, `tokens/tokens.json`, the Workbench icon set), the system the
workshop's other desktop apps build against. Mockup: macOS Paper and Bench, Windows 11 Paper (the owner's design
canvas, "Rackmac UI — Skeptical Engineering"). What that means inside our scope rules:

- **Paper and bench.** Documents sit on `paper` (warm off-white, not white). The Library sidebar (§2.1) is the dark
  `bench`, the same in both appearances. The brand's bench-colored *title bar* is not possible: the title bar and
  menu bar are native, and stay so.
- **Modern macOS and Windows 11, by layout and not by effects.** From the platforms we take what the brand allows:
  a sidebar-plus-content window, a single toolbar row of native buttons, the platform's own title bar, menus and
  control font, 4 px spacing, generous document margins, keyboard access everywhere. We do not imitate Mica,
  acrylic, vibrancy, pill buttons or shadows; the brand forbids glass and layering, and `racket/gui` cannot restyle
  native controls anyway. Structure comes from 1 px `stroke` rules and type.
- **One accent.** `accent` is always `moss`. Earlier builds borrowed the OS highlight color; that is dropped, since the
  system allows one accent. `ochre` marks caution (find matches, warnings), `rust` errors. Code coloring necessarily
  uses more than one hue; it stays in those families (§1.2) at readable contrast.
- **Type.** IBM Plex Serif for notes (the person's voice), IBM Plex Mono for code, paths and headings in the
  Markdown source view, IBM Plex Sans for text we paint in the chrome. Plex is used when installed and falls back to
  installed faces (§1.3). **Open question for the owner (#330):** bundle the Plex TTFs (OFL 1.1) inside the app. `racket/draw`
  cannot load a font file, so that needs a CoreText registration call through the FFI, a new kind of code in the
  core. Until it is decided, installing Plex (for example `brew install --cask font-ibm-plex-serif
  font-ibm-plex-mono font-ibm-plex-sans`) switches Rackmac to it with no other change.
- **A note on audience.** The brand is "half workshop, half terminal"; the product is for lawyers who live in Word
  (PRODUCT.md). Where the two pull apart the product wins: prose is serif at a readable size, labels are plain nouns
  in Plex Sans rather than uppercase mono, and mono appears only where it carries information (code, paths, dates,
  shortcuts).

### 1.1 What is native and what we paint

_Changed 2026-09-25: two additions in the right column (sidebar tree, editor snips)._

| Native `racket/gui` (OS look, OS accessibility) | Painted by Rackmac (`racket/draw`) |
|---|---|
| title bar, menu bar, `button%` (toolbar, dialogs), `text-field%`, `check-box%`, `choice%`, `list-box%` (Recent, Tags, Outline, Backlinks, results), `tab-panel%`, `message%`, `dialog%`, `popup-menu%` (Heading▾, Export▾, context menus), file and message dialogs | editor surface (`editor-canvas%` on `text%`): background, text, selection, caret, current line, find matches, prose and syntax styles; **editor snips** (checkbox, fold, image preview); gutter; status bar (`canvas%`); toolbar icons (vectors rendered to `bitmap%` labels); the Folders tree (`mrlib/hierlist`, editor-based, standard distribution); pane splitters (E9) |

### 1.2 Color tokens (`rackmac/ui/tokens.rkt`)

_Changed 2026-09-25: values are now the Skeptical Engineering tokens (§1.0); the roles are unchanged, plus four
`bench-*` roles for the Library sidebar. Notes reuse existing roles: `heading` for heading text, `text-2` for markup
characters, quotes and done tasks, `accent` for link text and today's date, `error` for overdue, `match` for find,
`line-highlight` off for prose. High-contrast columns remain RM-145._

Roles, not colors: code asks for `(token 'name)`, never a hex value. Each role names the design-system token it
takes (the light value is the token's light value, the dark value its dark value). Two source tokens that fail
4.5:1 for small text, `ink-label` and `bench-quiet`, are deliberately not mapped to any text role.

| Role | Light | Dark | Source token | Used for |
|---|---|---|---|---|
| `surface` | #F8F8F6 | #1C1C1C | `paper` | editor background (`canvas-background`) |
| `text` | #2A2A28 | #C8C8C0 | `ink-body` | editor text (`fg`) |
| `text-2` | #686860 | #909088 | `ink-quiet` | gutter numbers, status segments, placeholders, **Markdown markup, quotes, done tasks** |
| `text-disabled` | #888880 | #808078 | `ink-label` | dimmed segments (not required to pass 4.5:1) |
| `stroke` | #DCDCD4 | #3A3A36 | `rule` | 1 px line above the status bar, gutter edge, **sidebar edge** |
| `line-highlight` | #EFEFE9 | #242422 | `paper-sunk` | current line (prose Languages off, code on), code spans |
| `selection` | #D5E3D3 | #2F4430 | moss over paper | text selection where we paint it; `text%` draws the OS color itself |
| `accent` | #4A7C4A | #80A080 | `moss` | status-bar hover underline, gutter marker for the current line, find count when matches exist, **link text, due today** |
| `match` / `match-current` | #EDE3B8 / #D9C77E | #4A4424 / #5A4E20 | `ochre` family | Find All highlights (RM-109) |
| `info` / `success` / `warning` / `error` | #505048 / #3A5C3A / #6A6030 / #7A3526 | #A0A090 / #A0C0A0 / #D8C890 / #E0A090 | `ink-muted` / `moss-ink` / `ochre-ink` / `rust-ink` | status-bar icons, find "No matches", InfoBar text, **overdue tasks (`error`)**; the system has no blue, so `info` is plain ink |
| `status-bg` | #EFEFE9 | #242422 | `paper-sunk` | status bar: one step off the page, ruled above |
| `comment` / `string` / `constant` / `keyword` | #686860 / #6A6030 / #505048 / #3A5C3A | #909088 / #D8C890 / #A0A090 / #A0C0A0 | `ink-quiet` (italic) / `ochre-ink` / `ink-muted` / `moss-ink` | syntax coloring in code Languages |
| `heading` / `face-error` | #1C1C1C / #7A3526 | #E0E0D8 / #E0A090 | `ink` (bold) / `rust-ink` | note headings; lexer errors |
| `bench` / `bench-heading` / `bench-text` / `bench-rule` | #1C1C1C / #E0E0D8 / #A0A090 / #505048 | #141413 / same / same / same | `bench-*` | the Library sidebar (§2.1): the workbench does not change when the lights go down |

As built (`rackmac/ui/tokens.rkt`): the match colors are ours (the system's `ochre-tint` is too faint to find text
by), picked so that `text` on them stays above 4.5:1; dark `match-current` was darkened from the first choice when
the contrast test flagged it.

Rules: `text` and `text-2` on `surface`, and every status token on `status-bg`, meet 4.5:1 (a test computes
it); `stroke` and `accent` on their surfaces meet 3:1; nothing is conveyed by color alone (the current find match
also gets a thicker outline, the modified tab also has "•" and the window title, a done task is also checked and
a folded section also shows "…"). High-contrast variants (RM-145) are two more columns of this table.

### 1.3 Typography

_Changed 2026-09-25: the Skeptical Engineering faces (§1.0). `prose` is IBM Plex Serif, `mono` IBM Plex Mono,
painted `ui` text IBM Plex Sans; each falls back to the first installed face in its list (`resolve-face` over
`get-face-list`, `rackmac/theme.rkt`)._

Native controls use the OS control font automatically (`normal-control-font` is `.AppleSystemUIFont` 13 on
macOS and Segoe UI on Windows; nothing to do). We choose fonts only for what we paint and for the start screen.

| Slot | macOS | Windows | Where |
|---|---|---|---|
| `prose` | IBM Plex Serif → Charter → Georgia, `mono` size + 1 (15), line spacing 4 | IBM Plex Serif → Cambria → Georgia | Markdown and Plain Text body: the "Prose" named style, derived from "Standard" (so zoom scales it), chosen by the Language's `document-style` local through `buffer%`'s `default-style-name`. Headings 1.6× / 1.35× / 1.15× bold (H4–H6 1.0× bold) arrive with `md-render`. |
| `mono` | IBM Plex Mono → Menlo, 14 | IBM Plex Mono → Cascadia Mono → Consolas, 12 | code Languages ("Standard"), gutter, fenced code and inline code in notes (inline code one point smaller than the prose around it) |
| `ui` | IBM Plex Sans at `normal-control-font`'s size, else the control font (13) | same (Segoe UI 9 pt) | status bar, InfoBar text, sidebar tree |
| `ui-small` | `small-control-font` (11) | `small-control-font` | status segments when the window is narrow |
| `title` | `ui` face at 22 bold | `ui` face at 20 bold | start screen heading (`message%` with `font`) |
| `subtitle` | `ui` face at 15 | `ui` face at 14 | start screen card titles |

Zoom (`font-size`, existing) scales the "Standard" style, and every note style is derived from it in the shared
`style-list%` (`find-or-create-style base delta`), so headings and code spans scale with it; a `ui-scale` setting
(RM-146) scales gutter and status bar fonts and metrics in the same step.

### 1.4 Spacing, metrics, motion

_Changed 2026-09-25: the prose measure is a page, not 80 columns; sidebar width added._

- **4 px grid** through `panel%` `border`, `spacing`, `horiz-margin`, `vert-margin`: window rows `border 0`,
  toolbar `spacing 4` with an 8 px gap (a `pane%` spacer) between groups, InfoBar and find row `border 8 spacing 8`,
  dialogs `border 16 spacing 12`, sidebar `border 0`, sidebar section headers 8 px above.
- **Editor margins:** `horizontal-inset` 16, `vertical-inset` 12 for code. **Prose measure:** `prose-measure`
  (80) characters of the prose face, about 6.5 in at the default zoom; the text is **centered** by widening the
  canvas's own horizontal inset to `(view-width − measure) / 2` (`centered-inset` in `layout.rkt`, applied by the
  editor canvas on resize, on switching documents or Language, and on zoom), never below 16, with 48 px above the
  first line (`prose-inset-y`). _Changed 2026-09-25:_ this replaces the earlier plan of per-paragraph margins, which
  would have to be recomputed for every paragraph on each resize; `buffer.rkt`'s `set-max-width` clamp stays as the
  fallback. Code Languages: unwrapped, no centering.
- **Sidebar:** fixed 240 px (`min-width 240`, `stretchable-width #f`), a setting from 200 to 360; drag-resize arrives
  with the E9 splitter (v0.6).
- **Row heights** follow the controls: toolbar = button height + 8; tab strip as `tab-panel%` draws it; status
  bar 24 (macOS 22); InfoBar one line of `ui` + 16.
- **Motion:** none required. State changes are instant; caret blink is the editor's own. A reduced-motion
  setting exists from day one so anything added later (a status message fade) has an off switch.

### 1.5 Icons

_Changed 2026-09-25: the Skeptical Engineering Workbench set replaces the Fluent-style drawings; names added for
notes._

The Workbench set: drafting-style line icons on a 24-unit grid, a 1.5-unit stroke (1 px at 16 px) with square caps
and miter joins. Rackmac does not draw them itself: `tools/workbench-icons.rkt` copies the icons it uses from the
design repository into `rackmac/ui/workbench-icons.rktd`, taking each icon's **outlined** form (the stroke already
expanded to shapes), and `rackmac/ui/icons.rkt` interprets those paths (absolute `M L Q C A Z`; quadratics and arcs
become cubics) into a `dc-path%` that it fills. So the icons match the design system exactly, and no SVG stroker is
needed. The tool holds the mapping from Rackmac names to Workbench names (`run` → `play`, `activity` →
`logbook-moth`, `palette` → `terminal`, `zoom-reset` → `ruler`, …); `icon-source` reports it. Icons are rendered on
demand into a `bitmap%` at the display's backing scale (`make-bitmap #:backing-scale`) and handed to `button%` as
a bitmap label, so `#:icon` drives native buttons directly. **Gap (#332):** Workbench has no text-formatting icons (bold,
italic, heading, lists, quote). The Format group uses letter labels for Bold and Italic, as Pages does, and the
rest need drawing to `docs/iconography.md`'s rules in the design repository first, then vendoring. Toolbar icons take their color from the native chrome
(`get-label-foreground-color`), not from the editor tokens, so they stay visible when the editor is dark and
the Win32 chrome is light; only status-bar and gutter icons use `text`. Commands without `#:icon` get a
letter tile (their initial in a nearly square tile, `radius-sm`), which RM-052 "Add to Toolbar" needs. Set as built (49):
`new open save save-as close undo redo cut copy paste select-all find replace goto comment duplicate delete-line
arrow-up arrow-down indent outdent zoom-in zoom-out zoom-reset wrap theme activity palette language run run-all
keyboard help book info settings extensions history search chevron-down chevron-right chevron-left more x check
warning error maximize print`. **Added for notes:** `bold italic code-inline link
heading list-bullet list-number checklist quote export import word pdf note folder folder-cloud tag calendar outline
backlink today lock`.

## 2. Window layout

_Changed 2026-09-25: the sidebar and the two document looks are new; tabs, InfoBar, find row, status bar,
palette, dialogs, context menus and notifications are as built or as planned before._

```
frame% (native title: "• Weekly notes.md — Rackmac")
├─ menu-bar%                           native, generated from #:menu: File Edit Format View Tools Help
└─ vertical-panel% border 0 spacing 0
   ├─ toolbar   horizontal-panel%      button% per toolbar item; Format group only for prose Languages
   ├─ horizontal-panel% border 0 spacing 0
   │  ├─ sidebar  vertical-panel% 240  Library: filter, Recent, Folders (hierarchical-list%), Tags, Outline, Backlinks
   │  └─ tabs     tab-panel%           '(no-border flat-portable can-reorder can-close new-button)
   │     └─ vertical-panel% border 0
   │        ├─ infobar  horizontal-panel% hidden unless a message is pending
   │        ├─ find     vertical-panel%   hidden; one or two rows
   │        └─ horizontal-pane%
   │           ├─ gutter  canvas%         code Languages only
   │           └─ editor  editor-canvas%  or the start view when nothing is open
   └─ status   canvas%                 message segment left, clickable segments right
```

### 2.1 Library sidebar

_Changed 2026-09-25 (new)._

- **What it is.** The Library is an ordered list of folders the person chose (`library-folders` setting). A folder is
  a folder: `~/Documents/Notes`, a OneDrive folder, a SharePoint document library synced by the OneDrive client.
  On macOS those live under `~/Library/CloudStorage/OneDrive-<Org>/` and
  `~/Library/CloudStorage/OneDrive-SharedLibraries-<Org>/`; iCloud Drive under
  `~/Library/Mobile Documents/com~apple~CloudDocs/`. **Add Folder…** (`get-directory`) lists those candidates
  above the dialog button when they exist, with a cloud icon. That is the entire OneDrive/SharePoint integration:
  the sync client does the syncing, Rackmac reads and writes files. No Graph API, no sign-in.
- **Look (Skeptical Engineering, §1.0).** The sidebar is the `bench`: `bench-text` rows in `ui`, the selected row
  `bench-heading` with a 2 px `accent` marker on its left edge, `bench-rule` between sections and on the edge
  next to the tabs, sections labelled in `ui-small` (not uppercase mono: `bench-quiet` fails contrast). A bench is
  only possible on surfaces we paint: a native `list-box%` draws the OS's light table and a native `text-field%` a
  white box. **Decision for the owner (open, #331):** (a) every sidebar list editor-based (`hierarchical-list%` takes our
  background and styles) and the filter a painted row "Find a note ⇧⌘O" that opens Quick Open over the Library, as
  the mockup shows; or (b) a `paper-sunk` sidebar that keeps native `list-box%`es and a native filter field, which
  keeps the OS's VoiceOver support for Recent, Tags, Outline and Backlinks (§2.5) but gives up the bench.
  Recommended: (a), because the Folders tree is already editor-based in either plan, so the E10 accessibility work
  (v0.7) is needed for the sidebar regardless; (a) adds three more lists to that work.
- **Sections, top to bottom** (each a header in `ui-small`, `bench-text`):
  1. `text-field%` **Filter** (matches titles and paths; Enter opens the first hit; ⇧⌘O Quick Open is the same
     search as a picker).
  2. **Recent** (`list-box%`, last 10, from `recents.rktd`).
  3. **Folders** (`mrlib/hierlist` `hierarchical-list%`: one root per Library folder, subfolders collapsible,
     files `.md .markdown .txt .rkt .py .json .yaml .csv`; other files hidden by default, a setting shows all;
     modified open documents get the "•" prefix as tabs do).
  4. **Tags** (v0.4; `list-box%` of `#tags` and front-matter tags with counts; selecting filters Recent and Folders).
  5. **Outline** (v0.4; `list-box%` of the current document's headings, indented by level; follows the caret;
     click jumps).
  6. **Backlinks** (v0.4; `list-box%` of notes linking here, one row per linking line; click opens at that line;
     "Unlinked mentions" below).
  Sections collapse by clicking their header; the state persists. Outline and Backlinks share the lower half.
- **Actions.** Click opens (single tab per file, as today). Right-click (`popup-menu%` from the context registry,
  group `library`): New Note Here, New Folder, Rename, Reveal in Finder, Copy Path, Move to Trash (uses the Finder
  Trash through `/usr/bin/osascript`, **verify**; otherwise a confirm-then-delete with the file name). Drag a file
  into the editor to insert a link to it (`on-drop-file` exists on the frame; per-widget drop **verify**).
- **Toggle:** **View > Show Library** `⌥⌘S` (Apple Notes: Show Folders). `⌘B` cannot be the sidebar key any
  more; it is Bold. Save All loses `⌥⌘S` and keeps its menu item.
- **Refresh:** `filesystem-change-evt` per Library folder (v0.4) plus a rescan on `on-activate`; v0.3 rescans on
  activate and after our own saves.
- **Empty state:** "No folders yet. Add the folder where you keep your notes (OneDrive and SharePoint folders
  work)." with an **Add Folder…** button.
- **Keyboard:** Tab into the filter, Tab again to the tree; arrows move, Right/Left expand/collapse, Enter opens,
  Space previews nothing (no preview pane in this iteration).

### 2.2 The document area for notes (Markdown, WYSIWYM)

_Changed 2026-09-25 (new)._

The file on disk is plain Markdown. What you see is the same characters, styled: "what you see is what you
mean". Markup characters stay in the text, drawn small and in `text-2`, so the caret never jumps and a colleague
opening the file in another app sees ordinary Markdown. The rendering rules, all implementable with `text%`
styles, paragraph margins and a few snips (§5.3):

| Markdown | Rendering in the editor | Mechanism |
|---|---|---|
| `# Heading` … `###### ` | heading text in `heading` color, bold, 1.6× / 1.35× / 1.15× / 1.0×; the `#` marks in `text-2` at 0.8× | `change-style` with named styles "Heading 1..6", "Markup" |
| paragraph | `prose` font, `text`, centered measure, line spacing 4 | Standard style + paragraph margins |
| `**bold**` `*italic*` `` `code` `` | bold / italic / `mono` on `line-highlight` background; markers in "Markup" | style runs |
| `- item`, `1. item` | hanging indent (first line −16 px, body +24 px per level); the bullet character stays (`-`, drawn in `text-2`); numbers stay | `set-paragraph-margins` |
| `- [ ] task`, `- [x] task`, `- [-] task` | v0.3: `[ ]`/`[x]` in "Markup"; v0.4: a checkbox `snip%` drawn as a 14 px box with the OS accent check, clickable; done text in `text-2`, cancelled drawn with a line through it by the snip's paragraph decorator (`style-delta%` has no strikethrough) | snip whose `get-text` is `[ ]`, `[x]`, `[-]` |
| `> quote` | left margin +24, `text-2`, the `>` in "Markup" | paragraph margins + style |
| ```` ```lang ```` fenced code | `mono`, `line-highlight` background across the block, Racket/Python coloring inside (v0.5) | style runs; the block is a paragraph range |
| `[text](url)`, `<https://…>`, `[[Note]]` | text in `accent`, underlined; `(url)` in "Markup"; hover shows the target in the status message; **⌘-click follows** (Word's convention); plain click places the caret | `set-clickback` on the span; modifier check in `buffer%` `on-event` |
| `![alt](image.png)` | v0.5: the source line stays; an `image-snip%` preview (scaled to the measure) sits on its own line below, excluded from the file by `document-text` | image snip with `get-text` "" |
| `\| a \| b \|` tables | `mono` block with columns aligned on Tab (v0.5); no table layout in `text%` | style runs + reformat command |
| `---` | a thin `stroke` line drawn by a rule snip | snip with `get-text` `---` |
| `#tag`, `2026-09-30`, `due 2026-09-30`, `TODO`/`WAITING`/`DONE` in a heading | v0.4: tag in `accent` tinted background; today's date `accent`, overdue `error`, done `success`; keyword bold in the state's color | style runs |
| YAML front matter | collapsed to one dim line "title · tags" with a disclosure; open shows the block in `mono` | v0.4 fold snip |
| markup hidden on inactive lines | **not in v0.3**; a v0.4 experiment (`md-hide-markup`) using zero-width snips; the owner decides the default (REPLAN §9) | — |

_As built (#266, #268, 2026-09-26):_ `rackmac/md-style.rkt`. Each run's role stack from `style-runs` folds into
one delta style derived from the document's base style ("Prose"); the single-role ones are named ("Heading 1".."6",
"Markup", "Strong", "Emphasis", "Code", "Code Block", "Link", "Quote"). Join styles are not used: snip-lib's join
update stores the transparent-text flag on the shift style, so joined styles painted a white text background.
Indents: 24 px per quote or list level, an item's first line hanging 16 px. Code backgrounds cover the characters
only (`text%` has no full-width paragraph fill). On a 282 KB, 5,000-line note: 5-6 ms CPU per keystroke (one
paragraph restyled), about 0.65 s for the first render.

Behavior: Enter continues lists and checklists; Enter on an empty item ends the list; Tab/Shift+Tab indent and
outdent an item; typing `[[` opens the note picker (v0.4); a smart-typing setting is **off** (lawyers paste
citations with straight quotes; the file is Markdown, not typography). The find row, selection, undo, zoom and
word count work as today because nothing but styles changed.

#### 2.2.1 Two views of one document: Formatted and Markdown Source

_Changed 2026-09-25 (owner requirement)._ Every Markdown document has two views, switched per document at any time.
Both edit the same `text%`; the file never changes shape.

| | **Formatted** (default for notes) | **Markdown Source** |
|---|---|---|
| Looks like | a word-processor page: the table above (prose font, centered measure, sized headings, rendered bold/italic, lists and checkboxes, links as link text with the URL de-emphasized) | exactly today's Markdown mode: `mono`, unwrapped-at-window (80-column wrap), headings and inline code colored, every character the same size, no snips, no clickbacks, no centering |
| Markup | de-emphasized (v0.3); optionally hidden on inactive lines (v0.4 setting, §5.3) | always visible, plain |
| Who wants it | writing and reading notes | fixing a table, pasting a big block of raw Markdown, checking what a colleague will see in another tool, or when something renders unexpectedly |

- **Default.** Formatted for `.md`/`.markdown`; a setting `markdown-default-view` (Formatted / Source). Documents
  above the large-file threshold (500k characters, existing guard) open in Source with a status message, because
  styling them is slow; the toggle still works on request.
- **How to reach the toggle** (all run the one command `toggle-markdown-view`, so they never disagree):
  1. **View > Show Markdown Source** as a `checkable-menu-item%` (checked when in Source; `#:when` Markdown).
  2. The **Format group's last button**, whose icon and title swap between "Show Markdown Source" and "Show
     Formatted" (`button%` has no pressed state; a swapped label is the native way to show a toggle).
  3. A **status-bar segment** "Formatted" / "Markdown" next to the Language segment, clickable like the Language
     segment (hint: "Click to switch between the formatted view and Markdown source").
  4. Shortcut **⌥⌘U**: Chrome's and Safari's View Source key, which the owner's audience already knows; it is free in
     the defaults, is a ⌘ combination with a letter (allowed by `shortcuts-test`), and does not touch ⌘/ (Toggle
     Comment). Typora's ⌘/ and Obsidian's ⌘E were considered and rejected: ⌘/ is taken and ⌘E is Word's "center".
- **Remembered per document.** The choice is stored with the document's recents entry (`recents.rktd`: path, last
  view, cursor), so a note you keep in Source stays in Source across sessions; new documents follow the setting;
  untitled documents follow the setting until first saved.
- **Editing in Formatted view.**
  - The caret moves over the real characters. With markup de-emphasized (v0.3 default) every character has width,
    so Left/Right, Home/End, selection and Backspace behave exactly as in Source; nothing is hidden, only small.
  - With **hidden markup** on (v0.4 setting), the paragraph that holds the caret always shows its markers (as
    Obsidian's live preview does): entering a paragraph reveals them, leaving it hides them again. Markers in
    other paragraphs are zero-width snips (§5.3); arrow keys treat a marker as one step, Backspace/Delete at a
    hidden marker removes the whole marker, and a selection across hidden markers copies the source characters.
  - **Bold, Italic, Link, Headings, lists** are the same commands in both views (§2.4): they edit the source
    (`**` around the selection or the word at the caret; a `## ` prefix on the line; `- [ ] ` on the line) and the
    region restyle renders the result at once. Toggling again removes the markup. In Source view the same keys
    insert the same characters; they simply stay plain.
  - **Checkboxes** in Formatted view are snips: click toggles, ⇧⌘U toggles at the caret; in Source view they are
    the characters `[ ]` / `[x]` and ⇧⌘U still edits them.
  - **Links**: Formatted shows the text in `accent` with the `(url)` small; ⌘-click follows in both views; ⌘K
    inserts or edits the link either way. Pasting a URL onto a selection wraps it as a link (both views).
- **Copy and paste.** Copy always yields the source Markdown (the `copy` command reads `document-text`, §5.3), so
  a colleague receives readable Markdown and pasting back into a note re-renders. Copy as Rich Text (v0.4) is the
  explicit way to hand Word formatted text.
- **Switching** is a full restyle of the document (clear to Standard, then either render or the source coloring),
  inside one edit sequence so it paints once; cursor and scroll position are kept; nothing enters undo. A 5,000-line
  note switches in well under a second (acceptance in `md-view-toggle`).

### 2.3 Format group and Format menu

_Changed 2026-09-25 (new)._

The toolbar is one row (as built). For prose Languages the registry adds a **Format** group via
`add-toolbar-item! #:mode 'markdown-mode` (the same `#:mode` scoping that already shows Run only for Racket):

`New Open Save | Undo Redo | Cut Copy Paste | Find | B I 🔗 | H▾ • 1. ☑ | Export▾ Source/Formatted ⟨spacer⟩ Search commands`

`H▾` opens a `popup-menu%` (Heading 1, 2, 3, Body Text); `Export▾` opens PDF…, Word…, Markdown (copy); the last
button toggles Formatted / Markdown Source (§2.2.1) and swaps its icon and title to name the other view. The menu
bar gains **Format** between Edit and View, generated from `#:menu "Format"`, shown only when the current document
is prose (`#:when`). Buttons dim from `#:when`; hover shows title and shortcut in the status message (as built).

### 2.4 Shortcuts for notes

_Changed 2026-09-25 (new). Every binding must pass `tests/shortcuts-test.rkt` (no Option+letter, no OS-reserved
keys); all are ⌘ combinations with letters, digits or symbols._

| Command | macOS | Precedent |
|---|---|---|
| Bold / Italic | ⌘B / ⌘I | Word, Pages, Outlook, Google Docs |
| Inline Code | ⇧⌘C | Slack, Teams ("code" formatting) |
| Insert Link… | ⌘K | Word, Outlook, Pages, Google Docs |
| Heading 1 / 2 / 3 | ⌥⌘1 / 2 / 3 | Word for Mac (Apply Heading 1–3) |
| Body Text | ⌥⌘0 | completes the Word pattern (Word's own ⇧⌘N is a browser New Window key elsewhere) |
| Bulleted List / Numbered List | ⇧⌘8 / ⇧⌘7 | Google Docs |
| Checklist | ⇧⌘L | Apple Notes |
| Mark Done (toggle checkbox; cycle heading state) | ⇧⌘U | Apple Notes (Mark as Checked) |
| Quote | ⇧⌘9 | next to the list keys; no strong precedent |
| Show Markdown Source / Show Formatted (toggle) | ⌥⌘U | Chrome and Safari View Source; ⌘/ (Typora) is Toggle Comment here, ⌘E (Obsidian) is Word's Center |
| Follow link | ⌘-click | Word (⌘-click to follow), Outlook |
| Show Library | ⌥⌘S | Apple Notes (Show Folders) |
| New Note | ⌘N | Notes, Word, Pages |
| Quick Open (Library) | ⇧⌘O | as built |
| Search Library | ⇧⌘F | Xcode, VS Code (find in project) |
| Today | ⌃⌘T | free; ⇧⌘T is Reopen Closed Tab |
| Collapse / Expand Section (v0.4) | ⌥⌘[ / ⌥⌘] | free in the defaults; ⌥⌘− / ⌥⌘= were rejected because macOS Accessibility Zoom reserves them (with ⌥⌘8) when enabled; Word uses Alt+Shift+−/+ |
| Promote / Demote heading (on a heading line) | ⌘[ / ⌘] | reuse of Outdent/Indent Lines; Word outline uses Shift+Tab/Tab |
| Move Section Up / Down (caret on a heading) | ⌥↑ / ⌥↓ | reuse of Move Line; Word outline Alt+Shift+↑/↓ |
| Paste as Plain Text (v0.4) | ⇧⌥⌘V | Chrome, Word for Mac, Pages |
| Settings… | ⌘, | every macOS app (Customize with Code moves to Tools > Extensions, unbound) |
| Print… (Save as PDF in the dialog) | ⌘P | as built |
| Export as PDF… / Export to Word… / Import Word Document… | menu (File > Export ▸, File > Import…) | Pages: File > Export To |
| Run Selection / Run Document | ⌘↩ / ⇧⌘↩ **in code Languages only** | as built, rescoped |

### 2.5 Outline and Backlinks

_Changed 2026-09-25 (new)._ Both are `list-box%`es in the sidebar's lower half (§2.1), so they are native and
keyboard-reachable. The Outline is rebuilt from the parser's heading spans when a restyle touches a heading, and
its selection follows the caret's section. Backlinks come from the Library index (v0.4): each row is
"Note title — the linking line", double-click opens the note at that line. Empty states: "No headings yet. Start a line
with # to make one." and "Nothing links here yet. Type [[ in another note to link to this one." A **Today** entry at
the top of the sidebar opens the generated Today document (REPLAN `today-view`).

### 2.6 Clipboard with Word

_Changed 2026-09-25 (new; the one part of the design that could not be verified headless)._ `text%` copies plain
text (which is Markdown, so pasting into Word gives readable text). Two things depend on a spike (`clipboard-spike`,
v0.3): whether `clipboard-client%` `add-type` and `get-clipboard-data` on the Cocoa backend can carry
`public.html` / `public.rtf` (or Word's `HTML Format`) beside `TEXT`. If yes: **Paste** from Word converts the HTML
through `pandoc -f html -t gfm --wrap=none` into Markdown, and **Copy as Rich Text** puts pandoc's HTML on the
pasteboard so Word and Outlook receive headings and lists. If no: paste stays plain text (Word always supplies it)
and Copy as Rich Text writes an HTML file and offers Reveal; both are documented in the issue's outcome.

### 2.7 Code documents

_Changed 2026-09-25 (revised from "editor" and "gutter")._ A document whose Language descends from `prog-mode`
(Racket, Python, JSON, YAML, shell):

- `mono` font, no wrapping, no centering, `line-highlight` on the current line, syntax coloring
  (Racket through `syntax-color/module-lexer`, Python through a small lexer; v0.5).
- **Gutter** (`ui-gutter`, v0.5): a 48 px `canvas%` left of the editor painting line numbers in `text-2`
  (current line `text`, 2 px `accent` bar), synced through `position-location` and `after-scroll-to`.
- **Run** appears in the toolbar (`#:mode 'racket-mode`, as built) and in Tools; ⌘↩ / ⇧⌘↩ are bound in the code
  Languages' keymaps, not globally. Python gets **Run in Terminal** (opens Terminal.app), never an embedded terminal.
- **Review (read-only)** toggle (v0.5): locks the text, shows a lock badge in the status bar, disables Save; **Add Note
  About This Line** creates or appends to a note with a `file:` link `path#L12` that ⌘-click follows back.
- Status bar shows Ln/Col, encoding, line ending, Language, zoom (all as built); prose hides the first three.
- Toggle Comment, Indent/Outdent Lines, Go to Line stay as built and are `#:when` code.

### 2.8 Start screen

_Changed 2026-09-25 (revised)._ A `vertical-panel%` in the editor slot when nothing is open (and reopenable from
Help): title "Rackmac", subtitle "Notes and documents you can trust to plain files", three large `button%`s **New
Note**, **Add Folder…**, **Open…**, a `list-box%` **Recent** (double-click opens), and a text button **Get Started**
that opens the bundled `Getting started.md` (a real note with checkboxes: "Make this line bold", "Add a folder",
"Export this note to Word"). No Scratch Pad on the start screen; Tools > Scratch Pad exists for Racket users. A
setting skips the screen and opens the last note instead.

### 2.9 As built or as planned before

_Unchanged._ **Title bar and menus** (native; title carries name and modified dot; items enable from `#:when`).
**Tabs** (`tab-panel%` `'no-border 'flat-portable 'can-reorder 'can-close 'new-button`, right-click menu,
"• " prefix). **Find row** (native, in-layout, between tabs and editor; count doubles as wrap indicator; Advanced
discloses regex and In selection; Esc closes). **Status bar** (one `canvas%`; message segment left; clickable
segments right; hover underline in `accent`; keyboard reachable). **Command palette** (`dialog%` 640 × 440 over the
top third, Command · Category · Shortcut, recents first, `#:help` footer, empty-state row; the "Emacs:" footer line
leaves the default product). **Dialogs** (native; plain wording, platform button order). **Context menus** (native
`popup-menu%` from the registry). **Notifications** (status message for info; InfoBar row with native icon, one
sentence, Details, one action, dismiss; no floating toasts).

## 3. Modern UX practices, applied

_Unchanged, with two rows added at the end._

| Practice | Rackmac |
|---|---|
| **Discoverability three ways** | every command: menu path, toolbar or palette, shortcut shown in all three (existing metadata); shortcut cheat sheet (RM-039); one-time "Tip: ⌘S" in the status message after a menu or palette run (RM-041); which-key popup for chords (RM-040) only with the v0.8 preset, since the default has no chords |
| **Progressive disclosure** | Find shows two options, Advanced holds regex and scope; toolbar overflow when narrow; settings dialog with search and "Edit as code"; Activity has Details, not a backtrace |
| **Non-modal feedback** | status message for info, InfoBar for actionable warnings and errors; file-changed banner (RM-080) is an InfoBar; no modal error dialogs anywhere; the only modals are Save/Open/Confirm |
| **Empty states** | start screen; palette no-results with a next step; Activity "Nothing yet. Errors and messages appear here."; Recent "Files you open appear here."; Library "No folders yet…"; Outline "No headings yet…"; Backlinks "Nothing links here yet…" |
| **Select, then act** | selection-first commands, `#:when` disables Cut/Copy without a selection so the toolbar teaches the rule; Bold/Italic act on the selection or the word at the caret |
| **Safe by default** | autosave and Restore (E3) surfaced in an InfoBar on next launch; destructive confirmations name the file and offer Cancel; the recovery store never lives inside a synced folder |
| **Keyboard and accessibility** | native controls give focus rings, Tab order and VoiceOver/Narrator; the two painted pieces (status bar, gutter) are focusable, arrow-navigable and announce via the status message; 4.5:1 text contrast enforced by test; `ui-scale`; no color-only state |
| **Platform manners** | dialog button order, modifier glyphs, close-box side and Ctrl-click follow the OS (§4) |
| **The file is the truth** | what is on disk is plain Markdown a colleague can open anywhere; every decoration is a style or a snip whose text is the source, and a round-trip test proves it |
| **Office muscle memory** | ⌘B, ⌘I, ⌘K, ⌥⌘1–3, ⇧⌘L, ⌘-click follow, ⌘, Settings; nothing to unlearn from Word, Pages, Notes or Chrome |

## 4. Per-platform differences

_Unchanged. macOS is the release target; the Windows column records intent and keeps code paths compiling._

| Aspect | Windows | macOS | GNOME note (informative) |
|---|---|---|---|
| Title bar, menu bar | native in-window (light; Win32 controls do not follow dark mode) | native; menu in the system bar | header bar; not adopted |
| Tab strip | `flat-portable` (forced anyway with `can-close`) | `flat-portable` set explicitly; same strip and "+" as Windows | libadwaita tab bar looks the same |
| Chrome font | Segoe UI (auto) | SF Pro (auto) | Cantarell |
| Editor font | Cascadia Mono → Consolas 12; prose Segoe UI 11 pt | SF Mono → Menlo 14; prose system 15 | Source Code Pro → DejaVu Sans Mono |
| Accent / selection | `get-highlight-background-color` (follows Windows accent) | same (follows macOS accent) | same |
| Dark mode detection | registry `Personalize\AppsUseLightTheme` (0 = dark), polled on `on-activate`; today's panel-luminance heuristic cannot work there | `AppleInterfaceStyle` (existing), polled on `on-activate` | `color-scheme` |
| Dark-mode result | editor, gutter, status bar dark; native chrome stays light until `racket/gui`'s Win32 backend supports it | everything dark | — |
| Modifier glyphs | `Ctrl+Shift+P` | `⇧⌘P` | `Ctrl+Shift+P` |
| Menu shortcut hints | `\t` column | spaces (Cocoa ignores `\t`; existing) | — |
| Dialog button order | default first (`Save` `Don't Save` `Cancel`) | `Don't Save` … `Cancel` `Save` | like macOS |
| Context menu | right-click, Shift+F10, Menu key | right-click and Ctrl-click | right-click |
| Undo / redo, find next | Ctrl+Z / Ctrl+Y, F3 | ⌘Z / ⇧⌘Z, ⌘G | as Windows |
| Zoom gesture | Ctrl+wheel | pinch, ⌘+wheel | Ctrl+wheel |
| Status bar height | 24 | 22 | 24 |
| Synced folders | `%USERPROFILE%\OneDrive - <Org>` | `~/Library/CloudStorage/OneDrive-<Org>`, `OneDrive-SharedLibraries-<Org>`, `~/Library/Mobile Documents/com~apple~CloudDocs` | — |

## 5. Implementation strategy in Racket

### 5.1 Scope note on racket-skia

_Unchanged._ Out of scope for this plan. `skia-natipkgs/` holds macOS-arm64 and iOS binaries only, its
`gui/COVERAGE.md` lists `editor-canvas%` as missing (Rackmac's editor is `text%`), and its own `REVIEW.md` asks for a
re-architecture. The one thing borrowed is a habit: its headless PNG tour is the model for our golden tests (§5.4).

### 5.2 Modules

_Changed 2026-09-25: notes modules added; the built ones are marked._

```
rackmac/ui/tokens.rkt       built   roles, light/dark, accent from the OS; contrast test
rackmac/ui/icons.rkt        built   (icon-bitmap name size color scale) -> bitmap%; letter-tile fallback
rackmac/ui/layout.rkt       built   metric constants; gains prose-measure-inches, sidebar-width
rackmac/ui/toolbar-panel.rkt built  button% row from the toolbar registry; #:mode groups
rackmac/ui/status-bar.rkt   built   canvas%: pure layout/render; hit-test; keyboard
rackmac/ui/find-bar.rkt     built   find/replace rows
rackmac/ui/palette.rkt      built   picker restyle; loses the Emacs footer line by default
rackmac/ui/context-menu.rkt built   popup-menu% from the registry
rackmac/ui/appearance.rkt   v0.3    dark-mode re-check on activate (macOS part of #254)
rackmac/ui/sidebar.rkt      v0.3    the Library panel: sections, hierarchical-list% tree, list-box%es, filter
rackmac/ui/start-view.rkt   v0.3    start screen panel
rackmac/ui/settings-dialog.rkt v0.3 rows generated from define-setting
rackmac/ui/infobar.rkt      v0.4    message queue row
rackmac/ui/gutter.rkt       v0.5    line numbers for code Languages
rackmac/ui/splitter.rkt     v0.6    sash between panes
rackmac/markdown/parser.rkt v0.3    pure scanner: blocks and inline spans with positions
rackmac/markdown/render.rkt v0.3    spans -> styles, paragraph margins, clickbacks; region restyle
rackmac/markdown/snips.rkt  v0.4    checkbox, rule, fold, image-preview snip classes (get-text = source)
rackmac/markdown/edit.rkt   v0.3    formatting commands, list continuation, structure editing
rackmac/library/folders.rkt v0.3    library-folders setting, scan, candidates (CloudStorage, iCloud)
rackmac/library/recents.rkt v0.3    recents.rktd via put-preferences (filename argument)
rackmac/library/watch.rkt   v0.4    filesystem-change-evt threads
rackmac/library/index.rkt   v0.4    SQLite (db) index: titles, headings, tags, links, tasks, dates; FTS5
rackmac/office/pandoc.rkt   v0.3    locate and run pandoc; docx import/export; html <-> gfm for the clipboard
rackmac/office/pdf.rkt      v0.3    print-to-dc on pdf-dc%; page setup
rackmac/settings.rkt        v0.3    define-setting, contracts, scope resolution, settings.rktd
```

`rackmac/ui/*` stays private at API version 1. The registries (`add-toolbar-item!`, `add-context-item!`,
`add-status-segment!`) and, from v0.3, `define-setting`/`setting-ref` are exported from `rackmac/api`; the Markdown
parser's span structs are exported so extensions can build on them.

### 5.3 Techniques: what `text%` can do for a notes app, and where it stops

_Changed 2026-09-25 (new). The API facts below come from the `racket/gui` and `racket/draw` references; items
marked **verify** could not be run in this session and are the first things the maintainer's live session checks._

**Capabilities we build on**

1. **Style runs.** `change-style delta start end` with a `style-delta%`: face or family (`set-delta-face`,
   `set-family 'system|'modern|'roman`), size (`set-size-add`, `set-size-mult`), weight and slant
   (`set-weight-on 'bold`, `set-style-on 'italic`), underline (`set-underlined-on`), foreground and background
   (`set-delta-foreground`, `set-delta-background`). Applied inside `begin-edit-sequence #f #f` with
   `set-modified` restored afterwards, exactly as `highlight.rkt`'s `with-styling` does, so styling is never an
   edit and never enters undo.
2. **Named, derived styles.** The shared `style-list%` already has "Standard". Notes add "Heading 1..6", "Markup",
   "Code", "Quote", "Link", "Done" as named styles created with `find-or-create-style` from Standard plus a
   delta, so a zoom change on Standard restyles everything at once (this is how zoom already works).
3. **Paragraph layout.** `set-paragraph-margins para first-left left right` (hanging indents for list items,
   indented quotes, and the page-like centering by giving every paragraph equal left and right margins) and
   `set-paragraph-alignment`. `set-line-spacing` for the whole editor. `set-max-width` and `auto-wrap` for the
   measure. Margins are per paragraph and are re-applied by the region restyle whenever an edit splits or joins
   paragraphs.
4. **Clickable spans.** `set-clickback start end proc [hilite-delta call-on-down?]` and `remove-clickbacks`.
   A clickback fires on a plain click; `buffer%`'s existing `on-event` override checks the ⌘ modifier
   (`get-meta-down` on macOS) first and lets a plain click place the caret.
5. **Snips.** Content is a sequence of snips; a `snip%` subclass overrides `get-extent`, `draw`, `on-event`,
   `get-text`, `copy`. `text%` merges only adjacent snips of the same class, so our classes stay intact. The
   rule for every decoration snip: **its `get-text` returns the source markup it replaces** (`[ ]`, `[x]`, `---`,
   the folded lines), so `get-text` on the whole document still yields the file. Inserting and removing them
   happens outside undo like styles; the user's own edits around them undo normally. Copy/Cut inside Rackmac
   converts them to their text (our `copy` command is ours to define) so nothing depends on a registered
   `snip-class%` for the clipboard.
6. **Printing and PDF.** `print` opens the native dialog (macOS offers Save as PDF); `print-to-dc` renders the
   editor into any `dc<%>`, and `racket/draw`'s `pdf-dc%` writes a PDF without pandoc or LaTeX. Page size comes from
   the `pdf-dc%`; margins via the `ps-setup%` (**verify** margin handling and page breaks across a styled note).
7. **Word count, find, undo, zoom** keep working because the document text is unchanged by rendering.
8. **The tree widget.** `mrlib/hierlist`'s `hierarchical-list%` is in the standard distribution: collapsible items,
   keyboard navigation, custom item snips for icons; no new dependency.

**Limits, and what the design does about each**

| Limit | Consequence | Design response |
|---|---|---|
| No invisible or zero-size text style | markup cannot be hidden by styling; `set-size-add`'s floor is 1 pt and still occupies width | v0.3 de-emphasizes markup (`text-2`, 0.8×); hiding is a v0.4 experiment with zero-width snips whose `get-text` is the characters, on inactive lines only |
| No strikethrough in `style-delta%` or `font%` | done/cancelled tasks cannot be struck by a style | done tasks go `text-2`; cancelled ones are drawn through by the checkbox snip's paragraph decoration (or shown as `text-disabled`) |
| No per-paragraph spacing before/after | headings cannot get "space above" | larger size and bold carry the hierarchy; a setting adds a blank line on Enter after a heading |
| One caret per `text%` | two panes on one note share the cursor (#243) | panes (v0.6) save and restore the selection per pane |
| `editor-canvas%` children cannot overlap; no popovers | no floating link preview or inline date picker | hover text in the status message; Heading▾ and Export▾ are `popup-menu%`s; the date picker is a small `dialog%` |
| Whole-buffer restyle after each edit (as built, 120 ms timer; #244) | flicker and slowness on long notes; find highlights wiped | `md-restyle-region` (v0.3 prerequisite): restyle the edited paragraphs plus the enclosing block; other style sources survive |
| `image-snip%` `get-text` is a placeholder, not the source | saving a note with previews would corrupt it | `document-text` (v0.4) walks snips; every save/export/search path uses it; round-trip test |
| Images are drawn at bitmap size | huge photos blow the measure | scale into a bitmap at the measure width before making the snip |
| No table layout | pipe tables cannot be grid-edited | mono block with Tab alignment (v0.5); pandoc handles export |
| `find-string` and snips | search may or may not see snip text | **verify**; searching uses `document-text` offsets if not |
| Rich clipboard types on Cocoa unconfirmed | paste from Word may be plain text only | `clipboard-spike` (v0.3) decides; plain text is the documented floor |
| VoiceOver with `text%` and custom snips unknown | checkboxes may be silent to a screen reader | RM-148 investigation; the ⇧⌘U command always works without the mouse |

**Snip positions, concretely.** Every decoration snip keeps the **character count of the source it replaces**
(`set-count`: 3 for `[ ]`, 2 for `**`, the line count for a fold), so a `text%` position is always a source offset and
the parser, find row, Go to Line, clickbacks and the index never need an offset map. The cost is that a snip spans
several positions while drawing as one object; `buffer%` therefore treats a snip as **atomic**: Left/Right and
Shift-selection step over the whole snip (an override of the caret motion in `on-local-char`/`move-position`), a
click lands before or after it, and Backspace or Delete at its edge removes the whole snip, which removes the
whole marker from the file. Partial deletion inside a snip would call `snip%`'s `split`, so the atomic caret is
what keeps that path unreachable; a test asserts it. This policy is trialled first on checkboxes (v0.4
`task-checkbox`) and only then extended to hidden markup (`md-hide-markup`) and folds (`outline-fold`).

**Risks of the formatted view, and the test that covers each.** (a) *Undo:* styles and snip swaps run with
`undoable?` off, user edits stay undoable; a test performs edit → render → undo → `document-text` and expects the
pre-edit source. (b) *Copy/paste of rendered text:* `copy` reads `document-text`, so the clipboard always holds
source; a test copies across a checkbox and a bold run. (c) *Caret over hidden characters:* atomic snips as above; a
test walks a line with hidden markers key by key and checks positions. (d) *Large documents:* region restyle keeps
typing under 10 ms in a 5,000-line note; above the 500k-character guard the document opens in Source; a timing test
runs headless. (e) *Position drift:* count-preserving snips; a round-trip test over the corpus compares every
parser span with the styled range.

**Region restyle, concretely.** `after-insert`/`after-delete` record the touched paragraph range; the timer
callback asks the parser for the enclosing block range (a fenced block or list can span many paragraphs), clears
styles to "Standard" in that range only, re-applies spans, paragraph margins and clickbacks there, and leaves the
rest alone. Full restyles happen on open, on Language change and on zoom. Find highlights are applied by the find
row after the restyle (hook order), so they persist.

### 5.4 Headless testing

_Unchanged, plus notes tests._

- Native surfaces: as `picker-test.rkt` and `startup-test.rkt` do, build the frame unshown, drive controls with
  `set-value`/`command` and synthetic `key-event%`/`mouse-event%`, assert through hooks (`before-command`) and
  control state (`is-enabled?` after a selection change tests `#:when`). The sidebar tree and lists are driven the
  same way.
- Painted surfaces: `render` to a `bitmap-dc%` on a `make-bitmap` (verified: a 2× bitmap with the system font
  renders and pixels read back with no window); assert segment rects and pixel colors at segment centers
  (hover underline present, contrast of `text-2` on `status-bg`).
- Notes: a corpus of Markdown files; for each, parse → style → `document-text` equals the file byte for byte;
  golden bitmaps of a sample note at 1× and 2×, light and dark; a PDF written headless has the expected page count;
  pandoc tests skip cleanly when pandoc is absent.
- Goldens: a scripted tour writes PNGs of the status bar and gutter at 1× and 2×, light and dark; compared with a
  small tolerance per platform in CI (RM-017). Whole-window screenshots stay manual (RM-068 → #12).
- Contrast test over every token column, as §1.2 states.

## 6. Build plan

_Changed 2026-09-25._ The phased plan, issue keys, sizes and acceptance criteria now live in [REPLAN.md](REPLAN.md).
The E2.M0 UI foundation from the first version of this document (tokens, layout, tabs, icons, appearance, harness)
is built except #254 (appearance re-check) and #255 (harness), which REPLAN places in v0.3 and v0.4.

## 7. Wireframes

### 7.1 Notes window, macOS (light): Library, a rendered note, outline and backlinks

_Changed 2026-09-25._

```
┌────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●                          • Weekly notes.md — Rackmac                                     │  native title; menus in the system bar
├────────────────────────────────────────────────────────────────────────────────────────────────┤
│ [＋] [▭] [💾]  [↶] [↷]  [✂] [⧉] [📋]  [🔍]  [B] [I] [🔗]  [H▾] [•] [1.] [☑]  [⇪▾] [</>]  [🔍 Search commands…] │  Format group: prose only; </> = Show Markdown Source
├──────────────────────┬─────────────────────────────────────────────────────────────────────────┤
│ [ filter…          ] │ • Weekly notes.md ✕ │ Acme SPA — turn 4.md ✕ │ +                         │  tab-panel% flat-portable
│ RECENT               ├─────────────────────────────────────────────────────────────────────────┤
│  Weekly notes        │                                                                         │
│  Acme SPA — turn 4   │            # Weekly notes                          ← H1: heading color,  │  markup "#" small, text-2
│  Call with J. Roe    │                                                    1.6×, bold            │
│ FOLDERS              │            Monday                                                       │  prose 15 pt, centered 6.5 in
│  ▾ Notes             │                                                                         │
│    ▾ Matters         │            - ☑ Call the vendor about the **renewal**   ← checkbox snip, │  bold run; markers small
│       Acme SPA       │            - ☐ Draft the summary · due 2026-09-30      ← date in accent │  hanging indent
│       Roe v. Doe     │            - ☐ Send [[Acme SPA — turn 4]] to counsel   ← link: accent,  │  ⌘-click follows
│    Weekly notes      │                                                        underlined       │
│  ▸ OneDrive - Firm ☁ │            > Counsel asked for the redline by Friday.  ← quote: indent, │  text-2
│ TAGS                 │                                                                         │
│  #acme 12  #todo 4   │            ## Next week|                                                │  caret line; no line highlight in prose
│ OUTLINE              │                                                                         │
│  Weekly notes        │                                                                         │
│    Monday            │                                                                         │
│  ▸ Next week         │                                                                         │
│ BACKLINKS            │                                                                         │
│  Acme SPA — turn 4   │                                                                         │
│   "…see Weekly notes"│                                                                         │
├──────────────────────┴─────────────────────────────────────────────────────────────────────────┤
│ Saved Weekly notes.md                                  212 words   Formatted   Markdown   100%  │  prose: no Ln/Col, encoding, EOL; view segment clickable
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 Code window, macOS (dark): a Python script under review, with gutter

_Changed 2026-09-25._

```
┌────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●                          rename_exhibits.py — Rackmac                                    │
├────────────────────────────────────────────────────────────────────────────────────────────────┤
│ [＋] [▭] [💾]  [↶] [↷]  [✂] [⧉] [📋]  [🔍]  [🔒 Reviewing]  [▷ Run in Terminal]   [🔍 Search commands…] │  no Format group; code items
├──────────────────────┬─────────────────────────────────────────────────────────────────────────┤
│ [ filter…          ] │ Weekly notes.md ✕ │ rename_exhibits.py ✕ │ +                            │
│ RECENT               ├──────┬──────────────────────────────────────────────────────────────────┤
│  rename_exhibits.py  │  10  │ import pathlib                                                   │  mono 14, unwrapped
│  Weekly notes        │  11  │                                                                  │  gutter: text-2, current line text
│ FOLDERS              │▌ 12  │ for p in pathlib.Path("Exhibits").glob("*.pdf"):|                │  ▌ accent bar; line-highlight on
│  ▾ Scripts           │  13  │     new = p.with_name(p.stem.upper() + p.suffix)                 │  keywords, strings colored
│    rename_exhibits   │  14  │     p.rename(new)   # TODO: dry run first                        │  comment italic
│  ▾ Notes             │  15  │                                                                  │
│ OUTLINE              │      │                                                                  │
│  (no headings)       │      │                                                                  │
├──────────────────────┴──────┴──────────────────────────────────────────────────────────────────┤
│ Read-only while reviewing · Add Note About This Line          Ln 12, Col 49   UTF-8   LF   Python   100% │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 7.3 Start screen (nothing open)

_Changed 2026-09-25._

```
┌────────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●                                Rackmac                                                   │
├────────────────────────────────────────────────────────────────────────────────────────────────┤
│ [＋] [▭] [💾]  [↶] [↷]  [✂] [⧉] [📋]  [🔍]                                    [🔍 Search commands…] │
├──────────────────────┬─────────────────────────────────────────────────────────────────────────┤
│ [ filter…          ] │                                                                         │
│ RECENT               │                         Rackmac                                         │  title 22 bold
│  Weekly notes        │          Notes and documents you can trust to plain files              │  subtitle 15
│  Acme SPA — turn 4   │                                                                         │
│ FOLDERS              │        [   New Note   ]   [  Add Folder…  ]   [    Open…    ]           │  three button%s
│  ▾ Notes             │                                                                         │
│  ▸ OneDrive - Firm ☁ │        Recent                                                           │
│                      │        ┌───────────────────────────────────────────────────────┐        │  list-box%, double-click opens
│                      │        │ Weekly notes.md               Notes           today   │        │
│                      │        │ Acme SPA — turn 4.md          Matters/Acme    Mon     │        │
│                      │        │ Call with J. Roe.md           Matters/Roe     Fri     │        │
│                      │        └───────────────────────────────────────────────────────┘        │
│                      │        Get Started  ·  a short note that shows what Rackmac does        │  opens Getting started.md
├──────────────────────┴─────────────────────────────────────────────────────────────────────────┤
│                                                                                  Markdown  100% │
└────────────────────────────────────────────────────────────────────────────────────────────────┘
   Empty Library: the sidebar shows "No folders yet. Add the folder where you keep your notes (OneDrive and
   SharePoint folders work)." with an Add Folder… button; the Recent list says "Notes you open appear here."
```

### 7.4 Command palette (dialog%, 640 × 440, over the top third of the window)

_Unchanged, except the footer no longer shows an Emacs name by default._

```
          ┌──────────────────────────────────────────────────────────────────┐
          │ [ bol|                                                         ] │  text-field%
          ├──────────────────────────────────────────────────────────────────┤
          │ Command                          Category          Shortcut      │  list-box% with columns
          │ ▶ Bold                           Format            ⌘B            │  selected row = OS highlight
          │   Body Text                      Format            ⌥⌘0           │
          │   Bulleted List                  Format            ⇧⌘8           │
          │   Backlinks                      View                            │
          │                                                                  │
          ├──────────────────────────────────────────────────────────────────┤
          │ Make the selection bold.                        ↑↓ move · ⏎ run · esc close │  message% footer (#:help)
          └──────────────────────────────────────────────────────────────────┘
   Empty state row: "No commands match 'xyz'. Check the spelling or open Help > Keyboard Shortcuts."
```

### 7.5 Find and Replace rows (native controls, between the tabs and the editor)

_Unchanged (built in v0.2.0)._

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ Find    [ renewal                  ]  3 of 12   ☐ Match case  ☐ Whole word  [Advanced ▾]  [↑] [↓] [✕] │
│ Replace [ contract                 ]            [Replace] [Replace All]                                 │
│         ☐ Regular expression  ☐ In selection                     ← shown only after Advanced ▾          │
└──────────────────────────────────────────────────────────────────────────────────────┘
   Enter = next, Shift+Enter = previous, Esc = close and refocus the editor.
   Count states: "12 matches" while typing · "3 of 12" after stepping · "Wrapped · 1 of 12" · "No matches" (error color).
```

## Decisions

_Taken 2026-09-25 (v0.2.0 layer), unchanged:_ (1) the `flat-portable` tab strip on both OSes, (2) one row of
icon-only native buttons with overflow, (3) on Windows the editor follows the system theme with an "Editor theme"
setting, (4) the gutter ships for code Languages (now v0.5, code documents only).

_Open for the owner (notes layer):_ the four decisions at the end of [REPLAN.md](REPLAN.md) §9: in-house Markdown
scanner or a package; markup de-emphasized (default) or hidden on inactive lines; ⌘, → Settings and ⌥⌘S → Show
Library; the metadata convention (front matter plus inline tokens).
