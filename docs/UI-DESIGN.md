# Rackmac UI design: a modern desktop editor, not an Emacs clone

_Status: proposal for the owner. Targets macOS and Windows 11. GNOME/libadwaita is cited only where it
informs a cross-platform choice; Linux is not an official target. Nothing here changes the core: command
registry, keymaps, modes, hooks, buffers on `text%`, `#lang rackmac` with ownership and unload. Every surface
below is generated from command metadata (`#:title #:help #:icon #:when #:aliases`, mode `#:label`) and, where
ROADMAP says so, is an extension on the public API (toolbar, context menu)._

## 0. The short version

- **Look:** Fluent 2 on Windows, HIG on macOS, one shared token set with per-platform overrides. Flat tinted
  surfaces, 4 px grid, small radii, accent from the OS, system fonts for chrome, monospace for text.
- **Build:** a small custom-drawn widget layer on `canvas%` + `racket/draw` for every chrome row (command bar,
  tab strip, status bar, InfoBar, palette results, start screen). Native `racket/gui` stays for the menu bar,
  the editor (`editor-canvas%` on `text%`), single-line inputs (a one-line `text%`), context menus, file and
  message dialogs, and the window title bar.
- **racket-skia:** port its *design* (Fluent token values, `widget%` model, headless PNG tour), not the code,
  and keep a ten-function `gfx` interface so Skia can become a backend later. Reasons in §4.1.
- **Order:** a UI foundation milestone (E2.M0) lands *before* the toolbar; E2's toolbar, tabs, status bar and
  the palette restyle build on it in v0.2; InfoBar (E8), start screen (E5) and panes (E9) follow.

## 1. Visual language

### 1.1 Color roles (`rackmac/ui/tokens.rkt`)

Roles, not colors, are what widgets ask for. Seed values are Avalonia's Fluent set (already proven in
`racket-skia/gallery/ui.rkt`); macOS overrides a few roles to match HIG. `accent` is replaced by the OS accent
when it can be read (§4.5). "Mica-like" is an approximation: opaque canvases cannot show the desktop through the
window, so the window surface is a flat tint one step from the card color.

| Role | Light (Win) | Dark (Win) | macOS light / dark | Use |
|---|---|---|---|---|
| `window` | #F3F3F3 | #202020 | #ECECEC / #282828 | frame rows, command bar, tab strip (Mica-like tint) |
| `surface` | #FFFFFF | #2B2B2B | #FFFFFF / #1E1E1E | editor, active tab, cards, palette |
| `surface-alt` | #FAFAFA | #2C2C2C | #F6F6F6 / #262626 | menus, flyouts, InfoBar body |
| `stroke` | #E3E3E3 | #3A3A3A | #DCDCDC / #3C3C3C | 1 px dividers, card borders |
| `stroke-strong` | #868686 | #9A9A9A | same | unchecked box borders |
| `control` / `-hover` / `-press` / `-disabled` | #FDFDFD / #F6F6F6 / #EEEEEE / #F4F4F4 | #343434 / #3B3B3B / #2A2A2A / #2A2A2A | same | button fills |
| `subtle-hover` / `subtle-press` | 5% / 9% black | 7% / 12% white | same | icon buttons, tabs, segments |
| `text` / `text-2` / `text-disabled` | #1B1B1B / #606060 / #A6A6A6 | #FFFFFF / #C6C6C6 / #777777 | #1D1D1F / #6E6E73 / #B0B0B5 (dark: #F5F5F7 / #A1A1A6 / #6E6E73) | 4.5:1 minimum for `text` and `text-2` |
| `accent` / `-hover` / `-press` / `on-accent` | #0067C0 / #1975C5 / #3185CC / #FFF | #60CDFF / #52B9E6 / #47A5CC / #000 | #007AFF / #0A84FF (dark), on-accent #FFF | default button, selection, focused underline, dirty dot |
| `selection` | 33% accent | 40% accent | 30% accent | list and text selection |
| `focus` | #1B1B1B (+1 px #FFF inner) | #FFFFFF (+1 px #000 inner) | accent at 60%, 3 px | keyboard focus ring |
| `info` / `success` / `warning` / `error` | #0067C0 / #0F7B0F / #9D5D00 / #C42B1C | #60CDFF / #6CCB5F / #FCE100 / #FF99A4 | same | InfoBar, status icons |
| `scrim` | 33% black | 47% black | same | behind in-canvas modal cards |

Editor faces (`comment`, `string`, `keyword`, ...) stay in `theme.rkt`; it reads `bg`/`fg` from `surface`/`text`
so the editor and chrome cannot drift apart. High-contrast variants (RM-145) are a third and fourth column of
the same table, not new roles.

### 1.2 Typography

Chrome uses the system UI font; `normal-control-font` already resolves to `.AppleSystemUIFont` 13 on macOS
(measured) and Segoe UI on Windows. Faces are resolved once at startup with `get-face-list` and the first hit
wins.

| Slot | Windows (px/line, weight) | macOS | Fallback chain |
|---|---|---|---|
| `caption` | 12/16 400 | 11/13 400 | — |
| `body` | 14/20 400 | 13/16 400 | Segoe UI Variable Text → Segoe UI; SF Pro Text (`.AppleSystemUIFont`) → Helvetica Neue |
| `body-strong` | 14/20 600 | 13/16 600 (semibold) | same |
| `subtitle` | 20/28 600 | 17/22 600 | Segoe UI Variable Display → Segoe UI |
| `title` | 28/36 600 | 22/26 700 | same |
| `mono` (editor, status Ln/Col) | 12 Cascadia Mono → Consolas | 14 SF Mono → Menlo | current `theme.rkt` sizes; `font-size` zoom applies |

Text scaling (RM-146): every metric below is multiplied by a `ui-scale` parameter (1.0–2.0) that the settings
dialog exposes; fonts scale with it, icons scale in steps of 16/20/24.

### 1.3 Spacing, shape, elevation, focus, motion

- **Grid:** 4 px. Paddings 4/8/12/16; row heights are multiples of 4.
- **Control heights:** Windows 32, macOS 28 (`control-h`). Command bar row 40, tab strip 36, status bar 24,
  InfoBar 40 (single line) growing with wrapped text, palette input 36 and rows 32.
- **Corner radii:** Windows control 4, overlay 8 (flyout, palette, in-canvas dialog card), tab top 4.
  macOS control 6, overlay 10. Top-level windows get the OS's own corners; we draw none.
- **Elevation:** only *inside* a canvas (find card, which-key popup, in-canvas dialog): 1 px `stroke` border plus
  a 2-layer soft shadow (0 2 4 @ 8% and 0 8 16 @ 14% black; halve on macOS). Top-level windows and native menus
  get the OS shadow.
- **Focus ring:** drawn only for keyboard focus (a `kb-focus?` flag set by Tab/arrow navigation, cleared by a
  click, as in `ui.rkt`). Windows: 2 px `focus` stroke 2 px outside the control plus 1 px inner contrast line.
  macOS: 3 px accent ring at 60% alpha. Never the dotted Win32 rectangle.
- **Motion:** state changes are instant; caret blink 530 ms; the palette and find bar appear without animation.
  `timer%`-driven repaints make short fades possible later, but nothing in the plan depends on them, and a
  reduced-motion setting turns them off when they arrive.

### 1.4 Icons

Fluent System Icons style: single-weight line icons on a 16-unit grid, 1 px stroke at 16 px (1.5 at 20/24),
round caps and joins, filled only for state glyphs (dirty dot, check). Drawn as vectors (`racket/draw` paths in
logical units, so HiDPI is free), colored with `text`, `text-2` or `on-accent`, never baked bitmaps. Commands
without `#:icon` get a generated letter tile (initial on `subtle-hover` fill), which is what RM-052 needs.

Set required (name = `#:icon` value): `new`, `open`, `save`, `save-as`, `close`, `undo`, `redo`, `cut`, `copy`,
`paste`, `select-all`, `find`, `replace`, `goto`, `comment`, `duplicate`, `delete-line`, `arrow-up`,
`arrow-down`, `indent`, `outdent`, `zoom-in`, `zoom-out`, `zoom-reset`, `wrap`, `theme`, `activity`, `palette`,
`language`, `run`, `run-all`, `keyboard`, `help`, `book`, `info`, `settings`, `extensions`, `history`,
`chevron-down`, `chevron-right`, `chevron-left`, `more`, `x`, `dot`, `check`, `warning`, `error`, `search`,
`case-sensitive`, `regex`, `whole-word`, `split-right`, `split-down`, `sidebar`. About 55; `#:icon` is set on
0 of 61 built-ins today, so assigning names is its own small issue (`meta-icon-assign`).

## 2. Window layout

Two hard `racket/gui` facts shape everything here: children never overlap (no z-order, so no true overlays
inside the window), and `panel%` has no background setter while Win32 controls ignore dark mode. So the frame is
a `vertical-panel%` with `border 0 spacing 0` whose rows are *all* canvases that paint their own background;
no native panel pixel is ever visible.

```
frame%  (native title bar)
└─ vertical-panel% border 0 spacing 0
   ├─ command-bar   canvas%  40   (hideable: View > Show Toolbar)
   ├─ tab-strip     canvas%  36
   ├─ infobar       canvas%  0|40+ (hidden unless a message is pending)
   ├─ find-bar      canvas% + textbox row, 0|44 (hidden)
   ├─ editor slot   editor-canvas% | start-view canvas% | (E9) pane tree
   └─ status-bar    canvas%  24
```

- **Title bar: native on both.** On Windows the caption is tinted through `DwmSetWindowAttribute` on the HWND
  from `(send frame get-handle)` via `ffi/unsafe`: `DWMWA_USE_IMMERSIVE_DARK_MODE`, `DWMWA_CAPTION_COLOR`,
  `DWMWA_TEXT_COLOR`, and `DWMWA_SYSTEMBACKDROP_TYPE` for Mica where available (verify numeric ids against
  `dwmapi.h`; Windows 11 only). This keeps snap layouts, the system menu and accessibility of the caption
  buttons, which a `'no-caption` custom title bar (as in racket-skia's gallery) would lose. On macOS the traffic
  lights stay; a unified title/toolbar (transparent titlebar through `ffi/unsafe/objc` on the `NSWindow` handle)
  is optional polish, not in the plan.
- **Command bar: a single row, not a ribbon.** 61 commands do not justify tabs and groups; Office's own
  Simplified Ribbon is one row. Layout: `[New] [Open] [Save] | [Undo] [Redo] | [Cut] [Copy] [Paste] | [Find] | mode
  items (Racket: Run Selection) ... [⋯ overflow]  [Search commands…]`. Items come from the toolbar registry
  (RM-043) which reads `#:icon #:title #:help #:when`; icon-only 32×32 buttons with `subtle-hover`, tooltip
  text in the status bar (there is no tooltip API), overflow menu when the window is narrow, the whole row
  hideable. macOS shows the same row; labels under icons are a setting, off by default.
- **Tabs: browser/Office document tabs.** Custom strip replacing `tab-panel%`: active tab in `surface` with a 1 px
  `stroke` outline open at the bottom (merges into the editor), inactive tabs on `window` with hover; title in
  `body`; a 6 px accent `dot` when modified that turns into `x` on hover; close button on the right (Windows) or
  left (macOS); middle-click closes; drag to reorder; `+` at the end runs New Document; right-click opens the tab
  context menu (RM-071). Overflow scrolls with chevrons.
- **Editor surface.** `editor-canvas%` with `horizontal-inset` 16 (prose: a readable measure of ~80 columns when
  the window is wide, via `set-max-width`), `vertical-inset` 8, no border. An optional gutter (line numbers,
  wrap markers) is drawn by a sibling 48 px canvas kept in sync with the editor's scroll position; off for prose
  Languages, on for code, per mode local `gutter?`.
- **Find bar.** A card at the top-right of the editor slot, in-layout (not a true overlay): `[search icon]
  [textbox ..... 3 of 12] [Aa] [.*] [ab] | [↑] [↓] [x]`, with a second row for Replace. The textbox is a one-line
  `text%` (§4.3), so IME, undo and selection keep working. Esc closes and returns focus, Enter/Shift+Enter
  step, and the match count doubles as the "wrapped" indicator (RM-110).
- **Status bar.** Left: message segment (the echo area; errors get an `error` icon and stay until clicked, which
  opens Activity). Right: clickable segments `Ln 12, Col 8`, `12 words`, `UTF-8`, `LF`, `Racket`, `100%`, each
  with `subtle-hover`, underline on hover, arrow keys between them when focused, and a hint in the message
  segment. Clicks run commands exactly as ROADMAP E2.M4 lists.
- **Command palette.** A centered flyout 640×440 opening 96 px below the top of the window, as VS Code and
  PowerToys Run do: input 36 px, rows 32 px with icon, title, category (`text-2`) and shortcut; the highlighted
  row shows its `#:help` sentence in a footer (RM-030). Recents first when empty; a friendly empty state
  (RM-031). Built on a captionless `dialog%` so `picker-test.rkt` keeps finding it.
- **Dialogs.** Native `message-box`/`get-file`/`put-file` everywhere. App-specific confirmations use one helper
  that fixes platform button order (macOS: `Cancel` left of the default; Windows: default first) and plain
  language ("Save changes to notes.md?"), never "buffer".
- **Context menus.** Native `popup-menu%` from the context registry (RM-055); Windows 11 already renders Win32
  popup menus with rounded corners and dark mode, and macOS menus are native anyway.
- **Toasts and InfoBar.** No floating toasts (overlapping is impossible in-window; a floating `frame%` is a later
  experiment). Info-level messages go to the status message segment; warnings and errors that need an action
  (extension failed, file changed on disk) raise a Fluent **InfoBar** row: severity icon, one sentence,
  `Details`, an action button, and `x`. libadwaita's toast rule (one line, at most one action) is the content
  guideline.
- **Start screen.** A canvas in the editor slot when no files are given: title "Rackmac", three cards `New
  Document`, `Open…`, `Get Started`, a Recent list (RM-083) with paths in `text-2`, and a small "Scratch Pad"
  link for Racket users. Disappears when the first document opens.

## 3. Per-platform differences

| Aspect | Windows 11 | macOS | GNOME note (informative only) |
|---|---|---|---|
| Title bar | native, DWM-tinted caption, Mica where supported | native traffic lights, title from `set-label` | libadwaita header bar merges title and toolbar; not adopted |
| Menu bar | native Win32 in-window (light, not themed; accepted for now) | native, generated from `#:menu` | — |
| Chrome font | Segoe UI Variable Text → Segoe UI, 14/12 | SF Pro (`.AppleSystemUIFont`) 13/11 | Cantarell would follow the same slot table |
| Editor font | Cascadia Mono → Consolas 12 | SF Mono → Menlo 14 | Source Code Pro → DejaVu Sans Mono |
| Control height / radius | 32 / 4 (overlay 8) | 28 / 6 (overlay 10) | 34 / 6 (cards 12) |
| Focus ring | 2 px `text` + 1 px inner contrast | 3 px accent at 60% | accent 2 px offset 2 px, closest to macOS |
| Accent | registry `HKCU\...\DWM\AccentColor` | `defaults read -g AppleAccentColor` (-1..6, absent = blue) | gsettings `accent-color` |
| Dark mode | registry `Personalize\AppsUseLightTheme` (0 = dark), polled on activate | `AppleInterfaceStyle` (existing) polled on activate | `color-scheme` |
| Modifier glyphs | `Ctrl+Shift+P` | `⇧⌘P` (existing `key-sequence->string`) | `Ctrl+Shift+P` |
| Menu shortcut hints | `\t` column | spaces (Cocoa ignores `\t`; existing workaround) | — |
| Tab close button | right | left | right |
| Dialog button order | default first (`Save` `Don't Save` `Cancel`) | `Don't Save` ... `Cancel` `Save` | like macOS |
| Context menu trigger | right-click, Shift+F10, Menu key | right-click and Ctrl-click | right-click |
| Undo/redo, find keys | Ctrl+Z / Ctrl+Y, F3 | ⌘Z / ⇧⌘Z, ⌘G | as Windows |
| Zoom gesture | Ctrl+wheel | pinch, ⌘+wheel | Ctrl+wheel |
| Palette placement | centered, 96 px from top | same | same |

## 4. Implementation strategy in Racket

### 4.1 Native vs custom vs racket-skia

| Surface | Choice | Why |
|---|---|---|
| Menu bar, file/message dialogs, context menus, clipboard, title bar | native `racket/gui` | already modern on both OSes; accessibility comes free |
| Editor | `editor-canvas%` on `text%` | the buffer *is* `text%`; Cairo draws it identically on both OSes |
| Single-line inputs (find, replace, palette, go-to-line) | one-line `text%` in an `editor-canvas%` with custom border | keeps IME/undo/selection, drops the classic Win32 edit control (§4.3) |
| Command bar, tab strip, status bar, InfoBar, palette list, start view, gutter, which-key, splitters | custom `canvas%` + `racket/draw` | the only way to get Fluent/HIG visuals and dark mode on Windows; verified headless (a 2× `bitmap%`, system font, pixel readback) |

**racket-skia, honestly.** It should not be a dependency in v0.2–v0.4:

1. `skia-natipkgs/` holds `macos-arm64` and `ios` only; Windows is Phase 4 of its own plan. A macOS+Windows
   editor cannot depend on it today.
2. Its `gui/COVERAGE.md` lists `editor-canvas%` as missing and says `gui/` needs the real `racket/gui/base` at
   run time. Rackmac's editor is `text%`, so Skia could only ever draw chrome, and chrome is exactly what
   `racket/draw` on `canvas%` already draws (the experiment above).
3. The owner's own `REVIEW.md` says to retire the toolkit's layout/focus/event plumbing, keep only its drawing as
   "the look", and remove the module-level singletons (`the-root`, `the-gfx-v`, `redraw-hook`) before they
   spread. Rackmac should not inherit them.
4. It bundles Inter; the brief asks for Segoe UI / SF Pro.

What transfers: the Fluent token values (§1.1 seeds), the `widget%`/`panel%` model with `preferred-size`,
`find`, `mouse`, `key`, `focusable?`, the `kb-focus?` rule for focus rings, and the headless PNG tour as a
test style. `rackmac/ui/gfx.rkt` exposes the same ten verbs `ui.rkt` uses (`fill-rrect!`, `stroke-rrect!`,
`fill-rect!`, `line!`, `polyline!`, `path!`, `text!`, `text-width`, `clip!`, `push!/pop!`) over a `dc<%>`, so a
Skia `dc` is a swap when a Windows binary exists.

### 4.2 Modules

```
rackmac/ui/tokens.rkt      color roles, metrics, fonts; (token 'accent) (metric 'control-h) (ui-font 'body);
                           current appearance ('light|'dark, later 'hc-light|'hc-dark); ui-scale parameter;
                           accent override; fires 'theme-changed. theme.rkt reads surface/text from here.
rackmac/ui/gfx.rkt         drawing verbs over dc<%>, 0.5 px alignment for 1 px strokes, HiDPI via the dc's
                           backing scale, text measured with the slot fonts.
rackmac/ui/icons.rkt       (draw-icon dc name x y size color); icons as path data on a 16-unit grid;
                           (icon-names); letter-tile fallback.
rackmac/ui/widget.rkt      ui-canvas%: canvas% subclass ('no-autoclear) holding a list of `item`s
                           (id rect label icon enabled? tooltip on-click). Pure (layout w h) -> items and
                           (render dc w h) so tests draw to a bitmap-dc%. Hover/press/focus/kb-focus state;
                           Tab in/out, arrows between items, Enter/Space, Esc; tooltip -> status message.
rackmac/ui/textbox.rkt     one-line text% in an editor-canvas%; placeholder, on-change, on-enter, on-escape.
rackmac/ui/appearance.rkt  detect dark/accent per platform; poll on frame on-activate; update tokens.
rackmac/ui/dwm.rkt         Windows only: caption color, dark mode, backdrop via ffi/unsafe on the HWND.
rackmac/ui/command-bar.rkt tab-strip.rkt  status-bar.rkt  infobar.rkt  flyout.rkt (palette shell + results)
rackmac/ui/find-bar.rkt    start-view.rkt  dialogs.rkt (button-order helper)  splitter.rkt (E9)
```

`rackmac/ui/*` is private at API version 1; only the registries (`add-toolbar-item!`, `add-context-item!`,
later `add-status-segment!`) are exported from `rackmac/api`, as ROADMAP already says.

### 4.3 Key techniques

- **Textbox.** `editor-canvas%` with style `'(no-border hide-hscroll hide-vscroll)`, `set-line-count 1`, a
  `text%` subclass that swallows newline and reports Enter/Esc, `set-canvas-background` from `control`, and an
  `on-paint` override (confirmed present on `editor-canvas%`) that calls `super` then strokes the 1 px border and
  the 2 px accent focus underline inside the inset area. If a platform clips that paint, the fallback is a
  plain-canvas textbox as in `ui.rkt`.
- **Palette shell.** `dialog%` with `'no-caption`, one textbox and one results `ui-canvas%`; `on-subwindow-char`
  routing as today. A spike tries `frame%` `'(no-caption float)` for a shadowed flyout, with the explicit check
  that it takes keyboard focus on both OSes; the dialog is the shipping default until then.
- **Frame refactor.** `frame.rkt` moves the editor out of `tab-panel%` into the row panel above; `tabs` becomes
  `tab-strip%` driven by the same `buffers-changed` hooks; `find-bar` and `infobar` toggle via `change-children`
  as the find bar does today; `status-panel`/`message%` become `status-bar%` fed by the `echo` and
  `status-changed` hooks. Menus are untouched.
- **HiDPI.** All geometry in logical pixels; the canvas dc carries the backing scale (2.0 measured here);
  strokes at `.5` offsets, icons as paths, bitmaps only as `make-bitmap #:backing-scale` caches. RM-054 renders
  the tour at 1× and 2×.
- **Dark mode and accent.** `appearance.rkt` reads the OS on startup and on every `on-activate`, swaps the token
  table, and runs `theme-changed`; each `ui-canvas%` refreshes, `theme.rkt` re-applies the style delta (already
  implemented), and `dwm.rkt` retints the caption. `RACKMAC_THEME` still forces a theme.
- **Accessibility.** Custom canvases are invisible to VoiceOver and Narrator; that is RM-148's investigation and
  the reason menus, the editor and all text inputs stay native. What the widget layer guarantees now: every
  item reachable by Tab and arrows, activated by Enter/Space, a visible focus ring, 4.5:1 text contrast in
  every token column (a test computes it), icons always paired with a title in tooltips and menus, and no
  state carried by color alone (the dirty dot is also in the tab title's tooltip and the window title).

### 4.4 Testing headlessly

- **Unit:** `(layout w h)` returns item rects; tests assert geometry (close button inside its tab, overflow
  appears below 640 px). `(render dc w h)` draws into a `bitmap-dc%` on a `make-bitmap` (no window); tests read
  pixels (`get-argb-pixels`) at item centers to assert `control-hover` after a synthetic `mouse-event%`, the
  accent underline when focused, and `text-disabled` when `#:when` is false.
- **Interaction:** as `startup-test.rkt` and `picker-test.rkt` do today, build the frame unshown and deliver
  `mouse-event%`/`key-event%` through `on-event`/`on-char`; assert the command ran via the `before-command` hook.
- **Goldens:** a scripted tour (main window light/dark at 1× and 2×, palette, find bar, InfoBar) saved as PNGs
  per platform with a tolerance for anti-aliased edges (racket-skia measured ~3% edge pixels differing between
  rasterizers), diffed in CI (RM-017).
- **Contrast:** a test walks every token column and fails below 4.5:1 for text roles and 3:1 for `stroke-strong`
  and `focus` against their surfaces.

## 5. Phased build plan

Sizes follow ROADMAP (S under half a day, M 1–2 days, L 3–5). Issues are given in the `roadmap.rktd` shape so
they can be pasted; the owner adds them and runs `racket tools/roadmap.rkt` (`roadmap-test.rkt` enforces the sync).
Keys use a `ui-` prefix, unused today.

### E2.M0 UI foundation (new; v0.2, before E2.M1 rendering)

```
(milestone E2.M0 "UI foundation"
 (sub E2.M0.S1 "Tokens and drawing"
  (issue ui-tokens "Design tokens module: color roles, metrics, fonts, light/dark, per-platform overrides" M todo
    "rackmac/ui/tokens.rkt | theme.rkt reads surface and text from it | contrast test passes for every column | ui-scale parameter" ())
  (issue ui-gfx "Drawing verbs over dc<%> with HiDPI-safe strokes and slot fonts" S todo
    "fill/stroke rrect, line, path, text, clip, push/pop | 1 px lines crisp at 1x and 2x | headless bitmap test" (ui-tokens))
  (issue meta-icon-assign "Assign #:icon names to every built-in command" S todo
    "every command with a menu entry has an icon name from the documented set | test lists commands without one" (meta-icon)))
 (sub E2.M0.S2 "Widgets"
  (issue ui-widget "ui-canvas% base widget: items, layout, render, hover/press/focus, keyboard, tooltip-to-status" M todo
    "pure layout and render testable on a bitmap-dc% | Tab, arrows, Enter, Space, Esc | focus ring only for keyboard focus | disabled items skip focus" (ui-gfx))
  (issue ui-textbox "One-line text% input with Fluent border and accent focus underline" M todo
    "IME and undo work | placeholder | Enter, Shift+Enter, Esc callbacks | on-paint override verified on macOS; Windows verified under win-run" (ui-tokens))
  (issue ui-frame-rows "Refactor frame.rkt into canvas rows with border 0 spacing 0" M todo
    "editor no longer inside tab-panel% | no native panel pixel visible in light or dark | existing tests pass" (ui-widget))
  (issue ui-tabstrip "Document tab strip: dirty dot, close on hover, middle-click, plus button, overflow" M todo
    "replaces tab-panel% | dot becomes x on hover | keyboard: Ctrl+Tab unchanged, Left/Right when focused | tests for layout and click" (ui-frame-rows)))
 (sub E2.M0.S3 "Appearance"
  (issue ui-appearance "Detect dark mode and accent on macOS and Windows; poll on activate" M todo
    "Windows reads AppsUseLightTheme and AccentColor | macOS reads AppleInterfaceStyle and AppleAccentColor | theme-changed fires once per real change | RACKMAC_THEME still forces" (ui-tokens))
  (issue ui-dwm-caption "Windows 11: tint the native caption via DwmSetWindowAttribute" S todo
    "dark caption in dark mode | caption color matches window token | no-op below Windows 11 | verified under win-run" (ui-appearance win-run))
  (issue ui-tests "Headless UI test harness and golden tour" M todo
    "render main window, palette, find bar to PNG at 1x and 2x light and dark | pixel tolerance diff | runs in raco test" (ui-widget))))
```

### Existing epics, mapped

| Epic / milestone | What changes | New or amended issues |
|---|---|---|
| **E2.M1 Toolbar** (v0.2) | RM-046 `tb-icons` stays "drawn with racket/draw" and depends on `ui-gfx`; RM-047 `tb-button` becomes the icon-button item type of `ui-widget`; RM-048 `tb-frame` is the command bar row with overflow; RM-049 enable state via `#:when` refreshed on `after-command`, `status-changed` and selection hooks. | add deps: `tb-icons → ui-gfx`, `tb-button → ui-widget`, `tb-frame → ui-frame-rows` |
| **E2.M3 Context menu** | native `popup-menu%`; unchanged | — |
| **E2.M4 Status bar** | RM-059 `sb-widget` is a `ui-canvas%` with segments; message segment carries severity icon | add dep `sb-widget → ui-widget` |
| **E2.M5 Mouse** | RM-070 `mouse-tabs` is finished by `ui-tabstrip` plus drag-to-reorder | add dep `mouse-tabs → ui-tabstrip` |
| **E1.M2 Palette** (v0.2) | `(issue ui-palette "Command palette as a centered captionless flyout with icon, category, shortcut and help footer" M todo "captionless dialog% | recents first | help sentence for the highlighted row | picker-test passes | spike note on float frame" (ui-widget ui-textbox))` | `palette-category`, `palette-empty` depend on it |
| **E6.M1 Find bar** (restyle can land in v0.2) | `(issue ui-findbar "Find and replace as a Fluent card with one-line text% inputs, option toggles and match count" M todo "Esc returns focus | Enter and Shift+Enter step | count doubles as wrap indicator | replace row toggles" (ui-textbox ui-widget))` | `find-count`, `find-word`, `find-regex` toggles live in it |
| **E8.M1 Activity** (v0.3) | `(issue ui-infobar "InfoBar row: severity, sentence, Details, one action, dismiss" M todo "hidden when empty | queue of messages | keyboard reachable | error stays until dismissed" (ui-widget))`; RM-130 `act-levels` routes info to the status segment and warning/error to the InfoBar; the file-changed banner (RM-080) is an InfoBar. | add deps `act-levels → ui-infobar`, `ext-banner → ui-infobar` |
| **E5.M1 Start screen** (v0.4) | `(issue ui-start-view "Start view canvas: New, Open, Get Started cards, Recent list, Scratch Pad link" M todo "shown when no files are given | cards keyboard reachable | Recent from recent-files | leaves when a document opens" (ui-widget recent-files))` | `start-view` depends on it |
| **E4.M2 Settings dialog** (v0.3) | native `dialog%` shell; rows drawn with `ui-widget` items (toggle, choice, number) so Windows gets themed controls. `(issue ui-settings-rows "Toggle, choice and number rows for the settings dialog" M todo "generated from define-setting types | keyboard operable | dark mode" (ui-widget))` | `settings-dialog` depends on it |
| **E9 Panes** (v0.5) | `(issue ui-splitter "Draggable splitter canvas between panes, 4 px hit area 8 px, keyboard resize" M todo "cursor changes | min pane size | double-click resets" (ui-widget))`; `pane-model` renders each leaf as an `editor-canvas%` in the editor slot | `pane-commands` depends on it |
| **E10** (v0.6) | `a11y-keyboard` audits `ui-widget` items; `a11y-contrast` adds the two high-contrast token columns; `a11y-scale` exposes `ui-scale`; `a11y-sr` writes the plan for custom canvases | add deps to `ui-widget`, `ui-tokens` |

Suggested order inside v0.2: `ui-tokens` → `ui-gfx` → `ui-widget` → `ui-frame-rows` → `ui-tabstrip` → `tb-icons`
→ `tb-button` → `tb-frame` → `sb-widget` → `ui-textbox` → `ui-palette` → `ui-findbar` → `ui-appearance`
(`ui-dwm-caption` waits for `win-run`). That is roughly three extra weeks before the first toolbar button is
visible, in exchange for never re-doing the toolbar when the tabs and status bar arrive.

## 6. Wireframes

### 6.1 Main window, Windows 11 (light)

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ ▣ notes.md — Rackmac                                                        ─   ▢   ✕   │  native caption, DWM-tinted
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ File   Edit   View   Tools   Help                                                        │  native menu bar
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ [+] [▭] [💾] │ [↶] [↷] │ [✂] [⧉] [📋] │ [🔍] │ [▷ Run]                  [⋯]   [ 🔍 Search commands… ] │  command bar 40
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ ╭───────────────╮ ┌─────────────┐ ┌──────────────┐  +                                    │  tab strip 36
│ │ ● notes.md  ✕ │ │  init.rkt   │ │ Scratch Pad  │                                       │  ● dirty dot → ✕ on hover
├─┴───────────────┴─┴─────────────┴─┴──────────────┴───────────────────────────────────────┤
│ ⚠  init.rkt failed to load: unbound identifier `shout` at line 12.   Details   Disable extension   ✕ │  InfoBar 40 (when needed)
├──────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   # Weekly notes                                                                         │  editor: surface, inset 16/8
│                                                                                          │
│   - call the vendor about the renewal                                                    │
│   - draft the summary|                                                                   │
│                                                                                          │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ Saved notes.md              Ln 5, Col 22   84 words   UTF-8   LF   Markdown   100%      │  status bar 24, segments clickable
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 Main window, macOS (dark)

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●                          ● notes.md — Rackmac                                      │  native title bar; menu bar is in the system bar
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ [+] [▭] [💾] │ [↶] [↷] │ [✂] [⧉] [📋] │ [🔍] │ [▷ Run]                  [⋯]   [ 🔍 Search commands… ] │  command bar 40, radius 6, height 28
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ ╭───────────────╮ ┌─────────────┐ ┌──────────────┐  +                                    │  close button on the LEFT of the tab
│ │ ✕ notes.md  ● │ │  init.rkt   │ │ Scratch Pad  │                                       │
├─┴───────────────┴─┴─────────────┴─┴──────────────┴───────────────────────────────────────┤
│                                                                                          │
│   # Weekly notes                                                                         │  surface #1E1E1E, text #F5F5F7
│   - draft the summary|                                                                   │
│                                                                                          │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ Tip: ⌘S saves                Ln 5, Col 22   84 words   UTF-8   LF   Markdown   100%      │  shortcut tip (RM-041) in the message segment
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

### 6.3 Command palette (centered flyout, 640 × 440, 96 px from the window top)

```
            ╭──────────────────────────────────────────────────────────────────╮
            │ 🔍  pas|                                                        │  textbox 36, accent underline when focused
            ├──────────────────────────────────────────────────────────────────┤
            │ ▌📋  Paste                              Edit             ⌘V     │  highlighted: selection tint + 3 px accent bar
            │  🕘  Paste from History                 Clipboard      ⇧⌘V      │  icon · title · category (text-2) · shortcut
            │  ▭   Open Recent…                       File                    │
            │  A   Change Case…                       Text                    │  letter tile: command without #:icon
            │                                                                  │
            ├──────────────────────────────────────────────────────────────────┤
            │ Paste the clipboard at the cursor.  (Emacs: yank)      ↑↓ move · ⏎ run · esc close │  #:help footer
            ╰──────────────────────────────────────────────────────────────────╯
```

### 6.4 Find bar (card at the top-right of the editor slot, in-layout)

```
                                   ╭────────────────────────────────────────────────────────────╮
                                   │ 🔍 [ renewal                       3 of 12 ] [Aa] [ab] [.*] │ [↑] [↓] [✕] │
                                   │ ⇄  [ contract                               ] [Replace] [Replace All]      │  row 2 only for Find and Replace
                                   ╰────────────────────────────────────────────────────────────╯
   Toggles: Aa match case · ab whole word · .* regex (Advanced). Enter = next, Shift+Enter = previous, Esc = close and refocus editor.
   "3 of 12" becomes "12 matches" while typing and "Wrapped · 1 of 12" after wrap-around; "No matches" turns the count `error`.
```

## Decisions needed from the owner

1. **Title bar:** native caption with DWM tinting on Windows and native traffic lights on macOS (recommended),
   or a custom `'no-caption` title bar like the racket-skia gallery (loses snap layouts and the system menu)?
2. **Command bar:** confirm a single row with icon-only buttons and an overflow menu, labels-under-icons as an
   off-by-default setting; no ribbon.
3. **racket-skia:** agree to defer it until a Windows binary and the REVIEW.md refactor exist, and to keep the
   `gfx` interface as the seam; or should Rackmac be the driver that forces those to happen sooner?
4. **Windows 10:** supported or not? It decides whether `ui-dwm-caption` and Segoe UI Variable are must-have or
   best-effort, and whether the Win32 menu bar's light-only look is acceptable in dark mode for v0.2.
