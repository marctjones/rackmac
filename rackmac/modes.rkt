#lang racket/base
;; Built-in modes. Every one uses the same public define-mode that user code gets.
(require "mode.rkt" "keymap.rkt" "highlight.rkt")

(define-mode text-mode
  #:label "Plain Text"
  #:doc "Plain text. Wraps long lines."
  #:locals '((wrap-lines . #t) (indent-string . "  ")))

(define-mode prog-mode
  #:label "Code"
  #:doc "Parent of programming modes. No line wrapping."
  #:locals '((wrap-lines . #f) (indent-string . "  ")))

(define-mode racket-mode
  #:label "Racket"
  #:parent 'prog-mode
  #:files '("*.rkt" "*.rktl" "*.scrbl" "*.ss")
  #:locals '((comment-start . ";"))
  #:highlighter highlight-racket!
  #:doc "Racket source: syntax coloring and ; comments.")

(define-mode markdown-mode
  #:label "Markdown"
  #:parent 'text-mode
  #:files '("*.md" "*.markdown")
  #:highlighter highlight-markdown!
  #:doc "Markdown: headings and inline code are colored.")
