#lang racket/base
;; Design tokens: both appearances define every role, and the colors are readable
;; (WCAG AA: 4.5:1 for text, 3:1 for the accent), so a palette edit cannot quietly
;; make text hard to read.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/list racket/class
         "../rackmac/ui/tokens.rkt" "../rackmac/theme.rkt")

(define (ratio fg bg app) (contrast-ratio (token-hex fg app) (token-hex bg app)))
(define text-roles '(text text-2 comment string constant keyword heading face-error))
(define status-roles '(text text-2 info success warning error))

(test-case "contrast-ratio matches known values"
  (check-= (contrast-ratio "#000000" "#FFFFFF") 21.0 0.01)
  (check-= (contrast-ratio "#FFFFFF" "#FFFFFF") 1.0 0.001)
  (check-= (contrast-ratio "#767676" "#FFFFFF") 4.54 0.02 "the classic AA-passing grey"))

(test-case "every role exists in light and dark"
  (for* ([app '(light dark)] [r (roles)])
    (check-true (regexp-match? #px"^#[0-9A-F]{6}$" (token-hex r app)) (format "~a ~a" app r))))

(test-case "editor text and syntax colors are readable on the editor surface (4.5:1)"
  (for* ([app '(light dark)] [r text-roles])
    (check-true (>= (ratio r 'surface app) 4.5)
                (format "~a: ~a on surface is ~a:1" app r (real->decimal-string (ratio r 'surface app) 2)))))

(test-case "status bar text and severity colors are readable on the status bar (4.5:1)"
  (for* ([app '(light dark)] [r status-roles])
    (check-true (>= (ratio r 'status-bg app) 4.5)
                (format "~a: ~a on status-bg is ~a:1" app r (real->decimal-string (ratio r 'status-bg app) 2)))))

(test-case "text stays readable on find-match highlights (4.5:1)"
  (for* ([app '(light dark)] [bg '(match match-current)])
    (check-true (>= (ratio 'text bg app) 4.5) (format "~a: text on ~a" app bg))))

(test-case "the accent is visible on the surface and status bar (3:1)"
  (for* ([app '(light dark)] [bg '(surface status-bg)])
    (parameterize ([current-os-accent (lambda () #f)])
      (check-true (>= (ratio 'accent bg app) 3.0) (format "~a: accent on ~a" app bg)))))

(test-case "the OS accent is used only when it is readable"
  (parameterize ([current-os-accent (lambda () "#B3D7FF")])        ; macOS default: pale selection blue
    (check-equal? (token-hex 'accent 'light) "#0067C0" "too pale on white: fallback"))
  (parameterize ([current-os-accent (lambda () "#8E24AA")])        ; a strong purple accent
    (check-equal? (token-hex 'accent 'light) "#8E24AA" "readable: the user's accent wins")))

(test-case "switching appearance changes the editor colors"
  (define before (current-theme-name))
  (set-theme! 'light)
  (check-equal? (color->hex (canvas-background)) "#FFFFFF")
  (check-equal? (color->hex (theme-color 'fg)) (token-hex 'text 'light))
  (set-theme! 'dark)
  (check-equal? (color->hex (canvas-background)) "#1E1E1E")
  (check-eq? (current-theme-name) 'dark)
  (check-exn exn:fail? (lambda () (set-theme! 'purple)))
  (set-theme! before))

(test-case "unknown roles are an error, not a silent default"
  (check-exn exn:fail? (lambda () (token 'no-such-role))))
