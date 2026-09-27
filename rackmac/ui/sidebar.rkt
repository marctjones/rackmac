#lang racket/base
;; The Library sidebar's widgets (#273 lib-sidebar; docs/UI-DESIGN.md S2.1, decision #331 option
;; (a)): the dark `bench`, the same in both appearances, with every surface painted by us --
;; a native list-box% or text-field% would draw the OS's light table or white box on it.
;;
;;   filter-row%       the painted "Find a note ⇧⌘O" row (opens Quick Open; no text field)
;;   section-header%   "Recent" / "Folders" in the ui-small font, a bench-rule above
;;   bench-list%       a painted list (flat, or a tree of folders) on the bench
;;   layout-bench-rows the list's rows and where they go (pure)
;;   draw-bench-list   paints them on a dc (pure, so tests render it to a bitmap-dc%)
;;   rule-column%      the 1 px bench-rule edge next to the tabs
;;
;; Nothing here knows about the Library itself: rackmac/library/sidebar.rkt fills the lists
;; and says what activating a row does. Drawing is split into plain functions over a dc so
;; tests render to a bitmap-dc% (tests/ui-harness.rkt) without ever showing a window.
;;
;; Why not mrlib/hierlist (the first build, 2026-09-26): its selected-row fill is the OS
;; highlight color, captured once when the library is instantiated; the disclosure arrows are
;; its own blue bitmaps; and the row height it reports is not the height it lays out, so a list
;; sized to its rows clipped the last one. None of that is reachable through its API, so the
;; lists are painted like the start screen (rackmac/ui/start-screen.rkt): one canvas% per list,
;; rows from a pure layout function, the height taken from that same layout.
(require racket/class racket/gui/base racket/list racket/string
         "tokens.rkt" "icons.rkt" "../theme.rkt" "../command.rkt" "context-menu.rkt")
(provide filter-row% section-header% bench-list% rule-column% bench-row%
         draw-filter-row draw-section-header
         layout-bench-rows draw-bench-list (struct-out bench-slot)
         add-bench-row! set-bench-row-label! bench-row-label bench-row-data
         row-font header-font row-text-color marker-width
         ;; shared with rackmac/ui/outline.rkt (#298), a painted list of its own (headings are
         ;; depth-indented, never foldable, so it does not fit bench-list%'s folder model)
         text-width line-height truncate-to wrap-to double-click-ms wheel-step)

;; ---- fonts and colors ---------------------------------------------------------------------

(define row-font (ui-font normal-control-font))
(define header-font (ui-font small-control-font))

(define (row-text-color) (token 'bench-text))

(define (text-extent dc s)
  (define-values (w h d a) (send dc get-text-extent s))
  (values w h))

;; ---- painted rows -------------------------------------------------------------------------

;; The filter row: a 1 px bench-rule box (a field look, without a native field), "Find a
;; note" on the left, the Quick Open shortcut on the right; focused, a 2 px accent marker at
;; the left edge and the label in bench-heading.
(define (draw-filter-row dc w h #:focused? [focused? #f] #:shortcut [shortcut (command-shortcut 'quick-open)])
  (send dc set-smoothing 'aligned)
  (send dc set-pen (token 'bench) 1 'solid)
  (send dc set-brush (token 'bench) 'solid)
  (send dc draw-rectangle 0 0 w h)
  (send dc set-pen (token 'bench-rule) 1 'solid)
  (send dc set-brush (token 'bench) 'transparent)
  (send dc draw-rectangle 8 6 (max 0 (- w 16)) (max 0 (- h 12)))
  (when focused?
    (send dc set-pen (token 'accent) 1 'transparent)
    (send dc set-brush (token 'accent) 'solid)
    (send dc draw-rectangle 0 0 2 h))
  (send dc set-font row-font)
  (define-values (lw lh) (text-extent dc "Find a note"))
  (send dc set-text-foreground (if focused? (token 'bench-heading) (token 'bench-text)))
  (send dc draw-text "Find a note" 16 (/ (- h lh) 2))
  (when shortcut
    (send dc set-font header-font)
    (define-values (sw sh) (text-extent dc shortcut))
    (send dc set-text-foreground (token 'bench-text))
    (send dc draw-text shortcut (max 16 (- w 16 sw)) (/ (- h sh) 2))))

;; A section label in the ui-small font (not uppercase mono: bench-quiet fails contrast), with
;; a bench-rule line above every section but the first.
(define (draw-section-header dc w h label #:rule? [rule? #t] #:collapsed? [collapsed? #f])
  (send dc set-smoothing 'aligned)
  (send dc set-pen (token 'bench) 1 'solid)
  (send dc set-brush (token 'bench) 'solid)
  (send dc draw-rectangle 0 0 w h)
  (when rule?
    (send dc set-pen (token 'bench-rule) 1 'solid)
    (send dc draw-line 0 0 w 0))
  (send dc set-font header-font)
  (define text (if collapsed? (string-append label " (hidden)") label))
  (define-values (tw th) (text-extent dc text))
  (send dc set-text-foreground (token 'bench-text))
  (send dc draw-text text 12 (- h th 4)))

(define filter-row%
  (class canvas%
    (init-field [on-activate void])
    (super-new [min-height 36] [stretchable-height #f])
    (inherit get-client-size get-dc refresh has-focus?)
    (define/override (on-paint)
      (define-values (w h) (get-client-size))
      (draw-filter-row (get-dc) w h #:focused? (has-focus?)))
    (define/override (on-focus on?) (refresh))
    (define/override (on-event e) (when (send e button-up? 'left) (on-activate)))
    (define/override (on-char e)
      (when (memq (send e get-key-code) '(#\return #\newline numpad-enter #\space)) (on-activate)))))

(define section-header%
  (class canvas%
    (init-field label [rule? #t] [on-toggle void])
    (field [collapsed? #f])
    (super-new [style '(no-focus)] [min-height 26] [stretchable-height #f])
    (inherit get-client-size get-dc refresh)
    (define/public (set-collapsed! on?) (set! collapsed? on?) (refresh))
    (define/override (on-paint)
      (define-values (w h) (get-client-size))
      (draw-section-header (get-dc) w h label #:rule? rule? #:collapsed? collapsed?))
    (define/override (on-event e) (when (send e button-up? 'left) (on-toggle)))))

(define rule-column%
  (class canvas%
    (super-new [style '(no-focus)] [min-width 1] [stretchable-width #f])
    (inherit get-client-size get-dc)
    (define/override (on-paint)
      (define-values (w h) (get-client-size))
      (define dc (get-dc))
      (send dc set-pen (token 'bench-rule) 1 'solid)
      (send dc set-brush (token 'bench-rule) 'solid)
      (send dc draw-rectangle 0 0 (max 1 w) h))))


;; ---- rows ---------------------------------------------------------------------------------
;; A row is a label, the `data` the Library wants back when it is activated, and for a folder
;; its child rows (made lazily: the list calls on-opened the first time it opens). Opening and
;; closing go through the owning list, so it can call on-opened / on-closed and repaint.

(define bench-row%
  (class object%
    (init-field owner label data [folder? #f] [selectable? #t] [wrap? #f] [parent #f])
    (define children '())
    (define open? #f)
    (super-new)
    (define/public (get-label) label)
    (define/public (set-label! l) (set! label l))
    (define/public (get-data) data)
    (define/public (get-parent) parent)
    (define/public (is-folder?) folder?)
    (define/public (wraps?) wrap?)
    (define/public (get-allow-selection?) selectable?)
    (define/public (get-items) children)
    (define/public (add-child! r) (set! children (append children (list r))))
    (define/public (is-open?) open?)
    (define/public (open)
      (when (and folder? (not open?))
        (set! open? #t)
        (send owner row-opened this)))
    (define/public (close)
      (when open?
        (set! open? #f)
        (send owner row-closed this)))
    (define/public (toggle-open/closed) (if open? (close) (open)))))

(define (bench-row-label r) (send r get-label))
(define (bench-row-data r) (send r get-data))

;; `parent`: the bench-list% or a folder row. Returns the new row.
(define (add-bench-row! parent label data #:folder? [folder? #f] #:selectable? [selectable? #t]
                        #:wrap? [wrap? #f])
  (define owner (if (is-a? parent bench-row%) (get-field owner parent) parent))
  (define r (new bench-row% [owner owner] [label label] [data data] [folder? folder?]
                 [selectable? selectable?] [wrap? wrap?]
                 [parent (and (is-a? parent bench-row%) parent)]))
  (if (is-a? parent bench-row%) (send parent add-child! r) (send owner add-root! r))
  (send owner rows-changed!)
  r)

(define (set-bench-row-label! r label)
  (send r set-label! label)
  (send (get-field owner r) rows-changed!))

;; ---- layout (pure) ------------------------------------------------------------------------
;; row: the bench-row%. depth: 0 for a top row. rect: (list x y w h) in content coordinates
;; (before scrolling), the full width of the list. text-x: where the label starts. lines: the
;; label as drawn (truncated with "…" to fit, or wrapped for a row that wraps).
(struct bench-slot (row depth rect text-x lines) #:transparent)

(define row-pad 4)          ; above and below a row's text
(define list-pad 4)         ; above the first row and below the last
(define indent 14)          ; per folder level
(define chevron-size 16)
(define chevron-left 6)
(define marker-width 2)

(define (text-width dc s)
  (define-values (w h d a) (send dc get-text-extent s row-font))
  w)
(define (line-height dc)
  (define-values (w h d a) (send dc get-text-extent "Xg" row-font))
  h)

(define (truncate-to dc s room)
  (cond
    [(<= (text-width dc s) room) s]
    [else
     ;; the longest prefix that fits with "…", by bisection
     (define (cut n) (string-append (string-trim (substring s 0 n) #:left? #f) "…"))
     (let loop ([lo 0] [hi (string-length s)])      ; cut lo fits (or lo = 0); cut hi does not
       (if (<= (- hi lo) 1)
           (cut lo)
           (let ([mid (quotient (+ lo hi) 2)])
             (if (<= (text-width dc (cut mid)) room) (loop mid hi) (loop lo mid)))))]))

(define (wrap-to dc s room)
  (let loop ([words (string-split s)] [line ""] [out '()])
    (cond
      [(null? words) (reverse (if (string=? line "") out (cons line out)))]
      [else
       (define try (if (string=? line "") (car words) (string-append line " " (car words))))
       (if (or (string=? line "") (<= (text-width dc try) room))
           (loop (cdr words) try out)
           (loop words "" (cons line out)))])))

(define (text-left depth flat?)
  (if flat? 12 (+ chevron-left (* depth indent) chevron-size 4)))

;; roots: the top rows. Returns the slots of every visible row (the children of open folders
;; included), in paint order, and the height of the whole list.
(define (layout-bench-rows roots w dc #:flat? [flat? #f])
  (define lh (line-height dc))
  (define slots '())
  (define y list-pad)
  (let walk ([rows roots] [depth 0])
    (for ([r (in-list rows)])
      (define tx (text-left depth flat?))
      (define room (max 16 (- w tx 8)))
      (define lines (if (send r wraps?)
                        (wrap-to dc (send r get-label) room)
                        (list (truncate-to dc (send r get-label) room))))
      (define h (+ (* (max 1 (length lines)) lh) (* 2 row-pad)))
      (set! slots (cons (bench-slot r depth (list 0 y w h) tx lines) slots))
      (set! y (+ y h))
      (when (and (send r is-folder?) (send r is-open?))
        (walk (send r get-items) (add1 depth)))))
  (values (reverse slots) (+ y list-pad)))

;; ---- drawing (pure) -----------------------------------------------------------------------

(define (fill-rect! dc color x y w h)
  (send dc set-pen color 1 'transparent)
  (send dc set-brush color 'solid)
  (send dc draw-rectangle x y w h))

;; The list's rows on the bench. selected / hover: rows (or #f). focused?: the list has the
;; keyboard. scroll: how far the content is scrolled up, in pixels.
;; layout: (cons slots total) already computed for this width, or #f to compute it here.
(define (draw-bench-list dc w h roots #:flat? [flat? #f] #:selected [selected #f]
                         #:focused? [focused? #f] #:hover [hover #f] #:scroll [scroll 0]
                         #:layout [layout #f])
  (send dc set-smoothing 'aligned)
  (fill-rect! dc (token 'bench) 0 0 w h)
  (define-values (slots total)
    (if layout (values (car layout) (cdr layout)) (layout-bench-rows roots w dc #:flat? flat?)))
  (define lh (line-height dc))
  (send dc set-font row-font)
  (for ([s (in-list slots)])
    (define r (bench-slot-row s))
    (define-values (x y0 rw rh) (apply values (bench-slot-rect s)))
    (define y (- y0 scroll))
    (when (and (< y h) (> (+ y rh) 0))
      (define sel? (eq? r selected))
      (when sel?
        ;; the selection (brand: a moss left marker plus a sunk fill): a bench-hover fill, the
        ;; 2 px accent marker at the sidebar's edge and the label in bench-heading; with the
        ;; keyboard in the list, a 1 px accent ring as well (a change of shape, not only color)
        (fill-rect! dc (token 'bench-hover) 0 y w rh)
        (fill-rect! dc (token 'accent) 0 y marker-width rh)
        (when focused?
          (send dc set-pen (token 'accent) 1 'solid)
          (send dc set-brush (token 'accent) 'transparent)
          (send dc draw-rectangle marker-width y (max 1 (- w marker-width)) rh)))
      (when (send r is-folder?)
        (define p (icon-dc-path (if (send r is-open?) "chevron-down" "chevron-right") chevron-size))
        ;; bench-text at rest; accent while the pointer is on the row (brand: hover turns nav
        ;; chevrons moss)
        (define c (if (eq? r hover) (token 'accent) (token 'bench-text)))
        (send dc set-pen c 1 'transparent)
        (send dc set-brush c 'solid)
        (send dc set-smoothing 'smoothed)
        (send dc draw-path p (+ chevron-left (* (bench-slot-depth s) indent))
              (+ y row-pad (/ (- lh chevron-size) 2)) 'winding)
        (send dc set-smoothing 'aligned))
      (send dc set-text-foreground (if sel? (token 'bench-heading) (token 'bench-text)))
      (for ([line (in-list (bench-slot-lines s))] [i (in-naturals)])
        (send dc draw-text line (bench-slot-text-x s) (+ y row-pad (* i lh))))))
  ;; a thin bench-rule thumb while the rows overflow (no native scrollbar: its gutter is light)
  (when (> total h 0)
    (define th (max 16 (* h (/ h total))))
    (define ty (* (/ scroll (- total h)) (- h th)))
    (fill-rect! dc (token 'bench-rule) (- w 4) ty 3 th)))

;; ---- the list -----------------------------------------------------------------------------
;; on-activate: (row how) with how 'click, 'double or 'key -- a left click on a row, a second
;; click on it within the double-click interval, and Return (`activate-selected!`). Arrow keys
;; only move the selection, never open. on-selected: (row-or-#f) hears every change of
;; selection, quiet ones included. on-context: (row x y) for a right-click (or Ctrl-click),
;; after the row under the pointer is selected. on-opened / on-closed: (row) when a folder row
;; opens (the Library fills it then) or closes.
;; fit-to-rows?: the list is exactly as tall as its rows (`fit-height!`) and never scrolls.
(define double-click-ms (send (new keymap%) get-double-click-interval))
(define wheel-step 16)

(define bench-list%
  (class canvas%
    (init-field [on-activate void] [on-context void] [on-opened void] [on-closed void]
                [on-selected void] [fit-to-rows? #f])
    (super-new [style '(no-autoclear)])
    (inherit get-client-size get-dc refresh has-focus? focus min-height set-canvas-background)
    (set-canvas-background (token 'bench))

    (define roots '())
    (define selected #f)
    (define hover #f)
    (define scroll 0)
    (define flat? #f)
    (define last-down #f)          ; (cons row milliseconds) of the last left click on a row

    ;; ---- rows ----
    (define/public (get-items) roots)
    (define/public (add-root! r) (set! roots (append roots (list r))))
    ;; The layout is cached per width; any change to the rows only marks it stale, so filling
    ;; a folder of hundreds of files measures each label once, not once per row added.
    (define cache #f)               ; (list width slots total), or #f when stale
    (define (layout-for w)
      (unless (and cache (equal? (car cache) w))
        (define-values (slots total) (layout-bench-rows roots w (get-dc) #:flat? flat?))
        (set! cache (list w slots total)))
      (values (cadr cache) (caddr cache)))
    (define/public (rows-changed!) (set! cache #f) (refresh))
    (define/public (set-no-sublists on?) (set! flat? on?) (rows-changed!))
    (define/public (get-selected) selected)

    ;; Every visible row, depth first, including the contents of open folders.
    (define/public (all-rows) (map bench-slot-row (current-slots)))

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

    (define/public (clear-rows!)
      (select-quietly! #f)
      (set! roots '())
      (set! hover #f)
      (set! scroll 0)
      (rows-changed!))

    (define/public (row-opened r) (on-opened r) (rows-changed!))
    (define/public (row-closed r)
      ;; a selection inside the folder moves to the folder, as in Finder
      (when (and selected (let up ([p (send selected get-parent)])
                            (and p (or (eq? p r) (up (send p get-parent))))))
        (select-quietly! r))
      (on-closed r)
      (rows-changed!))

    ;; ---- selection ----
    (define (set-selected! r)
      (unless (eq? r selected)
        (set! selected r)
        (scroll-into-view! r)
        (on-selected r)
        (refresh)))

    ;; Selects without activating (programmatic: following the current document, or the row
    ;; a right-click landed on).
    (define/public (select-quietly! r) (set-selected! r))

    ;; What a left click on row `r` does, for tests (a hidden list has no real mouse).
    (define/public (click-row! r)
      (when (send r get-allow-selection?)
        (set-selected! r)
        (on-activate r 'click)))

    (define/public (activate-selected!)
      (when selected (on-activate selected 'key)))

    (define/public (restyle-selection!) (refresh))
    (define/public (refresh-colors!) (set-canvas-background (token 'bench)) (refresh))

    ;; ---- scrolling ----
    (define (max-scroll)
      (define-values (cw ch) (get-client-size))
      (if fit-to-rows? 0 (max 0 (- (content-height) ch))))
    (define (clamp-scroll!) (set! scroll (max 0 (min scroll (max-scroll)))))
    (define/public (scroll-by! dy) (set! scroll (+ scroll dy)) (clamp-scroll!) (refresh))
    (define/public (get-scroll) scroll)
    (define (scroll-into-view! r)
      (define-values (cw ch) (get-client-size))
      (define s (and r (> ch 1) (findf (lambda (s) (eq? (bench-slot-row s) r)) (current-slots))))
      (when s
        (define-values (x y w h) (apply values (bench-slot-rect s)))
        (cond
          [(< (- y list-pad) scroll) (set! scroll (- y list-pad))]
          [(> (+ y h list-pad) (+ scroll ch)) (set! scroll (- (+ y h list-pad) ch))])
        (clamp-scroll!)))

    ;; ---- painting ----
    (define/public (paint-to-dc dc w h #:focused? [focused? (has-focus?)])
      (define-values (slots total) (layout-for w))
      (draw-bench-list dc w h roots #:flat? flat? #:selected selected #:focused? focused?
                       #:hover hover #:scroll scroll #:layout (cons slots total)))
    (define/override (on-paint)
      (define-values (w h) (get-client-size))
      (clamp-scroll!)
      (paint-to-dc (get-dc) w h))
    (define/override (on-focus on?) (refresh))
    (define/override (on-size w h) (set! cache #f) (clamp-scroll!) (refresh))

    ;; ---- mouse ----
    (define (slot-at y)
      (define cy (+ y scroll))
      (findf (lambda (s) (let-values ([(x sy w h) (apply values (bench-slot-rect s))])
                           (and (>= cy sy) (< cy (+ sy h)))))
             (current-slots)))
    (define (on-chevron? s x)
      (define cx (+ chevron-left (* (bench-slot-depth s) indent)))
      (and (not flat?) (>= x (- cx 4)) (< x (+ cx chevron-size 2))))

    (define/override (on-event e)
      (define x (send e get-x))
      (define s (slot-at (send e get-y)))
      (define r (and s (bench-slot-row s)))
      (cond
        [(context-click-event? e)
         (focus)
         (when (and r (send r get-allow-selection?)) (select-quietly! r))
         (on-context selected x (send e get-y))]
        [(send e button-down? 'left)
         (focus)
         (when r
           (cond
             [(and (send r is-folder?) (on-chevron? s x)) (send r toggle-open/closed)]
             [(send r get-allow-selection?)
              (define t (send e get-time-stamp))
              (define double? (and last-down (eq? (car last-down) r) (< (- t (cdr last-down)) double-click-ms)))
              (set! last-down (if double? #f (cons r t)))
              (set-selected! r)
              (on-activate r (if double? 'double 'click))]))]
        [(memq (send e get-event-type) '(motion enter))
         (unless (eq? r hover) (set! hover r) (refresh))]
        [(eq? (send e get-event-type) 'leave)
         (set! hover #f)
         (refresh)]
        [else (void)]))

    ;; ---- keyboard ----
    ;; Up/Down move among the rows you can select; Right opens a folder and goes into it; Left
    ;; closes an open folder, or goes to the folder a row is in; Return activates.
    (define (selectable-rows) (filter (lambda (r) (send r get-allow-selection?)) (all-rows)))
    (define (move! delta)
      (define rows (selectable-rows))
      (unless (null? rows)
        (define i (index-of rows selected eq?))
        (set-selected! (cond
                         [(not i) (if (> delta 0) (car rows) (last rows))]
                         [else (list-ref rows (max 0 (min (sub1 (length rows)) (+ i delta))))]))))

    (define/override (on-char e)
      (define code (send e get-key-code))
      (case code
        [(down) (move! 1)]
        [(up) (move! -1)]
        [(home) (let ([rows (selectable-rows)]) (when (pair? rows) (set-selected! (car rows))))]
        [(end) (let ([rows (selectable-rows)]) (when (pair? rows) (set-selected! (last rows))))]
        [(right)
         (when (and selected (send selected is-folder?))
           (send selected open)
           (define first-child (findf (lambda (r) (send r get-allow-selection?)) (send selected get-items)))
           (when first-child (set-selected! first-child)))]
        [(left)
         (cond
           [(not selected) (void)]
           [(and (send selected is-folder?) (send selected is-open?)) (send selected close)]
           [(send selected get-parent) => set-selected!]
           [else (void)])]
        [(wheel-up) (scroll-by! (- wheel-step))]
        [(wheel-down) (scroll-by! wheel-step)]
        [(#\return #\newline numpad-enter) (activate-selected!)]
        [else (void)]))))
