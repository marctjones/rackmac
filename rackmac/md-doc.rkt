#lang racket/base
;; Shared plumbing for the Markdown editing commands (#335 md-format-commands, #336
;; md-toolbar-group, #337 md-lists-enter): the parsed document for a buffer's CURRENT text, and
;; applying rackmac-markdown/edits.rkt's edits to a buffer as one undo step.
;;
;; md-style.rkt's own parser (`markdown-parser-document`) is kept live by the buffer's normal
;; edit hooks only in the Formatted view; the Markdown Source view shadows `restyle-edit` and
;; `restyle-flush` to #f (it recolors with the older regex highlighter instead, md-view.rkt),
;; so after an edit made while in Source view the cached document is stale, or, for a document
;; that opened straight into Source, was never parsed at all (#f). `current-md-document` reuses
;; the cache when it still matches the buffer's text (the common, Formatted-view case: no
;; reparse) and falls back to a fresh parse otherwise, so the formatting commands behave
;; identically in both views.
(require racket/class "../rackmac-markdown/main.rkt" "md-style.rkt")
(provide current-md-document apply-md-edits! selection-range)

(define (current-md-document b)
  (define text (send b get-text))
  (define cached (markdown-parser-document b))
  (if (and cached (string=? (document-text cached) text))
      cached
      (parse-document text #:extensions all-extensions)))

;; Applies `edits` (ast.rkt: sorted, non-overlapping, offsets into the OLD text) to buffer `b`
;; as one undo step: last edit first inside one edit sequence, so earlier offsets stay valid
;; and the buffer's normal after-insert/after-delete hooks (md-style.rkt's incremental restyle,
;; in the Formatted view) see each change and reparse once when the sequence ends, the same as
;; if the user had typed them. Callers set the selection afterwards, once the sequence is closed.
(define (apply-md-edits! b edits)
  (send b begin-edit-sequence)
  (for ([e (in-list (reverse edits))])
    (send b insert (edit-text e) (edit-start e) (edit-end e)))
  (send b end-edit-sequence))

(define (selection-range b) (values (send b get-start-position) (send b get-end-position)))
