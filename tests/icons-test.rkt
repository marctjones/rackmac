#lang racket/base
;; Icons: every menu command has one from the drawn set, each icon renders visible pixels
;; at 1x and 2x, icons are distinguishable from each other, and the Workbench outlines are
;; interpreted as SVG would draw them. All headless (bitmaps).
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/draw racket/list racket/string
         "../rackmac/ui/icons.rkt" "../rackmac/commands.rkt" "../rackmac/command.rkt")

(define (pixels bm)
  (define w (send bm get-width)) (define h (send bm get-height))
  (define scale (send bm get-backing-scale))
  (define pw (inexact->exact (ceiling (* w scale)))) (define ph (inexact->exact (ceiling (* h scale))))
  (define buf (make-bytes (* 4 pw ph)))
  (send bm get-argb-pixels 0 0 pw ph buf #f #t)
  buf)
(define (inked bm) (for/sum ([i (in-range 0 (bytes-length (pixels bm)) 4)]) (if (> (bytes-ref (pixels bm) i) 40) 1 0)))

(test-case "every command in a menu has an icon from the drawn set"
  (define missing (for/list ([c (all-commands)] #:when (and (command-menu c) (not (command-icon c)))) (command-name c)))
  (check-equal? missing '() "menu commands without #:icon")
  (for ([c (all-commands)] #:when (command-icon c))
    (check-true (icon-name? (command-icon c)) (format "~a uses unknown icon ~s" (command-name c) (command-icon c)))))

(test-case "every icon draws something, at 1x and at 2x"
  (for* ([n (icon-names)] [scale '(1.0 2.0)])
    (define bm (icon-bitmap n #:scale scale))
    (check-equal? (send bm get-width) 16 "16 logical pixels")
    (check-true (> (inked bm) 4) (format "~a at ~ax is blank" n scale))))

(test-case "2x icons have 4x the pixels (crisp on HiDPI)"
  (check-equal? (bytes-length (pixels (icon-bitmap "save" #:scale 2.0)))
                (* 4 (bytes-length (pixels (icon-bitmap "save" #:scale 1.0))))))

(test-case "icons are distinguishable (no two render identically, aliases aside)"
  (define aliases '(("close" "x") ("find" "search")))
  (define (alias? a b) (for/or ([p aliases]) (and (member a p) (member b p))))
  (define by-image (group-by (lambda (n) (pixels (icon-bitmap n))) (icon-names)))
  (for ([g by-image] #:when (> (length g) 1))
    (check-true (for*/and ([a g] [b g]) (or (equal? a b) (alias? a b))) (format "identical icons: ~a" g))))

(test-case "the requested color is used"
  (define bm (icon-bitmap "run" #:color (make-object color% 200 0 0)))
  (define buf (pixels bm))
  (check-true (for/or ([i (in-range 0 (bytes-length buf) 4)])
                (and (> (bytes-ref buf i) 200) (> (bytes-ref buf (+ i 1)) 150) (< (bytes-ref buf (+ i 2)) 60)))
              "some fully-inked red pixels"))

(test-case "unknown icon names are an error; letter tiles cover commands without icons"
  (check-exn exn:fail? (lambda () (icon-bitmap "no-such-icon")))
  (check-true (> (inked (letter-tile-bitmap "Q")) 10)))

(test-case "bitmaps are cached"
  (check-eq? (icon-bitmap "copy") (icon-bitmap "copy")))

;; ---- the Workbench set and its path interpreter ----------------------------------

(define (bbox d)
  (define-values (x y w h) (send (path->dc-path d) get-bounding-box))
  (list x y w h))
(define (close-to? as bs) (for/and ([a as] [b bs]) (< (abs (- a b)) 0.01)))

(test-case "every icon is drawn from a named Workbench icon"
  (check-equal? (icon-source "run") "play")
  (check-equal? (icon-source "activity") "logbook-moth")
  (for ([n (icon-names)])
    (check-true (string? (icon-source n)) n)))

(test-case "path interpreter: lines, quadratics and SVG arcs land where SVG puts them"
  (check-true (close-to? (bbox "M2,2 L22,2 L22,22 Z") '(2 2 20 20)) "straight lines")
  ;; a quadratic from (0,0) to (24,0) bulging to y=24 becomes a cubic with controls at y=16
  (check-true (close-to? (bbox "M0,0 Q12,24 24,0 Z") '(0 0 24 16)) "quadratic as cubic")
  ;; two half-circle arcs of radius 10 around (12,12): the full circle's box
  (check-true (close-to? (bbox "M2,12 A10 10 0 1 0 22,12 A10 10 0 1 0 2,12 Z") '(2 2 20 20)) "arcs")
  (check-exn exn:fail? (lambda () (path->dc-path "M0,0 T4,4")) "unsupported commands are an error"))
