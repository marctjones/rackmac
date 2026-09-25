#lang racket/base
;; The main window: tab bar, editor canvas, find/replace bar and status bar, plus the
;; menu bar generated from command metadata. Key handling lives in buffer%/input.rkt;
;; menus deliberately carry no shortcuts of their own, so a key never fires twice.
(require racket/class racket/gui/base racket/list racket/string
         "editor.rkt" "command.rkt" "keymap.rkt" "hook.rkt" "theme.rkt" "ui/layout.rkt" "ui/toolbar-panel.rkt" "ui/status-bar.rkt")
(provide make-main-frame show-find-bar! hide-find-bar!
         find! replace-current! replace-all! focus-editor! main-frame main-canvas main-tabs set-find-options! tab-strip-style
         main-toolbar toolbar-shown? set-toolbar-shown! main-status-bar)

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
(define replace-row #f)
(define find-field #f)
(define replace-field #f)
(define case-box #f)
(define tab-buffers '())
(define syncing? #f)

(define (focus-editor!) (when canvas (send canvas focus)))

;; ---- window --------------------------------------------------------------

;; The tab strip's styles: close boxes, drag to reorder, a "+" button, same look on both OSes.
(define tab-strip-style '(no-border flat-portable can-reorder can-close new-button))

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
      (set-tab-order! (for/list ([i (in-list former)]) (list-ref tab-buffers i))))))

(define main-frame%
  (class frame%
    (super-new)
    (send this accept-drop-files #t)
    ;; Closing goes through the `quit` command so unsaved buffers are handled in one place.
    (define/augment (can-close?) (run-command/safe 'quit) #f)
    (define/override (on-drop-file path)
      (set-current-buffer! (open-file! path)))))

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
  (set! canvas (new editor-canvas% [parent tabs] [style '(auto-hscroll)]
                    [horizontal-inset editor-inset-x] [vertical-inset editor-inset-y]))
  (build-find-bar!)
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

(define (menu-label c)
  (define s (command-shortcut (command-name c)))
  (cond [(not s) (command-title c)]
        [(eq? (system-type 'os) 'macosx) (string-append (command-title c) "    " s)]   ; Cocoa ignores "\t"
        [else (string-append (command-title c) "\t" s)]))

(define (rebuild-menus!)
  (when menu-bar
    (for ([m (send menu-bar get-items)]) (send m delete))
    (define with-menu (filter command-menu (all-commands)))
    (define titles (append menu-titles
                           (remove-duplicates
                            (filter (lambda (t) (not (member t menu-titles))) (map command-menu with-menu)))))
    (for ([title (in-list titles)])
      (define cmds (sort (filter (lambda (c) (equal? (command-menu c) title)) with-menu)
                         < #:key command-menu-order))
      (unless (null? cmds)
        (define m (new menu% [label title] [parent menu-bar]))
        (for/fold ([prev #f]) ([c (in-list cmds)])
          (define group (quotient (command-menu-order c) 10))
          (when (and prev (not (= group prev))) (new separator-menu-item% [parent m]))
          (new menu-item% [label (menu-label c)] [parent m]
               [callback (lambda (i e) (run-command/safe (command-name c)))])
          group)))))

;; ---- find / replace bar --------------------------------------------------

(define find-field%
  (class text-field%
    (init-field on-enter)
    (define/override (on-subwindow-char r ev)
      (case (send ev get-key-code)
        [(escape) (hide-find-bar!) #t]
        [(#\return #\newline numpad-enter) (on-enter (send ev get-shift-down)) #t]
        [else (super on-subwindow-char r ev)]))
    (super-new)))

(define (build-find-bar!)
  (set! find-bar (new vertical-panel% [parent frame] [stretchable-height #f] [border bar-border]))
  (define row1 (new horizontal-panel% [parent find-bar] [stretchable-height #f] [spacing bar-spacing]))
  (set! find-field (new find-field% [parent row1] [label "Find"] [on-enter (lambda (shift?) (find! (if shift? 'backward 'forward)))]
                        [callback (lambda (t e)
                                    (when (eq? (send e get-event-type) 'text-field)
                                      (find! 'forward #:from-start? #t)))]))
  (new button% [parent row1] [label "Previous"] [callback (lambda (b e) (find! 'backward))])
  (new button% [parent row1] [label "Next"] [callback (lambda (b e) (find! 'forward))])
  (set! case-box (new check-box% [parent row1] [label "Match case"]))
  (new button% [parent row1] [label "Close"] [callback (lambda (b e) (hide-find-bar!))])
  (set! replace-row (new horizontal-panel% [parent find-bar] [stretchable-height #f] [spacing bar-spacing]))
  (set! replace-field (new find-field% [parent replace-row] [label "Replace"]
                           [on-enter (lambda (shift?) (replace-current!))]))
  (new button% [parent replace-row] [label "Replace"] [callback (lambda (b e) (replace-current!))])
  (new button% [parent replace-row] [label "Replace All"] [callback (lambda (b e) (replace-all!))])
  (send find-bar change-children (lambda (cs) (list row1)))     ; replace row hidden until asked
  (set! find-row1 row1)
  (send frame change-children (lambda (cs) (remq find-bar cs))))   ; hidden until Find; rows not all built yet

(define find-row1 #f)

(define (show-find-bar! [replace? #f])
  (define sel (selection-string))
  (when (and (> (string-length sel) 0) (not (regexp-match? #rx"\n" sel)))
    (send find-field set-value sel))
  (send find-bar change-children (lambda (cs) (if replace? (list find-row1 replace-row) (list find-row1))))
  (set! show-find? #t)
  (layout-rows!)
  (send find-field focus)
  (send (send find-field get-editor) select-all))

;; Set what the find bar searches for without the UI (tests, and recorded actions later).
(define (set-find-options! query #:replace [replacement #f] #:match-case? [case? #f])
  (send find-field set-value query)
  (when replacement (send replace-field set-value replacement))
  (send case-box set-value case?))

(define (hide-find-bar!)
  (set! show-find? #f)
  (layout-rows!)
  (focus-editor!))

;; Returns the position where the match begins. text%'s get-start? flag means "the start in
;; the search direction", which for a backward search is the match's END, so it is flipped.
(define (search b s dir start)
  (send b find-string s dir start (if (eq? dir 'forward) 'eof 0) (eq? dir 'forward) (send case-box get-value)))

(define (find! dir #:from-start? [from-start? #f])
  (define b (current-buffer))
  (define s (send find-field get-value))
  (cond
    [(string=? s "") #f]
    [else
     (define start (cond [from-start? (send b get-start-position)]
                         [(eq? dir 'forward) (send b get-end-position)]
                         [else (send b get-start-position)]))
     (define pos
       (or (search b s dir start)
           (let ([wrapped (search b s dir (if (eq? dir 'forward) 0 (send b last-position)))])
             (when wrapped (run-hook 'echo "Wrapped around"))
             wrapped)))
     (cond [pos (send b set-position pos (+ pos (string-length s))) #t]
           [else (run-hook 'echo (format "Not found: ~a" s)) #f])]))

(define (replace-current!)
  (define b (current-buffer))
  (define s (send find-field get-value))
  (define sel (selection-string b))
  (when (and (> (string-length s) 0)
             (if (send case-box get-value) (string=? sel s) (string-ci=? sel s)))
    (send b insert (send replace-field get-value) (send b get-start-position) (send b get-end-position)))
  (find! 'forward))

(define (replace-all!)
  (define b (current-buffer))
  (define s (send find-field get-value))
  (define r (send replace-field get-value))
  (unless (string=? s "")
    (send b begin-edit-sequence)
    (define n
      (let loop ([pos 0] [n 0])
        (define p (search b s 'forward pos))
        (cond [p (send b insert r p (+ p (string-length s)))
                 (loop (+ p (string-length r)) (add1 n))]
              [else n])))
    (send b end-edit-sequence)
    (message "Replaced ~a occurrence~a" n (if (= n 1) "" "s"))))
