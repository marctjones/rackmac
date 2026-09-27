#lang racket/base
;; Highlight-all for the find bar (RM-109): while the Find bar is open with a match, every
;; occurrence gets a light background wash (`match`); the one the caret is on (the active
;; match, which also carries the ordinary text selection) gets the stronger `match-current`
;; wash plus a thicker outline, so it is never distinguished by color alone
;; (docs/UI-DESIGN.md section 1.2). Drawn the same way rackmac/spell.rkt underlines
;; misspellings: a listener on buffer.rkt's paint hook, so no style, character or undo step is
;; ever added. Unlike spell.rkt's underline (drawn after the text), a background wash must sit
;; under the glyphs, so this uses the 'before' phase of that hook
;; (rackmac/buffer.rkt's 'paint-document-background).
(require racket/class racket/gui/base racket/list
         "hook.rkt" (only-in "ui/tokens.rkt" token))
(provide set-find-highlights! clear-find-highlights! find-highlight-ranges
         paint-match-wash! paint-match-outline!)

;; The current match's outline, in dc pixels (docs/UI-DESIGN.md 1.2: "the current find match
;; also gets a thicker outline" -- the wash color difference alone must not be the only cue).
(define outline-width 2)

;; buffer -> (listof (cons start end)), absolute buffer positions; '() (the default) paints
;; nothing, which is also what "no highlights" looks like.
(define highlights (make-weak-hasheq))

(define (find-highlight-ranges b) (hash-ref highlights b '()))

;; `ranges` replaces whatever was highlighted for `b`. Called every time the find bar
;; recomputes its matches, so an empty query or a query with no matches clears the wash on its
;; own -- callers never need a separate "clear" case for those (find-bar.rkt: recompute-matches!).
(define (set-find-highlights! b ranges)
  (define was (hash-ref highlights b '()))
  (define now (or ranges '()))
  (hash-set! highlights b now)
  (unless (equal? was now) (send b invalidate-bitmap-cache 0.0 0.0 'end 'end)))

(define (clear-find-highlights! b) (set-find-highlights! b '()))

;; Pure: fills one rectangle per `rects` (each a (list x0 y0 x1 y1) in dc coordinates) with
;; `color`, restoring the dc's pen and brush so it never leaks into the caller's own drawing.
;; Testable directly on a bitmap-dc% (docs/DEVELOPMENT.md: painted widgets are pure functions
;; of their inputs).
(define (paint-match-wash! dc rects color)
  (define old-pen (send dc get-pen))
  (define old-brush (send dc get-brush))
  (send dc set-pen "black" 1 'transparent)
  (send dc set-brush color 'solid)
  (for ([r (in-list rects)])
    (define x0 (car r)) (define y0 (cadr r)) (define x1 (caddr r)) (define y1 (cadddr r))
    (when (and (> x1 x0) (> y1 y0)) (send dc draw-rectangle x0 y0 (- x1 x0) (- y1 y0))))
  (send dc set-brush old-brush)
  (send dc set-pen old-pen))

;; Pure: strokes an unfilled, `width`-px outline around each rect in `color`, so it can be
;; layered over an already-filled wash (the current match: docs/UI-DESIGN.md 1.2). Same
;; restore discipline as paint-match-wash!, and just as testable on a bitmap-dc%.
(define (paint-match-outline! dc rects color [width outline-width])
  (define old-pen (send dc get-pen))
  (define old-brush (send dc get-brush))
  (send dc set-pen color width 'solid)
  (send dc set-brush "black" 'transparent)
  (for ([r (in-list rects)])
    (define x0 (car r)) (define y0 (cadr r)) (define x1 (caddr r)) (define y1 (cadddr r))
    (when (and (> x1 x0) (> y1 y0)) (send dc draw-rectangle x0 y0 (- x1 x0) (- y1 y0))))
  (send dc set-brush old-brush)
  (send dc set-pen old-pen))

;; The dc rectangle (a (list x0 y0 x1 y1), or #f) spanning `r`'s whole line, offset by dx/dy.
;; #f when the match is wrapped across a soft-wrapped line (as spell.rkt skips those for its
;; underline): there is no single rectangle for it.
(define (match-rect b r dx dy)
  (define x0 (box 0.0)) (define y0 (box 0.0))
  (define x1 (box 0.0)) (define y1 (box 0.0)) (define yt (box 0.0))
  (send b position-location (car r) x0 y0 #f)
  (send b position-location (cdr r) x1 y1 #f)
  (and (= (unbox y0) (unbox y1))
       (begin (send b position-location (car r) #f yt #t)
              (list (+ dx (unbox x0)) (+ dy (unbox yt)) (+ dx (unbox x1)) (+ dy (unbox y0))))))

;; Every highlighted range visible in [top, bottom], split into the active match (the buffer's
;; current selection, if it is exactly one of the ranges) and the rest, each painted in its own
;; wash color. The active one is painted last, on top, though the ranges never overlap.
(define (paint! b dc left top right bottom dx dy)
  (define ranges (hash-ref highlights b '()))
  (when (pair? ranges)
    (define from (send b line-start-position (send b find-line top)))
    (define to (send b line-end-position (send b find-line bottom)))
    (define sel-s (send b get-start-position))
    (define sel-e (send b get-end-position))
    (define visible (filter (lambda (r) (and (<= (car r) to) (>= (cdr r) from))) ranges))
    (define-values (current others)
      (partition (lambda (r) (and (= (car r) sel-s) (= (cdr r) sel-e))) visible))
    (define (rects rs) (filter values (map (lambda (r) (match-rect b r dx dy)) rs)))
    (define current-rects (rects current))
    (paint-match-wash! dc (rects others) (token 'match))
    (paint-match-wash! dc current-rects (token 'match-current))
    ;; Never color alone (docs/UI-DESIGN.md 1.2): the active match also gets a thicker outline,
    ;; drawn last so it stays visible even where text%'s own selection paints over the wash.
    (paint-match-outline! dc current-rects (token 'match-current))))

(add-hook! 'paint-document-background paint!)
