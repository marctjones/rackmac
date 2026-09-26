#lang racket/base
;; The main window: tab bar, editor canvas, find/replace bar and status bar, plus the
;; menu bar generated from command metadata. Key handling lives in buffer%/input.rkt;
;; menus deliberately carry no shortcuts of their own, so a key never fires twice.
(require racket/class racket/gui/base racket/list racket/string
         "editor.rkt" "command.rkt" "keymap.rkt" "hook.rkt" "theme.rkt" "platform.rkt" "owner.rkt"
         "ui/layout.rkt" "ui/toolbar-panel.rkt" "ui/status-bar.rkt" "ui/context-menu.rkt" "ui/find-bar.rkt")
(provide make-main-frame show-find-bar! hide-find-bar!
         find! replace-current! replace-all! focus-editor! main-frame main-canvas main-tabs
         set-find-options! main-find-bar tab-strip-style
         main-toolbar toolbar-shown? set-toolbar-shown! main-status-bar
         menu-for-title menu-item-for refresh-menu-enabled! tab-context-menu-groups
         register-submenu!
         register-start-screen! main-start-panel start-screen-shown? show-start-screen!)

(define frame #f)
(define (main-frame) frame)
(define (main-canvas) canvas)
(define (main-tabs) tabs)
(define toolbar #f)
(define (main-toolbar) toolbar)

;; The window's rows, top to bottom. Every show/hide goes through here.
(define show-toolbar? #t)
(define show-find? #f)
(define (toolbar-shown?) show-toolbar?)
(define (set-toolbar-shown! on?) (set! show-toolbar? (and on? #t)) (layout-rows!))
(define (layout-rows!)
  (send frame change-children
        (lambda (cs) (append (if show-toolbar? (list toolbar) '())
                             (list (if show-start-screen? start-panel tabs))
                             (if show-find? (list find-bar) '()) (list status-bar)))))
(define menu-bar #f)
(define tabs #f)
(define canvas #f)
(define status-bar #f)
(define (main-status-bar) status-bar)
(define find-bar #f)
(define (main-find-bar) find-bar)
(define tab-buffers '())
(define syncing? #f)

;; With the start screen showing, focus goes to its default control (its own New Note button)
;; instead of the hidden canvas -- otherwise every shortcut (⌘N, ⌘O, ⌘,...) would need a click
;; first, since key events dispatch through the focused editor canvas (see the header comment)
;; and a detached canvas never receives them.
(define (focus-editor!)
  (cond [(and show-start-screen? start-panel) (send start-panel focus-default!)]
        [canvas (send canvas focus)]))

;; The fallback when no feature module has called register-start-screen! (isolated tests that
;; require frame.rkt alone): a plain panel with the same focus-default! contract the real one
;; (rackmac/library/start-screen.rkt) provides.
(define trivial-start-panel%
  (class vertical-panel% (super-new) (define/public (focus-default!) (send this focus))))

;; ---- start screen (#277 start-view) ---------------------------------------
;; A native-controls panel that takes the tabs/canvas's spot when there is no document open,
;; built by rackmac/library/start-screen.rkt (which owns New Note/Add Folder/Recent/Get
;; Started -- frame.rkt only decides when to show it). `register-start-screen!` is called once,
;; like register-submenu!, but a builder rather than a registry: there is exactly one start
;; screen. A test that never requires that module gets an empty placeholder instead, so
;; existing frame tests are unaffected.
(define start-panel #f)
(define (main-start-panel) start-panel)
(define start-screen-builder #f)
(define (register-start-screen! builder) (set! start-screen-builder builder))

(define show-start-screen? #f)
;; Set by the `show-start-screen` command below; stays #t (even with documents open) until a
;; document actually becomes current again, per document -- see the current-buffer-changed
;; handler in make-main-frame, the only place that clears it.
(define forced-start-screen? #f)
(define (start-screen-shown?) show-start-screen?)

;; Called from a command (rackmac/library/start-screen.rkt's `show-start-screen`) to bring the
;; screen back on demand. Sets the flags directly rather than going through
;; recompute-start-screen! below, which would see the still-current real document and
;; immediately clear the force.
(define (show-start-screen!)
  (when frame
    (set! forced-start-screen? #t)
    (set! show-start-screen? #t)
    (layout-rows!)
    (run-hook 'focus-editor)))

;; Recomputes visibility from the current flags; called on 'buffers-changed (so the screen
;; comes back once the last document closes) and, after clearing the force, on
;; 'current-buffer-changed (so it leaves once a document opens). The focus-editor hook runs
;; last, after every other current-buffer-changed handler (including the one that focuses the
;; canvas unconditionally), so this always has the final say on where focus actually lands.
(define (recompute-start-screen!)
  (when frame
    (set! show-start-screen? (or forced-start-screen? (no-document-open?)))
    (layout-rows!)
    (run-hook 'focus-editor)))

;; ---- window --------------------------------------------------------------

;; The tab strip's styles: close boxes, drag to reorder, a "+" button, same look on both OSes.
(define tab-strip-style '(no-border flat-portable can-reorder can-close new-button))

;; RM-071: Close, Close Others, Close Tabs to the Right, Copy Path, Reveal in Finder/Explorer.
;; All are ordinary commands that act on (current-buffer); the tab strip makes the
;; right-clicked tab current first, the same way on-close-request already does above.
(define (tab-context-menu-groups)
  (list '(close-tab close-other-tabs close-tabs-to-right) '(copy-tab-path reveal-in-file-manager)))

;; The tab strip: a tab's close box closes that document (asking to save), "+" makes a new
;; one, and dragging reorders the documents.
(define document-tabs%
  (class tab-panel%
    (super-new)
    (define/override (on-close-request i)
      (when (< i (length tab-buffers))
        (set-current-buffer! (list-ref tab-buffers i))
        (run-command/safe 'close-tab)))
    (define/override (on-new-request) (run-command/safe 'new-note))   ; #276: "+" makes a note
    ;; `former` lists, for each tab position after the drag, the position it had before.
    (define/augment (on-reorder former)
      (set-tab-order! (for/list ([i (in-list former)]) (list-ref tab-buffers i))))
    ;; Right-click (Ctrl-click on macOS) opens the tab context menu. tab-panel% has no
    ;; per-tab hit test exposed to Racket (the flat-portable strip's own hit-testing is
    ;; native code, not in gui-lib's mrpanel.rkt), and on-subwindow-event runs before the
    ;; click can change which tab is selected, so this necessarily uses the tab selected
    ;; when the click arrives; right-clicking a tab other than the active one is a known
    ;; limitation (issue #71). `receiver` is only ever `this` for a click on the strip
    ;; itself, never on the editor canvas nested below it, so no extra guard is needed for
    ;; that.
    (define/override (on-subwindow-event receiver e)
      (when (and (eq? receiver this) (context-click-event? e))
        (define i (send this get-selection))
        (when (and i (< i (length tab-buffers)))
          (set-current-buffer! (list-ref tab-buffers i))
          (define menu (build-popup-menu (tab-context-menu-groups)))
          (send this popup-menu menu (send e get-x) (send e get-y))))
      (super on-subwindow-event receiver e))))

(define main-frame%
  (class frame%
    (super-new)
    (send this accept-drop-files #t)
    ;; Closing goes through the `quit` command so unsaved buffers are handled in one place.
    (define/augment (can-close?) (run-command/safe 'quit) #f)
    (define/override (on-drop-file path)
      (set-current-buffer! (open-file! path)))
    ;; #254: the system appearance may have changed while we were in the background.
    (define/override (on-activate on?)
      (super on-activate on?)
      (when on? (run-hook 'window-activated)))))

;; RM-056/057/058: right-click (Ctrl-click on macOS) builds a popup-menu% from the context
;; registry for the editor's current Language, moving the caret and selecting the word
;; under the pointer first when the click lands outside the current selection. This
;; intercepts the event itself (no `super`) so text%'s own click handling never collapses
;; the selection before the check above runs.
(define context-canvas%
  (class editor-canvas%
    (super-new)
    ;; Prose documents sit centered at their measure, like a page (docs/UI-DESIGN.md 1.4):
    ;; the insets grow with the window instead of every paragraph getting margins. Code
    ;; documents keep the normal insets, and so does a document whose `center-measure` local
    ;; is #f (the Markdown Source view, md-view.rkt: wrapped at its measure, not centered).
    (define/public (fit-measure!)
      (define ed (send this get-editor))
      (define measure (and ed (send ed auto-wrap) (send ed local-ref 'center-measure #t)
                           (send ed measure-width)))
      (define-values (cw ch) (send this get-client-size))
      (define x (centered-inset cw measure))
      (define y (if measure prose-inset-y editor-inset-y))
      (unless (= x (send this horizontal-inset)) (send this horizontal-inset x))
      (unless (= y (send this vertical-inset)) (send this vertical-inset y)))
    (define/override (on-size w h) (super on-size w h) (fit-measure!))
    (define/override (on-event ev)
      (define ed (send this get-editor))
      (cond
        [(and ed (context-click-event? ev))
         (send ed context-click! (send ev get-x) (send ev get-y))
         (send this popup-menu (build-popup-menu (editor-menu-groups (send ed get-mode) ed))
               (send ev get-x) (send ev get-y))]
        [else (super on-event ev)]))))

(define (make-main-frame)
  (set! frame (new main-frame% [label "Rackmac"] [width 1100] [height 760]))
  (set-ui-parent! frame)
  (set! menu-bar (new menu-bar% [parent frame]))
  (set! toolbar (new toolbar-panel% [parent frame] [mode-getter (lambda () (send (current-buffer) get-mode))]))
  ;; Browser-style document tabs: close boxes, drag to reorder, and a "+" button, drawn the
  ;; same way on macOS and Windows ('flat-portable).
  (set! tabs (new document-tabs% [parent frame] [choices '("untitled")]
                  [style tab-strip-style]
                  [callback (lambda (tp e)
                              (unless syncing?
                                (define i (send tp get-selection))
                                (when (and i (< i (length tab-buffers)))
                                  (set-current-buffer! (list-ref tab-buffers i)))))]))
  (set! canvas (new context-canvas% [parent tabs] [style '(auto-hscroll)]
                    [horizontal-inset editor-inset-x] [vertical-inset editor-inset-y]))
  (set! find-bar (new find-bar% [parent frame] [on-close (lambda () (hide-find-bar!))]))
  (send frame change-children (lambda (cs) (remq find-bar cs)))   ; hidden until Find
  (set! start-panel (if start-screen-builder (start-screen-builder frame)
                        (new trivial-start-panel% [parent frame])))    ; no start-screen module loaded
  (build-status-bar!)

  (add-hook! 'buffers-changed refresh-tabs!)
  (add-hook! 'buffers-changed recompute-start-screen!)
  (add-hook! 'current-buffer-changed
             (lambda (b)
               (when (and (send b is-shown?) (not (placeholder-buffer? b))) (set! forced-start-screen? #f))
               (recompute-start-screen!)))
  (add-hook! 'buffer-modified-changed (lambda (b) (refresh-tabs!) (send status-bar refresh)))
  (add-hook! 'current-buffer-changed (lambda (b) (show-buffer! b) (refresh-tabs!) (send status-bar refresh)))
  (add-hook! 'status-changed (lambda () (send status-bar refresh)))
  (add-hook! 'mode-changed (lambda (b) (send canvas fit-measure!) (send status-bar refresh)))
  (add-hook! 'markdown-view-changed (lambda (b) (send canvas fit-measure!) (send status-bar refresh)))   ; #269
  (add-hook! 'status-segments-changed (lambda () (send status-bar refresh)))
  ;; An edit that leaves the caret where it was (e.g. Replace All at position 0) fires
  ;; 'text-changed but not 'status-changed; the word count still needs a repaint.
  (add-hook! 'text-changed (lambda (b) (send status-bar refresh)))
  (add-hook! 'echo (lambda (s) (send status-bar set-message! s) (send status-bar refresh)))
  (add-hook! 'command-registered (lambda (n) (rebuild-menus!)))
  ;; #335: a top menu can come and go with the current document's Language ("Format" for
  ;; prose); rebuilding on every switch is what a mode-scoped menu costs, same as the toolbar.
  (add-hook! 'current-buffer-changed (lambda (b) (rebuild-menus!)))
  (add-hook! 'mode-changed (lambda (b) (when (eq? b (current-buffer)) (rebuild-menus!))))
  (add-hook! 'focus-editor focus-editor!)
  (add-hook! 'theme-changed
             (lambda () (send canvas set-canvas-background (canvas-background))
                        (send canvas fit-measure!)          ; zoom changes the measure
                        (send canvas refresh)
                        (send status-bar refresh)))

  (add-hook! 'toolbar-changed (lambda () (send toolbar rebuild!)))
  (add-hook! 'current-buffer-changed (lambda (b) (send toolbar ensure-mode! (send b get-mode))))
  (add-hook! 'mode-changed (lambda (b) (when (eq? b (current-buffer)) (send toolbar ensure-mode! (send b get-mode)))))
  (for ([h '(after-command status-changed buffer-modified-changed current-buffer-changed)])
    (add-hook! h (lambda _ (send toolbar refresh-enabled!))))

  (send toolbar rebuild!)
  (refresh-tabs!)
  (show-buffer! (current-buffer))
  (recompute-start-screen!)
  (rebuild-menus!)
  frame)

(define (show-buffer! b)
  (send canvas set-editor b)
  (send canvas fit-measure!)
  (send canvas set-canvas-background (canvas-background))
  (update-title!)
  (send canvas focus))

(define (tab-label b)
  (string-append (if (send b is-modified?) "• " "") (send b get-name)))

(define (refresh-tabs!)
  (when tabs
    (define bs (visible-buffers))
    (set! tab-buffers bs)
    (set! syncing? #t)
    (send tabs set (map tab-label bs))
    (define i (index-of bs (current-buffer)))
    (when i (send tabs set-selection i))
    (set! syncing? #f)
    (update-title!)))

(define (update-title!)
  (when frame
    (define b (current-buffer))
    (send frame set-label
          (if (placeholder-buffer? b)
              "Rackmac"
              (format "~a~a — Rackmac" (if (send b is-modified?) "• " "") (send b get-name))))))

;; ---- status bar ----------------------------------------------------------
;; The widget itself lives in ui/status-bar.rkt (pure layout and drawing, so it can be
;; tested on a bitmap-dc%); this just makes one and wires the hooks above.

(define (build-status-bar!)
  (set! status-bar (new status-bar% [parent frame])))

;; ---- menus (generated from command metadata) -----------------------------

;; "Format" (#335, docs/UI-DESIGN.md §2.3) sits between Edit and View, but only while it would
;; hold something usable: unlike the other fixed menus, every one of its commands is
;; `#:when`-scoped to prose documents, so `title-applies?` below drops it for a Racket document.
(define menu-titles '("File" "Edit" "Format" "View" "Tools" "Help"))

;; RM-065: menu items enable and disable from #:when. menu% has no per-item enabled hook,
;; so each top menu's demand-callback (run right before it opens) walks its own items and
;; sets them from command-enabled?. menu-item-for and menu-for-title let tests trigger that
;; the same way the GUI does: (send (menu-for-title "Edit") on-demand), then is-enabled?.
(define menu-items (make-hasheq))     ; command name -> menu-item%
(define menu-objects (make-hash))     ; title string -> menu% (top-level menus AND submenus)
(define (menu-item-for name) (hash-ref menu-items name #f))
(define (menu-for-title title) (hash-ref menu-objects title #f))

(define (refresh-menu-enabled!)
  (for ([(name item) (in-hash menu-items)])
    (define c (find-command name))
    (send item enable (and c (command-enabled? c)))
    (when (and c (command-checked c) (is-a? item checkable-menu-item%))   ; #333
      (send item check (command-checked? c)))))

;; A submenu (File > Open Recent, #275) is a menu item that opens a nested menu% instead of
;; running a command. `populate!` is called with that menu% right before it opens (its own
;; demand-callback, same mechanism as the top-level menus above) and is expected to add its
;; items fresh each time -- "rebuilt from the store on demand" -- so it is never built once and
;; left stale. Registered once by the feature that owns it (e.g. rackmac/library/open-recent.rkt)
;; and, like every other registry here, undoable so an extension's own submenu unloads with it.
(struct submenu-spec (title parent order populate!))
(define submenus (make-hash))         ; title -> submenu-spec

(define (register-submenu! title #:menu parent #:menu-order order populate!)
  (define old (hash-ref submenus title #f))
  (hash-set! submenus title (submenu-spec title parent order populate!))
  (register-undo! 'submenu
                  (lambda ()
                    (if old (hash-set! submenus title old) (hash-remove! submenus title))
                    (rebuild-menus!)))
  (rebuild-menus!))

(define (populate-submenu! m spec)
  (for ([i (send m get-items)]) (send i delete))
  ((submenu-spec-populate! spec) m))

;; A row is either a command% (from the ordinary command registry) or a submenu-spec; both
;; carry a menu-order, so the two interleave and group into separators exactly the same way.
(define (row-order r) (if (command? r) (command-menu-order r) (submenu-spec-order r)))

;; A top menu shows only while it would hold something usable now: at least one command whose
;; #:when passes (or none at all, since a menu with no #:when is always usable), or a submenu
;; (which has no #:when of its own -- its contents decide their own state when it opens). File,
;; Edit, View, Tools and Help commands mostly have no #:when, so this is a no-op for them; it is
;; how "Format" (menu-titles above) disappears for a document that is not prose.
(define (title-applies? title with-menu)
  (define cmds (filter (lambda (c) (equal? (command-menu c) title)) with-menu))
  (define subs (filter (lambda (s) (equal? (submenu-spec-parent s) title)) (hash-values submenus)))
  (or (pair? subs) (for/or ([c (in-list cmds)]) (command-enabled? c))))

(define (rebuild-menus!)
  (when menu-bar
    (for ([m (send menu-bar get-items)]) (send m delete))
    (hash-clear! menu-items)
    (hash-clear! menu-objects)
    (define with-menu (filter command-menu (all-commands)))
    (define sub-parents (map submenu-spec-parent (hash-values submenus)))
    (define known (append menu-titles
                          (remove-duplicates
                           (filter (lambda (t) (not (member t menu-titles)))
                                   (append (map command-menu with-menu) sub-parents)))))
    (define titles (filter (lambda (t) (title-applies? t with-menu)) known))
    (for ([title (in-list titles)])
      (define cmds (filter (lambda (c) (equal? (command-menu c) title)) with-menu))
      (define subs (filter (lambda (s) (equal? (submenu-spec-parent s) title)) (hash-values submenus)))
      (define rows (sort (append cmds subs) < #:key row-order))
      (unless (null? rows)
        (define m (new menu% [label title] [parent menu-bar]
                       [demand-callback (lambda (menu) (refresh-menu-enabled!))]))
        (hash-set! menu-objects title m)
        (for/fold ([prev #f]) ([r (in-list rows)])
          (define group (quotient (row-order r) 10))
          (when (and prev (not (= group prev))) (new separator-menu-item% [parent m]))
          (cond
            [(command? r)
             ;; A command with an on/off state (#:checked, #333) gets a checkable item.
             (define item (new (if (command-checked r) checkable-menu-item% menu-item%)
                               [label (command-menu-label (command-name r))] [parent m]
                               [callback (lambda (i e) (run-command/safe (command-name r)))]))
             (hash-set! menu-items (command-name r) item)]
            [else
             (define sm (new menu% [label (submenu-spec-title r)] [parent m]
                             [demand-callback (lambda (menu) (populate-submenu! menu r))]))
             (hash-set! menu-objects (submenu-spec-title r) sm)])
          group)))))

;; ---- find / replace bar ----------------------------------------------------------
;; The widget and its matching logic live in ui/find-bar.rkt and the pure search.rkt (moved
;; out per docs/UI-DESIGN.md section 5.2); these delegate so callers (commands.rkt, tests)
;; keep using the same names.

(define (show-find-bar! [replace? #f])
  (send find-bar show! replace?)
  (set! show-find? #t)
  (layout-rows!))

(define (hide-find-bar!)
  (set! show-find? #f)
  (layout-rows!)
  (run-hook 'focus-editor))

(define (find! dir #:from-start? [from-start? #f]) (send find-bar find! dir #:from-start? from-start?))
(define (replace-current!) (send find-bar replace-current!))
(define (replace-all!) (send find-bar replace-all!))

;; Set what the find bar searches for without the UI (tests, and recorded actions later).
(define (set-find-options! query #:replace [replacement #f] #:match-case? [case? #f]
                            #:whole-word? [word? #f] #:regex? [regex? #f] #:in-selection? [in-selection? #f])
  (send find-bar set-options! query replacement case? word? regex? in-selection?))
