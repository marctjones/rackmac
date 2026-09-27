#lang racket/base
;; Highlight-all for the find bar (RM-109, docs/HANDOFF.md E6.M1.S1): every match gets a
;; background wash while the query is non-empty; the active match (the buffer's current
;; selection) gets a stronger one; both clear when told to, and painting is never an edit.
;; find-bar-test itself lives in window-test.rkt (the real find bar, wired to a hidden window);
;; this file covers find-highlight.rkt directly: its state and its pure drawing.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base
         "../rackmac/find-highlight.rkt" "../rackmac/editor.rkt" "../rackmac/ui/tokens.rkt" "../rackmac/theme.rkt"
         "ui-harness.rkt")

;; ---- state: set / get / clear -----------------------------------------------------------

(test-case "a fresh object has no highlights"
  (define b (new text%))
  (check-equal? (find-highlight-ranges b) '()))

(test-case "set-find-highlights! replaces the ranges; clear-find-highlights! empties them"
  (define b (new text%))
  (set-find-highlights! b (list (cons 0 3) (cons 4 7)))
  (check-equal? (find-highlight-ranges b) (list (cons 0 3) (cons 4 7)))
  (set-find-highlights! b (list (cons 10 12)))
  (check-equal? (find-highlight-ranges b) (list (cons 10 12)) "a later call replaces, not appends")
  (clear-find-highlights! b)
  (check-equal? (find-highlight-ranges b) '()))

(test-case "highlights are tracked per object; clearing one leaves another alone"
  (define a (new text%)) (define b (new text%))
  (set-find-highlights! a (list (cons 0 1)))
  (set-find-highlights! b (list (cons 2 3)))
  (clear-find-highlights! a)
  (check-equal? (find-highlight-ranges a) '())
  (check-equal? (find-highlight-ranges b) (list (cons 2 3))))

;; ---- pure drawing: paint-match-wash! ------------------------------------------------------

(test-case "paint-match-wash! is a pure drawing on any dc: fills exactly its rectangles"
  (define bm (render-bitmap 40 20 (lambda (dc) (paint-match-wash! dc (list (list 2 2 10 10)) (token 'match)))
                            #:background (token 'surface)))
  (check-equal? (bitmap-pixel-hex bm 5 5) (token-hex 'match) "inside the rectangle")
  (check-equal? (bitmap-pixel-hex bm 20 15) (token-hex 'surface) "outside it, untouched"))

(test-case "paint-match-wash! draws every rectangle given, each in the requested color"
  (define bm (render-bitmap 40 20
                            (lambda (dc)
                              (paint-match-wash! dc (list (list 0 0 5 5)) (token 'match))
                              (paint-match-wash! dc (list (list 10 10 20 20)) (token 'match-current)))
                            #:background (token 'surface)))
  (check-equal? (bitmap-pixel-hex bm 2 2) (token-hex 'match))
  (check-equal? (bitmap-pixel-hex bm 15 15) (token-hex 'match-current)))

;; docs/UI-DESIGN.md 1.2: "the current find match also gets a thicker outline" -- nothing may be
;; conveyed by color alone, so the active match needs a shape cue too, not just match-current.
(test-case "paint-match-outline! strokes a border without filling the inside"
  (define bm (render-bitmap 40 20 (lambda (dc) (paint-match-outline! dc (list (list 5 5 25 15)) (token 'match-current)))
                            #:background (token 'surface)))
  (check-equal? (bitmap-pixel-hex bm 5 10) (token-hex 'match-current) "the border")
  (check-equal? (bitmap-pixel-hex bm 15 10) (token-hex 'surface) "the inside is left unfilled"))

;; ---- end to end: painted on a real document, over buffer.rkt's paint hook ----------------

;; A document drawn by the editor itself (print-to-dc, as ui-harness's render-document does),
;; after `set-find-highlights!` -- so the whole path (buffer.rkt's on-paint -> find-highlight.rkt's
;; hook -> paint-match-wash!) runs, not just the pure drawing function above.
(define (render text ranges #:select [sel #f])
  (define b (new-buffer! "find-highlight-test"))
  (send b insert text)
  (send b clear-undos)
  (send b set-modified #f)
  (when sel (send b set-position (car sel) (cdr sel)))
  (set-find-highlights! b ranges)
  (new editor-canvas% [parent (new frame% [label "find-highlight"])] [editor b])   ; never shown
  (send b set-max-width 400)
  (values b (render-bitmap 440 80 (lambda (dc) (send b print-to-dc dc 1)) #:background (token 'surface))))

(test-case "every match is washed, not just one, and painting is never an edit"
  (for ([app (in-list appearances)])
    (with-appearance app
      (lambda ()
        (define-values (b bm) (render "cat cat cat" (list (cons 0 3) (cons 4 7) (cons 8 11))))
        (write-tour-png! (format "find-highlight-all-~a" app) bm)
        (check-true (hash-has-key? (bitmap-colors bm) (token-hex 'match))
                    (format "~a: the match wash is drawn" app))
        (check-false (send b is-modified?))
        (check-false (send b can-do-edit-operation? 'undo) "painting added no undo step")))))

(test-case "the active match (the current selection) gets the stronger match-current wash"
  (with-appearance 'light
    (lambda ()
      (define-values (b bm) (render "cat cat cat" (list (cons 0 3) (cons 4 7) (cons 8 11)) #:select (cons 4 7)))
      (check-true (hash-has-key? (bitmap-colors bm) (token-hex 'match)) "the other two matches")
      (check-true (hash-has-key? (bitmap-colors bm) (token-hex 'match-current)) "the active one"))))

(test-case "clearing the highlights leaves nothing painted"
  (with-appearance 'light
    (lambda ()
      (define-values (b bm) (render "cat cat cat" '()))
      (check-false (hash-has-key? (bitmap-colors bm) (token-hex 'match)))
      (check-false (hash-has-key? (bitmap-colors bm) (token-hex 'match-current))))))
