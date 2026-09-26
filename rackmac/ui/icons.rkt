#lang racket/base
;; Line icons from the Skeptical Engineering Workbench set: drafting-style strokes (1.5 units
;; on a 24-unit grid, square caps, miter joins) vendored as outlined shapes in
;; workbench-icons.rktd (tools/workbench-icons.rkt). They are filled into bitmaps at the
;; display's backing scale so they are crisp on Retina and 200% Windows displays.
;; docs/UI-DESIGN.md section 1.5.
(require racket/class racket/draw racket/math racket/list racket/runtime-path)
(provide icon-bitmap letter-tile-bitmap icon-names icon-name? icon-source path->dc-path)

(define-runtime-path data-path "workbench-icons.rktd")

;; name -> (cons workbench-name path-string)
(define icons
  (for/hash ([e (in-list (call-with-input-file data-path read))])
    (values (car e) (cons (cadr e) (caddr e)))))

(define (icon-names) (sort (hash-keys icons) string<?))
(define (icon-name? s) (hash-has-key? icons s))
;; The Workbench icon a Rackmac icon name is drawn from (for docs and tests).
(define (icon-source name) (car (hash-ref icons name)))

;; ---- outlined SVG paths --------------------------------------------------
;; The vendored paths use absolute M L Q C A Z only. Q becomes a cubic; A becomes cubics
;; through the SVG spec's endpoint-to-center conversion (SVG 1.1 appendix F.6.5).

(define (tokenize s)
  (for/list ([t (in-list (regexp-match* #px"[A-Za-z]|-?[0-9]*\\.?[0-9]+(?:e-?[0-9]+)?" s))])
    (if (char-alphabetic? (string-ref t 0)) (string->symbol t) (string->number t))))

(define (arc->cubics x1 y1 rx ry phi-deg large? sweep? x2 y2)
  (define phi (degrees->radians phi-deg))
  (define c (cos phi)) (define s (sin phi))
  (define dx (/ (- x1 x2) 2.0)) (define dy (/ (- y1 y2) 2.0))
  (define x1p (+ (* c dx) (* s dy))) (define y1p (+ (* (- s) dx) (* c dy)))
  ;; Radii too small to reach the end point are scaled up, as the spec says.
  (define lam (+ (/ (sqr x1p) (sqr rx)) (/ (sqr y1p) (sqr ry))))
  (define rx* (if (> lam 1) (* (abs rx) (sqrt lam)) (abs rx)))
  (define ry* (if (> lam 1) (* (abs ry) (sqrt lam)) (abs ry)))
  (define num (- (* (sqr rx*) (sqr ry*)) (* (sqr rx*) (sqr y1p)) (* (sqr ry*) (sqr x1p))))
  (define den (+ (* (sqr rx*) (sqr y1p)) (* (sqr ry*) (sqr x1p))))
  (define k (* (if (eq? large? sweep?) -1 1) (sqrt (max 0 (/ num den)))))
  (define cxp (* k (/ (* rx* y1p) ry*))) (define cyp (* k (- (/ (* ry* x1p) rx*))))
  (define cx (+ (* c cxp) (* (- s) cyp) (/ (+ x1 x2) 2))) (define cy (+ (* s cxp) (* c cyp) (/ (+ y1 y2) 2)))
  (define (angle ux uy vx vy)
    (define cosv (/ (+ (* ux vx) (* uy vy)) (* (sqrt (+ (sqr ux) (sqr uy))) (sqrt (+ (sqr vx) (sqr vy))))))
    (define a (acos (max -1.0 (min 1.0 cosv))))
    (if (< (- (* ux vy) (* uy vx)) 0) (- a) a))
  (define ux (/ (- x1p cxp) rx*)) (define uy (/ (- y1p cyp) ry*))
  (define t1 (angle 1 0 ux uy))
  (define dt0 (angle ux uy (/ (- (- x1p) cxp) rx*) (/ (- (- y1p) cyp) ry*)))
  (define dt (cond [(and (not sweep?) (> dt0 0)) (- dt0 (* 2 pi))] [(and sweep? (< dt0 0)) (+ dt0 (* 2 pi))] [else dt0]))
  (define n (max 1 (exact-ceiling (/ (abs dt) (/ pi 2)))))
  (define step (/ dt n))
  (define alpha (* 4/3 (tan (/ step 4))))
  (define (pt t) (values (- (+ cx (* rx* c (cos t))) (* ry* s (sin t))) (+ cy (* rx* s (cos t)) (* ry* c (sin t)))))
  (define (deriv t) (values (- (* (- rx*) c (sin t)) (* ry* s (cos t))) (+ (* (- rx*) s (sin t)) (* ry* c (cos t)))))
  (for/list ([i (in-range n)])
    (define a (+ t1 (* i step))) (define b (+ a step))
    (define-values (ax ay) (pt a)) (define-values (bx by) (pt b))
    (define-values (adx ady) (deriv a)) (define-values (bdx bdy) (deriv b))
    (list (+ ax (* alpha adx)) (+ ay (* alpha ady)) (- bx (* alpha bdx)) (- by (* alpha bdy)) bx by)))

;; A dc-path% for an outlined path string. Fill it with 'winding (SVG's nonzero rule).
(define (path->dc-path s)
  (define p (new dc-path%))
  (define (curve! seg) (send p curve-to (list-ref seg 0) (list-ref seg 1) (list-ref seg 2)
                             (list-ref seg 3) (list-ref seg 4) (list-ref seg 5)))
  ;; (x, y) is the current point, (sx, sy) the start of the subpath, where Z returns to.
  (let loop ([ts (tokenize s)] [x 0.0] [y 0.0] [sx 0.0] [sy 0.0])
    (unless (null? ts)
      (define (arg i) (list-ref ts (add1 i)))
      (define (rest k) (drop ts (add1 k)))
      (case (car ts)
        [(M) (send p move-to (arg 0) (arg 1)) (loop (rest 2) (arg 0) (arg 1) (arg 0) (arg 1))]
        [(L) (send p line-to (arg 0) (arg 1)) (loop (rest 2) (arg 0) (arg 1) sx sy)]
        [(Q) (define-values (qx qy ex ey) (values (arg 0) (arg 1) (arg 2) (arg 3)))
             (curve! (list (+ x (* 2/3 (- qx x))) (+ y (* 2/3 (- qy y)))
                           (+ ex (* 2/3 (- qx ex))) (+ ey (* 2/3 (- qy ey))) ex ey))
             (loop (rest 4) ex ey sx sy)]
        [(C) (curve! (for/list ([i 6]) (arg i))) (loop (rest 6) (arg 4) (arg 5) sx sy)]
        [(A) (for-each curve! (arc->cubics x y (arg 0) (arg 1) (arg 2) (= (arg 3) 1) (= (arg 4) 1) (arg 5) (arg 6)))
             (loop (rest 7) (arg 5) (arg 6) sx sy)]
        [(Z) (send p close) (loop (cdr ts) sx sy sx sy)]
        [else (error 'path->dc-path "unsupported path command ~s" (car ts))])))
  p)

(define dc-paths (make-hash))       ; name -> dc-path%, built once

;; ---- bitmaps ------------------------------------------------------------

(define cache (make-hash))

(define (render size scale draw)
  (define bm (make-bitmap size size #t #:backing-scale scale))
  (define dc (new bitmap-dc% [bitmap bm]))
  (send dc set-smoothing 'smoothed)
  (draw dc)
  (send dc set-bitmap #f)
  bm)

(define (color-key c) (list (send c red) (send c green) (send c blue)))

;; A bitmap for icon `name` at `size` logical pixels. Unknown names raise, so a typo in
;; #:icon is caught by the tests rather than showing an empty button.
(define (icon-bitmap name #:size [size 16] #:color [color (make-object color% 40 40 40)] #:scale [scale 1.0])
  (define entry (hash-ref icons name (lambda () (raise-argument-error 'icon-bitmap "a known icon name" name))))
  (hash-ref! cache (list name size (color-key color) scale)
             (lambda ()
               (define p (hash-ref! dc-paths name (lambda () (path->dc-path (cdr entry)))))
               (render size scale
                       (lambda (dc)
                         (send dc set-scale (/ size 24) (/ size 24))
                         (send dc set-pen color 0 'transparent)
                         (send dc set-brush color 'solid)
                         (send dc draw-path p 0 0 'winding))))))

;; For commands without an icon: their initial in a nearly square tile (radius-sm), needed
;; by "Add to Toolbar".
(define (letter-tile-bitmap letter #:size [size 16] #:color [color (make-object color% 40 40 40)] #:scale [scale 1.0])
  (hash-ref! cache (list 'tile letter size (color-key color) scale)
             (lambda ()
               (render size scale
                       (lambda (dc)
                         (send dc set-scale (/ size 16) (/ size 16))
                         (send dc set-pen (new pen% [color color] [width 1] [cap 'projecting] [join 'miter]))
                         (send dc set-brush "white" 'transparent)
                         (send dc draw-rounded-rectangle 1.5 1.5 13 13 2)
                         (send dc set-font (make-font #:size 9 #:weight 'bold #:size-in-pixels? #t))
                         (send dc set-text-foreground color)
                         (define-values (w h d a) (send dc get-text-extent letter))
                         (send dc draw-text letter (/ (- 16 w) 2) (/ (- 16 h) 2)))))))
