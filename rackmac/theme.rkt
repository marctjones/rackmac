#lang racket/base
;; Light/dark colors, the editor font, and applying them to the shared style list.
(require racket/class racket/gui/base racket/list racket/port racket/system "ui/tokens.rkt")
(provide theme-color current-theme-name set-theme! toggle-theme! detect-theme
         font-size set-font-size! default-font-size apply-base-style! canvas-background editor-style-list)

; Colors come from ui/tokens.rkt (roles); this module keeps the editor font and style list.
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

(set-appearance! (let ([d (detect-theme)]) (if (memq d '(light dark)) d 'light)))
(define (current-theme-name) current-appearance)
(define (set-theme! name) (set-appearance! name) (apply-base-style!))
(define (toggle-theme!) (set-theme! (if (eq? current-appearance 'dark) 'light 'dark)))

;; Old names used by the highlighter: bg/fg are the surface/text roles, error is a face.
(define (theme-color key)
  (token (case key [(bg) 'surface] [(fg) 'text] [(error) 'face-error] [else key])))

(define (canvas-background) (token 'surface))

;; The zoom percentage segment in the status bar is font-size / (default-font-size).
(define (default-font-size) (if (eq? (system-type 'os) 'macosx) 14 12))
(define font-size (default-font-size))
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
