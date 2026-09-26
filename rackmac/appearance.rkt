#lang racket/base
;; Appearance (#254, macOS part): which theme the editor uses, and when it changes. The
;; `editor-theme` setting is System (follow macOS), Light or Dark; RACKMAC_THEME still forces
;; one. The system appearance is re-read when the window is activated, so switching macOS
;; to Dark while Rackmac is in the background restyles it once on return. docs/UI-DESIGN.md §5.3.
(require racket/class racket/gui/base
         "settings.rkt" "theme.rkt" "hook.rkt" "editor.rkt" "frame.rkt")
(provide desired-theme refresh-appearance! editor-themes appearance-detector)

(define editor-themes '(system light dark))

(define-setting editor-theme
  #:contract (lambda (v) (and (memq v editor-themes) #t))
  #:default 'system
  #:category "Appearance"
  #:doc "Editor theme: follow the system appearance, or always Light or Dark.")

;; How the system appearance is read: a parameter so tests can stand in for macOS.
(define appearance-detector (make-parameter detect-theme))

;; The theme the editor should show now. `detect` and `forced` are arguments so tests can
;; stand in for macOS and the environment.
(define (desired-theme #:detect [detect (appearance-detector)]
                       #:forced [forced (getenv "RACKMAC_THEME")])
  (define choice (setting-ref 'editor-theme))
  (cond
    [(and forced (memq (string->symbol forced) '(light dark))) (string->symbol forced)]
    [(eq? choice 'system) (let ([d (detect)]) (if (memq d '(light dark)) d 'light))]
    [else choice]))

;; Apply the desired theme. Restyles and fires 'theme-changed only on a real change, so the
;; frequent activation checks cost nothing. Returns #t when the theme changed.
(define (refresh-appearance! #:detect [detect (appearance-detector)]
                             #:forced [forced (getenv "RACKMAC_THEME")])
  (define want (desired-theme #:detect detect #:forced forced))
  (cond
    [(eq? want (current-theme-name)) #f]
    [else
     (set-theme! want)
     (for ([b (in-list (all-buffers))]) (send b rehighlight!))
     (run-hook 'theme-changed)
     #t]))

(add-hook! 'window-activated (lambda () (refresh-appearance!)))
(add-hook! 'setting-changed
           (lambda (name . _) (when (eq? name 'editor-theme) (refresh-appearance!))))

;; View > Editor Theme ▸ System / Light / Dark, the current choice checked.
(define (populate! m)
  (define current (setting-ref 'editor-theme))
  (for ([choice (in-list editor-themes)]
        [label (in-list '("Use System Setting" "Light" "Dark"))])
    (new checkable-menu-item% [label label] [parent m] [checked (eq? choice current)]
         [callback (lambda (i e) (setting-set! 'editor-theme choice))])))

(register-submenu! "Editor Theme" #:menu "View" #:menu-order 22 populate!)
