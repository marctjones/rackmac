#lang racket/base
;; The flattened heading outline of a parsed Markdown document (#298 outline-panel;
;; docs/UI-DESIGN.md §2.1, §2.5): every `heading` block (ATX or setext, levels 1-6), in document
;; order, with its span and its plain text (markup and inline styling stripped, for display).
;;
;; This walks the AST rackmac-markdown/main.rkt already exposes (document-blocks, block-inlines,
;; and every block/inline struct), so it needs no new mdlib API: `document-headings` is a pure
;; function of a `document?` from `markdown-parser-document` (md-style.rkt). Reusable beyond the
;; Outline sidebar (rackmac/library/outline.rkt) -- anything else that wants "the headings in
;; this document" (a heading picker, promote/demote commands, a table of contents export) can
;; require this module instead of re-walking the tree.
(require racket/list racket/string "markdown-lib.rkt")
(provide (struct-out doc-heading) document-headings inlines->text)

;; level: 1-6. start/end: the heading block's span, as offsets into the document text --
;; the same numbers `send buffer set-position` and `document-restyled` use. text: the heading's
;; plain text.
(struct doc-heading (level start end text) #:transparent)

;; The document's headings, in document order, wherever they occur (top level, or nested in a
;; block quote or list item -- CommonMark allows both).
(define (document-headings doc) (headings-in (document-blocks doc)))

(define (headings-in blocks)
  (append-map
   (lambda (b)
     (cond
       [(heading? b) (list (doc-heading (heading-level b) (block-start b) (block-end b) (heading-text b)))]
       [(block-quote? b) (headings-in (block-quote-children b))]
       [(list-block? b) (headings-in (list-block-children b))]
       [(list-item? b) (headings-in (list-item-children b))]
       [else '()]))
   blocks))

(define (heading-text h) (string-trim (inlines->text (block-inlines h))))

;; The same idea as rackmac-markdown/html.rkt's internal `plain-text`, over the public inline
;; structs: text and code stay, markup (emphasis, links, wiki-links, tags...) is stripped to
;; its visible text.
(define (inlines->text xs) (apply string-append (map inline->text xs)))
(define (inline->text x)
  (cond
    [(text? x) (text-value x)]
    [(code-span? x) (code-span-value x)]
    [(emph? x) (inlines->text (emph-children x))]
    [(strong? x) (inlines->text (strong-children x))]
    [(strike? x) (inlines->text (strike-children x))]
    [(link? x) (inlines->text (link-children x))]
    [(image? x) (inlines->text (image-children x))]
    [(wiki-link? x) (or (wiki-link-alias x) (wiki-link-target x))]
    [(tag? x) (string-append "#" (tag-name x))]
    ;; A date's span includes its keyword ("due 2026-09-30"), so both are its visible text.
    [(date-ref? x) (if (date-ref-keyword x) (string-append (date-ref-keyword x) " " (date-ref-date x)) (date-ref-date x))]
    [(or (soft-break? x) (hard-break? x)) " "]
    [else ""]))
