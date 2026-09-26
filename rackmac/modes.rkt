#lang racket/base
;; Built-in modes. Every one uses the same public define-mode that user code gets.
(require "mode.rkt" "keymap.rkt" "highlight.rkt" "md-style.rkt" "md-view.rkt" "md-links.rkt" "ui/layout.rkt")

(define-mode text-mode
  #:label "Plain Text"
  #:doc "Plain text. Wraps long lines."
  #:locals `((wrap-lines . #t) (indent-string . "  ") (measure . ,prose-measure)
             (document-style . "Prose") (line-spacing . 4)))

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


;; Enter/Tab/Shift-Tab in a list (#337, md-lists.rkt) are bound ahead of the global keymap's
;; plain "Enter"/"Tab"/"Shift-Tab" commands, by NAME: a keymap only ever stores command symbols
;; (keymap.rkt), so this module never has to require md-lists.rkt (which would cycle back
;; through editor.rkt -- see md-view.rkt's note on why it avoids the same thing).
(define markdown-keymap
  (make-keymap/pairs 'markdown-mode
                     (list (cons "Enter" 'markdown-enter)
                           (cons "Tab" 'markdown-indent)
                           (cons "Shift-Tab" 'markdown-outdent))))

;; Two views of one document (md-view.rkt, #269): Formatted, styled from the Markdown parser and
;; restyled per edit (md-style.rkt); Markdown Source, the regex coloring on the mono style.
(define-mode markdown-mode
  #:label "Markdown"
  #:parent 'text-mode
  #:files '("*.md" "*.markdown")
  #:keymap markdown-keymap
  #:locals `((restyle-edit . ,markdown-edit!) (restyle-flush . ,markdown-flush!)
             (link-at . ,markdown-link-at))                  ; ⌘-click and hover (#338)
  #:highlighter markdown-highlight!
  #:on-enable markdown-view-enable!
  #:on-disable markdown-view-disable!
  #:doc "Markdown: headings, emphasis, code, links, lists and quotes are formatted as you type.")
