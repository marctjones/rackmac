;; Source of truth for ROADMAP.md. Regenerate with:  racket tools/roadmap.rkt
;; Hierarchy: epic > milestone > sub-milestone > issue.
;; (issue KEY "Title" SIZE STATUS "acceptance criteria | separated by bars" (DEPENDENCY-KEYS))
;; SIZE: S (under half a day), M (1-2 days), L (3-5 days).   STATUS: todo, doing, done, icebox.
(roadmap
 (releases
  ("v0.2 Friendly"  "Office vocabulary, toolbar, context menu, clickable status bar." (E0 E1 E2))
  ("v0.3 Safe"      "Never lose work; settings you can click; calm errors."          (E3 E4 E8))
  ("v0.4 Welcome"   "Start screen, tutorial, better find, clipboard history, macros." (E5 E6 E7))
  ("v0.5 Workspace" "Split panes and sidebar."                                       (E9))
  ("v0.6 Open"      "Accessibility, extension platform and docs, Windows parity."    (E10 E11))
  ("v0.7 Backwards Compat" "Optional Emacs preset: Emacs labels and shortcuts as surface preferences only." (E13)))

 (epic E0 "Foundation and verification"
  "Delivered core, plus the open verification work that has been floating: real keys in the live window, Windows, CI."
  "README, DESIGN section 'Extension model'"
  (milestone E0.M1 "Delivered core (iteration 1)"
   (sub E0.M1.S1 "Editor core"
    (issue core-registry "Command registry with menus, palette and keys reading one source" M done "define-command registers name, title, doc, keys, menu | keys per platform (#:keys/mac, #:keys/windows)" ())
    (issue core-keymaps "Layered keymaps with key chords and per-platform Mod" M done "minor > major > global lookup | chords wait for the next key | Mod = Cmd on macOS, Ctrl on Windows" ())
    (issue core-modes "Modes with inheritance, buffer-local variables, hooks" M done "define-mode with parent, locals, highlighter | failing hook is reported, not fatal" ())
    (issue core-buffers "Buffers on text% with tabs, CRLF-preserving file I/O, mode detection" M done "open/save round trip keeps CRLF | tab per buffer | unique names" ())
    (issue core-find "Find and replace bar" S done "live search, case option, replace one/all" ())
    (issue core-palette "Command palette and picker with fuzzy matching" M done "Mod-Shift-P | Enter runs, Esc cancels | driven by a timer test" ())
    (issue core-editing "Line and selection commands" M done "comment, duplicate, delete, move, indent, word/line/doc motion with Shift-extend" ())
    (issue core-highlight "Racket and Markdown syntax coloring, light/dark theme" M done "colors applied outside undo history | follows system appearance on macOS" ()))
   (sub E0.M1.S2 "Extension model"
    (issue core-init "Init file, live eval, shared namespace" M done "a command defined in init.rkt lands in the running registry" ())
    (issue core-lang "#lang rackmac with ownership, unloading and public-API restriction" L done "compile-time key and API-version checks | reload replaces, never duplicates | private core modules refused" ())
    (issue core-tests "Automated test suite" M done "47 tests: core, editing, init, lang, picker, startup" ())))
  (milestone E0.M2 "Verify real input"
   (sub E0.M2.S1 "Live key dispatch (blocks calling the editor verified)"
    (issue verify-keys "Verify real keystrokes reach the buffer in the live macOS window" M todo "Cmd+Shift+P opens the palette | Cmd+= zooms | typing inserts text | result recorded in README" ())
    (issue keylog "Opt-in RACKMAC_KEYLOG=1 key event log" S todo "logs code and modifiers and the dispatch result to stderr | documented" ())
    (issue key-smoke "Automated in-process smoke: deliver key events through the frame, not the buffer" M todo "test builds the frame and sends events via the eventspace | asserts before-command hook" (keylog)))
   (sub E0.M2.S2 "Windows"
    (issue win-run "Run and verify on a real Windows machine" L todo "launch, palette, Ctrl combos, AltGr typing, file dialogs | notes added to README" ())
    (issue win-keys "Windows key-normalization checks on real hardware" M todo "Ctrl/Alt/AltGr behavior matches unit tests | international layouts tried" (win-run))
    (issue ci "CI matrix for macOS and Windows running raco test" M todo "both platforms green on every change" ())))
  (milestone E0.M3 "Distribution"
   (sub E0.M3.S1 "Packages"
    (issue pkg-mac "macOS app bundle via raco distribute" L todo "double-clickable .app | runs without Racket installed" ())
    (issue pkg-win "Windows executable and installer" L todo "runs without Racket installed" ())
    (issue pkg-sign "Code signing and notarization" M icebox "macOS notarized | Windows signed" (pkg-mac pkg-win)))))

 (epic E1 "Vocabulary and discoverability"
  "The same commands under office-friendly names, findable by their Emacs names too."
  "DESIGN section 14.1 and 14.2"
  (milestone E1.M1 "Command metadata"
   (sub E1.M1.S1 "define-command fields"
    (issue meta-aliases "Add #:aliases (search synonyms) to define-command" S done "optional keyword | stored on the command | existing #lang rackmac extensions still compile" ())
    (issue meta-help "Add #:help (one plain sentence) alongside #:doc" S done "optional keyword | shown by Describe and the palette" ())
    (issue meta-when "Add #:when (context predicate) to define-command" S done "command-enabled? honors it | used later by menus and the toolbar" ())
    (issue meta-icon "Add #:icon (icon name) to define-command" S done "stored for the toolbar and menus" ()))
   (sub E1.M1.S2 "Built-in coverage"
    (issue meta-emacs-aliases "Emacs-name aliases for every built-in command" M done "backward-word, kill-line, yank, find-file, M-x and the rest resolve in the palette" (meta-aliases))
    (issue meta-help-all "A help sentence for every built-in command" M done "test fails if any built-in lacks #:help" (meta-help)))
   (sub E1.M1.S3 "Modes"
    (issue mode-label "Add #:label to define-mode (display name)" S done "racket-mode shows as Racket, text-mode as Plain Text" ())))
  (milestone E1.M2 "Palette and Describe"
   (sub E1.M2.S1 "Palette"
    (issue palette-synonyms "Palette searches title, aliases and name" S done "typing yank finds Paste | typing kill-line finds Delete Line" (meta-aliases))
    (issue palette-recents "Recently used commands first when the box is empty" S done "last 8 distinct commands, most recent first" ())
    (issue palette-category "Show category and help in the palette" S todo "third column | hint text for the highlighted row" (meta-help))
    (issue palette-empty "Helpful no-results state" S todo "suggests checking spelling or opening Help" ()))
   (sub E1.M2.S2 "Describe"
    (issue describe-both "Describe shows both names and aliases" S done "Title, internal name, Also known as, shortcut, help, doc" (meta-aliases meta-help))
    (issue describe-key-friendly "Rename Describe Key to What Does This Key Do?" S done "alias describe-key kept" ())))
  (milestone E1.M3 "Apply the vocabulary"
   (sub E1.M3.S1 "Display names"
    (issue vocab-titles "Rename built-in titles per the vocabulary table" M done "Run Selection, Show Activity Log, Set Language, Customize with Code, Reload Extensions | no command name symbol changes" ())
    (issue vocab-buffers "Scratch Pad and Activity replace *scratch* and *Messages*" S done "display names only | tests updated" ())
    (issue vocab-status "Status bar shows Language labels not mode symbols" S done "uses mode-label" (mode-label))
    (issue vocab-glossary "Glossary page mapping Emacs terms to Rackmac terms" S done "in README and Help" ())
    (issue vocab-guard "Test that every command name still resolves after relabeling" S done "init.rkt files referencing names keep working" (vocab-titles))))
  (milestone E1.M4 "Shortcut discoverability"
   (sub E1.M4.S1 "Cheat sheet and hints"
    (issue cheat-sheet "Searchable shortcut cheat sheet" M todo "per platform | grouped by category | opens from Help" ())
    (issue chord-popup "Which-key popup after the first key of a chord" M todo "lists valid next keys | disappears on completion or Esc" ())
    (issue shortcut-tips "Show a command's shortcut once after using it from a menu or palette" S todo "setting to turn off | never repeats for the same command in a session" ())
    (issue conflict-check "Warn at load about bindings that shadow OS-reserved shortcuts" M todo "per platform list | warning in Activity" ()))))

 (epic E2 "Toolbar and direct manipulation"
  "Buttons, right-click menus, clickable status bar and mouse behavior, built only on the public API."
  "DESIGN section 14.3"
  (milestone E2.M1 "Toolbar as an extension"
   (sub E2.M1.S1 "Registry"
    (issue tb-registry "Toolbar item registry with layering by Language" M todo "add-toolbar-item! | global then mode-chain items | pure module with tests" ())
    (issue tb-ownership "Toolbar items are unloaded with their extension" S todo "reload does not duplicate buttons" (tb-registry))
    (issue tb-api "Export add-toolbar-item! and remove-toolbar-item! from rackmac/api" S todo "usable from #lang rackmac" (tb-registry)))
   (sub E2.M1.S2 "Rendering"
    (issue tb-icons "Vector icon set drawn with racket/draw" M todo "new, open, save, undo, redo, cut, copy, paste, find, run | crisp on HiDPI | follows theme" ())
    (issue tb-button "Flat icon button widget" M todo "hover, pressed, disabled states | tooltip text in the status bar" (tb-icons))
    (issue tb-frame "Toolbar panel in the main frame with a Show Toolbar command" M todo "View > Show Toolbar | hidden state remembered for the session" (tb-registry tb-button))
    (issue tb-enable "Enabled state from #:when, refreshed by hooks" M todo "Cut/Copy dim without a selection | Save dims when nothing to save" (meta-when tb-frame))
    (issue tb-tests "Toolbar tests" M todo "registry layering | click runs the command | enable state changes with selection" (tb-frame))))
  (milestone E2.M2 "Toolbar customization"
   (sub E2.M2.S1 "User control"
    (issue tb-per-language "Language-specific buttons" S todo "Racket documents show Run Selection | Markdown does not" (tb-registry))
    (issue tb-add "Add to Toolbar from the palette" M todo "any command with an icon or a generated letter icon" (tb-frame))
    (issue tb-reorder "Reorder and hide buttons" M todo "persisted in settings" (tb-add settings-store))
    (issue tb-hidpi "2x rendering check on Retina and 200% Windows" S todo "icons crisp" (tb-icons))))
  (milestone E2.M3 "Context menu"
   (sub E2.M3.S1 "Right-click"
    (issue ctx-registry "Context menu item registry" S todo "add-context-item! | ownership undo" ())
    (issue ctx-popup "Right-click shows Cut, Copy, Paste, Select All, Find" M todo "items enabled per selection | Ctrl-click on macOS" (ctx-registry meta-when))
    (issue ctx-language "Language-specific context items" S todo "Racket adds Run Selection" (ctx-registry))
    (issue ctx-word "Right-click outside the selection selects the word under the pointer" S todo "matches common editors" (ctx-popup))))
  (milestone E2.M4 "Clickable status bar"
   (sub E2.M4.S1 "Segments"
    (issue sb-widget "Status segment widget" M todo "hover underline | click runs a command | hint text" ())
    (issue sb-position "Line and column opens Go to Line" S todo "" (sb-widget))
    (issue sb-language "Language opens a picker" S todo "uses mode labels" (sb-widget mode-label))
    (issue sb-eol "Line ending segment (LF/CRLF) with a convert command" M todo "toggling rewrites on save | undoable flag" (sb-widget))
    (issue sb-zoom "Zoom percentage resets on click" S todo "" (sb-widget))
    (issue sb-selection "Selection count and word count" S todo "words for prose Languages" ())))
  (milestone E2.M5 "Menus and mouse"
   (sub E2.M5.S1 "Menus"
    (issue menu-enable "Menu items enable and disable from #:when" M todo "menu on-demand refresh" (meta-when))
    (issue menu-recent "Open Recent submenu" M todo "needs the recent files store" (recent-files))
    (issue menu-tabs "Tabs listed in a Window menu" S todo "" ())
    (issue menu-hints "Verify shortcut hints render on macOS and Windows menus" S todo "screenshot on both" (verify-keys)))
   (sub E2.M5.S2 "Mouse"
    (issue mouse-click "Verify double-click word and triple-click line" S todo "documented result" ())
    (issue mouse-tabs "Tab close button, middle-click close, drag to reorder" M todo "" ())
    (issue mouse-tab-menu "Tab context menu" S todo "Close, Close Others, Reveal in Finder/Explorer, Copy Path" (ctx-registry))
    (issue mouse-dnd "Drag and drop text within a document" M todo "" ())
    (issue mouse-zoom "Pinch and Ctrl+wheel zoom" S todo "" ()))))

 (epic E3 "Never lose work"
  "Autosave, recovery, external-change handling, and safer file operations."
  "DESIGN section 14.4 item 1"
  (milestone E3.M1 "Autosave and recovery"
   (sub E3.M1.S1 "Recovery store"
    (issue as-store "Recovery store on disk (per document snapshot with metadata)" M todo "atomic writes | outside the user's folders | encrypted-at-rest not required" ())
    (issue as-timer "Autosave timer" S todo "interval setting | only when modified | debounced" (as-store))
    (issue as-clean "Delete snapshots on save and close" S todo "" (as-store)))
   (sub E3.M1.S2 "Restore"
    (issue as-restore "Restore unsaved changes on next launch" M todo "list of recovered documents | Restore or Discard each" (as-store))
    (issue as-crash-test "Crash and kill test" S todo "kill -9 then relaunch recovers the text" (as-restore))))
  (milestone E3.M2 "External changes"
   (sub E3.M2.S1 "Detection and banner"
    (issue ext-detect "Detect a file changed on disk (check on focus)" M todo "mtime and size" ())
    (issue ext-banner "Non-modal banner: Reload, Keep mine, Compare" M todo "auto-reload when unmodified | banner when modified" (ext-detect))
    (issue ext-deleted "Handle deleted and renamed files" S todo "keeps the text, marks the tab" (ext-detect))
    (issue ext-compare "Compare view for a changed file" L todo "side-by-side or unified diff" (ext-banner))))
  (milestone E3.M3 "Files"
   (sub E3.M3.S1 "Operations"
    (issue recent-files "Recent files and folders store" S todo "persisted | Open Recent" ())
    (issue reload-disk "Reload from Disk command" S todo "asks if modified" ())
    (issue save-all "Save All" S todo "" ())
    (issue safe-save "Safe save: write a temp file then rename" M todo "permissions preserved | failed save leaves the original" ())
    (issue encoding "Encoding and BOM detection" M todo "UTF-8, UTF-16 | shown in the status bar" (sb-widget))
    (issue large-files "Large file guard" S todo "warn and disable highlighting over a size" ())))
  (milestone E3.M4 "Session"
   (sub E3.M4.S1 "Restore the workspace"
    (issue session-tabs "Reopen tabs and cursor positions on launch" M todo "setting to turn off" (recent-files)))))

 (epic E4 "Settings you can click"
  "One registry of settings behind both a dialog and code."
  "DESIGN section 14.3"
  (milestone E4.M1 "Settings registry"
   (sub E4.M1.S1 "define-setting"
    (issue settings-define "define-setting with name, type, default, doc, category" M todo "usable from #lang rackmac | change hook" ())
    (issue settings-store "Persistence in settings.rktd" M todo "atomic | survives restart" (settings-define))
    (issue settings-migrate "Move font size, theme, wrap and toolbar visibility onto settings" M todo "" (settings-define))
    (issue settings-ownership "Settings declared by extensions are unloaded with them" S todo "" (settings-define))))
  (milestone E4.M2 "Settings dialog"
   (sub E4.M2.S1 "UI"
    (issue settings-dialog "Dialog generated from the registry" L todo "checkbox, choice, number, text | categories" (settings-store))
    (issue settings-search "Search settings" S todo "" (settings-dialog))
    (issue settings-code "Edit as code opens the init file" S todo "" (settings-dialog))
    (issue settings-language "Per-Language overrides" M todo "tab width, wrap" (settings-dialog))
    (issue settings-reset "Reset to default" S todo "" (settings-dialog)))))

 (epic E5 "Start screen and learning"
  "First launch and the learning path, replacing the Lisp scratch buffer for newcomers."
  "DESIGN section 14.3 and 14.4 item 7"
  (milestone E5.M1 "Start screen"
   (sub E5.M1.S1 "Home"
    (issue start-view "Start screen: New, Open, Recent, Get Started" M todo "shown when no files are given" (recent-files))
    (issue start-setting "Setting to show or hide it at launch" S todo "" (settings-store))
    (issue start-scratch "Scratch Pad remains available for Racket users" S todo "" ())))
  (milestone E5.M2 "Get Started tutorial"
   (sub E5.M2.S1 "Interactive practice document"
    (issue tut-format "Practice document format with task check-offs" M todo "tasks complete when the matching command runs" ())
    (issue tut-content "Tutorial content mapped from the Emacs tutorial" L todo "cursor, select, cut/paste, undo, files, tabs, find, palette, settings" (tut-format))
    (issue tut-menu "Help > Get Started opens it" S todo "" (tut-format))))
  (milestone E5.M3 "Guides"
   (sub E5.M3.S1 "How do I"
    (issue guides "Task-based guides with Emacs-term callouts" L todo "" ())
    (issue help-viewer "In-app help viewer" M todo "" (guides)))))

 (epic E6 "Find and replace 2.0"
  "One find bar with Find All, Replace One by One, scope and regex under Advanced."
  "DESIGN section 14.4 item 2"
  (milestone E6.M1 "Find bar"
   (sub E6.M1.S1 "Matching"
    (issue find-regex "Regex under Advanced" M todo "errors shown inline" ())
    (issue find-word "Whole word" S todo "" ())
    (issue find-highlight "Highlight all matches" M todo "" ())
    (issue find-count "Match count and wrap indicator" S todo "" ())))
  (milestone E6.M2 "Find All"
   (sub E6.M2.S1 "Results"
    (issue findall-panel "Results list with context" M todo "click jumps to the match" (find-highlight))
    (issue findall-selection "Find within the selection" S todo "" ())))
  (milestone E6.M3 "Replace"
   (sub E6.M3.S1 "Interactive"
    (issue replace-onebyone "Replace One by One" M todo "Replace, Skip, Replace All, Stop | one undo step" ())
    (issue replace-preview "Replace preview" M todo "" (findall-panel))
    (issue replace-scope "Scope: document, open tabs, folder" M todo "" (folder-search))))
  (milestone E6.M4 "Folder search"
   (sub E6.M4.S1 "Files"
    (issue folder-search "Search a folder with ignore rules" L todo "skips .git, compiled, node_modules" ())
    (issue folder-results "Grouped results" M todo "" (folder-search findall-panel)))))

 (epic E7 "Clipboard and actions"
  "Clipboard History, Record Actions, and selection commands."
  "DESIGN section 14.4 items 3-5"
  (milestone E7.M1 "Clipboard History"
   (sub E7.M1.S1 "Kill ring"
    (issue clip-capture "Capture copies and cuts" S todo "size limit" ())
    (issue clip-picker "Cmd+Shift+V picker" M todo "" (clip-capture))
    (issue clip-privacy "History is memory-only by default; setting to persist" S todo "no passwords on disk" (clip-capture))))
  (milestone E7.M2 "Record Actions"
   (sub E7.M2.S1 "Macros"
    (issue macro-record "Record and stop at the command level" M todo "survives rebinding" ())
    (issue macro-play "Play N times" S todo "" (macro-record))
    (issue macro-save "Save as a named command with a shortcut" M todo "becomes a normal command" (macro-record))
    (issue macro-ui "Record, Stop, Play buttons" S todo "" (macro-record tb-frame))))
  (milestone E7.M3 "Selection actions"
   (sub E7.M3.S1 "Text tools"
    (issue act-case "Change Case" S todo "upper, lower, title" ())
    (issue act-sort "Sort Lines" S todo "" ())
    (issue act-swap "Swap words and lines" S todo "aliases transpose-*" ())
    (issue act-wrap "Wrap Text to Width" M todo "alias fill-paragraph" ())
    (issue act-trim "Trim trailing whitespace" S todo "" ()))))

 (epic E8 "Friendly errors and activity"
  "Calm, recoverable failures."
  "DESIGN section 14.3"
  (milestone E8.M1 "Activity panel"
   (sub E8.M1.S1 "Panel"
    (issue act-levels "Severity levels and toasts" M todo "info, warning, error" ())
    (issue act-panel "Activity panel with Details" M todo "replaces the Messages buffer view" (act-levels))
    (issue act-filter "Filter and clear" S todo "" (act-panel))))
  (milestone E8.M2 "Extension failures"
   (sub E8.M2.S1 "Recovery"
    (issue ext-disable "Disable this extension button" M todo "unloads it and records the choice" ())
    (issue safe-mode "Start in safe mode (no extensions)" S todo "command line flag and menu item" ())
    (issue ext-attribute "Attribute errors to the extension that caused them" M todo "" ()))))

 (epic E9 "Panes and sidebar"
  "Split views and side panels."
  "DESIGN section 14.3"
  (milestone E9.M1 "Split panes"
   (sub E9.M1.S1 "Window tree"
    (issue pane-model "Pane tree model with focus" L todo "" ())
    (issue pane-commands "Split right, split down, close pane" M todo "" (pane-model))
    (issue pane-drag "Drag a tab to an edge to split" L todo "" (pane-model mouse-tabs))))
  (milestone E9.M2 "Sidebar"
   (sub E9.M2.S1 "Panels"
    (issue side-container "Sidebar container with Cmd+B" M todo "" ())
    (issue side-files "Files panel" L todo "" (side-container))
    (issue side-outline "Outline panel for headings" M todo "" (side-container))
    (issue side-results "Find results panel" M todo "" (side-container findall-panel))))
  (milestone E9.M3 "Folders"
   (sub E9.M3.S1 "Workspace"
    (issue open-folder "Open Folder" M todo "" (side-files)))))

 (epic E10 "Accessibility and internationalization"
  "Usable without a mouse, at any size, in any layout."
  "DESIGN section 14.4 item 8"
  (milestone E10.M1 "Keyboard"
   (sub E10.M1.S1 "Audit"
    (issue a11y-keyboard "Every surface reachable and operable by keyboard" L todo "toolbar, status bar, dialogs, tabs" (tb-frame sb-widget))))
  (milestone E10.M2 "Visual"
   (sub E10.M2.S1 "Themes"
    (issue a11y-contrast "High-contrast themes" M todo "" ())
    (issue a11y-scale "Text scaling" S todo "" ())
    (issue a11y-color "No information carried by color alone" S todo "" ())))
  (milestone E10.M3 "Assistive technology"
   (sub E10.M3.S1 "Screen readers"
    (issue a11y-sr "Investigate VoiceOver and Narrator with text% and custom widgets" L todo "written plan" ())))
  (milestone E10.M4 "Layouts and language"
   (sub E10.M4.S1 "International"
    (issue i18n-ime "IME composition tests" M todo "" ())
    (issue i18n-altgr "AltGr and non-US layouts" M todo "" (win-run))
    (issue i18n-strings "String table for UI text" L todo "" ()))))

 (epic E11 "Extension platform"
  "Make the extension boundary a real product."
  "DESIGN section 'Extension model'"
  (milestone E11.M1 "Core and API"
   (sub E11.M1.S1 "Boundary"
    (issue core-dir "Move private modules under core/" M todo "restriction rule updated" ())
    (issue api-policy "API version policy" S todo "when to bump | changelog" ())))
  (milestone E11.M2 "Packaging"
   (sub E11.M2.S1 "Distribution"
    (issue ext-manifest "raco package manifest keys for extensions" M todo "" ())
    (issue ext-ui "Enable and disable extensions" M todo "" (ext-disable))
    (issue ext-perms "Permissions for filesystem and network" L icebox "" ())))
  (milestone E11.M3 "Build tooling"
   (sub E11.M3.S1 "Custom builds"
    (issue build-cmd "rackmac build --with ext... -o app using raco exe" L todo "extensions compiled in" (pkg-mac))
    (issue init-cache "Compilation cache for init and ext" S todo "faster startup" ())))
  (milestone E11.M4 "Docs"
   (sub E11.M4.S1 "Reference"
    (issue api-docs "API reference generated from define-command and define-setting docs" L todo "" ())
    (issue author-guide "Extension author guide" M todo "" ()))))


 (epic E13 "Emacs compatibility mode"
  "An optional preset that lets an experienced Emacs user switch the labels and shortcuts to Emacs conventions, as close as possible, using surface preferences only. No architectural changes: the preset is a #lang rackmac extension that loads and unloads through the existing ownership machinery."
  "DESIGN section 14 (the vocabulary layer in reverse) and 'Extension model'"
  (milestone E13.M1 "Preset mechanism (surface only)"
   (sub E13.M1.S1 "Presets as reversible extensions"
    (issue preset-define "define-preset: a named bundle of key bindings, title overrides, menu layout and setting overrides" M todo "declared in #lang rackmac | uses only the public API | no change to the core registry" ())
    (issue preset-loader "Activate and deactivate a preset by loading it as a built-in extension" M todo "registrations go through the ownership machinery so deactivation restores exactly | activating then deactivating leaves keymaps, titles and menus identical to the start" (preset-define))
    (issue preset-setting "Setting: Interface style (Standard or Emacs)" S todo "in the settings dialog | persisted | applied at startup" (preset-loader settings-store))
    (issue preset-command "Switch Interface Style command" S todo "palette entry with aliases emacs mode and emacs keys | takes effect without a restart" (preset-loader))
    (issue preset-first-run "First-run choice: Standard or Emacs" S todo "offered on the start screen | skippable | reversible any time" (start-view preset-setting)))
   (sub E13.M1.S2 "Display-name and layout overrides"
    (issue relabel-api "relabel-command! and relabel-mode!: display-title overrides with ownership undo" M todo "titles change in menus, palette and tooltips | name symbols never change | undone on deactivation" ())
    (issue relabel-palette "Palette matches both the standard and the Emacs title" S todo "typing Paste or Yank finds it in either style" (relabel-api))
    (issue menu-relocate "relocate-command-menu!: move a command to another menu with ownership undo" M todo "makes an Emacs-style menu layout possible" ())
    (issue conditional-bindings "Key bindings that apply only while a command's #:when is true" M todo "input dispatch consults #:when | needed for CUA-style Ctrl+C/X/V | small and contained in input.rkt; review whether it counts as architectural before starting" (meta-when))))
  (milestone E13.M2 "Emacs key bindings"
   (sub E13.M2.S1 "Movement"
    (issue ek-move-basic "C-f, C-b, C-n, C-p, C-a, C-e" S todo "character, line, line start and end | Shift extends the selection" (preset-loader))
    (issue ek-move-word "M-f, M-b, M-<, M->, C-v, M-v" M todo "word, document start and end, page up and down" (preset-loader))
    (issue ek-meta-key "Meta key options" M todo "Option as Meta or Esc as a prefix on macOS, Alt on Windows | Esc prefix implemented as chords | setting documents that Option-as-Meta stops accented typing" (preset-loader))
    (issue ek-goto "M-g g and M-g M-g go to line" S todo "" (preset-loader)))
   (sub E13.M2.S2 "Editing"
    (issue ek-kill-line "C-k kills to the end of the line" S todo "at the end of a line it kills the newline | consecutive kills append to one clipboard entry" (cmd-kill-line clip-capture))
    (issue ek-kill-yank "C-w, M-w, C-y and M-y" M todo "cut, copy, paste, paste from history" (clip-picker))
    (issue ek-undo "C-/, C-_ and C-x u undo" S todo "" (preset-loader))
    (issue ek-delete "C-d, M-d and M-Backspace" S todo "delete char, word forward, word back" (preset-loader))
    (issue ek-mark "C-SPC sets the mark; motion extends the selection; C-x C-x exchanges; C-x h selects all" L todo "built on the existing selection-extension parameter | no mark ring" (preset-loader)))
   (sub E13.M2.S3 "Files, buffers, windows, help"
    (issue ek-files "C-x C-f, C-x C-s, C-x C-w, C-x C-c" M todo "open, save, save as, quit" (preset-loader))
    (issue ek-buffers "C-x b, C-x k, C-x C-b, C-x left and right" M todo "switch buffer picker, kill buffer, list buffers, previous and next" (preset-loader))
    (issue ek-windows "C-x 0, C-x 1, C-x 2, C-x 3, C-x o" L todo "needs split panes" (preset-loader pane-commands))
    (issue ek-help "C-h k, C-h f, C-h b, C-h t, C-h a, C-h ?" M todo "describe key, describe command, list bindings, tutorial, palette search" (preset-loader tut-format))
    (issue ek-mx "M-x opens the command palette" S todo "Alt-x on Windows and Option-x on macOS" (preset-loader ek-meta-key))
    (issue ek-search "C-s and C-r incremental search in the find bar" M todo "repeat to advance | Enter stops | C-g cancels and returns to the start" (preset-loader))
    (issue ek-replace "M-% query-replace and C-M-% with regex" M todo "" (preset-loader replace-onebyone find-regex))
    (issue ek-quit "C-g quits: closes the palette and find bar, cancels a chord, clears the mark" S todo "" (preset-loader ek-mark))
    (issue ek-prefix "C-u numeric prefix for repeatable commands (limited)" M todo "repeat count for motion, deletion and insertion | documented as limited, not a general prefix-argument system, so no architectural change" (preset-loader))
    (issue ek-eval "C-x C-e and C-M-x evaluate" S todo "" (preset-loader))
    (issue ek-macros "C-x (, C-x ) and C-x e" S todo "" (preset-loader macro-record)))
   (sub E13.M2.S4 "Coexisting with platform shortcuts"
    (issue ek-platform "Setting: keep platform shortcuts alongside Emacs keys" M todo "defaults on for Cmd on macOS, off for Ctrl on Windows where C-x and C-c conflict" (preset-loader settings-store))
    (issue ek-cua "CUA behavior: Ctrl+C, X, V copy, cut and paste while text is selected, prefix keys otherwise" M todo "same idea as Emacs cua-mode" (conditional-bindings ek-platform))
    (issue ek-conflicts "Report which platform shortcuts the active preset shadows" S todo "shown when switching style" (preset-loader conflict-check))
    (issue ek-macos-option "macOS Option-as-Meta via special-option-key" S todo "warns that accented characters need another method" (ek-meta-key))))
  (milestone E13.M3 "Commands Emacs users expect"
   (sub E13.M3.S1 "New editing commands (added like any other command)"
    (issue cmd-kill-line "kill-line" S todo "usable from the palette in any style" ())
    (issue cmd-open-line "open-line (C-o)" S todo "" ())
    (issue cmd-transpose "transpose-chars, transpose-words, transpose-lines" M todo "keys C-t, M-t, C-x C-t" (act-swap))
    (issue cmd-case-word "upcase-word, downcase-word, capitalize-word" S todo "keys M-u, M-l, M-c" (act-case))
    (issue cmd-join-line "delete-indentation (M-^)" S todo "" ())
    (issue cmd-blank "delete-blank-lines and just-one-space" S todo "keys C-x C-o and M-SPC" ())
    (issue cmd-fill "fill-paragraph (M-q)" M todo "" (act-wrap))
    (issue cmd-zap "zap-to-char (M-z)" S todo "" ())
    (issue cmd-recenter "recenter-top-bottom (C-l)" S todo "cycles center, top, bottom" ())
    (issue cmd-comment "comment-dwim (M-;)" S todo "reuses toggle-comment" ())
    (issue cmd-sexp "forward-sexp and backward-sexp for Racket" M todo "keys C-M-f and C-M-b" ())))
  (milestone E13.M4 "Emacs vocabulary and layout"
   (sub E13.M4.S1 "Labels"
    (issue ev-terms "Emacs terms replace the office terms in the UI" M todo "buffer, window, frame, region, kill and yank, minibuffer, mode line, major and minor mode" (relabel-api))
    (issue ev-titles "Emacs command titles" M todo "Find File, Save Buffer, Kill Buffer, Yank" (relabel-api))
    (issue ev-buffers "Scratch Pad and Activity display as *scratch* and *Messages*" S todo "display names only" (relabel-api))
    (issue ev-tabs "Tab bar labeled as buffers, with an option to hide it" S todo "" (relabel-api))
    (issue ev-menus "Emacs-style menu bar: File, Edit, Options, Buffers, Tools, Help and a mode menu" L todo "" (menu-relocate)))
   (sub E13.M4.S2 "Mode line and echo area"
    (issue ev-modeline "Optional text mode line" M todo "for example -:**-  name  L12  (Racket)" (sb-widget))
    (issue ev-echo "Echo-area style messages and an M-x prompt label on the command bar" S todo "" (relabel-api))
    (issue ev-toolbar "Setting to hide the toolbar in Emacs style" S todo "" (tb-frame))))
  (milestone E13.M5 "Guardrails, docs and onboarding"
   (sub E13.M5.S1 "Safety"
    (issue eg-snapshot "Reversibility test for every preset" M todo "activate then deactivate leaves keymaps, titles and menus identical" (preset-loader))
    (issue eg-no-core "Preset code may only require the public API" S todo "a test scans the preset file's requires" (preset-define))
    (issue eg-unsupported "Documented list of what cannot be emulated, with the Rackmac alternative" S todo "general prefix arguments, recursive edit, most of Emacs Lisp" ()))
   (sub E13.M5.S2 "Learning"
    (issue eg-cheatsheet "Emacs-key cheat sheet generated from the active preset" S todo "" (cheat-sheet))
    (issue eg-tutorial "Emacs-key variant of the Get Started tutorial" L todo "" (tut-format tut-content))
    (issue eg-mapping "Emacs to Rackmac mapping table for experienced users" S todo "" ())
    (issue eg-whichkey "which-key popup for the C-x and C-c prefixes in Emacs style" S todo "" (chord-popup)))))

 (epic E12 "Icebox: Rackorg and the legal workspace"
  "Parked by request. See DESIGN sections 9 and 10."
  "DESIGN sections 9, 10"
  (milestone E12.M1 "Rackorg"
   (sub E12.M1.S1 "Org-compatible mode"
    (issue org-parser "Org parser with incremental section reparse" L icebox "" ())
    (issue org-fold "Outline folding and structure editing" L icebox "" (org-parser))
    (issue org-agenda "Agenda index" L icebox "" (org-parser))))
  (milestone E12.M2 "Legal workspace"
   (sub E12.M2.S1 "Integrations"
    (issue legal-matters "Matter model and switcher" L icebox "" ())
    (issue legal-pdf "Read-only PDF viewer on PDFium" L icebox "" ())
    (issue legal-word "Word read, index, compare" L icebox "" ())))))
