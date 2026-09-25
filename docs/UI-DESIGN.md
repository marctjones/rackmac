# Rackmac UI design: a modern desktop editor on native controls

_Status: proposal for the owner. Targets macOS and Windows. Scope, in the owner's words: use the existing
Windows and macOS `racket/gui` controls; make the **window layout and coloring** modern and follow modern UX
practice; do not make it look like old Emacs. So: no custom widget toolkit, no Skia layer, no custom title bar,
no restyled buttons or text fields. Custom painting is limited to areas that are ours anyway (editor surface,
gutter, selection, status bar) and to small `canvas%` pieces where `racket/gui` has no control at all. GNOME
(libadwaita) is cited only where it informs a cross-platform choice; Linux is not a target. Nothing here changes
the core: command registry, keymaps, modes, hooks, buffers on `text%`, `#lang rackmac` with ownership and unload.
Every surface reads command metadata (`#:title #:help #:icon #:when #:aliases`, mode `#:label`), and the toolbar
and context menu are extensions on the public API as ROADMAP E2 says._

## 0. The short version

- **Layout:** title bar (native) → menu bar (native) → one-row toolbar of native icon buttons → document tabs
  (`tab-panel%` with close boxes, reordering and a "+" button, all built in) → optional InfoBar row → optional
  find row → editor → status bar. Everything on a 4 px grid with real margins.
- **Color:** one token module for the surfaces we paint (editor, gutter, selection, find highlight, status bar,
  syntax faces), light and dark, with the accent taken from the OS highlight color. Native chrome keeps the OS look.
- **UX:** discover by menu, toolbar, palette and shortcut hints; progressive disclosure (Advanced in Find,
  overflow, settings search); non-modal feedback (status message and InfoBar, never a modal error box);
  designed empty states; keyboard everything, which native controls give us for free with the screen reader.
- **Order:** a small UI foundation milestone (tokens, layout constants, appearance detection, headless tests)
  lands before the toolbar; E2 builds on it in v0.2; InfoBar (E8), start screen (E5) and panes (E9) follow.
- **racket-skia:** out of scope for now (§4.1, one paragraph).

## 1. Visual language

### 1.1 What is native and what we paint

| Native `racket/gui` (OS look, OS accessibility) | Painted by Rackmac (`racket/draw`) |
|---|---|
| title bar, menu bar, `button%` (toolbar, dialogs), `text-field%`, `check-box%`, `choice%`, `list-box%`, `tab-panel%`, `message%`, `dialog%`, `popup-menu%`, file and message dialogs | editor surface (`editor-canvas%` on `text%`): background, text, selection, caret, current line, find matches, syntax faces; gutter; status bar (`canvas%`); toolbar icons (vectors rendered to `bitmap%` labels); pane splitters (E9) |

### 1.2 Color tokens (`rackmac/ui/tokens.rkt`)

Roles, not colors. `theme.rkt` already holds `bg fg comment string constant keyword error heading`; this table
extends it and moves it behind `(token 'name)`. Seeds: GitHub-light/VS-dark values already in `theme.rkt` for
faces; Fluent 2 and HIG neutrals for surfaces. `accent` comes from `get-highlight-background-color` (the OS
selection color, which follows the Windows accent and the macOS accent setting) and is only used where we paint.

| Role | Light | Dark | Used for |
|---|---|---|---|
| `surface` | #FFFFFF | #1E1E1E | editor background (`canvas-background`) |
| `text` | #1F2328 | #D4D4D4 | editor text (`fg`) |
| `text-2` | #6E7781 | #9DA5AD | gutter numbers, status segments, placeholders |
| `text-disabled` | #A6A6A6 | #6E6E6E | dimmed segments |
| `stroke` | #E3E3E3 | #3A3A3A | 1 px line above the status bar, gutter edge |
| `line-highlight` | #F6F8FA | #262626 | current line (prose Languages off, code on) |
| `selection` | OS highlight (fallback #B3D7FF) | OS highlight (fallback #264F78) | text selection; `text%` uses the OS color itself |
| `accent` | OS highlight, fallback #0067C0 / macOS #007AFF | fallback #60CDFF / macOS #0A84FF | status-bar hover underline, gutter marker for the current line, find count when matches exist |
| `match` / `match-current` | #FFE08A / #FFB000 | #6B5900 / #B58900 | Find All highlights (RM-109), 35% alpha |
| `info` / `success` / `warning` / `error` | #0067C0 / #0F7B0F / #9D5D00 / #C42B1C | #60CDFF / #6CCB5F / #FCE100 / #FF99A4 | status-bar icons, find "No matches", InfoBar text |
| `status-bg` | #F3F3F3 (macOS #ECECEC) | #202020 (macOS #282828) | status bar; sits visually with the OS window color |
| faces `comment string constant keyword heading` | as `theme.rkt` | as `theme.rkt` | syntax coloring, unchanged |

Rules: `text` and `text-2` on `surface`, and every status token on `status-bg`, meet 4.5:1 (a test computes
it); `stroke` and `accent` on their surfaces meet 3:1; nothing is conveyed by color alone (the current find match
also gets a thicker outline, the modified tab also has "•" and the window title). High-contrast variants
(RM-145) are two more columns of this table.

### 1.3 Typography

Native controls use the OS control font automatically (`normal-control-font` is `.AppleSystemUIFont` 13 on
macOS and Segoe UI on Windows; nothing to do). We choose fonts only for what we paint and for the start screen.

| Slot | macOS | Windows | Where |
|---|---|---|---|
| `mono` | SF Mono → Menlo, 14 | Cascadia Mono → Consolas, 12 | editor, gutter; resolved once with `get-face-list` (SF Mono and Cascadia are not on a base install; Menlo and Consolas are) |
| `ui` | `normal-control-font` (13) | `normal-control-font` (Segoe UI 9 pt) | status bar, InfoBar text |
| `ui-small` | `small-control-font` (11) | `small-control-font` | status segments when the window is narrow |
| `title` | `ui` face at 22 bold | `ui` face at 20 bold | start screen heading (`message%` with `font`) |
| `subtitle` | `ui` face at 15 | `ui` face at 14 | start screen card titles |

Zoom (`font-size`, existing) scales the editor only; a `ui-scale` setting (RM-146) scales gutter and status
bar fonts and metrics in the same step.

### 1.4 Spacing, metrics, motion

- **4 px grid** through `panel%` `border`, `spacing`, `horiz-margin`, `vert-margin`: window rows `border 0`,
  toolbar `spacing 4` with an 8 px gap (a `pane%` spacer) between groups, InfoBar and find row `border 8 spacing 8`,
  dialogs `border 16 spacing 12`.
- **Editor margins:** `horizontal-inset` 16 (today 12), `vertical-inset` 12; prose Languages wrap at a readable
  measure (a fixed `set-max-width` of ~80 columns of the mono font instead of `buffer.rkt`'s `auto-wrap #t`,
  which wraps at the window edge), text left-aligned; code Languages unwrapped.
- **Row heights** follow the controls: toolbar = button height + 8; tab strip as `tab-panel%` draws it; status
  bar 24 (macOS 22); InfoBar one line of `ui` + 16.
- **Motion:** none required. State changes are instant; caret blink is the editor's own. A reduced-motion
  setting exists from day one so anything added later (a status message fade) has an off switch.

### 1.5 Icons

Fluent System Icons style: single-weight line icons on a 16-unit grid, 1 px stroke at 16 px, 1.5 at 20 px,
round caps. Each icon is a small `racket/draw` path program in `rackmac/ui/icons.rkt`, rendered on demand into a
`bitmap%` at the display's backing scale (`make-bitmap #:backing-scale`) and handed to `button%` as a bitmap
label, so `#:icon` drives native buttons directly. Toolbar icons take their color from the native chrome
(`get-label-foreground-color`), not from the editor tokens, so they stay visible when the editor is dark and
the Win32 chrome is light; only status-bar and gutter icons use `text`. Commands without `#:icon` get a
letter tile (their initial in a rounded square), which RM-052 "Add to Toolbar" needs. Set: `new open save
save-as close undo redo cut copy paste select-all find replace goto comment duplicate delete-line arrow-up
arrow-down indent outdent zoom-in zoom-out zoom-reset wrap theme activity palette language run run-all keyboard
help book info settings extensions history search chevron-down chevron-right chevron-left more x check warning
error split-right split-down sidebar record stop play` (about 55). `#:icon` is set on 0 of 61 built-ins today;
assigning names is its own small issue.

## 2. Window layout

```
frame% (native title: "• notes.md — Rackmac")
├─ menu-bar%                           native, generated from #:menu (unchanged)
└─ vertical-panel% border 0 spacing 0
   ├─ toolbar   horizontal-panel%      button% per toolbar item, bitmap labels, group spacers, hideable
   ├─ tabs      tab-panel%             '(no-border flat-portable can-reorder can-close new-button)
   │  └─ vertical-panel% border 0      the stacked rows under the strip
   │     ├─ infobar  horizontal-panel% hidden unless a message is pending
   │     ├─ find     vertical-panel%   hidden; one or two rows
   │     └─ horizontal-pane%
   │        ├─ gutter  canvas%         optional, line numbers for code Languages
   │        └─ editor  editor-canvas%  or the start view panel when no documents are open
   └─ status   canvas%                 message segment left, clickable segments right
```

- **Title bar and menus:** native, unchanged. The title carries the document name and the modified dot; the
  menu bar keeps its metadata generation. Menu items enable from `#:when` on open (RM-065).
- **Toolbar (one row, not a ribbon).** 61 commands do not justify tabs and groups; Office's Simplified Ribbon is
  one row too. Default layout: `New Open Save | Undo Redo | Cut Copy Paste | Find | ⟨Language items: Run
  Selection for Racket⟩ ... ⟨spacer⟩ Search commands` where the last is a `button%` that opens the palette.
  Items come from the toolbar registry (RM-043, `add-toolbar-item!`), enable from `#:when` on the
  `after-command`, `status-changed` and `buffer-modified-changed` hooks (RM-049), and the whole row hides from
  View > Show Toolbar. Icon-only by default; `button%` accepts `(list bitmap "Save" 'bottom)` so labels under
  icons are a setting. There is no tooltip API, so the hovered button's title and shortcut go to the status
  message via `on-subwindow-event` on the toolbar panel (verify on both OSes that motion over a native
  `button%` reaches it; if not, the hint shows on focus and in the menus only).
- **Tabs.** `tab-panel%` with `'no-border 'flat-portable 'can-reorder 'can-close 'new-button`: close boxes
  call `on-close-request` → `close-tab` on that buffer; dragging calls `on-reorder`; "+" calls
  `on-new-request` → `new-document`. Labels keep the "• " modified prefix. `'flat-portable` must be explicit:
  `mrpanel.rkt` only forces it on Windows, and without it macOS gets Cocoa's own no-border strip (close and
  reorder, but no "+" and a different drawing). With it, both OSes draw the same strip. Right-click on the
  strip (`on-subwindow-event`) opens the tab context menu (RM-071); middle-click closes (RM-070). Keyboard:
  Ctrl+Tab as today.
- **Editor.** `editor-canvas%` with the margins above and `set-canvas-background` from `surface`. The optional
  gutter is a 48 px `canvas%` to the left that paints line numbers in `text-2` (current line in `text`) using
  the editor's `position-location` and scroll offset; it is on for code Languages, off for prose, per mode local
  `gutter?` (new issue `ui-gutter`).
- **Find row.** Native and in-layout, appearing between the tabs and the editor (a real overlay is impossible:
  `racket/gui` children never overlap). Row 1: `[ find text-field% ] 3 of 12  [☐ Match case] [☐ Whole word]
  [Advanced ▾] [Previous] [Next] [✕]`; row 2 (Find and Replace): `[ replace text-field% ] [Replace] [Replace All]`.
  `Advanced ▾` discloses `[☐ Regular expression] [☐ In selection]` inline (RM-107, RM-112). Esc closes and
  refocuses the editor, Enter and Shift+Enter step, the count doubles as the wrap indicator ("Wrapped · 1 of 12")
  and turns `error` at "No matches" (RM-110). Buttons take icon labels from the same set.
- **Status bar.** One `canvas%` (a clickable native equivalent does not exist). Left: the message segment (the
  echo area). Errors get an `error` icon and stay until clicked, which opens Activity. Right: segments `Ln 12,
  Col 8 · 84 words · UTF-8 · LF · Markdown · 100%`, each hit-tested, underlined in `accent` on hover, with a hint
  in the message segment ("Click to change the Language"), and reachable by Tab then Left/Right/Enter. Clicks
  run the commands E2.M4 lists.
- **Command palette.** The existing `dialog%` + `text-field%` + `list-box%`, restyled: 640 × 440, placed over
  the top third of the main window (`move` after `center`), `'no-caption` when the platform accepts it (titled
  "Command Palette" otherwise), columns `Command · Category · Shortcut`, recents first when empty (done), the
  highlighted command's `#:help` and Emacs alias in a `message%` footer (RM-030), and an empty state row
  "No commands match 'xyz'. Check the spelling or open Help > Keyboard Shortcuts." (RM-031).
- **Dialogs.** Native `message-box`, `get-file`, `put-file`. One helper wraps app confirmations so wording is
  plain ("Save changes to notes.md?", "Don't Save", never "buffer") and button order follows the platform.
- **Context menus.** Native `popup-menu%` from the context registry (RM-055), items enabled per selection.
- **Notifications.** Two channels, no floating toasts (they would need a second window; a later experiment).
  *Info* goes to the status message. *Warning* and *error* that need an action raise the **InfoBar** row:
  `message%` with the native `'caution` or `'stop` icon, one plain sentence, `Details` (opens Activity),
  one action (`Disable extension`, `Reload`, `Keep mine`), `✕`. Several messages queue; the row hides when
  empty. libadwaita's toast rule (one line, at most one action) is the content guideline.
- **Start screen.** A `vertical-panel%` shown in the editor slot when no files are given: title "Rackmac",
  subtitle "A modern editor you can program", three large `button%`s `New Document`, `Open…`, `Get Started`,
  a `list-box%` "Recent" (RM-083; double-click opens), and a small "Scratch Pad" button for Racket users. It
  leaves when the first document opens (`change-children`) and is a command, so it can come back from Help.

## 3. Modern UX practices, applied

| Practice | Rackmac |
|---|---|
| **Discoverability three ways** | every command: menu path, toolbar or palette, shortcut shown in all three (existing metadata); shortcut cheat sheet (RM-039); one-time "Tip: ⌘S" in the status message after a menu or palette run (RM-041); which-key popup for chords (RM-040) as a small captionless `dialog%` near the caret |
| **Progressive disclosure** | Find shows two options, Advanced holds regex and scope; toolbar overflow when narrow; settings dialog with search and "Edit as code"; Activity has Details, not a backtrace |
| **Non-modal feedback** | status message for info, InfoBar for actionable warnings and errors; file-changed banner (RM-080) is an InfoBar; no modal error dialogs anywhere; the only modals are Save/Open/Confirm |
| **Empty states** | start screen; palette no-results with a next step; Activity "Nothing yet. Errors and messages appear here."; Recent "Files you open appear here." |
| **Select, then act** | selection-first commands, `#:when` disables Cut/Copy without a selection so the toolbar teaches the rule |
| **Safe by default** | autosave and Restore (E3) surfaced in an InfoBar on next launch; destructive confirmations name the file and offer Cancel |
| **Keyboard and accessibility** | native controls give focus rings, Tab order and VoiceOver/Narrator; the two painted pieces (status bar, gutter) are focusable, arrow-navigable and announce via the status message; 4.5:1 text contrast enforced by test; `ui-scale`; no color-only state |
| **Platform manners** | dialog button order, modifier glyphs, close-box side and Ctrl-click follow the OS (§4) |

## 4. Per-platform differences

| Aspect | Windows | macOS | GNOME note (informative) |
|---|---|---|---|
| Title bar, menu bar | native in-window (light; Win32 controls do not follow dark mode) | native; menu in the system bar | header bar; not adopted |
| Tab strip | `flat-portable` (forced anyway with `can-close`) | `flat-portable` set explicitly; same strip and "+" as Windows | libadwaita tab bar looks the same |
| Chrome font | Segoe UI (auto) | SF Pro (auto) | Cantarell |
| Editor font | Cascadia Mono → Consolas 12 | SF Mono → Menlo 14 | Source Code Pro → DejaVu Sans Mono |
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

## 5. Implementation strategy in Racket

### 5.1 Scope note on racket-skia

Out of scope for this plan. `skia-natipkgs/` holds macOS-arm64 and iOS binaries only, its `gui/COVERAGE.md` lists
`editor-canvas%` as missing (Rackmac's editor is `text%`), and its own `REVIEW.md` asks for a re-architecture.
The one thing borrowed is a habit: its headless PNG tour is the model for our golden tests (§5.4).

### 5.2 Modules

```
rackmac/ui/tokens.rkt      (token 'surface) etc. for light/dark (+ high-contrast later); accent from the OS
                           highlight color; ui-scale; fires 'theme-changed. theme.rkt keeps the faces and
                           reads bg/fg from here, so editor and chrome cannot drift.
rackmac/ui/icons.rkt       (icon-bitmap name size color scale) -> bitmap%, cached per (name size color scale);
                           letter-tile fallback; (icon-names).
rackmac/ui/layout.rkt      the metric constants (insets, spacing, row heights) and the frame row builder.
rackmac/ui/appearance.rkt  detect dark mode per platform, poll on on-activate, swap tokens once per real change.
rackmac/ui/toolbar.rkt     horizontal-panel% of button%s from the toolbar registry; enable from #:when.
rackmac/ui/tabs.rkt        tab-panel% subclass: on-close-request / on-reorder / on-new-request -> commands.
rackmac/ui/status-bar.rkt  canvas%: pure (layout w h) -> segments, (render dc w h); hit-test; keyboard.
rackmac/ui/find-bar.rkt    today's find code, moved, with the count message% and Advanced disclosure.
rackmac/ui/infobar.rkt     horizontal-panel% row with a message queue.
rackmac/ui/palette.rkt     picker.rkt restyle (placement, columns, footer, empty state).
rackmac/ui/start-view.rkt  vertical-panel% for the start screen.
rackmac/ui/gutter.rkt      canvas% line numbers synced to the editor (optional, code Languages).
rackmac/ui/dialogs.rkt     confirm helper with platform button order and plain wording.
rackmac/ui/splitter.rkt    (E9) 6 px canvas% sash between panes; racket/gui has no splitter.
```

`rackmac/ui/*` is private at API version 1. Only the registries (`add-toolbar-item!`, `add-context-item!`,
later `add-status-segment!`) are exported from `rackmac/api`, as ROADMAP says.

### 5.3 Techniques

- **frame.rkt refactor.** The editor leaves `tab-panel%`'s child area only conceptually: `tab-panel%` stays the
  parent of the InfoBar/find/editor stack (it is a panel), gains the new styles, and `refresh-tabs!` keeps
  syncing labels from `visible-buffers`. `status-panel` and its two `message%`s become `status-bar%`, fed by the
  `echo` and `status-changed` hooks. Menus are untouched.
- **Toolbar icons at HiDPI.** Render each icon into `(make-bitmap 16 16 #t #:backing-scale s)` where `s` is
  the frame's display scale (2.0 measured here), stroked in `get-label-foreground-color`; re-render when that
  color changes (macOS appearance switch), not when the editor theme does. `button%` draws the bitmap at
  logical size.
- **Gutter.** `on-paint` draws numbers for the visible paragraph range using the editor's `position-location`
  and `get-view`; it refreshes from the buffer's `after-scroll-to` (an `editor<%>` method; `editor-canvas%` has
  no scroll hook) and the change hooks. The current line number is in `text`, others `text-2`; a 2 px `accent`
  bar marks the current line.
- **Status bar.** `render` is a pure function of (segments, hover, focus, width), so tests draw it to a
  `bitmap-dc%`; `on-event` maps x to a segment; Tab focuses the canvas, Left/Right move, Enter runs.
- **Appearance.** On startup and every `on-activate`: read the OS (registry on Windows via `reg query`, or
  `ffi/unsafe` later; `defaults` on macOS as today), compare with the current theme, and only then swap tokens
  and run `theme-changed`; `theme.rkt` re-applies its style delta (existing), the status bar, gutter and icons
  re-render. `RACKMAC_THEME` still forces a theme. On Windows the editor goes dark while the chrome stays light;
  a setting "Editor theme: System / Light / Dark" lets people who dislike the mix pick.
- **Text inputs.** `text-field%` everywhere (find, replace, palette, go-to-line). No placeholder API exists, so
  labels sit to the left; the count `message%` gives the live feedback instead.

### 5.4 Headless testing

- Native surfaces: as `picker-test.rkt` and `startup-test.rkt` do, build the frame unshown, drive controls with
  `set-value`/`command` and synthetic `key-event%`/`mouse-event%`, assert through hooks (`before-command`) and
  control state (`is-enabled?` after a selection change tests `#:when`).
- Painted surfaces: `render` to a `bitmap-dc%` on a `make-bitmap` (verified: a 2× bitmap with the system font
  renders and pixels read back with no window); assert segment rects and pixel colors at segment centers
  (hover underline present, contrast of `text-2` on `status-bg`).
- Goldens: a scripted tour writes PNGs of the status bar and gutter at 1× and 2×, light and dark; compared with a
  small tolerance per platform in CI (RM-017). Whole-window screenshots stay manual (RM-068).
- Contrast test over every token column, as §1.2 states.

## 6. Phased build plan

Sizes follow ROADMAP (S under half a day, M 1–2 days, L 3–5). New issues are in `roadmap.rktd` shape with a
`ui-` prefix (unused today) so they can be pasted; the owner adds them and runs `racket tools/roadmap.rkt`
(`roadmap-test.rkt` enforces the sync).

### E2.M0 UI foundation (new; v0.2, before E2.M1)

```
(milestone E2.M0 "UI foundation"
 (sub E2.M0.S1 "Tokens and layout"
  (issue ui-tokens "Token module for painted surfaces: roles, light/dark, accent from the OS highlight color" S todo
    "rackmac/ui/tokens.rkt | theme.rkt reads bg and fg from it | contrast test passes for every column | ui-scale parameter" ())
  (issue ui-layout "Layout constants and frame rows on the 4 px grid; editor insets 16/12; prose measure" S todo
    "border 0 spacing 0 rows | insets applied | set-max-width for prose Languages | tests pass" (ui-tokens))
  (issue ui-tabs "Document tabs with close boxes, reordering and a new-tab button via tab-panel% styles" S todo
    "no-border flat-portable can-reorder can-close new-button | close box runs close-tab | + runs new-document on both OSes | order change updates the buffer list" (ui-layout))
  (issue meta-icon-assign "Assign #:icon names to every built-in command with a menu entry" S todo
    "names from the documented set | test lists commands without one" (meta-icon)))
 (sub E2.M0.S2 "Appearance and tests"
  (issue ui-appearance "Detect dark mode on Windows (registry) and macOS; poll on activate; fire theme-changed once per change" M todo
    "AppsUseLightTheme read on Windows | AppleInterfaceStyle on macOS | icons and painted surfaces re-render | RACKMAC_THEME still forces | Editor theme setting System/Light/Dark" (ui-tokens))
  (issue ui-tests "Headless harness: render painted widgets to bitmap-dc%, pixel and geometry asserts, golden PNGs at 1x and 2x" S todo
    "runs in raco test | tolerance diff | contrast test included" (ui-tokens))))
```

### Existing epics, mapped

| Epic / milestone | What changes | New issues and dependency edits |
|---|---|---|
| **E2.M1 Toolbar** (v0.2) | RM-046 `tb-icons`: vectors rendered to `bitmap%` at the display scale (depends `ui-tokens`); RM-047 `tb-button`: native `button%` with bitmap label, hover title to status message; RM-048 `tb-frame`: `horizontal-panel%` row with group spacers and View > Show Toolbar; RM-049 enable from `#:when` on hooks | `tb-icons → ui-tokens`, `tb-frame → ui-layout`; add `(issue tb-overflow "Overflow: hide trailing groups when the window is narrow; a ⋯ button lists them in a popup-menu%" S todo "no clipping at 640 px | items still reachable" (tb-frame))` |
| **E2.M3 Context menu** | native `popup-menu%`; unchanged | — |
| **E2.M4 Status bar** (v0.2) | RM-059 `sb-widget` is the `canvas%` in §5.3 with keyboard access; message segment carries severity icons | `sb-widget → ui-tokens ui-tests` |
| **E2.M5 Mouse** | RM-070 `mouse-tabs` is mostly delivered by `ui-tabs` (close box, reorder); middle-click and RM-071 use `on-subwindow-event` on the tab panel | `mouse-tabs → ui-tabs`, `mouse-tab-menu → ui-tabs` |
| **E1.M2 Palette** (v0.2) | `(issue ui-palette "Palette placement over the top third, Category column, #:help footer, no-caption where accepted, empty state" M todo "picker-test passes | recents first | footer shows help and Emacs alias | no-results row" (ui-layout))` | `palette-category → ui-palette`, `palette-empty → ui-palette` |
| **E6.M1 Find bar** (row restyle can land in v0.2) | `(issue ui-findbar "Find row: count message, Match case, Whole word, Advanced disclosure, icon buttons, Esc refocuses" M todo "count doubles as wrap indicator | No matches in error color | Advanced reveals regex and In selection | replace row toggles" (ui-layout tb-icons))` | `find-count`, `find-word`, `find-regex`, `findall-selection` depend on it |
| **E8.M1 Activity** (v0.3) | `(issue ui-infobar "InfoBar row: native caution/stop icon, one sentence, Details, one action, dismiss; message queue" M todo "hidden when empty | keyboard reachable | error stays until dismissed | info never uses it" (ui-layout))`; RM-130 `act-levels` routes info to the status message and warning/error to the InfoBar; RM-080 `ext-banner` is an InfoBar | `act-levels → ui-infobar`, `ext-banner → ui-infobar` |
| **E5.M1 Start screen** (v0.4) | `(issue ui-start-view "Start view panel: title, New, Open, Get Started, Recent list, Scratch Pad; command to reopen" M todo "shown with no file arguments | leaves when a document opens | Recent from recent-files | keyboard reachable" (ui-layout recent-files))` | `start-view → ui-start-view` |
| **Editor** (v0.3, optional) | `(issue ui-gutter "Line-number gutter canvas synced to the editor; on for code Languages, off for prose" M todo "numbers align with lines at 1x and 2x | current line in text color with accent bar | mode local gutter? | zoom follows" (ui-tokens ui-tests))` | `a11y-scale` scales it |
| **E4.M2 Settings** (v0.3) | native `dialog%` with `check-box%`, `choice%`, `text-field%` rows generated from `define-setting`; a `text-field%` search filters rows; "Edit as code" button | `settings-dialog → ui-layout` |
| **E9 Panes** (v0.5) | `(issue ui-splitter "6 px canvas% sash between panes: drag, cursor, min size, double-click resets, keyboard resize" M todo "two editor-canvas% resize live | no native panel pixel exposed" (ui-layout))` | `pane-commands → ui-splitter` |
| **E10** (v0.6) | `a11y-keyboard` audits status bar and gutter; `a11y-contrast` adds the high-contrast columns; `a11y-scale` exposes `ui-scale` | depend on `ui-tokens` |

Suggested order in v0.2: `ui-tokens` → `ui-layout` → `ui-tabs` → `meta-icon-assign` → `tb-icons` →
`tb-button` → `tb-frame` → `sb-widget` → `ui-palette` → `ui-findbar` → `ui-appearance` → `ui-tests` alongside.
The foundation is about a week; nothing in it is throwaway.

## 7. Wireframes

### 7.1 Main window, Windows (light)

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ ▣  • notes.md — Rackmac                                                  ─   ▢   ✕  │  native caption
├──────────────────────────────────────────────────────────────────────────────────────┤
│ File   Edit   View   Tools   Help                                                    │  native menu bar
├──────────────────────────────────────────────────────────────────────────────────────┤
│ [＋] [▭] [💾]   [↶] [↷]   [✂] [⧉] [📋]   [🔍]   [▷]                 [🔍 Search commands…] │  button% row, 4 px + 8 px gaps
├──────────────────────────────────────────────────────────────────────────────────────┤
│ • notes.md ✕ │ init.rkt ✕ │ Scratch Pad ✕ │ +                                        │  tab-panel% flat-portable
├──────────────────────────────────────────────────────────────────────────────────────┤
│ ⚠  init.rkt could not load: unbound identifier `shout` (line 12).  [Details] [Disable extension] [✕] │  InfoBar (when needed)
├──────────────────────────────────────────────────────────────────────────────────────┤
│ Find [ renewal            ] 3 of 12  ☐ Match case ☐ Whole word [Advanced ▾] [↑] [↓] [✕] │  find row (when open)
├──────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│    # Weekly notes                                                                    │  editor, inset 16 / 12
│                                                                                      │
│    - call the vendor about the renewal                                               │  ← match highlighted
│    - draft the summary|                                                              │
│                                                                                      │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ Saved notes.md                   Ln 5, Col 22   84 words   UTF-8   LF   Markdown  100% │  status canvas 24
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 Main window, macOS (dark), code document with gutter

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●                          • init.rkt — Rackmac                                  │  native title bar; menus in the system bar
├──────────────────────────────────────────────────────────────────────────────────────┤
│ [＋] [▭] [💾]   [↶] [↷]   [✂] [⧉] [📋]   [🔍]   [▷ Run]             [🔍 Search commands…] │  Racket adds Run Selection
├──────────────────────────────────────────────────────────────────────────────────────┤
│ notes.md ✕ │ • init.rkt ✕ │ Scratch Pad ✕ │ +                                        │
├──────┬───────────────────────────────────────────────────────────────────────────────┤
│  10  │ (define-command (shout)                                                       │  gutter: text-2, current line text
│  11  │   #:title "Shout" #:keys ("Mod-Shift-u")                                      │  surface #1E1E1E
│▌ 12  │   (replace-selection! (string-upcase (selection-string))))|                   │  ▌ accent bar on the current line
│  13  │                                                                               │
├──────┴───────────────────────────────────────────────────────────────────────────────┤
│ Tip: ⌘S saves                    Ln 12, Col 62   UTF-8   LF   Racket   100%          │  one-time shortcut tip (RM-041)
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### 7.3 Command palette (dialog%, 640 × 440, over the top third of the window)

```
          ┌──────────────────────────────────────────────────────────────────┐
          │ [ pas|                                                         ] │  text-field%
          ├──────────────────────────────────────────────────────────────────┤
          │ Command                          Category          Shortcut      │  list-box% with columns
          │ ▶ Paste                          Edit              ⌘V            │  selected row = OS highlight
          │   Paste from History             Clipboard         ⇧⌘V           │
          │   Open Recent…                   File                            │
          │   Change Case…                   Text                            │
          │                                                                  │
          ├──────────────────────────────────────────────────────────────────┤
          │ Paste the clipboard at the cursor.   Emacs: yank     ↑↓ move · ⏎ run · esc close │  message% footer
          └──────────────────────────────────────────────────────────────────┘
   Empty state row: "No commands match 'xyz'. Check the spelling or open Help > Keyboard Shortcuts."
```

### 7.4 Find and Replace rows (native controls, between the tabs and the editor)

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ Find    [ renewal                  ]  3 of 12   ☐ Match case  ☐ Whole word  [Advanced ▾]  [↑] [↓] [✕] │
│ Replace [ contract                 ]            [Replace] [Replace All]                                 │
│         ☐ Regular expression  ☐ In selection                     ← shown only after Advanced ▾          │
└──────────────────────────────────────────────────────────────────────────────────────┘
   Enter = next, Shift+Enter = previous, Esc = close and refocus the editor.
   Count states: "12 matches" while typing · "3 of 12" after stepping · "Wrapped · 1 of 12" · "No matches" (error color).
```

## Decisions needed from the owner

1. **Tabs:** the built-in `flat-portable` strip (close boxes, drag to reorder, "+", identical on both OSes;
   recommended), or Cocoa's own no-border strip on macOS (close boxes and reorder, native look, but no "+"
   button and a different drawing from Windows)?
2. **Toolbar:** confirm one row of icon-only native buttons with an overflow menu; labels under icons as an
   off-by-default setting.
3. **Windows dark mode:** when the system is dark, should the editor and status bar go dark even though the
   native chrome stays light (recommended, with an "Editor theme" setting), or should Windows default to light?
4. **Gutter:** ship line numbers for code Languages in v0.3 (`ui-gutter`, M), or leave the gutter deferred as
   README lists it today?
