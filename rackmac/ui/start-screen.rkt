#lang racket/base
;; The start screen's painted surface (docs/UI-DESIGN.md S2.8): one canvas% on the paper
;; ground (`surface`), like a document, rather than native controls on the OS panel color --
;; racket/gui panels cannot be colored, so a native button% or list-box% would sit on a grey
;; strip and read as a dialog (the first live look, 2026-09-26). The Library sidebar made the
;; same call for the bench (S2.1).
;;
;;   layout-start-view   model + size -> the items and where they go (pure)
;;   draw-start-view     paints them on a dc (pure, so tests render it to a bitmap-dc%)
;;   start-view%         the canvas: mouse, keyboard focus, hover
;;
;; Nothing here knows what the actions do or where Recent comes from: the model says what to
;; show and rackmac/library/start-screen.rkt says what activating an item does.
;;
;; Look: title and subtitle centered; the actions as 1 px `stroke` boxes (no pills, no
;; shadows); Recent as rows ruled in `stroke`, the name in `text` and its folder in `text-2`;
;; Get Started as a link in `accent`. Keyboard focus is a 2 px `accent` outline (a box or the
;; link) or a 2 px `accent` marker at a row's left edge -- a change of shape, not only color.
(require racket/class racket/gui/base racket/list
         "tokens.rkt" "../theme.rkt")
(provide start-view% (struct-out start-model) (struct-out sv-item)
         layout-start-view draw-start-view focusable-items
         empty-recent-text)

;; subtitle: string. actions: (listof (cons id label)). recent: #f (not shown) or a list of
;; (list label detail data). link: (cons id label) or #f; link-detail: string or #f.
(struct start-model (title subtitle actions recent link link-detail) #:transparent)

;; id: a symbol for actions and the link, (cons 'recent i) for Recent rows, #f for text.
;; kind: 'title 'subtitle 'action 'heading 'recent 'empty 'link. rect: (list x y w h).
(struct sv-item (id kind label detail data rect) #:transparent)

(define empty-recent-text "Notes you open appear here.")

;; ---- fonts --------------------------------------------------------------------------------

(define body-font (ui-font normal-control-font))
(define small-font (ui-font small-control-font))
(define title-font
  (let ([f body-font])
    (make-font #:face (send f get-face) #:family 'swiss #:size 22 #:weight 'bold)))

(define (extent dc s font)
  (define-values (w h d a) (send dc get-text-extent s font))
  (values w h))

;; ---- layout -------------------------------------------------------------------------------

(define column-max 520)
(define action-h 32)
(define action-gap 12)
(define row-h 28)
(define side 32)

;; Returns every item in paint order. Recent rows that would run into the link are left off.
(define (layout-start-view model w h dc)
  (define cw (max 120 (min column-max (- w (* 2 side)))))
  (define x0 (/ (- w cw) 2))
  (define items '())
  (define (add! it) (set! items (cons it items)))
  (define y (max 32 (* 0.12 h)))
  ;; title and subtitle
  (define-values (tw th) (extent dc (start-model-title model) title-font))
  (add! (sv-item #f 'title (start-model-title model) #f #f (list (/ (- w tw) 2) y tw th)))
  (set! y (+ y th 4))
  (define-values (sw sh) (extent dc (start-model-subtitle model) body-font))
  (add! (sv-item #f 'subtitle (start-model-subtitle model) #f #f (list (/ (- w sw) 2) y sw sh)))
  (set! y (+ y sh 28))
  ;; actions: equal boxes across the column
  (define actions (start-model-actions model))
  (define n (length actions))
  (when (> n 0)
    (define bw (/ (- cw (* (sub1 n) action-gap)) n))
    (for ([a (in-list actions)] [i (in-naturals)])
      (add! (sv-item (car a) 'action (cdr a) #f #f
                     (list (+ x0 (* i (+ bw action-gap))) y bw action-h))))
    (set! y (+ y action-h 32)))
  ;; the link sits at the foot of the column: after Recent, or right under the actions
  (define link (start-model-link model))
  (define-values (lw lh) (if link (extent dc (cdr link) body-font) (values 0 0)))
  (define recent (start-model-recent model))
  (when recent
    (define-values (hw hh) (extent dc "Recent" small-font))
    (add! (sv-item #f 'heading "Recent" #f #f (list x0 y cw (+ hh 6))))
    (set! y (+ y hh 6))
    (cond
      [(null? recent)
       (add! (sv-item #f 'empty empty-recent-text #f #f (list x0 y cw row-h)))
       (set! y (+ y row-h))]
      [else
       (define room (- h y 24 lh 24))                       ; keep the link on screen
       (define fits (max 1 (inexact->exact (floor (/ room row-h)))))
       (for ([r (in-list recent)] [i (in-naturals)] #:when (< i fits))
         (add! (sv-item (cons 'recent i) 'recent (first r) (second r) (third r) (list x0 y cw row-h)))
         (set! y (+ y row-h)))])
    (set! y (+ y 24)))
  (when link
    (define detail (start-model-link-detail model))
    (define-values (dw dh) (if detail (extent dc (link-detail-text detail) body-font) (values 0 0)))
    (add! (sv-item (car link) 'link (cdr link) detail #f
                   (list (if recent x0 (/ (- w lw dw) 2)) y lw lh))))
  (reverse items))

(define (link-detail-text d) (string-append "  ·  " d))

(define (focusable-items items)
  (filter (lambda (it) (memq (sv-item-kind it) '(action recent link))) items))

;; ---- drawing ------------------------------------------------------------------------------

(define (rect-values r) (apply values r))

(define (fill-rect! dc color x y w h)
  (send dc set-pen color 1 'transparent)
  (send dc set-brush color 'solid)
  (send dc draw-rectangle x y w h))

(define (outline! dc color width x y w h)
  (send dc set-pen color width 'solid)
  (send dc set-brush color 'transparent)
  (define inset (/ width 2))
  (send dc draw-rectangle (+ x inset) (+ y inset) (- w width) (- h width)))

(define (draw-text! dc s font color x y)
  (send dc set-font font)
  (send dc set-text-foreground color)
  (send dc draw-text s x y))

;; focus / hover: the focused and hovered item ids (or #f).
(define (draw-start-view dc w h model #:focus [focus #f] #:hover [hover #f])
  (send dc set-smoothing 'aligned)
  (fill-rect! dc (token 'surface) 0 0 w h)
  (for ([it (in-list (layout-start-view model w h dc))])
    (define-values (x y iw ih) (rect-values (sv-item-rect it)))
    (define id (sv-item-id it))
    (define focused? (and id (equal? id focus)))
    (define hovered? (and id (equal? id hover)))
    (case (sv-item-kind it)
      [(title) (draw-text! dc (sv-item-label it) title-font (token 'heading) x y)]
      [(subtitle) (draw-text! dc (sv-item-label it) body-font (token 'text-2) x y)]
      [(action)
       (fill-rect! dc (if hovered? (token 'line-highlight) (token 'surface)) x y iw ih)
       (if focused?
           (outline! dc (token 'accent) 2 x y iw ih)
           (outline! dc (token 'stroke) 1 x y iw ih))
       (define-values (lw lh) (extent dc (sv-item-label it) body-font))
       (draw-text! dc (sv-item-label it) body-font (token 'text) (+ x (/ (- iw lw) 2)) (+ y (/ (- ih lh) 2)))]
      [(heading)
       (draw-text! dc (sv-item-label it) small-font (token 'text-2) x y)
       (send dc set-pen (token 'stroke) 1 'solid)
       (send dc draw-line x (+ y ih -1) (+ x iw) (+ y ih -1))]
      [(empty)
       (define-values (lw lh) (extent dc (sv-item-label it) body-font))
       (draw-text! dc (sv-item-label it) body-font (token 'text-2) (+ x 12) (+ y (/ (- ih lh) 2)))]
      [(recent)
       (when (or focused? hovered?) (fill-rect! dc (token 'line-highlight) x y iw ih))
       (when focused? (fill-rect! dc (token 'accent) x y 2 ih))
       (define-values (lw lh) (extent dc (sv-item-label it) body-font))
       (define ty (+ y (/ (- ih lh) 2)))
       (define detail (sv-item-detail it))
       (define-values (dw dh) (if detail (extent dc detail small-font) (values 0 0)))
       (when detail
         (draw-text! dc detail small-font (token 'text-2) (+ x iw (- dw) -12) (+ y (/ (- ih dh) 2))))
       (send dc set-clipping-rect x y (max 1 (- iw dw 36)) ih)
       (draw-text! dc (sv-item-label it) body-font (token 'text) (+ x 12) ty)
       (send dc set-clipping-region #f)
       (send dc set-pen (token 'stroke) 1 'solid)
       (send dc draw-line x (+ y ih -1) (+ x iw) (+ y ih -1))]
      [(link)
       (draw-text! dc (sv-item-label it) body-font (token 'accent) x y)
       (send dc set-pen (token 'accent) 1 'solid)
       (send dc draw-line x (+ y ih -1) (+ x iw) (+ y ih -1))              ; a link, not only a color
       (define detail (sv-item-detail it))
       (when detail
         (draw-text! dc (link-detail-text detail) body-font (token 'text-2) (+ x iw) y))
       (when focused? (outline! dc (token 'accent) 2 (- x 6) (- y 4) (+ iw 12) (+ ih 8)))]
      [else (void)])))

;; ---- the canvas ---------------------------------------------------------------------------
;; model-getter: (-> start-model), read at every paint, so Recent and whether it shows follow
;; the Library without being told. on-activate: (sv-item) for a click, Return or Space.
;; on-shortcut: (key-event) -> any, for ⌘/Ctrl combinations (the document keymap's shortcuts).
(define start-view%
  (class canvas%
    (init-field model-getter [on-activate void] [on-shortcut (lambda (e) #f)])
    (super-new [style '()])
    (inherit get-client-size get-dc refresh focus set-canvas-background)
    (set-canvas-background (token 'surface))

    (define focus-id #f)
    (define hover-id #f)

    (define/public (current-items [w #f] [h #f])
      (define-values (cw ch) (get-client-size))
      (layout-start-view (model-getter) (or w cw) (or h ch) (get-dc)))
    (define/public (focused-id) focus-id)
    (define (focusables) (focusable-items (current-items)))
    (define (item-for id) (findf (lambda (it) (equal? (sv-item-id it) id)) (focusables)))

    (define/public (set-focus-id! id) (set! focus-id id) (refresh))
    (define/public (focus-first!)
      (define fs (focusables))
      (set-focus-id! (and (pair? fs) (sv-item-id (car fs))))
      (focus))

    (define/public (refresh-colors!)
      (set-canvas-background (token 'surface))
      (refresh))

    ;; Moves keyboard focus by `delta` among the focusable items, wrapping at the ends.
    (define/public (move-focus! delta)
      (define ids (map sv-item-id (focusables)))
      (unless (null? ids)
        (define i (index-of ids focus-id))
        (set-focus-id! (list-ref ids (modulo (if i (+ i delta) (if (> delta 0) 0 -1)) (length ids))))))

    (define/public (activate! id)
      (define it (item-for id))
      (when it (on-activate it)))

    (define (hit x y)
      (for/first ([it (in-list (focusables))]
                  #:when (let-values ([(ix iy iw ih) (rect-values (sv-item-rect it))])
                           (and (>= x ix) (< x (+ ix iw)) (>= y iy) (< y (+ iy ih)))))
        it))

    (define/override (on-paint)
      (define-values (w h) (get-client-size))
      ;; the focus shows only while the canvas has the keyboard
      (draw-start-view (get-dc) w h (model-getter)
                       #:focus (and (send this has-focus?) focus-id) #:hover hover-id))

    (define/override (on-focus on?) (refresh))
    (define/override (on-size w h) (refresh))

    (define/override (on-event e)
      (define it (hit (send e get-x) (send e get-y)))
      (define id (and it (sv-item-id it)))
      (case (send e get-event-type)
        [(motion enter)
         (unless (equal? id hover-id) (set! hover-id id) (refresh))]
        [(leave) (set! hover-id #f) (refresh)]
        [(left-down) (when id (set! focus-id id)) (focus) (refresh)]
        [(left-up) (when it (on-activate it))]
        [else (void)]))

    ;; Tab / Shift+Tab and the arrow keys move between items; Return or Space activates;
    ;; ⌘ (Ctrl on Windows) combinations are shortcuts, sent on as the editor would send them.
    (define/override (on-char e)
      (define code (send e get-key-code))
      (define mod? (if (eq? (system-type 'os) 'macosx) (send e get-meta-down) (send e get-control-down)))
      (cond
        [(and mod? (not (memq code '(release shift control menu)))) (on-shortcut e)]
        [(eqv? code #\tab) (move-focus! (if (send e get-shift-down) -1 1))]
        [(memq code '(down right)) (move-focus! 1)]
        [(memq code '(up left)) (move-focus! -1)]
        [(memq code '(#\return #\newline numpad-enter #\space))
         (when focus-id (activate! focus-id))]
        [else (void)]))))
