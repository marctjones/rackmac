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
    (check-true (>= (ratio 'accent bg app) 3.0) (format "~a: accent on ~a" app bg))))

(test-case "Skeptical Engineering: paper ground and moss the one accent, whatever the OS accent is"
  (check-equal? (token-hex 'surface 'light) "#F8F8F6" "paper")
  (check-equal? (token-hex 'surface 'dark) "#1C1C1C" "paper, dark")
  (check-equal? (token-hex 'accent 'light) "#4A7C4A" "moss")
  (check-equal? (token-hex 'accent 'dark) "#80A080" "moss, dark")
  (check-equal? (token-hex 'success 'light) (token-hex 'keyword 'light) "moss-ink carries both"))

(test-case "the workbench is the same in both appearances, and its text is readable on it"
  (for ([r '(bench-heading bench-text bench-rule)])
    (check-equal? (token-hex r 'light) (token-hex r 'dark) (format "~a" r)))
  (for* ([app '(light dark)] [r '(bench-heading bench-text)])
    (check-true (>= (ratio r 'bench app) 4.5) (format "~a: ~a on bench" app r))))

(test-case "switching appearance changes the editor colors"
  (define before (current-theme-name))
  (set-theme! 'light)
  (check-equal? (color->hex (canvas-background)) "#F8F8F6")
  (check-equal? (color->hex (theme-color 'fg)) (token-hex 'text 'light))
  (set-theme! 'dark)
  (check-equal? (color->hex (canvas-background)) "#1C1C1C")
  (check-eq? (current-theme-name) 'dark)
  (check-exn exn:fail? (lambda () (set-theme! 'purple)))
  (set-theme! before))

(test-case "unknown roles are an error, not a silent default"
  (check-exn exn:fail? (lambda () (token 'no-such-role))))
