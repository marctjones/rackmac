#lang racket/base
;; Promote/Demote heading and Move Section Up/Down (#299, docs/UI-DESIGN.md "Promote / Demote
;; heading" and "Move Section Up / Down", docs/REPLAN.md E17.M2 outline-structure): reuse of
;; Outdent/Indent Lines (⌘[ / ⌘]) and Move Line Up/Down (⌥↑ / ⌥↓) when the caret is on a heading
;; line, bound ahead of those commands in markdown-mode's own keymap (rackmac/modes.rkt), the same
;; way md-lists.rkt's Enter/Tab/Shift-Tab are: outside a heading line, and outside Markdown
;; altogether, they fall through to the plain commands unchanged.
;;
;; Renumbering a heading's '#'s (or converting a setext underline) is handled by
;; rackmac-markdown's own `set-heading-level-edits` (the same operation Heading 1-3/Body Text use,
;; md-format.rkt); splicing a moved section's text is one text-replacement edit. Both go through
;; rackmac/md-doc.rkt's `apply-md-edits!`, the same begin-edit-sequence/end-edit-sequence grouping
;; the other Markdown editing commands use to make a multi-part change one undo step, rather than
;; a new mechanism. The heading structure itself (siblings, subtrees) comes from md-outline.rkt.
(require racket/class racket/list
         "command.rkt" "editor.rkt" "md-doc.rkt" "md-view-commands.rkt" "md-outline.rkt"
         "../rackmac-markdown/main.rkt")

;; ---- caret/selection -> heading(s) -------------------------------------------------------------

;; The heading (if any) whose own line(s) hold buffer position `pos`.
(define (heading-at-position b outline pos)
  (define p (send b position-paragraph pos))
  (for/or ([h (in-list outline)])
    (and (<= (send b position-paragraph (outline-heading-start h))
             p
             (send b position-paragraph (max (outline-heading-start h) (sub1 (outline-heading-end h)))))
         h)))

;; Paragraph range covered by the selection (mirrors commands.rkt's private `selected-lines`,
;; not exported: a selection ending at a line's very start does not count that line).
(define (selected-paragraphs b)
  (define s (send b get-start-position))
  (define e (send b get-end-position))
  (define e* (if (and (> e s) (= e (send b paragraph-start-position (send b position-paragraph e)))) (sub1 e) e))
  (values (send b position-paragraph s) (send b position-paragraph e*)))

;; Every heading with a line inside the current selection -- a single heading when the caret is
;; simply on one (docs/REPLAN.md: "the heading containing the caret, or a selection spanning
;; headings").
(define (headings-in-selection b outline)
  (define-values (p1 p2) (selected-paragraphs b))
  (for/list ([h (in-list outline)]
             #:when (<= p1 (send b position-paragraph (outline-heading-start h)) p2))
    h))

(define (outline-of b) (document-outline (current-md-document b)))

;; ---- Promote / Demote ---------------------------------------------------------------------------

;; `h`'s new level moving `delta` (-1 promote, +1 demote), or #f at the boundary: H1 can't promote
;; past level 1, H6 can't demote past level 6. (0 is deliberately excluded even though
;; `set-heading-level-edits` accepts it -- that call makes body text, not "no lower heading level".)
(define (retarget-level h delta)
  (define lvl (+ (outline-heading-level h) delta))
  (and (<= 1 lvl 6) lvl))

(define (retarget-headings! b delta fallback)
  (define outline (outline-of b))
  (define targets (headings-in-selection b outline))
  (define doc (current-md-document b))
  (define edits
    (append*
     (for*/list ([h (in-list targets)] [lvl (in-value (retarget-level h delta))] #:when lvl)
       (set-heading-level-edits doc (outline-heading-start h) (outline-heading-start h) lvl))))
  (cond
    [(null? targets) (run-command fallback)]
    [(null? edits) (void)]            ; every targeted heading is already at the boundary
    [else
     (define-values (s e) (selection-range b))
     (define ns (map-position edits s 'after)) (define ne (map-position edits e 'before))
     (apply-md-edits! b edits)
     (send b set-position ns ne)]))

(define-command (promote-heading)
  #:title "Promote Heading" #:aliases ("promote heading" "outdent heading" "heading level up")
  #:help "Decrease the heading's level by one, or the editor's normal Outdent Lines elsewhere."
  #:when markdown-document?
  (define b (current-buffer))
  (if (markdown-document? b) (retarget-headings! b -1 'outdent-lines) (run-command 'outdent-lines)))

(define-command (demote-heading)
  #:title "Demote Heading" #:aliases ("demote heading" "indent heading" "heading level down")
  #:help "Increase the heading's level by one, or the editor's normal Indent Lines elsewhere."
  #:when markdown-document?
  (define b (current-buffer))
  (if (markdown-document? b) (retarget-headings! b 1 'indent-lines) (run-command 'indent-lines)))

;; ---- Move Section Up / Down -----------------------------------------------------------------

;; The sibling `h` would swap with in `dir` ('up or 'down), or #f (the top/bottom of its level).
(define (move-target outline h dir)
  (if (eq? dir 'up) (previous-sibling outline h) (next-sibling outline h)))

(define (move-section! b dir fallback)
  (define outline (outline-of b))
  (define pos (send b get-start-position))
  (define h (heading-at-position b outline pos))
  (cond
    [(not h) (run-command fallback)]
    [else
     (define sib (move-target outline h dir))
     (when sib
       (define doc-end (send b last-position))
       (define h-start (outline-heading-start h))
       (define h-end (heading-subtree-end outline h doc-end))
       (define-values (region-start mid region-end)
         (if (eq? dir 'up)
             (values (outline-heading-start sib) h-start h-end)
             (values h-start h-end (heading-subtree-end outline sib doc-end))))
       (define before-text (send b document-text region-start mid))
       ;; The section moving into the middle of the document must keep its own line to itself: it
       ;; only lacks a trailing newline when it was the document's last line (no final newline),
       ;; which is fine there but would otherwise glue it to what follows.
       (define after-raw (send b document-text mid region-end))
       (define after-text (if (regexp-match? #rx"\n$" after-raw) after-raw (string-append after-raw "\n")))
       (define delta (- pos h-start))                  ; caret's offset within h's own text
       (define new-caret (if (eq? dir 'up) (+ region-start delta) (+ region-start (string-length after-text) delta)))
       (apply-md-edits! b (list (edit region-start region-end (string-append after-text before-text))))
       (send b set-position new-caret new-caret))]))

(define-command (move-section-up)
  #:title "Move Section Up" #:aliases ("move section up" "move heading up")
  #:help "Move this heading and its section above the previous one, or the editor's normal Move Line Up elsewhere."
  #:when markdown-document?
  (define b (current-buffer))
  (if (markdown-document? b) (move-section! b 'up 'move-line-up) (run-command 'move-line-up)))

(define-command (move-section-down)
  #:title "Move Section Down" #:aliases ("move section down" "move heading down")
  #:help "Move this heading and its section below the next one, or the editor's normal Move Line Down elsewhere."
  #:when markdown-document?
  (define b (current-buffer))
  (if (markdown-document? b) (move-section! b 'down 'move-line-down) (run-command 'move-line-down)))
