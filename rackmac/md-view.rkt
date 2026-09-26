#lang racket/base
;; The two views of a Markdown document (#269, docs/UI-DESIGN.md §2.2.1): Formatted (md-style.rkt)
;; and Markdown Source (the regex coloring in highlight.rkt, on the mono "Standard" style, not
;; centered). Both are a styling layer over the same text: switching changes styles, paragraph
;; margins and a few document locals, never a character, and nothing enters undo.
;;
;; The view is the document local `markdown-view`. Source view shadows three of markdown-mode's
;; locals: `document-style` ("Standard"), `restyle-edit`/`restyle-flush` (#f, so edits recolor the
;; whole document shortly after typing stops, as highlight.rkt always did) and `center-measure`
;; (#f: the 80-column measure is kept but not centered, frame.rkt). Leaving markdown-mode removes
;; the shadows and keeps `markdown-view`, so switching the Language back restores the view.
;;
;; No editor.rkt here: modes.rkt requires this module, and editor.rkt requires modes.rkt. The
;; command, the status segment and the per-document memory's hooks are in md-view-commands.rkt.
(require racket/class
         "md-style.rkt" "highlight.rkt" "hook.rkt" "settings.rkt" "library/recents.rkt")
(provide markdown-view set-markdown-view! markdown-view-label
         markdown-highlight! markdown-view-enable! markdown-view-disable!
         view-memory-enabled? enable-markdown-view-memory! remember-markdown-view!)

(define views '(formatted source))

(define-setting markdown-default-view
  #:contract (lambda (v) (and (memq v views) #t))
  #:default 'formatted
  #:category "Notes"
  #:choices '((formatted . "Formatted") (source . "Markdown Source"))
  #:doc "How Markdown notes open: formatted like a page, or as plain Markdown source.")

;; ---- per-document memory (recents.rktd) -----------------------------------------------------
;; Off until the app turns it on (app.rkt), like recent-files tracking, so tests that open notes
;; never read or write the real recents store.
(define memory? #f)
(define (view-memory-enabled?) memory?)
(define (enable-markdown-view-memory! [on? #t]) (set! memory? (and on? #t)))

(define (remembered-view b)
  (define p (and memory? (send b get-path)))
  (define e (and p (find-recent p)))
  (define v (and e (recent-entry-view e)))
  (and (memq v views) v))

(define (remember-markdown-view! b)
  (define p (and memory? (send b get-path)))
  (when p (set-recent-view! p (markdown-view b))))

;; ---- the view -------------------------------------------------------------------------------

(define (markdown-view b) (send b local-ref 'markdown-view 'formatted))

;; What the status segment shows: #f for documents that are not Markdown.
(define (markdown-view-label b)
  (and (eq? (send b get-mode) 'markdown-mode)
       (if (eq? (markdown-view b) 'source) "Markdown" "Formatted")))

(define shadowed '(document-style restyle-edit restyle-flush center-measure))

(define (apply-view-locals! b view)
  (case view
    [(source) (send b local-set! 'document-style "Standard")
              (send b local-set! 'restyle-edit #f)
              (send b local-set! 'restyle-flush #f)
              (send b local-set! 'center-measure #f)]
    [else (for ([k (in-list shadowed)]) (send b local-remove! k))]))

;; markdown-mode's #:on-enable, run by set-mode! before the document is restyled. A document
;; that already has a view keeps it (reloading, or the Language switched away and back);
;; otherwise a long one opens in Source, since formatting it is slow; otherwise the view
;; remembered for its file; otherwise the setting.
(define (markdown-view-enable! b)
  (define view
    (cond [(memq (send b local-ref 'markdown-view #f) views) => car]
          [(send b large?) 'source]
          [(remembered-view b)]
          [else (setting-ref 'markdown-default-view)]))
  (send b local-set! 'markdown-view view)
  (apply-view-locals! b view))

;; markdown-mode's #:on-disable: another Language takes over.
(define (markdown-view-disable! b)
  (apply-view-locals! b 'formatted)
  (reset-paragraph-margins! b))

;; markdown-mode's highlighter.
(define (markdown-highlight! b)
  (case (markdown-view b)
    [(source) (reset-paragraph-margins! b) (highlight-markdown! b)]
    [else (render-markdown! b)]))

;; Switch `b` to `view`: one restyle of the whole document in one edit sequence, so it paints
;; once. The selection is kept, and so is the scroll position: the line that was at the top of
;; the window is at the top again (line heights change, so pixels cannot be). The styler is
;; called directly rather than through rehighlight!, which skips long documents: asking for a
;; view is asking for it to be drawn.
(define (set-markdown-view! b view)
  (unless (memq view views) (raise-argument-error 'set-markdown-view! "(or/c 'formatted 'source)" view))
  (unless (eq? view (markdown-view b))
    (define s (send b get-start-position))
    (define e (send b get-end-position))
    (define top (visible-top b))
    (define was-modified? (send b is-modified?))
    (send b local-set! 'markdown-view view)
    (apply-view-locals! b view)
    (send b begin-edit-sequence #f #f)
    (markdown-highlight! b)
    (send b on-display-size)                 ; the measure is 80 columns of another face now
    (send b end-edit-sequence)
    (unless (eq? was-modified? (send b is-modified?)) (send b set-modified was-modified?))
    (send b set-position s e #f #f)
    (when top (scroll-to-top! b top))
    (remember-markdown-view! b)
    (run-hook 'markdown-view-changed b)))

;; The first position shown in the window, or #f when the document is not in one.
(define (visible-top b)
  (and (send b get-admin)
       (let ([s (box 0)] [e (box 0)])
         (send b get-visible-position-range s e #f)
         (unbox s))))

;; Scroll so position `pos` is on the window's first line: ask for a view-high rectangle that
;; starts at its line, which only fits when that line is at the top.
(define (scroll-to-top! b pos)
  (define admin (send b get-admin))
  (when admin
    (define y (box 0))
    (send b position-location pos #f y #t)
    (define w (box 0)) (define h (box 0))
    (send admin get-view #f #f w h)
    (send admin scroll-to 0 (unbox y) 1 (max 1 (unbox h)) #t 'start)))
