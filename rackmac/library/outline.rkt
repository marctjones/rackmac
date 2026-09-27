#lang racket/base
;; The Outline section's data (#298 outline-panel; docs/UI-DESIGN.md §2.1, §2.5): the current
;; document's headings, turned into rows for the painted list (rackmac/ui/outline.rkt), and what
;; activating one does. The fifth section of the Library sidebar, in its lower half, below
;; Folders; the future Backlinks panel (#305/E16.M1) shares that lower half beside it.
;;
;; rackmac/headings.rkt walks the parsed document into a flat, ordered heading list; this module
;; only turns that into outline-list% rows and moves the caret when one is activated.
;; rackmac/library/sidebar.rkt places the section (header + list) in the panel and wires the
;; live-update hook: `document-restyled`, run by md-style.rkt for md-restyle-region (an edited
;; region) and for the whole document (open, Language change) -- rebuilding from it is how the
;; Outline "updates from md-restyle-region" (#298's acceptance criterion).
(require racket/class "../headings.rkt" "../md-style.rkt" "../ui/outline.rkt")
(provide empty-outline-text outline-rows-for heading-at-caret jump-to-heading!)

(define empty-outline-text "No headings yet. Start a line with # to make one.")

;; The headings of `b`'s parsed document -- empty for a document with none, or with no parser
;; yet (a non-Markdown Language, or a large file, where syntax coloring and this are both off).
(define (buffer-headings b)
  (define doc (markdown-parser-document b))
  (if doc (document-headings doc) '()))

;; A blank heading ("#" with nothing after it) still needs a label to click.
(define (heading-label h) (define t (doc-heading-text h)) (if (string=? t "") "(untitled heading)" t))

;; The current outline rows for buffer `b`: one heading-row per heading, in document order, or a
;; single unselectable empty-state row (docs/UI-DESIGN.md §2.5's empty-state copy).
(define (outline-rows-for b)
  (define hs (buffer-headings b))
  (if (null? hs)
      (list (empty-outline-row empty-outline-text))
      (for/list ([h (in-list hs)]) (heading-row (doc-heading-level h) (heading-label h) h))))

;; The last heading `b`'s caret is at or past -- i.e. the section it is in -- or #f before the
;; first heading (or when there are none). Used to keep the Outline's selection on the caret's
;; section (docs/UI-DESIGN.md §2.5), the same idea as Recent/Folders following the open document.
(define (heading-at-caret b pos)
  (for/fold ([best #f]) ([h (in-list (buffer-headings b))] #:when (<= (doc-heading-start h) pos))
    h))

;; Moves the caret to the start of heading `h` in buffer `b` and scrolls it into view, like a
;; Find match (ui/find-bar.rkt's `step!`) -- the sidebar keeps the keyboard, so another click or
;; Up/Down can keep browsing the outline.
(define (jump-to-heading! b h)
  (send b set-position (doc-heading-start h) (doc-heading-start h)))
