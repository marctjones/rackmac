#lang racket/base
;; Appearance (#254, macOS part): the Editor Theme setting (System / Light / Dark), RACKMAC_THEME
;; forcing a theme, the system appearance re-read when the window is activated, and
;; 'theme-changed firing once per real change. The OS is stood in for by appearance-detector.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file
         "../rackmac/appearance.rkt" "../rackmac/settings.rkt" "../rackmac/theme.rkt"
         "../rackmac/hook.rkt" "../rackmac/frame.rkt" "../rackmac/commands.rkt" "../rackmac/command.rkt")

(void (putenv "RACKMAC_HOME" (path->string (make-temporary-file "rackmac-appearance~a" 'directory))))
(define f (make-main-frame))                 ; hidden: show is never called
(define changes 0)
(add-hook! 'theme-changed (lambda () (set! changes (add1 changes))))
(define (reset! theme) (setting-set! 'editor-theme 'system)
  (parameterize ([appearance-detector (lambda () theme)]) (refresh-appearance! #:forced #f))
  (set! changes 0))

(test-case "System follows the detected appearance; Light and Dark ignore it"
  (setting-set! 'editor-theme 'system)
  (check-eq? (desired-theme #:detect (lambda () 'dark) #:forced #f) 'dark)
  (check-eq? (desired-theme #:detect (lambda () 'light) #:forced #f) 'light)
  (setting-set! 'editor-theme 'light)
  (check-eq? (desired-theme #:detect (lambda () 'dark) #:forced #f) 'light)
  (setting-set! 'editor-theme 'dark)
  (check-eq? (desired-theme #:detect (lambda () 'light) #:forced #f) 'dark)
  (setting-set! 'editor-theme 'system))

(test-case "RACKMAC_THEME still forces a theme, over the setting and the system"
  (setting-set! 'editor-theme 'light)
  (check-eq? (desired-theme #:detect (lambda () 'light) #:forced "dark") 'dark)
  (check-eq? (desired-theme #:detect (lambda () 'dark) #:forced "light") 'light)
  (check-eq? (desired-theme #:detect (lambda () 'dark) #:forced "purple") 'light "an unknown value is ignored")
  (setting-set! 'editor-theme 'system))

(test-case "a bad setting value is refused (reported, not raised) and the theme is unchanged"
  (setting-set! 'editor-theme 'purple)
  (check-eq? (setting-ref 'editor-theme) 'system))

(test-case "'theme-changed fires once per real change, never for a no-op refresh"
  (reset! 'light)
  (parameterize ([appearance-detector (lambda () 'dark)])
    (check-true (refresh-appearance! #:forced #f))
    (check-false (refresh-appearance! #:forced #f) "second check: nothing changed"))
  (check-eq? (current-theme-name) 'dark)
  (check-equal? changes 1))

(test-case "activating the window re-reads the system appearance"
  (reset! 'light)
  (parameterize ([appearance-detector (lambda () 'dark)])
    (send f on-activate #t))
  (check-eq? (current-theme-name) 'dark "macOS went dark while Rackmac was in the background")
  (check-equal? changes 1)
  (parameterize ([appearance-detector (lambda () 'dark)])
    (send f on-activate #t) (send f on-activate #f))
  (check-equal? changes 1 "no change, no restyle"))

(test-case "choosing Light or Dark in the setting restyles at once; System goes back to following"
  (reset! 'light)
  (parameterize ([appearance-detector (lambda () 'light)])
    (setting-set! 'editor-theme 'dark)
    (check-eq? (current-theme-name) 'dark)
    (setting-set! 'editor-theme 'system)
    (check-eq? (current-theme-name) 'light)))

(test-case "Toggle Dark/Light Theme records an explicit choice opposite to what is showing"
  (reset! 'light)
  (parameterize ([appearance-detector (lambda () 'light)])
    (run-command 'toggle-theme)
    (check-eq? (setting-ref 'editor-theme) 'dark)
    (check-eq? (current-theme-name) 'dark)
    (run-command 'toggle-theme)
    (check-eq? (setting-ref 'editor-theme) 'light)
    (setting-set! 'editor-theme 'system)))

(test-case "View > Editor Theme lists the three choices with the current one checked"
  (setting-set! 'editor-theme 'dark)
  (define m (menu-for-title "Editor Theme"))
  (check-true (and m #t) "the submenu exists")
  (send m on-demand)
  (define items (send m get-items))
  (check-equal? (map (lambda (i) (send i get-label)) items) '("Use System Setting" "Light" "Dark"))
  (check-equal? (map (lambda (i) (send i is-checked?)) items) '(#f #f #t))
  (setting-set! 'editor-theme 'system))
