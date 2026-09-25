#lang racket/base
;; The find/replace row(s): native controls between the tabs and the editor. Matching, stepping
;; and Replace All are delegated to the pure rackmac/search.rkt so this module only wires
;; widgets to buffer positions. docs/UI-DESIGN.md section 2, section 7.4.
(require racket/class racket/gui/base
         "../search.rkt" "../editor.rkt" "icons.rkt" "layout.rkt" "tokens.rkt" "status-bar.rkt")
(provide find-bar%)

;; A text-field% that intercepts Enter/Shift+Enter (step) and Esc (close) before the editor
;; ever sees them, same trick the old find-field% used.
(define find-field%
  (class text-field%
    (init-field on-enter on-escape)
    (define/override (on-subwindow-char r ev)
      (case (send ev get-key-code)
        [(escape) (on-escape) #t]
        [(#\return #\newline numpad-enter) (on-enter (send ev get-shift-down)) #t]
        [else (super on-subwindow-char r ev)]))
    (super-new)))

;; The count message%'s label is always a rendered bitmap (a fixed size, so message% never
;; needs to resize itself, which is the combination that is reliable across platforms) so it
;; can be colored; if that ever fails on some backend, plain text with a glyph is the fallback.
(define count-box-w 210)
(define count-box-h 18)

(define (render-count-bitmap text color)
  (define scale (or (get-display-backing-scale) 1.0))
  (define bm (make-bitmap count-box-w count-box-h #t #:backing-scale scale))
  (define dc (new bitmap-dc% [bitmap bm]))
  (send dc set-font normal-control-font)
  (send dc set-text-foreground color)
  (define shown (truncate-to-width dc text count-box-w))
  (define-values (tw th td ta) (send dc get-text-extent shown))
  (send dc draw-text shown 0 (/ (- count-box-h th) 2))
  (send dc set-bitmap #f)
  bm)

(define find-bar%
  (class vertical-panel%
    ;; Esc and Close cannot fully hide the bar themselves (that also means leaving it out of
    ;; the frame's own row list, which is frame.rkt's state); they call back into it instead.
    (init-field [on-close (lambda () (void))])
    (super-new [stretchable-height #f] [border bar-border])
    (inherit change-children)

    ;; ---- state ------------------------------------------------------------------------
    (define sel-range #f)            ; (cons start end) captured when shown; #f = no restriction
    (define matches '())             ; (listof (cons start end)) or a find-error, absolute positions
    (define current-count-text "")   ; plain text, mirrors the count bitmap, for tests
    (define repl-shown? #f)
    (define adv-shown? #f)

    ;; ---- icon helper (as ui/toolbar-panel.rkt) -----------------------------------------
    (define (fb-icon name)
      (icon-bitmap name #:scale (or (get-display-backing-scale) 1.0) #:color (get-label-foreground-color)))

    ;; ---- row 1: Find -------------------------------------------------------------------
    (define row1 (new horizontal-panel% [parent this] [stretchable-height #f] [spacing bar-spacing]))
    (define find-field
      (new find-field% [parent row1] [label "Find"]
           [on-enter (lambda (shift?) (find! (if shift? 'backward 'forward)))]
           [on-escape (lambda () (on-close))]
           [callback (lambda (t e) (when (eq? (send e get-event-type) 'text-field) (live-search!)))]))
    (define count-msg (new message% [parent row1] [label (render-count-bitmap "" (token 'text))]))
    (define case-box (new check-box% [parent row1] [label "Match case"] [callback (lambda (b e) (options-changed!))]))
    (define word-box (new check-box% [parent row1] [label "Whole word"] [callback (lambda (b e) (options-changed!))]))
    (define advanced-btn (new button% [parent row1] [label "Advanced ▾"] [callback (lambda (b e) (toggle-advanced!))]))
    (define prev-btn (new button% [parent row1] [label (fb-icon "arrow-up")] [callback (lambda (b e) (find! 'backward))]))
    (define next-btn (new button% [parent row1] [label (fb-icon "arrow-down")] [callback (lambda (b e) (find! 'forward))]))
    (define close-btn (new button% [parent row1] [label (fb-icon "x")] [callback (lambda (b e) (on-close))]))

    ;; ---- row 2: Replace (Find and Replace only) ----------------------------------------
    (define replace-row (new horizontal-panel% [parent this] [stretchable-height #f] [spacing bar-spacing]))
    (define replace-field
      (new find-field% [parent replace-row] [label "Replace"]
           [on-enter (lambda (shift?) (replace-current!))]
           [on-escape (lambda () (on-close))]))
    (new button% [parent replace-row] [label "Replace"] [callback (lambda (b e) (replace-current!))])
    (new button% [parent replace-row] [label "Replace All"] [callback (lambda (b e) (replace-all!))])

    ;; ---- row 3: Advanced (Regular expression, In selection), disclosed on demand -------
    (define advanced-row (new horizontal-panel% [parent this] [stretchable-height #f] [spacing bar-spacing]))
    (define regex-box (new check-box% [parent advanced-row] [label "Regular expression"] [callback (lambda (b e) (options-changed!))]))
    (define selection-box (new check-box% [parent advanced-row] [label "In selection"] [callback (lambda (b e) (options-changed!))]))

    ;; ---- layout -------------------------------------------------------------------------
    (define (relayout!)
      (change-children (lambda (cs) (append (list row1)
                                             (if repl-shown? (list replace-row) '())
                                             (if adv-shown? (list advanced-row) '())))))

    (define (toggle-advanced!)
      (set! adv-shown? (not adv-shown?))
      (send advanced-btn set-label (if adv-shown? "Advanced ▴" "Advanced ▾"))
      (relayout!))

    (relayout!)   ; row2/row3 start hidden

    ;; ---- options and search scope ---------------------------------------------------------
    (define (current-options) (values (send case-box get-value) (send word-box get-value) (send regex-box get-value)))

    ;; The selection at the time the bar was opened restricts the search when "In selection"
    ;; is checked; an empty (or never-captured) selection means "no restriction".
    (define (search-scope)
      (define full (buffer-string (current-buffer)))
      (cond
        [(and (send selection-box get-value) sel-range (> (cdr sel-range) (car sel-range)))
         (values (substring full (car sel-range) (cdr sel-range)) (car sel-range))]
        [else (values full 0)]))

    (define (recompute-matches!)
      (define-values (text offset) (search-scope))
      (define-values (case? word? regex?) (current-options))
      (define result (find-matches text (send find-field get-value) #:case? case? #:word? word? #:regex? regex?))
      (set! matches (if (find-error? result) result
                        (for/list ([m (in-list result)]) (cons (+ (car m) offset) (+ (cdr m) offset)))))
      result)

    ;; ---- the count area -------------------------------------------------------------------
    (define (severity-color sev) (case sev [(error) (token 'error)] [(accent) (token 'accent)] [else (token 'text)]))

    (define (show-count! text [sev 'text])
      (set! current-count-text text)
      (with-handlers ([exn:fail? (lambda (e) (send count-msg set-label (if (eq? sev 'error) (string-append "⚠ " text) text)))])
        (send count-msg set-label (render-count-bitmap text (severity-color sev)))))

    (define (count-phrase n) (if (= n 1) "1 match" (format "~a matches" (format-count n))))

    ;; Shows the (possibly stale) live count after a query/option change: not a step, so it
    ;; is always "N matches", never "K of N" (that only appears from `step!` with #t).
    (define (show-live-count! result)
      (cond [(find-error? result) (show-count! (find-error-message result) 'error)]
            [(null? result) (show-count! (if (string=? (send find-field get-value) "") "" "No matches") 'error)]
            [else (show-count! (count-phrase (length result)) 'accent)]))

    ;; ---- stepping ---------------------------------------------------------------------
    ;; `mark-stepped?` distinguishes an explicit Next/Previous/Enter ("3 of 12") from typing
    ;; or an option change ("12 matches") per docs/UI-DESIGN.md section 7.4.
    (define (step! dir anchor mark-stepped?)
      (recompute-matches!)
      (cond
        [(find-error? matches) (show-count! (find-error-message matches) 'error) #f]
        [(null? matches) (show-count! (if (string=? (send find-field get-value) "") "" "No matches") 'error) #f]
        [else
         (define-values (idx wrapped?) (step-match-index matches anchor dir))
         (define m (list-ref matches idx))
         (send (current-buffer) set-position (car m) (cdr m))
         (if mark-stepped?
             (show-count! (format "~a~a of ~a" (if wrapped? "Wrapped · " "") (add1 idx) (format-count (length matches))) 'accent)
             (show-count! (count-phrase (length matches)) 'accent))
         #t]))

    (define (live-search!) (step! 'forward (send (current-buffer) get-start-position) #f))
    (define (options-changed!) (live-search!))

    ;; ---- public API (frame.rkt delegates find!/replace-*!/set-find-options! here) -------
    (define/public (find! dir #:from-start? [from-start? #f])
      (define b (current-buffer))
      (define anchor (cond [from-start? (send b get-start-position)]
                           [(eq? dir 'forward) (send b get-end-position)]
                           [else (send b get-start-position)]))
      (step! dir anchor #t))

    (define/public (replace-current!)
      (define b (current-buffer))
      (define query (send find-field get-value))
      (define sel (selection-string b))
      (define-values (case? word? regex?) (current-options))
      (when (> (string-length query) 0)
        (define pat (compile-find-pattern query #:case? case? #:regex? regex?))
        (when (and (not (find-error? pat)) (not (string=? sel "")))
          (define m (regexp-match-positions pat sel))
          (when (and m (= (caar m) 0) (= (cdar m) (string-length sel)))
            (define repl-text (if regex? (regexp-replace pat sel (send replace-field get-value)) (send replace-field get-value)))
            (send b insert repl-text (send b get-start-position) (send b get-end-position)))))
      (find! 'forward))

    (define/public (replace-all!)
      (define b (current-buffer))
      (define query (send find-field get-value))
      (define replacement (send replace-field get-value))
      (define-values (case? word? regex?) (current-options))
      (define-values (text offset) (search-scope))
      (unless (string=? query "")
        (define result (replace-all-string text query replacement #:case? case? #:word? word? #:regex? regex?))
        (cond
          [(find-error? result) (show-count! (find-error-message result) 'error)]
          [(zero? (replace-result-count result)) (message "No matches")]
          [else
           (send b begin-edit-sequence)
           (send b insert (replace-result-text result) offset (+ offset (string-length text)))
           (send b end-edit-sequence)
           (message "Replaced ~a occurrence~a" (replace-result-count result) (if (= (replace-result-count result) 1) "" "s"))])
        (show-live-count! (recompute-matches!))))

    (define/public (set-options! query replacement case? word? regex? in-selection?)
      (send find-field set-value query)
      (when replacement (send replace-field set-value replacement))
      (send case-box set-value (and case? #t))
      (send word-box set-value (and word? #t))
      (send regex-box set-value (and regex? #t))
      (send selection-box set-value (and in-selection? #t))
      (show-live-count! (recompute-matches!)))

    (define/public (show! replace?)
      (define b (current-buffer))
      (define sel (selection-string b))
      (set! sel-range (and (> (string-length sel) 0) (cons (send b get-start-position) (send b get-end-position))))
      (when (and sel-range (not (regexp-match? #rx"\n" sel))) (send find-field set-value sel))
      (set! repl-shown? (and replace? #t))
      (relayout!)
      (send find-field focus)
      (send (send find-field get-editor) select-all)
      (show-live-count! (recompute-matches!)))

    ;; ---- accessors for tests (docs/DEVELOPMENT.md: assert through state, not the GUI) ---
    (define/public (get-find-field) find-field)
    (define/public (get-replace-field) replace-field)
    (define/public (get-case-box) case-box)
    (define/public (get-word-box) word-box)
    (define/public (get-regex-box) regex-box)
    (define/public (get-selection-box) selection-box)
    (define/public (get-advanced-button) advanced-btn)
    (define/public (advanced-shown?) adv-shown?)
    (define/public (replace-shown?) repl-shown?)
    (define/public (count-text) current-count-text)
    (define/public (match-count) (if (find-error? matches) #f (length matches)))))
