#lang racket/base
;; The main window: tab bar, editor canvas, find/replace bar and status bar, plus the
;; menu bar generated from command metadata. Key handling lives in buffer%/input.rkt;
;; menus deliberately carry no shortcuts of their own, so a key never fires twice.
(require racket/class racket/gui/base racket/list racket/string
         "editor.rkt" "command.rkt" "keymap.rkt" "hook.rkt" "theme.rkt" "platform.rkt"
         "ui/layout.rkt" "ui/toolbar-panel.rkt" "ui/status-bar.rkt" "ui/context-menu.rkt" "ui/find-bar.rkt")
(provide make-main-frame show-find-bar! hide-find-bar!
         find! replace-current! replace-all! focus-editor! main-frame main-canvas main-tabs
         set-find-options! main-find-bar tab-strip-style
         main-toolbar toolbar-shown? set-toolbar-shown! main-status-bar
         menu-for-title menu-item-for refresh-menu-enabled! tab-context-menu-groups)

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
        (lambda (cs) (append (if show-toolbar? (list toolbar) '()) (list tabs)
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

(define (focus-editor!) (when canvas (send canvas focus)))

;; ---- window --------------------------------------------------------------

;; The tab strip's styles: close boxes, drag to reorder, a "+" button, same look on both OSes.
(define tab-strip-style '(no-border flat-portable can-reorder can-close new-button))

;; RM-071: Close, Close Others, Close Tabs to the Right, Copy Path, Reveal in Finder/Explorer.
;; All are ordinary commands that act on (current-buffer); the tab strip makes the
;; right-clicked tab current first, the same way on-close-request already does above.
(define (tab-context-menu-groups)
  (list '(close-buffer close-other-tabs close-tabs-to-right) '(copy-tab-path reveal-in-file-manager)))

;; The tab strip: a tab's close box closes that document (asking to save), "+" makes a new
;; one, and dragging reorders the documents.
(define document-tabs%
  (class tab-panel%
    (super-new)
    (define/override (on-close-request i)
      (when (< i (length tab-buffers))
        (set-current-buffer! (list-ref tab-buffers i))
        (run-command/safe 'close-buffer)))
    (define/override (on-new-request) (run-command/safe 'new-buffer))
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
      (set-current-buffer! (open-file! path)))))

;; RM-056/057/058: right-click (Ctrl-click on macOS) builds a popup-menu% from the context
;; registry for the editor's current Language, moving the caret and selecting the word
;; under the pointer first when the click lands outside the current selection. This
;; intercepts the event itself (no `super`) so text%'s own click handling never collapses
;; the selection before the check above runs.
(define context-canvas%
  (class editor-canvas%
    (super-new)
    (define/override (on-event ev)
      (define ed (send this get-editor))
      (cond
        [(and ed (context-click-event? ev))
         (send ed context-click! (send ev get-x) (send ev get-y))
         (send this popup-menu (build-popup-menu (editor-menu-groups (send ed get-mode)))
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
  (build-status-bar!)

  (add-hook! 'buffers-changed refresh-tabs!)
  (add-hook! 'buffer-modified-changed (lambda (b) (refresh-tabs!) (send status-bar refresh)))
  (add-hook! 'current-buffer-changed (lambda (b) (show-buffer! b) (refresh-tabs!) (send status-bar refresh)))
  (add-hook! 'status-changed (lambda () (send status-bar refresh)))
  (add-hook! 'mode-changed (lambda (b) (send status-bar refresh)))
  (add-hook! 'status-segments-changed (lambda () (send status-bar refresh)))
  ;; An edit that leaves the caret where it was (e.g. Replace All at position 0) fires
  ;; 'text-changed but not 'status-changed; the word count still needs a repaint.
  (add-hook! 'text-changed (lambda (b) (send status-bar refresh)))
  (add-hook! 'echo (lambda (s) (send status-bar set-message! s) (send status-bar refresh)))
  (add-hook! 'command-registered (lambda (n) (rebuild-menus!)))
  (add-hook! 'focus-editor focus-editor!)
  (add-hook! 'theme-changed
             (lambda () (send canvas set-canvas-background (canvas-background))
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
  (rebuild-menus!)
  frame)

(define (show-buffer! b)
  (send canvas set-editor b)
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
          (format "~a~a — Rackmac" (if (send b is-modified?) "• " "") (send b get-name)))))

;; ---- status bar ----------------------------------------------------------
;; The widget itself lives in ui/status-bar.rkt (pure layout and drawing, so it can be
;; tested on a bitmap-dc%); this just makes one and wires the hooks above.

(define (build-status-bar!)
  (set! status-bar (new status-bar% [parent frame])))

;; ---- menus (generated from command metadata) -----------------------------

(define menu-titles '("File" "Edit" "View" "Tools" "Help"))

;; RM-065: menu items enable and disable from #:when. menu% has no per-item enabled hook,
;; so each top menu's demand-callback (run right before it opens) walks its own items and
;; sets them from command-enabled?. menu-item-for and menu-for-title let tests trigger that
;; the same way the GUI does: (send (menu-for-title "Edit") on-demand), then is-enabled?.
(define menu-items (make-hasheq))     ; command name -> menu-item%
(define menu-objects (make-hash))     ; title string -> menu%
(define (menu-item-for name) (hash-ref menu-items name #f))
(define (menu-for-title title) (hash-ref menu-objects title #f))

(define (refresh-menu-enabled!)
  (for ([(name item) (in-hash menu-items)])
    (define c (find-command name))
    (send item enable (and c (command-enabled? c)))))

(define (rebuild-menus!)
  (when menu-bar
    (for ([m (send menu-bar get-items)]) (send m delete))
    (hash-clear! menu-items)
    (hash-clear! menu-objects)
    (define with-menu (filter command-menu (all-commands)))
    (define titles (append menu-titles
                           (remove-duplicates
                            (filter (lambda (t) (not (member t menu-titles))) (map command-menu with-menu)))))
    (for ([title (in-list titles)])
      (define cmds (sort (filter (lambda (c) (equal? (command-menu c) title)) with-menu)
                         < #:key command-menu-order))
      (unless (null? cmds)
        (define m (new menu% [label title] [parent menu-bar]
                       [demand-callback (lambda (menu) (refresh-menu-enabled!))]))
        (hash-set! menu-objects title m)
        (for/fold ([prev #f]) ([c (in-list cmds)])
          (define group (quotient (command-menu-order c) 10))
          (when (and prev (not (= group prev))) (new separator-menu-item% [parent m]))
          (define item (new menu-item% [label (command-menu-label (command-name c))] [parent m]
                            [callback (lambda (i e) (run-command/safe (command-name c)))]))
          (hash-set! menu-items (command-name c) item)
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
