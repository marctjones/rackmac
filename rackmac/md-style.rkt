#lang racket/base
;; The Formatted view of a Markdown note (#268, docs/UI-DESIGN.md §2.2) and its region restyle
;; (#266, §5.3). Each Markdown document keeps one parser from rackmac-markdown; every edit becomes
;; a `parser-reparse!`, and only the change report's ranges and changed blocks are restyled, so a
;; keystroke in a long note costs a few milliseconds and styles other sources put elsewhere (find
;; highlights) survive. The whole document is restyled only by `render-markdown!` (the Language's
;; highlighter: on open, on Language change, on theme and zoom changes).
;;
;; Styling never changes the text: markup characters stay, drawn small in `text-2`. It runs in
;; edit sequences that are not undoable, and restores the modified flag, as highlight.rkt does.
;;
;; Styles. Each run's role stack (outermost first) folds into one set of effects (size factor,
;; weight, slant, face, colors, underline); that becomes one style: a join of the document's base
;; style ("Prose") with a delta style holding the effects. One level of join only, so zoom (which
;; changes "Standard", and through it "Prose") re-sizes every note style at once. The single-role
;; styles are also named in the shared style list ("Heading 1" .. "Heading 6", "Markup", ...).
(require racket/class racket/gui/base racket/list
         "../rackmac-markdown/main.rkt" "theme.rkt" "hook.rkt" (rename-in "ui/tokens.rkt" [token color-token]))
(provide render-markdown! markdown-edit! markdown-flush!
         markdown-parser-document markdown-style-for reset-paragraph-margins!
         note-style-names indent-step hang-indent)

;; ---- styles ---------------------------------------------------------------------------------

;; What a role does to the text, as UI-DESIGN §2.2 describes. `size` multiplies the size so far.
(struct fx (size bold? italic? face fg bg underline) #:transparent)
(define plain (fx 1.0 #f #f #f #f #f #f))

(define heading-sizes #(#f 1.6 1.35 1.15 1.0 1.0 1.0))

(define (apply-role f role)
  (define (with #:size [size 1.0] #:bold [bold #f] #:italic [italic #f] #:face [face #f]
                #:fg [fg #f] #:bg [bg #f] #:underline [underline #f])
    (fx (* (fx-size f) size) (or bold (fx-bold? f)) (or italic (fx-italic? f))
        (or face (fx-face f)) (or fg (fx-fg f)) (or bg (fx-bg f))
        (or underline (fx-underline f))))
  (case role
    [(heading-1 heading-2 heading-3 heading-4 heading-5 heading-6)
     (define n (- (char->integer (string-ref (symbol->string role) 8)) 48))
     (with #:size (vector-ref heading-sizes n) #:bold #t #:fg 'heading)]
    ;; markup is de-emphasized, never hidden; never underlined, even inside a link
    [(markup) (struct-copy fx (with #:size 0.8 #:fg 'text-2) [underline 'off])]
    [(strong keyword) (with #:bold #t)]
    [(emph) (with #:italic #t)]
    ;; code: the mono face a little smaller than the serif around it (a multiplier, since
    ;; size-add cannot be negative), on the sunk paper
    [(code code-block) (with #:size 0.93 #:face 'mono #:bg 'line-highlight)]
    [(front-matter) (with #:size 0.93 #:face 'mono #:fg 'text-2)]
    [(link wiki-link image) (with #:fg 'accent #:underline 'on)]
    [(tag) (with #:fg 'accent)]
    [(quote html task-done) (with #:fg 'text-2)]
    [(task-cancelled) (with #:fg 'text-disabled)]
    [else f]))                                    ; link-dest, strike, date: markup only

(define (stack->fx roles) (for/fold ([f plain]) ([r (in-list roles)]) (apply-role f r)))

(define (fx->delta f)
  (define d (make-object style-delta%))
  (unless (= (fx-size f) 1.0) (send d set-size-mult (fx-size f)))
  (when (fx-bold? f) (send d set-weight-on 'bold))
  (when (fx-italic? f) (send d set-style-on 'italic))
  (when (eq? (fx-face f) 'mono) (send d set-delta-face mono-face 'modern))
  (when (fx-fg f) (send d set-delta-foreground (color-token (fx-fg f))))
  (when (fx-bg f)
    (send d set-delta-background (color-token (fx-bg f)))
    (send d set-transparent-text-backing-off #t))
  (case (fx-underline f)
    [(on) (send d set-underlined-on #t)]
    [(off) (send d set-underlined-off #t)]
    [else (void)])
  d)

(define (shift-style f)
  (send editor-style-list find-or-create-style (send editor-style-list basic-style) (fx->delta f)))

;; The named single-role styles ("Heading 1", "Markup", ...): each holds its role's delta over the
;; root style, and the Formatted view joins it over "Prose". The theme's colors are in the deltas,
;; so they are reset when the theme changes (set-delta; style%'s set-shift-style has a bug in
;; snip-lib's style.rkt, `get-s-join-style`, so joins are never re-pointed).
(define note-style-names
  '(("Heading 1" heading-1) ("Heading 2" heading-2) ("Heading 3" heading-3)
    ("Heading 4" heading-4) ("Heading 5" heading-5) ("Heading 6" heading-6)
    ("Markup" markup) ("Strong" strong) ("Emphasis" emph) ("Code" code) ("Code Block" code-block)
    ("Link" link) ("Quote" quote)))
(define named-theme #f)
(define (refresh-named-styles!)
  (unless (eq? named-theme (current-theme-name))
    (set! named-theme (current-theme-name))
    (for ([e (in-list note-style-names)])
      (define d (fx->delta (stack->fx (cdr e))))
      (define named (send editor-style-list find-named-style (car e)))
      (if named
          (send named set-delta d)
          (send editor-style-list new-named-style (car e)
                (send editor-style-list find-or-create-style (send editor-style-list basic-style) d))))))

;; (theme base-name . roles) -> style%. Styles are cached per theme: a theme change re-renders
;; every document (appearance.rkt), which then picks up the new colors.
(define style-cache (make-hash))
(define (markdown-style-for base-name roles)
  (hash-ref! style-cache (list* (current-theme-name) base-name roles)
             (lambda ()
               (define base (send editor-style-list find-named-style base-name))
               (cond
                 [(null? roles) base]
                 [else
                  (refresh-named-styles!)
                  (define named (and (null? (cdr roles))
                                     (for/first ([e (in-list note-style-names)] #:when (eq? (cadr e) (car roles)))
                                       (send editor-style-list find-named-style (car e)))))
                  (send editor-style-list find-or-create-join-style base
                        (or named (shift-style (stack->fx roles))))]))))

;; ---- per-document state ---------------------------------------------------------------------

;; parser: the document's parser, or #f until the first full render.
;; pending: #f; 'full (restyle everything next); or the edits since the last restyle merged into
;;   one, as the vector #(start old-end new-end): the parsed text's [start, old-end) is now
;;   [start, new-end).
(struct state ([parser #:mutable] [pending #:mutable]))
(define states (make-weak-hasheq))
(define (state-of b) (hash-ref! states b (lambda () (state #f #f))))

(define (markdown-parser-document b)
  (define st (hash-ref states b #f))
  (and st (state-parser st) (parser-document (state-parser st))))

;; ---- full render ----------------------------------------------------------------------------

;; The Language's highlighter: parse the whole document and style all of it.
(define (render-markdown! b)
  (define st (state-of b))
  (define p (make-parser #:extensions all-extensions))
  (set-state-parser! st p)
  (set-state-pending! st #f)
  (define doc (parser-parse! p (send b get-text)))
  (with-styling b
    (lambda ()
      (define base-name (send b default-style-name))
      (send b change-style (send editor-style-list find-named-style base-name) 0 'end)
      (apply-runs! b (style-runs doc) base-name #:skip-base? #t)
      (apply-margins! b doc 0 (send b last-position))))
  (run-hook 'document-restyled b 0 (send b last-position)))

;; ---- region restyle -------------------------------------------------------------------------

;; Called by buffer% after each insert or delete: [start, old-end) became `new-len` characters.
;; Inside an edit sequence (Replace All, Undo, loading) the edits are merged and restyled once
;; when it ends (`markdown-flush!`); otherwise at once, so the typed character is styled before
;; it is drawn.
(define (markdown-edit! b start old-end new-len)
  (define st (state-of b))
  (cond
    [(send b large?) (set-state-parser! st #f) (set-state-pending! st #f)]
    [(not (state-parser st)) (set-state-pending! st 'full)   ; shrank below the large-file guard
                             (unless (send b in-edit-sequence?) (markdown-flush! b))]
    [else
     (define new-end (+ start new-len))
     (define pend (state-pending st))
     (set-state-pending! st
       (if pend
           ;; pending: parsed text's [ps, poe) is now [ps, pne); this edit is on the current text
           (let* ([ps (vector-ref pend 0)] [poe (vector-ref pend 1)] [pne (vector-ref pend 2)]
                  [lo (min ps start)] [hi (max pne old-end)])
             (vector lo (+ hi (- poe pne)) (+ hi (- new-end old-end))))
           (vector start old-end new-end)))
     (unless (send b in-edit-sequence?) (markdown-flush! b))]))

(define (markdown-flush! b)
  (define st (hash-ref states b #f))
  (define pend (and st (state-pending st)))
  (cond
   [(eq? pend 'full) (set-state-pending! st #f) (unless (send b large?) (render-markdown! b))]
   [pend
    (set-state-pending! st #f)
    (define p (state-parser st))
    (define old (document-text (parser-document p)))
    (define-values (s oe ne) (values (vector-ref pend 0) (vector-ref pend 1) (vector-ref pend 2)))
    (define inserted (send b get-text s ne))
    (define text (string-append (substring old 0 s) inserted (substring old oe)))
    (cond
      [(not (= (string-length text) (send b last-position))) (render-markdown! b)]
      [else
       (define-values (doc report)
         (with-handlers ([exn:fail? (lambda (e) (values #f #f))])
           (parser-reparse! p text (edit s oe inserted))))
       (if doc (restyle-report! b doc report) (render-markdown! b))])]
   [else (void)]))

;; The union of the report's ranges and its changed blocks, as sorted disjoint (start . end).
(define (report-regions report)
  (define spans (append (change-report-ranges report)
                        (for/list ([blk (in-list (change-report-blocks report))])
                          (cons (block-start blk) (block-end blk)))))
  (let loop ([xs (sort spans < #:key car)] [acc '()])
    (cond
      [(null? xs) (reverse acc)]
      [(and (pair? acc) (<= (car (car xs)) (cdr (car acc))))
       (loop (cdr xs) (cons (cons (car (car acc)) (max (cdr (car acc)) (cdr (car xs)))) (cdr acc)))]
      [else (loop (cdr xs) (cons (car xs) acc))])))

(define (restyle-report! b doc report)
  (define base-name (send b default-style-name))
  (define last (send b last-position))
  (define regions
    (for/list ([r (in-list (report-regions report))])
      (cons (min last (car r)) (min last (cdr r)))))
  (with-styling b
    (lambda ()
      (for ([r (in-list regions)])
        (apply-runs! b (style-runs doc #:start (car r) #:end (cdr r)) base-name)
        (apply-margins! b doc (car r) (cdr r)))))
  (for ([r (in-list regions)]) (run-hook 'document-restyled b (car r) (cdr r))))

;; ---- applying styles and paragraph layout ---------------------------------------------------

(define (with-styling b proc)
  (define was-modified? (send b is-modified?))
  (send b begin-edit-sequence #f #f)
  (proc)
  (send b end-edit-sequence)
  (send b set-modified was-modified?))

;; One change-style per stretch of runs that resolve to the same style. After a reset to the
;; base style, runs without roles need nothing.
(define (apply-runs! b runs base-name #:skip-base? [skip-base? #f])
  (define base (send editor-style-list find-named-style base-name))
  (let loop ([rs runs] [cur #f] [from 0] [to 0])
    (define (flush!)
      (when (and cur (< from to) (not (and skip-base? (eq? cur base))))
        (send b change-style cur from to)))
    (cond
      [(null? rs) (flush!)]
      [else
       (define r (car rs))
       (define st (markdown-style-for base-name (run-roles r)))
       (if (and (eq? st cur) (= (run-start r) to))
           (loop (cdr rs) cur from (run-end r))
           (begin (flush!) (loop (cdr rs) st (run-start r) (run-end r))))])))

;; Paragraph margins (UI-DESIGN §2.2): quotes and list items are indented `indent-step` per level;
;; an item's first line hangs `hang-indent` to the left, so its marker sits in the margin and
;; wrapped lines align with the text after it.
(define indent-step 24)
(define hang-indent 16)

(define (apply-margins! b doc start end)
  (define p0 (send b position-paragraph start))
  (define p1 (send b position-paragraph end))
  ;; Layouts are disjoint and in order, like the paragraphs, so one pass pairs them up.
  (define layouts
    (for/list ([l (in-list (block-layouts doc))]
               #:when (and (<= (layout-start l) end) (>= (layout-end l) start) (> (layout-depth l) 0)))
      l))
  (for/fold ([ls layouts]) ([para (in-range p0 (add1 p1))])
    (define ps (send b paragraph-start-position para))
    (define pe (send b paragraph-end-position para))
    (define rest (let skip ([ls ls]) (if (and (pair? ls) (< (layout-end (car ls)) ps)) (skip (cdr ls)) ls)))
    (define l (and (pair? rest) (<= (layout-start (car rest)) pe) (car rest)))
    (cond
      [(not l) (send b set-paragraph-margins para 0 0 0)]
      [else
       (define left (* indent-step (layout-depth l)))
       (define first-left (if (item-first-line? b doc l para) (max 0 (- left hang-indent)) left))
       (send b set-paragraph-margins para first-left left 0)])
    rest))

;; Does paragraph `para` hold the marker of the list item that `l` (a leaf) begins?
(define (item-first-line? b doc l para)
  (and (> (layout-list-level l) 0)
       (> (layout-start l) 0)
       (= para (send b position-paragraph (layout-start l)))
       (let ([item (block-at doc (sub1 (layout-start l)))])
         (and (list-item? item)
              (= para (send b position-paragraph (block-start item)))))))

;; Leaving the Formatted view (another Language): no indents.
(define (reset-paragraph-margins! b)
  (define was-modified? (send b is-modified?))
  (send b begin-edit-sequence #f #f)
  (for ([para (in-range (add1 (send b last-paragraph)))])
    (send b set-paragraph-margins para 0 0 0))
  (send b end-edit-sequence)
  (send b set-modified was-modified?))
