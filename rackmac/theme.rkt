#lang racket/base
;; Light/dark colors, the editor font, and applying them to the shared style list.
(require racket/class racket/gui/base racket/list racket/port racket/system "ui/tokens.rkt")
(provide theme-color current-theme-name set-theme! toggle-theme! detect-theme
         font-size set-font-size! default-font-size apply-base-style! canvas-background editor-style-list
         mono-face prose-face ui-face ui-font resolve-face mono-faces prose-faces)

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

;; Faces from the Skeptical Engineering type system (docs/UI-DESIGN.md section 1.3): IBM Plex
;; Mono for code, IBM Plex Serif for prose, IBM Plex Sans for text we paint in the chrome.
;; Plex is used when it is installed; otherwise the first installed fallback, so a machine
;; without Plex still gets a serif page and a monospace code view.
(define mono-faces
  (case (system-type 'os)
    [(macosx) '("IBM Plex Mono" "Menlo")] [(windows) '("IBM Plex Mono" "Cascadia Mono" "Consolas")]
    [else '("IBM Plex Mono" "DejaVu Sans Mono")]))
(define prose-faces
  (case (system-type 'os)
    [(macosx) '("IBM Plex Serif" "Charter" "Georgia")] [(windows) '("IBM Plex Serif" "Cambria" "Georgia")]
    [else '("IBM Plex Serif" "DejaVu Serif")]))
(define ui-faces '("IBM Plex Sans"))

;; The first of `candidates` that is installed, else #f. Tests pass their own `installed`.
(define (resolve-face candidates [installed (installed-faces)])
  (for/first ([f (in-list candidates)] #:when (member f installed)) f))
(define installed-faces
  (let ([cache #f]) (lambda () (or cache (begin (set! cache (get-face-list)) cache)))))

(define mono-face (or (resolve-face mono-faces) (last mono-faces)))
(define prose-face (or (resolve-face prose-faces) (last prose-faces)))
(define ui-face (resolve-face ui-faces))    ; #f: the OS control font

;; A font for text we paint in the chrome (status bar, later the sidebar): IBM Plex Sans at
;; the control font's size when installed, else the control font itself.
;; (Tests pass `face` to exercise the Plex branch on a machine without Plex.)
(define (ui-font [base normal-control-font] [face ui-face])
  (if face
      (make-font #:face face #:family 'swiss #:size (send base get-size)
                 #:size-in-pixels? (send base get-size-in-pixels))
      base))

;; All buffers share one style list. "Standard" holds the code font and the foreground;
;; "Prose", derived from it, swaps in the serif face one point larger, so zoom and theme
;; changes to "Standard" restyle both. A document uses the style its Language names in
;; the `document-style` local (buffer.rkt's default-style-name).
(define editor-style-list (new style-list%))
(define standard-style
  (send editor-style-list new-named-style "Standard"
        (send editor-style-list find-or-create-style
              (send editor-style-list basic-style) (make-object style-delta%))))
(define prose-style
  (send editor-style-list new-named-style "Prose"
        (send editor-style-list find-or-create-style standard-style (make-object style-delta%))))

(define (apply-base-style!)
  (define d (make-object style-delta%))
  (send d set-delta-face mono-face 'modern)
  (send d set-size-mult 0.0)
  (send d set-size-add font-size)
  (send d set-delta-foreground (theme-color 'fg))
  (send standard-style set-delta d)
  (define p (make-object style-delta%))
  (send p set-delta-face prose-face 'roman)
  (send p set-size-add 1)
  (send prose-style set-delta p))

(apply-base-style!)
