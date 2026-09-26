#lang racket/base
;; Enter, Tab and Shift+Tab in Markdown lists (#337, docs/UI-DESIGN.md §2.2 and §2.4): Enter
;; continues the current bullet, number (renumbering) or checklist item, and ends the list on an
;; empty item; Tab and Shift+Tab indent and outdent a list item. Bound ahead of the global
;; "Enter"/"Tab"/"Shift-Tab" commands by markdown-mode's own keymap (modes.rkt binds these
;; command NAMES, so it never needs to require this module -- see its comment), so outside a
;; list item, and outside Markdown altogether, they fall through to the existing commands
;; (`newline-and-indent`, `indent-or-insert`, `outdent-lines`) unchanged.
(require racket/class "command.rkt" "editor.rkt" "md-doc.rkt" "md-view-commands.rkt"
         "../rackmac-markdown/main.rkt")

;; `list-enter-edits` doubles as the "is this position inside a list item's text" test: it
;; returns #f edits exactly when `pos` is outside one (edits.rkt's own contract).
(define (in-list-item? doc pos)
  (define-values (edits caret) (list-enter-edits doc pos))
  (and edits #t))

(define-command (markdown-enter)
  #:title "Continue List" #:aliases ("list enter" "continue list" "end list")
  #:help "Continue the current list item; on an empty item, end the list."
  #:when markdown-document?
  (define b (current-buffer))
  (cond
    [(not (markdown-document? b)) (run-command 'newline-and-indent)]
    [else
     (define-values (s e) (selection-range b))
     (define-values (edits caret)
       (if (= s e) (list-enter-edits (current-md-document b) s) (values #f #f)))
     (cond
       [edits (apply-md-edits! b edits) (send b set-position caret caret)]
       [else (run-command 'newline-and-indent)])]))

(define-command (markdown-indent)
  #:title "Indent List Item" #:aliases ("indent list item" "demote list item")
  #:help "Indent the selected list items one level, or the editor's normal Tab elsewhere."
  #:when markdown-document?
  (define b (current-buffer))
  (cond
    [(not (markdown-document? b)) (run-command 'indent-or-insert)]
    [else
     (define-values (s e) (selection-range b))
     (define doc (current-md-document b))
     (cond
       [(in-list-item? doc s)
        (define edits (indent-list-edits doc s e))
        (when (pair? edits)
          (define ns (map-position edits s 'after)) (define ne (map-position edits e 'before))
          (apply-md-edits! b edits)
          (send b set-position ns ne))]
       [else (run-command 'indent-or-insert)])]))

(define-command (markdown-outdent)
  #:title "Outdent List Item" #:aliases ("outdent list item" "promote list item")
  #:help "Outdent the selected list items one level, or the editor's normal Shift+Tab elsewhere."
  #:when markdown-document?
  (define b (current-buffer))
  (cond
    [(not (markdown-document? b)) (run-command 'outdent-lines)]
    [else
     (define-values (s e) (selection-range b))
     (define doc (current-md-document b))
     (cond
       [(in-list-item? doc s)
        (define edits (outdent-list-edits doc s e))
        (when (pair? edits)
          (define ns (map-position edits s 'after)) (define ne (map-position edits e 'before))
          (apply-md-edits! b edits)
          (send b set-position ns ne))]
       [else (run-command 'outdent-lines)])]))
