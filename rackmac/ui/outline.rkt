#lang racket/base
;; The Outline: the current document's Markdown headings, painted on the bench like Recent and
;; Folders (rackmac/ui/sidebar.rkt; docs/UI-DESIGN.md §2.1, §2.5) but its own list. Headings are
;; a flat sequence indented by level (H1..H6), never foldable, so bench-list%'s folder/chevron
;; machinery (open/close, on-opened/on-closed) does not fit; this is the same painted-row and
;; keyboard-navigable-canvas shape without it. It shares its look and its pure row-measuring
;; helpers (row-font, truncate-to, wrap-to, the accent selection marker) with ui/sidebar.rkt.
;;
;;   outline-row          one row: level (0 for the empty state), label, opaque `data`,
;;                        selectable? and wrap? (the empty state wraps; headings truncate)
;;   layout-outline-rows  the rows and where they go, indented by level (pure)
;;   draw-outline-rows    paints them on a dc (pure, so tests render it to a bitmap-dc%)
;;   outline-list%        the painted, keyboard-navigable list
;;
;; Nothing here knows about documents or Markdown: rackmac/library/outline.rkt (#298) fills the
;; rows from the current document's headings (rackmac/headings.rkt) and says what activating a
;; row does (move the caret there).
(require racket/class racket/gui/base racket/list
         "tokens.rkt"
         (only-in "sidebar.rkt" row-font row-text-color marker-width text-width line-height
                  truncate-to wrap-to double-click-ms wheel-step))
(provide (struct-out outline-row) heading-row empty-outline-row
         outline-list% layout-outline-rows draw-outline-rows (struct-out outline-slot))

;; ---- rows (plain data: the whole list is rebuilt on every refresh, nothing is filled lazily) --

(struct outline-row (level label data selectable? wrap?) #:transparent)

(define (heading-row level label data) (outline-row level label data #t #f))
(define (empty-outline-row text) (outline-row 0 text #f #f #t))

;; ---- layout (pure) --------------------------------------------------------------------------
;; row: the outline-row. depth: level - 1 (0 for the empty state). rect: (list x y w h) in
;; content coordinates (before scrolling), the full width of the list. text-x: where the label
;; starts. lines: the label as drawn (truncated with "…", or wrapped for the empty state).
(struct outline-slot (row depth rect text-x lines) #:transparent)

(define row-pad 4)          ; above and below a row's text
(define list-pad 4)         ; above the first row and below the last
(define left-margin 12)
(define indent 14)          ; per heading level

(define (depth-of r) (max 0 (sub1 (outline-row-level r))))
(define (text-left depth) (+ left-margin (* depth indent)))

;; Every row's slot, in paint order, and the height of the whole list.
(define (layout-outline-rows rows w dc)
  (define lh (line-height dc))
  (define slots '())
  (define y list-pad)
  (for ([r (in-list rows)])
    (define depth (depth-of r))
    (define tx (text-left depth))
    (define room (max 16 (- w tx 8)))
    (define lines (if (outline-row-wrap? r)
                      (wrap-to dc (outline-row-label r) room)
                      (list (truncate-to dc (outline-row-label r) room))))
    (define h (+ (* (max 1 (length lines)) lh) (* 2 row-pad)))
    (set! slots (cons (outline-slot r depth (list 0 y w h) tx lines) slots))
    (set! y (+ y h)))
  (values (reverse slots) (+ y list-pad)))

;; ---- drawing (pure) -------------------------------------------------------------------------

(define (fill-rect! dc color x y w h)
  (send dc set-pen color 1 'transparent)
  (send dc set-brush color 'solid)
  (send dc draw-rectangle x y w h))

;; selected: a row (or #f). focused?: the list has the keyboard. scroll: how far the content is
;; scrolled up, in pixels. layout: (cons slots total) already computed for this width, or #f.
(define (draw-outline-rows dc w h rows #:selected [selected #f] #:focused? [focused? #f]
                           #:scroll [scroll 0] #:layout [layout #f])
  (send dc set-smoothing 'aligned)
  (fill-rect! dc (token 'bench) 0 0 w h)
  (define-values (slots total)
    (if layout (values (car layout) (cdr layout)) (layout-outline-rows rows w dc)))
  (define lh (line-height dc))
  (send dc set-font row-font)
  (for ([s (in-list slots)])
    (define r (outline-slot-row s))
    (define-values (x y0 rw rh) (apply values (outline-slot-rect s)))
    (define y (- y0 scroll))
    (when (and (< y h) (> (+ y rh) 0))
      (define sel? (eq? r selected))
      (when sel?
        ;; the same selection brand as the bench: a sunk fill, the 2 px accent marker at the
        ;; sidebar's edge, and (with the keyboard in the list) a 1 px accent ring
        (fill-rect! dc (token 'bench-hover) 0 y w rh)
        (fill-rect! dc (token 'accent) 0 y marker-width rh)
        (when focused?
          (send dc set-pen (token 'accent) 1 'solid)
          (send dc set-brush (token 'accent) 'transparent)
          (send dc draw-rectangle marker-width y (max 1 (- w marker-width)) rh)))
      (send dc set-text-foreground (if sel? (token 'bench-heading) (row-text-color)))
      (for ([line (in-list (outline-slot-lines s))] [i (in-naturals)])
        (send dc draw-text line (outline-slot-text-x s) (+ y row-pad (* i lh))))))
  ;; a thin bench-rule thumb while the rows overflow (no native scrollbar: its gutter is light)
  (when (> total h 0)
    (define th (max 16 (* h (/ h total))))
    (define ty (* (/ scroll (- total h)) (- h th)))
    (fill-rect! dc (token 'bench-rule) (- w 4) ty 3 th)))

;; ---- the list ---------------------------------------------------------------------------------
;; on-activate: (row how) with how 'click, 'double or 'key -- a left click on a row, a second
;; click on it within the double-click interval, and Return (`activate-selected!`). Arrow keys
;; only move the selection, never activate. on-selected: (row-or-#f) hears every change of
;; selection, quiet ones included.
(define outline-list%
  (class canvas%
    (init-field [on-activate void] [on-selected void])
    (super-new [style '(no-autoclear)])
    (inherit get-client-size get-dc refresh has-focus? focus min-height set-canvas-background)
    (set-canvas-background (token 'bench))

    (define rows '())
    (define selected #f)
    (define scroll 0)
    (define last-down #f)          ; (cons row milliseconds) of the last left click on a row

    ;; ---- rows ----
    ;; The layout is cached per width; rebuilding the whole outline on every keystroke's restyle
    ;; only re-measures labels when the width actually changed.
    (define cache #f)               ; (list width slots total), or #f when stale
    (define (layout-for w)
      (unless (and cache (equal? (car cache) w))
        (define-values (slots total) (layout-outline-rows rows w (get-dc)))
        (set! cache (list w slots total)))
      (values (cadr cache) (caddr cache)))
    (define/public (all-rows) rows)
    (define/public (get-selected) selected)

    (define/public (set-rows! new-rows)
      (set! rows new-rows)
      (set! cache #f)
      (unless (memq selected rows) (set! selected #f))
      (refresh))

    (define/public (current-slots [w #f])
      (define-values (cw ch) (get-client-size))
      (define-values (slots total) (layout-for (or w cw)))
      slots)
    (define/public (content-height)
      (define-values (cw ch) (get-client-size))
      (define-values (slots total) (layout-for cw))
      total)

    ;; Makes the list exactly as tall as its rows, from the same layout that paints them.
    (define/public (fit-height!)
      (min-height (max 1 (inexact->exact (ceiling (content-height))))))

    ;; ---- selection ----
    (define (set-selected! r)
      (unless (eq? r selected)
        (set! selected r)
        (scroll-into-view! r)
        (on-selected r)
        (refresh)))

    ;; Selects without activating (programmatic: following the caret).
    (define/public (select-quietly! r) (set-selected! r))

    ;; What a left click on row `r` does, for tests (a hidden list has no real mouse).
    (define/public (click-row! r)
      (when (outline-row-selectable? r) (set-selected! r) (on-activate r 'click)))

    (define/public (activate-selected!) (when selected (on-activate selected 'key)))
    (define/public (refresh-colors!) (set-canvas-background (token 'bench)) (refresh))

    ;; ---- scrolling ----
    (define (max-scroll)
      (define-values (cw ch) (get-client-size))
      (max 0 (- (content-height) ch)))
    (define (clamp-scroll!) (set! scroll (max 0 (min scroll (max-scroll)))))
    (define/public (scroll-by! dy) (set! scroll (+ scroll dy)) (clamp-scroll!) (refresh))
    (define/public (get-scroll) scroll)
    (define (scroll-into-view! r)
      (define-values (cw ch) (get-client-size))
      (define s (and r (> ch 1) (findf (lambda (s) (eq? (outline-slot-row s) r)) (current-slots))))
      (when s
        (define-values (x y w h) (apply values (outline-slot-rect s)))
        (cond
          [(< (- y list-pad) scroll) (set! scroll (- y list-pad))]
          [(> (+ y h list-pad) (+ scroll ch)) (set! scroll (- (+ y h list-pad) ch))])
        (clamp-scroll!)))

    ;; ---- painting ----
    (define/public (paint-to-dc dc w h #:focused? [focused? (has-focus?)])
      (define-values (slots total) (layout-for w))
      (draw-outline-rows dc w h rows #:selected selected #:focused? focused?
                         #:scroll scroll #:layout (cons slots total)))
    (define/override (on-paint)
      (define-values (w h) (get-client-size))
      (clamp-scroll!)
      (paint-to-dc (get-dc) w h))
    (define/override (on-focus on?) (refresh))
    (define/override (on-size w h) (set! cache #f) (clamp-scroll!) (refresh))

    ;; ---- mouse ----
    (define (slot-at y)
      (define cy (+ y scroll))
      (findf (lambda (s) (let-values ([(x sy w h) (apply values (outline-slot-rect s))])
                           (and (>= cy sy) (< cy (+ sy h)))))
             (current-slots)))

    (define/override (on-event e)
      (define s (slot-at (send e get-y)))
      (define r (and s (outline-slot-row s)))
      (cond
        [(send e button-down? 'left)
         (focus)
         (when (and r (outline-row-selectable? r))
           (define t (send e get-time-stamp))
           (define double? (and last-down (eq? (car last-down) r) (< (- t (cdr last-down)) double-click-ms)))
           (set! last-down (if double? #f (cons r t)))
           (set-selected! r)
           (on-activate r (if double? 'double 'click)))]
        [else (void)]))

    ;; ---- keyboard ----
    ;; Up/Down move among the rows you can select; Home/End jump to the first/last; Return
    ;; activates (jumps), like Recent and Folders (rackmac/ui/sidebar.rkt).
    (define (selectable-rows) (filter outline-row-selectable? rows))
    (define (move! delta)
      (define rs (selectable-rows))
      (unless (null? rs)
        (define i (index-of rs selected eq?))
        (set-selected! (cond
                         [(not i) (if (> delta 0) (car rs) (last rs))]
                         [else (list-ref rs (max 0 (min (sub1 (length rs)) (+ i delta))))]))))

    (define/override (on-char e)
      (define code (send e get-key-code))
      (case code
        [(down) (move! 1)]
        [(up) (move! -1)]
        [(home) (let ([rs (selectable-rows)]) (when (pair? rs) (set-selected! (car rs))))]
        [(end) (let ([rs (selectable-rows)]) (when (pair? rs) (set-selected! (last rs))))]
        [(wheel-up) (scroll-by! (- wheel-step))]
        [(wheel-down) (scroll-by! wheel-step)]
        [(#\return #\newline numpad-enter) (activate-selected!)]
        [else (void)]))))
