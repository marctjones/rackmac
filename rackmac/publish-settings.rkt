#lang racket/base
;; Publishing settings (#424, docs/PUBLISHING-DESIGN.md): where built output goes, where the
;; preview shows, whether it refreshes on save, and whether a file outside a Library folder may
;; be built. All four are `#:scope 'document` settings, which is how rackmac/settings.rkt spells
;; "Language scope": a value resolves document, then Language, then everywhere, so a lawyer can
;; keep one output folder for Scribble and another for slides, or turn refresh on for one file.
;; Only the settings live here; the build (#420) and the preview panes read them through
;; `publish-setting`. They show in the generated Settings dialog with the labels and help below.
(require racket/class "settings.rkt")
(provide publish-setting)

(define-setting publish-output-folder
  #:contract string? #:default "" #:scope 'document #:category "Publishing"
  #:label "Output folder"
  #:doc "Where built files are put. Leave empty to use a folder named Published beside the document.")

(define-setting publish-preview-target
  #:contract (lambda (v) (and (memq v '(browser embedded)) #t)) #:default 'browser
  #:scope 'document #:category "Publishing"
  #:label "Show the preview in"
  #:choices '((browser . "My web browser") (embedded . "A pane inside Rackmac"))
  #:doc "Where Preview opens the built document.")

(define-setting publish-refresh-on-save
  #:contract boolean? #:default #f #:scope 'document #:category "Publishing"
  #:label "Refresh the preview when I save"
  #:doc "Rebuild the open preview each time the document is saved. Off by default, because building runs the document.")

(define-setting publish-outside-library
  #:contract (lambda (v) (and (memq v '(confirm never)) #t)) #:default 'confirm
  #:scope 'document #:category "Publishing"
  #:label "Build files outside the Library"
  #:choices '((confirm . "Ask me first") (never . "Never"))
  #:doc "Documents in these languages run code when built. Choose whether a file from outside your Library folders may be built at all, after you confirm once.")

;; The value of a publishing setting for document `b`: this document's own override, else the
;; one for its Language, else the global value.
(define (publish-setting name b)
  (setting-ref name #:document b #:language (send b get-mode)))
