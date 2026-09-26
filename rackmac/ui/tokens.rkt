#lang racket/base
;; Design tokens: colors by ROLE for the surfaces Rackmac paints itself (editor, status
;; bar, gutter, icons, and later the Library sidebar), in light ("Paper") and dark
;; ("Bench"). Native controls keep the OS look and are not colored from here. The values
;; come from the Skeptical Engineering design system (skepticalengineering-design,
;; tokens/tokens.json); the comment on each light value names its source token, and the
;; dark value is the same token's dark variant. See docs/UI-DESIGN.md section 1.2.
(require racket/class racket/gui/base racket/list)
(provide token token-hex roles current-appearance set-appearance!
         hex->color color->hex contrast-ratio)

(define palettes
  (hash
   'light (hash 'surface "#F8F8F6"          ; paper
                'text "#2A2A28"             ; ink-body
                'text-2 "#686860"           ; ink-quiet: the lightest text that still passes 4.5:1
                'text-disabled "#888880"    ; ink-label
                'stroke "#DCDCD4"           ; rule
                'line-highlight "#EFEFE9"   ; paper-sunk
                'selection "#D5E3D3"        ; moss over paper (text% itself draws the OS color)
                'accent "#4A7C4A"           ; moss: the one accent
                'match "#EDE3B8"            ; ochre family, chosen so text stays above 4.5:1
                'match-current "#D9C77E"
                'info "#505048"             ; ink-muted: the system has no blue
                'success "#3A5C3A"          ; moss-ink
                'warning "#6A6030"          ; ochre-ink
                'error "#7A3526"            ; rust-ink
                'status-bg "#EFEFE9"        ; paper-sunk
                ;; syntax faces: one restrained hue family each
                'comment "#686860"          ; ink-quiet, drawn italic
                'string "#6A6030"           ; ochre-ink
                'constant "#505048"         ; ink-muted
                'keyword "#3A5C3A"          ; moss-ink
                'heading "#1C1C1C"          ; ink, drawn bold
                'face-error "#7A3526"       ; rust-ink
                ;; the workbench (Library sidebar): the same in both appearances by intent
                'bench "#1C1C1C" 'bench-heading "#E0E0D8" 'bench-text "#A0A090" 'bench-rule "#505048")
   'dark  (hash 'surface "#1C1C1C" 'text "#C8C8C0" 'text-2 "#909088" 'text-disabled "#808078"
                'stroke "#3A3A36" 'line-highlight "#242422" 'selection "#2F4430"
                'accent "#80A080" 'match "#4A4424" 'match-current "#5A4E20"
                'info "#A0A090" 'success "#A0C0A0" 'warning "#D8C890" 'error "#E0A090"
                'status-bg "#242422"
                'comment "#909088" 'string "#D8C890" 'constant "#A0A090" 'keyword "#A0C0A0"
                'heading "#E0E0D8" 'face-error "#E0A090"
                'bench "#141413" 'bench-heading "#E0E0D8" 'bench-text "#A0A090" 'bench-rule "#505048")))

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

;; A role's color as "#RRGGBB" in `appearance`. The accent is always moss: the design
;; system has one accent, so the OS highlight color is no longer borrowed for it.
(define (token-hex role [appearance current-appearance])
  (hash-ref (hash-ref palettes appearance) role (lambda () (raise-argument-error 'token "a known role" role))))

(define (token role [appearance current-appearance]) (hex->color (token-hex role appearance)))
