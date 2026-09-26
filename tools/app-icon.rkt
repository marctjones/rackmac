#lang racket/base
;; The Rackmac app icon (#286), a Skeptical Engineering project mark (brand book, "Logos"): a
;; slate rounded tile with paper-coloured content and a single verdigris detail. Here the
;; content is a page of notes with a turned corner, and the verdigris detail is the margin
;; rule of a legal pad. Drawn from one set of shapes on the brand's 128-unit grid (the same
;; tile as the napkin and excise marks), as PNG with racket/draw and as SVG, so the icon is
;; reproducible from this file alone. Small sizes (32 px and under) use a simpler variant:
;; no turned corner, fewer and heavier lines, as napkin-mark-small.svg does.
;;
;;   racket tools/app-icon.rkt iconset DIR   write DIR/icon_16x16.png ... icon_512x512@2x.png
;;                                           (the names iconutil wants; the build makes the .icns)
;;   racket tools/app-icon.rkt assets        rewrite assets/icon/ (SVG masters, 256 px preview)
(require racket/class racket/draw racket/list racket/string racket/file racket/math
         racket/runtime-path)
(provide icon-shapes icon-svg render-icon write-iconset! iconset-entries)

(define-runtime-path assets-dir "../assets/icon")

;; Brand tokens (skepticalengineering-design tokens/tokens.json).
(define slate "#232B36")
(define paper "#F8F8F6")
(define rule "#DCDCD4")          ; the turned corner's underside
(define verdigris "#43BEB0")

;; Shapes on the 128 grid: (rrect x y w h radius colour), (poly ((x . y) ...) colour),
;; (line x1 y1 x2 y2 width colour).
(define (icon-shapes small?)
  (define tile `(rrect 6 6 116 116 26 ,slate))
  (if small?
      (list tile
            `(poly ((28 . 20) (100 . 20) (100 . 108) (28 . 108)) ,paper)
            `(line 44 20 44 108 8 ,verdigris)
            `(line 56 46 90 46 8 ,slate)
            `(line 56 64 90 64 8 ,slate)
            `(line 56 82 78 82 8 ,slate))
      (list tile
            `(poly ((32 . 22) (78 . 22) (96 . 40) (96 . 106) (32 . 106)) ,paper)
            `(poly ((78 . 22) (78 . 40) (96 . 40)) ,rule)
            `(line 44 22 44 106 3 ,verdigris)
            `(line 52 40 70 40 3 ,slate)
            `(line 52 52 88 52 3 ,slate)
            `(line 52 62 88 62 3 ,slate)
            `(line 52 72 84 72 3 ,slate)
            `(line 52 82 88 82 3 ,slate)
            `(line 52 92 74 92 3 ,slate))))

(define (small-size? px) (<= px 32))

(define (hex->color h)
  (define (at i) (string->number (substring h i (+ i 2)) 16))
  (make-color (at 1) (at 3) (at 5)))

;; ---- PNG --------------------------------------------------------------------------------

(define (render-icon px)
  (define bm (make-bitmap px px #t))
  (define dc (new bitmap-dc% [bitmap bm]))
  (send dc set-smoothing 'smoothed)
  (send dc set-scale (/ px 128.0) (/ px 128.0))
  (for ([s (in-list (icon-shapes (small-size? px)))])
    (case (car s)
      [(rrect)
       (define-values (x y w h r c) (apply values (cdr s)))
       (send dc set-pen (hex->color c) 0 'transparent)
       (send dc set-brush (hex->color c) 'solid)
       (send dc draw-rounded-rectangle x y w h r)]
      [(poly)
       (send dc set-pen (hex->color (third s)) 0 'transparent)
       (send dc set-brush (hex->color (third s)) 'solid)
       (send dc draw-polygon (for/list ([p (in-list (second s))]) (cons (car p) (cdr p))))]
      [(line)
       (define-values (x1 y1 x2 y2 w c) (apply values (cdr s)))
       (send dc set-pen (new pen% [color (hex->color c)] [width w] [cap 'butt]))
       (send dc draw-line x1 y1 x2 y2)]))
  (send dc set-bitmap #f)
  bm)

;; iconutil's file names and each one's pixel size.
(define iconset-entries
  (append* (for/list ([pt (in-list '(16 32 128 256 512))])
             (list (cons (format "icon_~ax~a.png" pt pt) pt)
                   (cons (format "icon_~ax~a@2x.png" pt pt) (* 2 pt))))))

(define (write-iconset! dir)
  (make-directory* dir)
  (for ([e (in-list iconset-entries)])
    (void (send (render-icon (cdr e)) save-file (build-path dir (car e)) 'png))))

;; ---- SVG --------------------------------------------------------------------------------

(define (num n) (if (integer? n) (number->string (exact-round n)) (number->string (exact->inexact n))))

(define (icon-svg small?)
  (define body
    (for/list ([s (in-list (icon-shapes small?))])
      (case (car s)
        [(rrect)
         (define-values (x y w h r c) (apply values (cdr s)))
         (format "  <rect x=\"~a\" y=\"~a\" width=\"~a\" height=\"~a\" rx=\"~a\" fill=\"~a\"/>"
                 (num x) (num y) (num w) (num h) (num r) c)]
        [(poly)
         (format "  <path d=\"M~a Z\" fill=\"~a\"/>"
                 (string-join (for/list ([p (in-list (second s))]) (format "~a ~a" (num (car p)) (num (cdr p)))) " L")
                 (third s))]
        [(line)
         (define-values (x1 y1 x2 y2 w c) (apply values (cdr s)))
         (format "  <path d=\"M~a ~a L~a ~a\" stroke=\"~a\" stroke-width=\"~a\"/>"
                 (num x1) (num y1) (num x2) (num y2) c (num w))])))
  (string-append
   "<svg width=\"128\" height=\"128\" viewBox=\"0 0 128 128\" fill=\"none\" xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" aria-label=\"Rackmac\">\n"
   (format "  <title>Rackmac~a</title>\n" (if small? " (16 and 32 px)" ""))
   "  <!-- generated by tools/app-icon.rkt; edit the shapes there -->\n"
   (string-join body "\n")
   "\n</svg>\n"))

(define (write-assets!)
  (make-directory* assets-dir)
  (display-to-file (icon-svg #f) (build-path assets-dir "rackmac-mark.svg") #:exists 'truncate)
  (display-to-file (icon-svg #t) (build-path assets-dir "rackmac-mark-small.svg") #:exists 'truncate)
  (void (send (render-icon 256) save-file (build-path assets-dir "rackmac-256.png") 'png)))

(module+ main
  (define args (current-command-line-arguments))
  (cond
    [(and (= 2 (vector-length args)) (equal? (vector-ref args 0) "iconset"))
     (write-iconset! (vector-ref args 1))]
    [(and (= 1 (vector-length args)) (equal? (vector-ref args 0) "assets"))
     (write-assets!)]
    [else (eprintf "usage: racket tools/app-icon.rkt iconset DIR | assets\n") (exit 1)]))
