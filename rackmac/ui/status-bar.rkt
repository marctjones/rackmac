#lang racket/base
;; The status bar: one canvas% at the bottom of the window. Left: the message segment (fed
;; by the 'echo hook, as the old two-message% panel was). Right: clickable segments from the
;; registry (rackmac/status.rkt), underlined in accent on hover, with a hint in the message
;; area. Layout and drawing are pure functions of their inputs (docs/UI-DESIGN.md 5.3/5.4),
;; so tests render to a bitmap-dc% instead of a real window.
(require racket/class racket/gui/base racket/list
         "../status.rkt" "../hook.rkt" "../command.rkt" "tokens.rkt" "layout.rkt")
(provide status-bar% layout-segments render-status font-for-width truncate-to-width
         (struct-out seg-view) compute-segments)

;; A segment as drawn: `name` 'message for the left-hand one (never clickable). `command`
;; is a command name or #f; `hint` is shown in the message area on hover.
(struct seg-view (name text command hint priority) #:transparent)

(define seg-pad 8)     ; each segment's own left/right inset (its clickable box)
(define seg-sep " · ")
(define min-message-width 24)

(define (font-for-width w) (if (< w 480) small-control-font normal-control-font))

(define (text-w dc s)
  (define-values (w h d a) (send dc get-text-extent s))
  w)

;; Build the (message . segments) list `layout-segments`/`render-status` take, from the
;; registry and the current message text. Segments whose thunk errors or returns #f drop out.
(define (compute-segments message)
  (cons (seg-view 'message message #f #f 0)
        (for*/list ([s (in-list (status-segments))]
                    [text (in-value (segment-text s))]
                    #:when text)
          (seg-view (status-segment-name s) text (status-segment-command s)
                    (or (status-segment-hint s) (fallback-hint (status-segment-command s)))
                    (status-segment-priority s)))))

(define (segment-text s)
  (with-handlers ([exn:fail? (lambda (e) (report-error! (status-segment-name s) e) #f)])
    ((status-segment-thunk s))))

(define (fallback-hint command)
  (and command (let ([c (find-command command)]) (and c (command-title c)))))

;; ---- pure layout -----------------------------------------------------------

;; segments: (list message-view right-view ...), as `compute-segments` returns. `dc` must
;; already have its font set (render-status does this; a caller of layout-segments alone
;; sets it first, so measuring matches drawing). Returns a parallel list of (or/c (list x y
;; w h) #f): the message always gets a rect; a right segment is #f when it was dropped for
;; width, lowest #:priority first.
(define (layout-segments segments width dc [height status-bar-height])
  (define rights (cdr segments))
  (define sep-w (text-w dc seg-sep))
  (define (seg-w s) (+ (* 2 seg-pad) (text-w dc (seg-view-text s))))
  (define (row-width rs) (if (null? rs) 0 (+ (apply + (map seg-w rs)) (* (sub1 (length rs)) sep-w))))
  (define (fits? rs) (<= (+ (row-width rs) (if (pair? rs) seg-pad 0) min-message-width) width))
  (define ascending (sort rights < #:key seg-view-priority))
  (define dropped
    (let loop ([candidates ascending] [dropped '()])
      (define remaining (filter (lambda (s) (not (memq s dropped))) rights))
      (cond [(fits? remaining) dropped]
            [(null? candidates) dropped]
            [else (loop (cdr candidates) (cons (car candidates) dropped))])))
  (define kept (filter (lambda (s) (not (memq s dropped))) rights))
  ;; Place `kept` right to left, in its own (left-to-right) order.
  (define placed
    (let loop ([ss (reverse kept)] [x width] [acc '()])
      (cond [(null? ss) acc]
            [else
             (define s (car ss))
             (define ww (seg-w s))
             (define x0 (- x ww))
             (loop (cdr ss) (- x0 sep-w) (cons (cons s (list x0 0 ww height)) acc))])))
  (define first-right-x (if (pair? placed) (car (cdr (car placed))) (- width seg-pad)))
  (define msg-rect (list seg-pad 0 (max 0 (- first-right-x seg-pad)) height))
  (cons msg-rect
        (for/list ([s (in-list rights)])
          (define hit (assq s placed))
          (and hit (cdr hit)))))

;; Truncate `s` to fit `w`, adding "…" when it does not, per docs/UI-DESIGN.md 2 (the status
;; message). `dc` must already have its font set.
(define (truncate-to-width dc s w)
  (cond
    [(<= w 0) ""]
    [(<= (text-w dc s) w) s]
    [else
     (let loop ([n (sub1 (string-length s))])
       (cond [(<= n 0) "…"]
             [else
              (define candidate (string-append (substring s 0 n) "…"))
              (if (<= (text-w dc candidate) w) candidate (loop (sub1 n)))]))]))

;; ---- pure rendering ---------------------------------------------------------

(define (draw-message! dc text rect)
  (when (and rect (> (third rect) 0))
    (define x (first rect)) (define y (second rect)) (define w (third rect)) (define h (fourth rect))
    (define shown (truncate-to-width dc text w))
    (define-values (tw th td ta) (send dc get-text-extent shown))
    (send dc draw-text shown x (+ y (/ (- h th) 2)))))

(define (draw-segment! dc s rect hover? focused?)
  (when rect
    (define x (first rect)) (define y (second rect)) (define w (third rect)) (define h (fourth rect))
    (define text (seg-view-text s))
    (define-values (tw th td ta) (send dc get-text-extent text))
    (define tx (+ x (/ (- w tw) 2)))
    (define ty (+ y (/ (- h th) 2)))
    (send dc draw-text text tx ty)
    (when hover?
      (send dc set-pen (token 'accent) 1 'solid)
      (send dc draw-line tx (+ ty th 1) (+ tx tw) (+ ty th 1)))
    (when focused?
      (send dc set-pen (token 'accent) 1 'long-dash)
      (send dc set-brush "black" 'transparent)
      (send dc draw-rectangle (+ x 0.5) (+ y 0.5) (- w 1) (- h 1)))))

;; model: (compute-segments message). hover/focused: the hovered/keyboard-focused segment's
;; name, or #f. A pure function of its inputs, so tests draw it to a bitmap-dc%.
(define (render-status dc w h model hover [focused #f])
  (send dc set-pen "black" 0 'transparent)
  (send dc set-brush (token 'status-bg) 'solid)
  (send dc draw-rectangle 0 0 w h)
  (send dc set-pen (token 'stroke) 1 'solid)
  (send dc draw-line 0 0 w 0)
  (send dc set-font (font-for-width w))
  (define rects (layout-segments model w dc h))
  (send dc set-text-foreground (token 'text))
  (draw-message! dc (seg-view-text (car model)) (car rects))
  (send dc set-text-foreground (token 'text-2))
  (for ([s (in-list (cdr model))] [r (in-list (cdr rects))])
    (draw-segment! dc s r (eq? hover (seg-view-name s)) (eq? focused (seg-view-name s)))))

;; ---- the widget --------------------------------------------------------------

(define status-bar%
  (class canvas%
    (super-new [style '()] [stretchable-width #t] [stretchable-height #f] [min-height status-bar-height])
    (inherit get-dc get-width get-height refresh)

    (define message "")
    (define hover #f)
    (define focused #f)

    (define/public (set-message! s) (set! message s))
    (define/public (current-model) (compute-segments message))

    (define (measuring-dc)
      (define dc (get-dc))
      (send dc set-font (font-for-width (get-width)))
      dc)

    (define/public (hit-test x y)
      (define w (get-width)) (define h (get-height))
      (define model (current-model))
      (define rects (layout-segments model w (measuring-dc) h))
      (for/or ([s (in-list model)] [r (in-list rects)])
        (and r (>= x (first r)) (< x (+ (first r) (third r)))
             (>= y (second r)) (< y (+ (second r) (fourth r)))
             s)))

    (define (clickable-segments) (filter seg-view-command (cdr (current-model))))

    ;; Clicking (or Enter on) a segment runs its command and hands focus back to the editor,
    ;; the same as a toolbar button (ui/toolbar-panel.rkt); otherwise the canvas would keep
    ;; keyboard focus after a click, and typing would go nowhere.
    (define/public (activate! s)
      (when (and s (seg-view-command s)) (run-command/safe (seg-view-command s)))
      (run-hook 'focus-editor))

    (define (set-hover! s)
      (define name (and s (seg-view-command s) (seg-view-name s)))
      (unless (eq? name hover)
        (set! hover name)
        (run-hook 'echo (if s (or (seg-view-hint s) "") ""))
        (refresh)))

    (define (move-focus! delta)
      (define cs (clickable-segments))
      (cond
        [(null? cs) (set! focused #f)]
        [(not focused) (set! focused (seg-view-name (if (> delta 0) (car cs) (last cs))))]
        [else
         (define names (map seg-view-name cs))
         (define i (or (index-of names focused) 0))
         (set! focused (list-ref names (modulo (+ i delta) (length names))))]))

    (define/override (on-paint)
      (define dc (get-dc)) (define w (get-width)) (define h (get-height))
      (render-status dc w h (current-model) hover focused))

    (define/override (on-event e)
      (case (send e get-event-type)
        [(motion enter) (set-hover! (hit-test (send e get-x) (send e get-y)))]
        [(leave) (set-hover! #f)]
        [(left-down) (activate! (hit-test (send e get-x) (send e get-y)))]
        [else (super on-event e)]))

    (define/override (on-char e)
      (case (send e get-key-code)
        [(left) (move-focus! -1) (refresh)]
        [(right) (move-focus! 1) (refresh)]
        [(#\return #\newline numpad-enter)
         (define cs (clickable-segments))
         (activate! (and focused (findf (lambda (s) (eq? (seg-view-name s) focused)) cs)))]
        [else (super on-char e)]))))
