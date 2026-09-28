#lang racket/base
;; Built-in modes. Every one uses the same public define-mode that user code gets.
(require "mode.rkt" "keymap.rkt" "highlight.rkt" "md-style.rkt" "md-view.rkt" "md-links.rkt" "md-checkbox.rkt" "ui/layout.rkt")
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


;; Enter/Tab/Shift-Tab in a list (#337, md-lists.rkt), Enter/Tab/Shift-Tab in a pipe table (#343,
;; #414, md-tables.rkt), and Promote/Demote heading and Move Section Up/Down on a heading line
;; (#299, outline-structure.rkt), are bound ahead of the global keymap's plain "Enter"/"Tab"/
;; "Shift-Tab", "Outdent/Indent Lines" and "Move Line Up/Down" commands, by NAME: a keymap only
;; ever stores command symbols (keymap.rkt), so this module never has to require md-lists.rkt,
;; md-tables.rkt or outline-structure.rkt (which would cycle back through editor.rkt -- see
;; md-view.rkt's note on why it avoids the same thing). md-tables.rkt's table-tab/table-shift-tab/
;; table-enter take "Tab"/"Shift-Tab"/"Enter" here instead of md-lists.rkt's own markdown-indent/
;; markdown-outdent/markdown-enter, and fall through BY NAME to those exactly when the caret is
;; not inside a pipe table, so list behavior is unchanged.
(define markdown-keymap
  (make-keymap/pairs 'markdown-mode
                     (list (cons "Enter" 'table-enter)
                           (cons "Tab" 'table-tab)
                           (cons "Shift-Tab" 'table-shift-tab)
                           (cons "Mod-[" 'promote-heading)
                           (cons "Mod-]" 'demote-heading)
                           (cons "Alt-Up" 'move-section-up)
                           (cons "Alt-Down" 'move-section-down))))

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
