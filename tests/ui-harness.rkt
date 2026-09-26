#lang racket/base
;; Headless UI harness (#255, docs/UI-DESIGN.md §5.4): render painted surfaces to bitmaps at 1x
;; and 2x in light and dark, read pixels back, and measure what a person would see (background,
;; ink, contrast). No window is ever shown. Set RACKMAC_TOUR_DIR to also write each rendering
;; as a PNG for a person to look at (the "scripted tour"); tests never compare against
;; golden images, because font rasterization differs between machines.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require racket/class racket/gui/base racket/list
         "../rackmac/ui/tokens.rkt" "../rackmac/theme.rkt" "../rackmac/editor.rkt")
(provide render-bitmap bitmap-pixel-hex bitmap-colors dominant-color ink-contrast
         render-document with-appearance appearances scales write-tour-png!)

(define appearances '(light dark))
(define scales '(1.0 2.0))

;; A w x h (logical) bitmap at `scale`, cleared to `background`, drawn by (draw dc).
(define (render-bitmap w h draw #:scale [scale 1.0] #:background [background #f])
  (define bm (make-bitmap w h #f #:backing-scale scale))
  (define dc (new bitmap-dc% [bitmap bm]))
  (send dc set-smoothing 'smoothed)
  (when background (send dc set-background background) (send dc clear))
  (draw dc)
  (send dc set-bitmap #f)
  bm)

;; Every device pixel as "#RRGGBB", with its count.
(define (bitmap-colors bm)
  (define scale (send bm get-backing-scale))
  (define pw (inexact->exact (ceiling (* scale (send bm get-width)))))
  (define ph (inexact->exact (ceiling (* scale (send bm get-height)))))
  (define buf (make-bytes (* 4 pw ph)))
  (send bm get-argb-pixels 0 0 pw ph buf #f #f #:unscaled? #t)
  (for/fold ([h (hash)]) ([i (in-range 0 (bytes-length buf) 4)])
    (hash-update h (rgb->hex (bytes-ref buf (+ i 1)) (bytes-ref buf (+ i 2)) (bytes-ref buf (+ i 3))) add1 0)))

(define (rgb->hex r g b)
  (string-upcase (apply string-append "#" (for/list ([v (list r g b)])
                                            (let ([s (number->string v 16)]) (if (= 1 (string-length s)) (string-append "0" s) s))))))

;; The color at logical (x, y).
(define (bitmap-pixel-hex bm x y)
  (define scale (send bm get-backing-scale))
  (define buf (make-bytes 4))
  (send bm get-argb-pixels (inexact->exact (floor (* scale x))) (inexact->exact (floor (* scale y))) 1 1 buf #f #f
        #:unscaled? #t)
  (rgb->hex (bytes-ref buf 1) (bytes-ref buf 2) (bytes-ref buf 3)))

(define (dominant-color bm)
  (car (argmax cdr (hash->list (bitmap-colors bm)))))

;; The strongest contrast between any drawn pixel and `bg-hex`: for antialiased text this is
;; the text's own color against the ground, i.e. what the reader sees at the glyph cores.
(define (ink-contrast bm bg-hex)
  (for/fold ([best 1.0]) ([c (in-hash-keys (bitmap-colors bm))])
    (max best (contrast-ratio c bg-hex))))

;; A document of `text` in Language `mode`, drawn by the editor itself (print-to-dc), on the
;; editor surface. The document needs an editor admin, so an unshown frame hosts it.
(define (render-document text mode #:width [w 640] #:height [h 240] #:scale [scale 1.0])
  (define b (new-buffer! "harness" #:mode mode))
  (send b insert text)
  (send b rehighlight!)
  (new editor-canvas% [parent (new frame% [label "harness"])] [editor b])   ; never shown
  (send b set-max-width (- w 32))
  (render-bitmap w h (lambda (dc) (send b print-to-dc dc 1)) #:scale scale #:background (token 'surface)))

(define (with-appearance app thunk)
  (define before (current-theme-name))
  (dynamic-wind (lambda () (set-theme! app)) thunk (lambda () (set-theme! before))))

(define (write-tour-png! name bm)
  (define dir (getenv "RACKMAC_TOUR_DIR"))
  (when dir
    (make-directory* dir)
    (send bm save-file (build-path dir (string-append name ".png")) 'png)))

(define (make-directory* d) (unless (directory-exists? d) (make-directory d)))
