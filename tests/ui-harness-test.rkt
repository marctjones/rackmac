#lang racket/base
;; Painted surfaces as a person sees them (#255): each rendered headless at 1x and 2x, light and
;; dark, then checked for its ground color, visible ink and readable contrast. Run with
;; RACKMAC_TOUR_DIR=<dir> to also write the renderings as PNGs.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base
         "ui-harness.rkt" "../rackmac/ui/tokens.rkt" "../rackmac/ui/status-bar.rkt"
         "../rackmac/ui/icons.rkt" "../rackmac/commands.rkt")

(define (name-of what app scale) (format "~a-~a-~ax" what app (inexact->exact scale)))

(test-case "harness: a 2x bitmap has four times the device pixels, and pixels read back"
  (define one (render-bitmap 10 10 void #:background (hex->color "#123456")))
  (define two (render-bitmap 10 10 void #:scale 2.0 #:background (hex->color "#123456")))
  (check-equal? (apply + (hash-values (bitmap-colors two))) (* 4 (apply + (hash-values (bitmap-colors one)))))
  (check-equal? (bitmap-pixel-hex two 5 5) "#123456")
  (check-equal? (dominant-color one) "#123456"))

(test-case "status bar: paper-sunk ground, readable message and segments, both appearances, 1x and 2x"
  (for* ([app appearances] [scale scales])
    (with-appearance app
      (lambda ()
        (define model (list (seg-view 'message "Saved" #f #f 0) (seg-view 'words "214 words" #f #f 4)
                            (seg-view 'lang "Markdown" 'set-language #f 3)))
        (define bm (render-bitmap 600 22 (lambda (dc) (render-status dc 600 22 model #f)) #:scale scale))
        (write-tour-png! (name-of "status" app scale) bm)
        (check-equal? (dominant-color bm) (token-hex 'status-bg app) (name-of "status ground" app scale))
        (check-true (>= (ink-contrast bm (token-hex 'status-bg app)) 4.5)
                    (format "~a: text contrast ~a" (name-of "status" app scale)
                            (real->decimal-string (ink-contrast bm (token-hex 'status-bg app)) 2)))))))

(test-case "a note renders on paper with readable text, both appearances, 1x and 2x"
  (for* ([app appearances] [scale scales])
    (with-appearance app
      (lambda ()
        (define bm (render-document "# Call notes\n\nThe tenant accepts the schedule in Exhibit B.\n"
                                    'markdown-mode #:scale scale))
        (write-tour-png! (name-of "note" app scale) bm)
        (check-equal? (dominant-color bm) (token-hex 'surface app) (name-of "note ground" app scale))
        (check-true (>= (ink-contrast bm (token-hex 'surface app)) 4.5) (name-of "note text" app scale))))))

(test-case "a code document renders with its syntax colors visible, both appearances"
  (for ([app appearances])
    (with-appearance app
      (lambda ()
        (define bm (render-document ";; a comment\n(define x \"text\")\n" 'racket-mode #:scale 2.0))
        (write-tour-png! (name-of "code" app 2.0) bm)
        (define colors (bitmap-colors bm))
        (check-true (hash-has-key? colors (token-hex 'keyword app)) (format "~a: keyword color drawn" app))
        (check-true (hash-has-key? colors (token-hex 'string app)) (format "~a: string color drawn" app))))))

(test-case "every icon is visible on the editor surface in both appearances (3:1 for graphics)"
  (for* ([app appearances] [n (icon-names)])
    (with-appearance app
      (lambda ()
        (define bm (render-bitmap 16 16 (lambda (dc) (send dc draw-bitmap (icon-bitmap n #:scale 2.0 #:color (token 'text)) 0 0))
                                  #:scale 2.0 #:background (token 'surface)))
        (check-true (>= (ink-contrast bm (token-hex 'surface app)) 3.0) (format "~a icon ~a" app n))))))
