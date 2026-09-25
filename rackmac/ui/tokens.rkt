#lang racket/base
;; Design tokens: colors by ROLE for the surfaces Rackmac paints itself (editor, status
;; bar, gutter, icons), in light and dark. Native controls keep the OS look and are not
;; colored from here. See docs/UI-DESIGN.md section 1.2.
(require racket/class racket/gui/base racket/list)
(provide token token-hex roles current-appearance set-appearance!
         hex->color color->hex contrast-ratio os-accent current-os-accent)

(define palettes
  (hash
   'light (hash 'surface "#FFFFFF" 'text "#1F2328" 'text-2 "#636C76" 'text-disabled "#A6A6A6"
                'stroke "#D0D7DE" 'line-highlight "#F6F8FA" 'selection "#B3D7FF"
                'accent "#0067C0" 'match "#FFE08A" 'match-current "#FFB000"
                'info "#0067C0" 'success "#0F7B0F" 'warning "#8A5100" 'error "#C42B1C"
                'status-bg (if (eq? (system-type 'os) 'macosx) "#ECECEC" "#F3F3F3")
                ;; syntax faces
                'comment "#6E7781" 'string "#0A7B34" 'constant "#0550AE" 'keyword "#8250DF"
                'heading "#0550AE" 'face-error "#CF222E")
   'dark  (hash 'surface "#1E1E1E" 'text "#D4D4D4" 'text-2 "#9DA5AD" 'text-disabled "#6E6E6E"
                'stroke "#3A3A3A" 'line-highlight "#262626" 'selection "#264F78"
                'accent "#60CDFF" 'match "#6B5900" 'match-current "#7A4000"
                'info "#60CDFF" 'success "#6CCB5F" 'warning "#FCE100" 'error "#FF99A4"
                'status-bg (if (eq? (system-type 'os) 'macosx) "#282828" "#202020")
                'comment "#8B9BA3" 'string "#CE9178" 'constant "#B5CEA8" 'keyword "#C586C0"
                'heading "#4FC1FF" 'face-error "#F44747")))

(define (roles) (sort (hash-keys (hash-ref palettes 'light)) symbol<?))

;; 'light or 'dark. Changed only through set-appearance! (theme.rkt restyles after it).
(define current-appearance 'light)
(define (set-appearance! a)
  (unless (memq a '(light dark)) (raise-argument-error 'set-appearance! "(or/c 'light 'dark)" a))
  (set! current-appearance a))

(define (hex->color hex)
  (define n (string->number (substring hex 1) 16))
  (make-object color% (quotient n 65536) (modulo (quotient n 256) 256) (modulo n 256)))

(define (color->hex c)
  (string-upcase (apply string-append "#" (for/list ([v (list (send c red) (send c green) (send c blue))])
                                            (let ([s (number->string v 16)]) (if (= 1 (string-length s)) (string-append "0" s) s))))))

;; WCAG 2 contrast ratio between two "#RRGGBB" colors (1 to 21).
(define (contrast-ratio a b)
  (define (lum hex)
    (define n (string->number (substring hex 1) 16))
    (define (ch v) (let ([c (/ v 255.0)]) (if (<= c 0.03928) (/ c 12.92) (expt (/ (+ c 0.055) 1.055) 2.4))))
    (+ (* 0.2126 (ch (quotient n 65536))) (* 0.7152 (ch (modulo (quotient n 256) 256))) (* 0.0722 (ch (modulo n 256)))))
  (define-values (hi lo) (let ([x (lum a)] [y (lum b)]) (values (max x y) (min x y))))
  (/ (+ hi 0.05) (+ lo 0.05)))

;; The OS highlight color, when the toolkit reports one.
(define (os-accent)
  (with-handlers ([exn:fail? (lambda (e) #f)]) (color->hex (get-highlight-background-color))))

;; Where the OS accent comes from; a parameter so tests can supply one.
(define current-os-accent (make-parameter os-accent))

;; A role's color as "#RRGGBB" in `appearance`. The accent follows the OS highlight color
;; when that is readable on the surface (3:1); macOS's default highlight is a pale blue
;; selection color that is not, so the fallback is used then.
(define (token-hex role [appearance current-appearance])
  (define p (hash-ref palettes appearance))
  (cond
    [(eq? role 'accent)
     (define os ((current-os-accent)))
     (if (and os (>= (contrast-ratio os (hash-ref p 'surface)) 3.0)) os (hash-ref p 'accent))]
    [else (hash-ref p role (lambda () (raise-argument-error 'token "a known role" role)))]))

(define (token role [appearance current-appearance]) (hex->color (token-hex role appearance)))
