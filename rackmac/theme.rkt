#lang racket/base
;; Light/dark colors, the editor font, and applying them to the shared style list.
(require racket/class racket/gui/base racket/list racket/port racket/system)
(provide theme-color current-theme-name set-theme! toggle-theme! detect-theme
         font-size set-font-size! apply-base-style! canvas-background editor-style-list)

(define themes
  (hash 'light (hash 'bg "#FFFFFF" 'fg "#1F2328" 'comment "#6E7781" 'string "#0A7B34"
                     'constant "#0550AE" 'keyword "#8250DF" 'error "#CF222E" 'heading "#0550AE")
        'dark  (hash 'bg "#1E1E1E" 'fg "#D4D4D4" 'comment "#7C8B91" 'string "#CE9178"
                     'constant "#B5CEA8" 'keyword "#C586C0" 'error "#F44747" 'heading "#4FC1FF")))

(define (mac-dark-mode?)
  ;; `AppleInterfaceStyle` is "Dark" in dark mode and absent in light mode.
  (with-handlers ([exn:fail? (lambda (e) #f)])        ; no `defaults` command: assume light
    (regexp-match? #rx"^Dark"
                   (with-output-to-string
                     (lambda () (parameterize ([current-error-port (open-output-nowhere)])
                                  (system* "/usr/bin/defaults" "read" "-g" "AppleInterfaceStyle")))))))

(define (detect-theme)
  (cond [(getenv "RACKMAC_THEME") => string->symbol]
        [(eq? (system-type 'os) 'macosx) (if (mac-dark-mode?) 'dark 'light)]
        [else
         (define c (get-panel-background))
         (if (< (+ (send c red) (send c green) (send c blue)) 384) 'dark 'light)]))

(define current-theme-name (detect-theme))
(define (set-theme! name) (set! current-theme-name name) (apply-base-style!))
(define (toggle-theme!) (set-theme! (if (eq? current-theme-name 'dark) 'light 'dark)))

(define (theme-color key)
  (define hex (hash-ref (hash-ref themes current-theme-name) key))
  (define n (string->number (substring hex 1) 16))
  (make-object color% (quotient n 65536) (modulo (quotient n 256) 256) (modulo n 256)))

(define (canvas-background) (theme-color 'bg))

(define font-size (if (eq? (system-type 'os) 'macosx) 14 12))
(define (set-font-size! n) (set! font-size (max 8 (min 48 n))) (apply-base-style!))

(define face
  (case (system-type 'os) [(macosx) "Menlo"] [(windows) "Consolas"] [else "DejaVu Sans Mono"]))

;; All buffers share one style list whose "Standard" style holds the base font and
;; foreground; changing its delta restyles every open buffer at once.
(define editor-style-list (new style-list%))
(define standard-style
  (send editor-style-list new-named-style "Standard"
        (send editor-style-list find-or-create-style
              (send editor-style-list basic-style) (make-object style-delta%))))

(define (apply-base-style!)
  (define d (make-object style-delta%))
  (send d set-delta-face face 'modern)
  (send d set-size-mult 0.0)
  (send d set-size-add font-size)
  (send d set-delta-foreground (theme-color 'fg))
  (send standard-style set-delta d))

(apply-base-style!)
