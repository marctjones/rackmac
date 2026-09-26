#lang racket/base
;; Built-in modes. Every one uses the same public define-mode that user code gets.
(require "mode.rkt" "keymap.rkt" "highlight.rkt" "md-style.rkt" "ui/layout.rkt")
(provide code-keymap)

(define-mode text-mode
  #:label "Plain Text"
  #:doc "Plain text. Wraps long lines."
  #:locals `((wrap-lines . #t) (indent-string . "  ") (measure . ,prose-measure)
             (document-style . "Prose") (line-spacing . 4)))

;; run-code-only (#288): Run Selection/Run Document (rackmac/commands.rkt, bound here via
;; #:key-keymap) live only for prog-mode and its children -- ⌘Return does nothing in a note
;; because it is simply unbound there, not merely disabled.
(define code-keymap (make-keymap 'code))

(define-mode prog-mode
  #:label "Code"
  #:doc "Parent of programming modes. No line wrapping."
  #:keymap code-keymap
  #:locals '((wrap-lines . #f) (indent-string . "  ")))

(define-mode racket-mode
  #:label "Racket"
  #:parent 'prog-mode
  #:files '("*.rkt" "*.rktl" "*.scrbl" "*.ss")
  #:locals '((comment-start . ";"))
  #:highlighter highlight-racket!
  #:doc "Racket source: syntax coloring and ; comments.")


;; The Formatted view (md-style.rkt): styled from the Markdown parser, restyled per edit.
;; highlight-markdown! (regex coloring) stays for the Markdown Source view (#269).
(define-mode markdown-mode
  #:label "Markdown"
  #:parent 'text-mode
  #:files '("*.md" "*.markdown")
  #:locals `((restyle-edit . ,markdown-edit!) (restyle-flush . ,markdown-flush!))
  #:highlighter render-markdown!
  #:on-disable reset-paragraph-margins!
  #:doc "Markdown: headings, emphasis, code, links, lists and quotes are formatted as you type.")
