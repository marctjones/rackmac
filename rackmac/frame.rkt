#lang racket/base
;; The main window: tab bar, editor canvas, find/replace bar and status bar, plus the
;; menu bar generated from command metadata. Key handling lives in buffer%/input.rkt;
;; menus deliberately carry no shortcuts of their own, so a key never fires twice.
(require racket/class racket/gui/base racket/list racket/string
         "editor.rkt" "command.rkt" "keymap.rkt" "hook.rkt" "theme.rkt" "mode.rkt")
(provide make-main-frame show-find-bar! hide-find-bar!
         find! replace-current! replace-all! focus-editor! main-frame main-canvas set-find-options!)

(define frame #f)
(define (main-frame) frame)
(define (main-canvas) canvas)
(define menu-bar #f)
(define tabs #f)
(define canvas #f)
(define status-panel #f)
(define echo-label #f)
(define info-label #f)
(define find-bar #f)
(define replace-row #f)
(define find-field #f)
(define replace-field #f)
(define case-box #f)
(define tab-buffers '())
(define syncing? #f)

(define (focus-editor!) (when canvas (send canvas focus)))

;; ---- window --------------------------------------------------------------

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
  (set! tabs (new tab-panel% [parent frame] [choices '("untitled")]
                  [callback (lambda (tp e)
                              (unless syncing?
                                (define i (send tp get-selection))
                                (when (and i (< i (length tab-buffers)))
                                  (set-current-buffer! (list-ref tab-buffers i)))))]))
  (set! canvas (new editor-canvas% [parent tabs] [style '(auto-hscroll)]
                    [horizontal-inset 12] [vertical-inset 8]))
  (build-find-bar!)
  (build-status-bar!)

  (add-hook! 'buffers-changed refresh-tabs!)
  (add-hook! 'buffer-modified-changed (lambda (b) (refresh-tabs!)))
  (add-hook! 'current-buffer-changed (lambda (b) (show-buffer! b) (refresh-tabs!)))
  (add-hook! 'status-changed update-status!)
  (add-hook! 'mode-changed (lambda (b) (update-status!)))
  (add-hook! 'echo (lambda (s) (send echo-label set-label (if (string=? s "") " " s))))
  (add-hook! 'command-registered (lambda (n) (rebuild-menus!)))
  (add-hook! 'focus-editor focus-editor!)
  (add-hook! 'theme-changed
             (lambda () (send canvas set-canvas-background (canvas-background))
                        (send canvas refresh)))

  (refresh-tabs!)
  (show-buffer! (current-buffer))
  (rebuild-menus!)
  frame)

(define (show-buffer! b)
  (send canvas set-editor b)
  (send canvas set-canvas-background (canvas-background))
  (update-title!)
  (update-status!)
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

(define (build-status-bar!)
  (set! status-panel (new horizontal-panel% [parent frame] [stretchable-height #f]
                          [border 4] [spacing 12]))
  (set! echo-label (new message% [parent status-panel] [label " "] [stretchable-width #t]))
  (set! info-label (new message% [parent status-panel] [label "Ln 1, Col 1"] [min-width 320])))

(define (update-status!)
  (when info-label
    (define b (current-buffer))
    (define pos (send b get-start-position))
    (define para (send b position-paragraph pos))
    (define col (- pos (send b paragraph-start-position para)))
    (define n (- (send b get-end-position) pos))
    (send info-label set-label
          (format "Ln ~a, Col ~a~a   ~a" (add1 para) (add1 col)
                  (if (> n 0) (format "  (~a selected)" n) "")
                  (mode-display-name (send b get-mode))))))

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
  (set! find-bar (new vertical-panel% [parent frame] [stretchable-height #f] [border 4]))
  (define row1 (new horizontal-panel% [parent find-bar] [stretchable-height #f] [spacing 6]))
  (set! find-field (new find-field% [parent row1] [label "Find"] [on-enter (lambda (shift?) (find! (if shift? 'backward 'forward)))]
                        [callback (lambda (t e)
                                    (when (eq? (send e get-event-type) 'text-field)
                                      (find! 'forward #:from-start? #t)))]))
  (new button% [parent row1] [label "Previous"] [callback (lambda (b e) (find! 'backward))])
  (new button% [parent row1] [label "Next"] [callback (lambda (b e) (find! 'forward))])
  (set! case-box (new check-box% [parent row1] [label "Match case"]))
  (new button% [parent row1] [label "Close"] [callback (lambda (b e) (hide-find-bar!))])
  (set! replace-row (new horizontal-panel% [parent find-bar] [stretchable-height #f] [spacing 6]))
  (set! replace-field (new find-field% [parent replace-row] [label "Replace"]
                           [on-enter (lambda (shift?) (replace-current!))]))
  (new button% [parent replace-row] [label "Replace"] [callback (lambda (b e) (replace-current!))])
  (new button% [parent replace-row] [label "Replace All"] [callback (lambda (b e) (replace-all!))])
  (send find-bar change-children (lambda (cs) (list row1)))     ; replace row hidden until asked
  (set! find-row1 row1)
  (send frame change-children (lambda (cs) (remq find-bar cs))))

(define find-row1 #f)

(define (show-find-bar! [replace? #f])
  (define sel (selection-string))
  (when (and (> (string-length sel) 0) (not (regexp-match? #rx"\n" sel)))
    (send find-field set-value sel))
  (send find-bar change-children (lambda (cs) (if replace? (list find-row1 replace-row) (list find-row1))))
  (send frame change-children (lambda (cs) (list tabs find-bar status-panel)))
  (send find-field focus)
  (send (send find-field get-editor) select-all))

;; Set what the find bar searches for without the UI (tests, and recorded actions later).
(define (set-find-options! query #:replace [replacement #f] #:match-case? [case? #f])
  (send find-field set-value query)
  (when replacement (send replace-field set-value replacement))
  (send case-box set-value case?))

(define (hide-find-bar!)
  (send frame change-children (lambda (cs) (list tabs status-panel)))
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
