#lang racket/base
;; A document's Markdown heading outline: level and source span per top-level heading, built from
;; a rackmac-markdown parsed document (rackmac/md-doc.rkt's `current-md-document`). Pure (no GUI,
;; no buffer dependency) so it can be shared by anything that needs "the note's heading structure"
;; -- today rackmac/outline-structure.rkt (#299: Promote/Demote heading, Move Section Up/Down); an
;; Outline sidebar (#298) can read the same shape instead of re-walking the AST for its own list.
;;
;; Headings nested inside a block quote or list item describe THAT container's content, not the
;; note's own structure -- a Markdown outline is conventionally the document's own top-level
;; headings -- so `document-outline` only looks at `document-blocks` (top level).
(require racket/list "../rackmac-markdown/main.rkt")
(provide (struct-out outline-heading) document-outline previous-sibling next-sibling heading-subtree-end)

;; level: 1-6. start/end: the heading's own source span (block-start/block-end of the AST node,
;; its one ATX line or both lines of a setext heading) -- never its subtree.
(struct outline-heading (level start end) #:transparent)

(define (document-outline doc)
  (for/list ([b (in-list (document-blocks doc))] #:when (heading? b))
    (outline-heading (heading-level b) (block-start b) (block-end b))))

(define (heading-index outline h) (index-where outline (lambda (x) (eq? x h))))

;; The first heading after `h` (in source order) whose level is <= `h`'s -- where `h`'s own
;; subtree ends: a heading at the same or an outer (numerically smaller) level closes it; any
;; heading of a deeper level in between is `h`'s own child, not a boundary.
(define (next-heading-at-or-above outline h)
  (define i (heading-index outline h))
  (for/first ([h2 (in-list (list-tail outline (add1 i)))]
              #:when (<= (outline-heading-level h2) (outline-heading-level h)))
    h2))

;; Symmetric lookup walking backward from `h`, skipping deeper (child) headings that belong to
;; whatever came before it.
(define (previous-heading-at-or-above outline h)
  (define i (heading-index outline h))
  (for/first ([h2 (in-list (reverse (take outline i)))]
              #:when (<= (outline-heading-level h2) (outline-heading-level h)))
    h2))

;; `h`'s subtree runs from its own start to the next heading at or above its level, or the end of
;; the document (`doc-end`, since a pure AST has no notion of "end of buffer").
(define (heading-subtree-end outline h doc-end)
  (define h2 (next-heading-at-or-above outline h))
  (if h2 (outline-heading-start h2) doc-end))

;; `h`'s next/previous sibling: the next/previous heading at or above its level, but only when
;; that heading is truly at the SAME level -- an outer (numerically smaller) level means `h` has
;; no sibling in that direction (it is its parent's first or last child), so #f.
(define (next-sibling outline h)
  (define h2 (next-heading-at-or-above outline h))
  (and h2 (= (outline-heading-level h2) (outline-heading-level h)) h2))

(define (previous-sibling outline h)
  (define h2 (previous-heading-at-or-above outline h))
  (and h2 (= (outline-heading-level h2) (outline-heading-level h)) h2))
