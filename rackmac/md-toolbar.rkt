#lang racket/base
;; The Format toolbar group for notes (#336, docs/UI-DESIGN.md §2.3): Bold, Italic, Link, a
;; Heading popup (Heading 1-3, Body Text), Bulleted, Numbered, Checklist, and the
;; Formatted/Markdown Source toggle at the end. Shown only for Markdown documents, the same
;; #:mode scoping the toolbar already uses to show Run only for Racket (toolbar.rkt). Export▾
;; (the REPLAN row's last item) is left out: nothing to export to yet (E18.M1 PDF export, #279,
;; is unbuilt; Export to Word, #278, has no toolbar slot of its own in the design).
(require "editor.rkt" "command.rkt" "toolbar.rkt" "md-view-commands.rkt" "md-format.rkt")

;; The Heading button's backing command (toolbar.rkt's `#:items`): never on a key or in the
;; Format menu, since Heading 1-3 and Body Text already are (md-format.rkt); it exists only so
;; the popup button has a title, a hover hint and a #:when to dim by. Run directly (the palette,
;; an alias) it just names the commands its popup groups.
(define-command (heading-menu)
  #:title "Heading" #:aliases ("heading menu" "heading styles" "apply heading")
  #:help "Choose a heading level or body text for the current paragraph."
  #:when markdown-document?
  (message "Format > Heading 1, Heading 2, Heading 3 or Body Text; or the toolbar's Heading button."))

(add-toolbar-item! 'toggle-bold #:group 'format #:mode 'markdown-mode #:label "B")
(add-toolbar-item! 'toggle-italic #:group 'format #:mode 'markdown-mode #:label "I")
(add-toolbar-item! 'insert-link #:group 'format #:mode 'markdown-mode)
(add-toolbar-item! 'heading-menu #:group 'format #:mode 'markdown-mode
                    #:items '(heading-1 heading-2 heading-3 body-text) #:label "H▾")
(add-toolbar-item! 'toggle-bulleted-list #:group 'format #:mode 'markdown-mode #:label "•")
(add-toolbar-item! 'toggle-numbered-list #:group 'format #:mode 'markdown-mode #:label "1.")
(add-toolbar-item! 'toggle-checklist #:group 'format #:mode 'markdown-mode)
(add-toolbar-item! 'toggle-markdown-view #:group 'format #:mode 'markdown-mode)
