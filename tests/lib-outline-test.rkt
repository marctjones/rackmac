#lang racket/base
;; The Outline (#298 outline-panel; docs/UI-DESIGN.md §2.1, §2.5): heading extraction and
;; indentation (rackmac/headings.rkt), the painted depth-indented list (rackmac/ui/outline.rkt),
;; and the sidebar section (rackmac/library/sidebar.rkt, rackmac/library/outline.rkt) -- it
;; updates live from md-restyle-region (the `document-restyled` hook), a click or Enter jumps
;; the caret, its selection follows the caret's section, and it is keyboard reachable like
;; Recent and Folders.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/list
         "ui-harness.rkt"
         "../rackmac/headings.rkt" "../rackmac/markdown-lib.rkt"
         "../rackmac/library/outline.rkt" "../rackmac/library/sidebar.rkt"
         "../rackmac/ui/outline.rkt" (only-in "../rackmac/ui/tokens.rkt" token-hex)
         "../rackmac/editor.rkt" "../rackmac/frame.rkt" "../rackmac/hook.rkt")

;; ---- heading extraction and indentation (pure) -----------------------------------------------

(define (headings-of text) (document-headings (parse-document text)))
(define (levels+labels text) (map (lambda (h) (cons (doc-heading-level h) (doc-heading-text h))) (headings-of text)))

(test-case "every ATX level, in document order, with plain text"
  (check-equal? (levels+labels "# One\n\n## Two\n\n###### Six\n")
                '((1 . "One") (2 . "Two") (6 . "Six"))))

(test-case "setext headings (level 1 '===', level 2 '---')"
  (check-equal? (levels+labels "Title\n=====\n\nSubtitle\n--------\n")
                '((1 . "Title") (2 . "Subtitle"))))

(test-case "inline markup is stripped to plain text, but not hidden entirely"
  (check-equal? (levels+labels "## **Bold** and `code` and _emph_\n")
                '((2 . "Bold and code and emph"))))

(test-case "a heading with nothing after the hashes still has a span (label-for gives it a name)"
  (check-equal? (levels+labels "##\n\nParagraph\n") '((2 . ""))))

(test-case "headings nested in a block quote or a list item are still found, in document order"
  (check-equal? (levels+labels "> ## Quoted\n\n- ## In a list item\n")
                '((2 . "Quoted") (2 . "In a list item"))))

(test-case "no headings: an empty list, not an error"
  (check-equal? (headings-of "Just a paragraph.\n") '()))

(test-case "start/end are the heading block's span, usable as buffer offsets"
  (define text "Intro\n\n## Section\n\nBody\n")
  (define h (car (headings-of text)))
  (check-equal? (substring text (doc-heading-start h) (doc-heading-end h)) "## Section"))

(test-case "outline-rows-for: one heading-row per heading, indented by level; empty doc gets the empty-state row"
  (define hs (headings-of "# A\n\n## B\n\n### C\n"))
  (define rows (for/list ([h (in-list hs)]) (heading-row (doc-heading-level h) (doc-heading-text h) h)))
  (check-equal? (map outline-row-level rows) '(1 2 3))
  (check-equal? (map outline-row-label rows) '("A" "B" "C"))
  (check-true (andmap outline-row-selectable? rows))
  (define empty-row (empty-outline-row empty-outline-text))
  (check-equal? (outline-row-level empty-row) 0)
  (check-false (outline-row-selectable? empty-row)))

;; ---- the painted list's layout: depth increases with level, indentation is monotone ----------

(define (slot-for lst row) (findf (lambda (s) (eq? (outline-slot-row s) row)) (send lst current-slots 240)))

(test-case "rows are indented by level: each deeper heading starts further right"
  (define rows (list (heading-row 1 "H1" 'a) (heading-row 3 "H3" 'b) (heading-row 2 "H2" 'c)))
  (define lst (new outline-list% [parent (new frame% [label "t"])]))
  (send lst set-rows! rows)
  (define xs (map (lambda (r) (outline-slot-text-x (slot-for lst r))) rows))
  (check-true (apply < (list (car xs) (caddr xs) (cadr xs))) "H1 < H2 < H3's left edge")
  (check-equal? (map outline-slot-depth (map (lambda (r) (slot-for lst r)) rows)) '(0 2 1)))

(test-case "the empty state does not indent (depth 0) and is not selectable"
  (define lst (new outline-list% [parent (new frame% [label "t"])]))
  (send lst set-rows! (list (empty-outline-row "No headings yet. Start a line with # to make one.")))
  (check-equal? (outline-slot-depth (car (send lst current-slots 240))) 0)
  (send lst on-char (new key-event% [key-code 'down]))
  (check-false (send lst get-selected) "nothing selectable to move to"))

;; ---- painted on the bench: no white boxes, a marker on the selection --------------------------

(test-case "the Outline list paints on the bench like Recent and Folders"
  (for ([a appearances])
    (with-appearance a
      (lambda ()
        (define rows (list (heading-row 1 "Introduction" 'a) (heading-row 2 "Details" 'b)))
        (define lst (new outline-list% [parent (new frame% [label "t"])]))
        (send lst set-rows! rows)
        (send lst select-quietly! (car rows))
        (define bm (render-bitmap 240 100 (lambda (dc) (send lst paint-to-dc dc 240 100 #:focused? #f))))
        (write-tour-png! (format "outline-~a" a) bm)
        (check-false (hash-ref (bitmap-colors bm) "#FFFFFF" #f) "no white boxes")
        (check-equal? (dominant-color bm) (token-hex 'bench a))
        (define-values (x y w h) (apply values (outline-slot-rect (slot-for lst (car rows)))))
        (check-equal? (bitmap-pixel-hex bm 0 (+ y (/ h 2))) (token-hex 'accent a)
                      "the selected row has the accent marker, as Recent/Folders do")))))

;; ---- in the window: live refresh, click-to-jump, keyboard, follow-the-caret -------------------

(define f (make-main-frame))     ; hidden: show is never called
(define (panel) (main-sidebar))
(define (outline) (send (panel) get-outline-list))
(define (labels) (map outline-row-label (send (outline) all-rows)))
(define (row-for label) (findf (lambda (r) (equal? (outline-row-label r) label)) (send (outline) all-rows)))

(define (note text)
  (define b (new-buffer! "outline-note" #:mode 'markdown-mode))
  (send b insert text)
  (send b clear-undos)
  (send b set-modified #f)
  b)

(test-case "the Outline shows the current document's headings, indented, in order"
  (define b (note "# Title\n\nIntro text.\n\n## First\n\nBody.\n\n## Second\n\n### Nested\n"))
  (set-current-buffer! b)
  (send (panel) refresh-outline!)
  (check-equal? (labels) '("Title" "First" "Second" "Nested"))
  (check-equal? (map outline-row-level (send (outline) all-rows)) '(1 2 2 3)))

(test-case "a document with no headings shows the empty state, not a blank list"
  (define b (note "Just a paragraph, no headings.\n"))
  (set-current-buffer! b)
  (send (panel) refresh-outline!)
  (check-equal? (labels) (list empty-outline-text))
  (check-false (outline-row-selectable? (car (send (outline) all-rows)))))

(test-case "updates live from md-restyle-region: typing a new heading rebuilds the Outline"
  (define b (note "# Only\n"))
  (set-current-buffer! b)
  (send (panel) refresh-outline!)
  (check-equal? (labels) '("Only"))
  ;; an edit inside an already-open document restyles just the touched region
  ;; (md-style.rkt's region restyle), which fires 'document-restyled -- the Outline listens
  ;; for it directly (rackmac/library/sidebar.rkt), not through refresh-outline! called by hand.
  (send b insert "\n\n## Added While Typing\n" (send b last-position))
  (check-equal? (labels) '("Only" "Added While Typing"))
  (send b insert "!" 4)   ; "# Only" -> "# On!ly": the label changes, no heading added or removed
  (check-equal? (labels) '("On!ly" "Added While Typing")))

(test-case "an edit in another buffer never touches the Outline"
  (define b (note "# Shown\n"))
  (set-current-buffer! b)
  (send (panel) refresh-outline!)
  (define other (new-buffer! "other" #:mode 'markdown-mode))
  (send other insert "# Not Shown\n")
  (check-equal? (labels) '("Shown")))

(test-case "a click on a row jumps the caret to that heading and scrolls it into view"
  (define b (note "# Title\n\nIntro.\n\n## Target\n\nBody text here.\n"))
  (set-current-buffer! b)
  (send (panel) refresh-outline!)
  (define row (row-for "Target"))
  (check-not-false row)
  (send (outline) click-row! row)
  (check-equal? (send b get-start-position) (doc-heading-start (outline-row-data row)))
  (check-equal? (send b get-end-position) (doc-heading-start (outline-row-data row))))

(test-case "keyboard reachable: Tab from Folders reaches the Outline; arrows move; Enter jumps"
  (define b (note "# Title\n\n## Alpha\n\n## Beta\n"))
  (set-current-buffer! b)
  (send (panel) refresh-outline!)
  (define p (panel))
  (check-eq? (send p next-focus (send p get-folders-list) #f) (outline))
  (check-eq? (send p next-focus (outline) #f) 'document)
  (check-eq? (send p next-focus (outline) #t) (send p get-folders-list))
  (send (outline) on-char (new key-event% [key-code 'down]))
  (check-equal? (outline-row-label (send (outline) get-selected)) "Title")
  (send (outline) on-char (new key-event% [key-code 'down]))
  (check-equal? (outline-row-label (send (outline) get-selected)) "Alpha")
  (send (outline) on-char (new key-event% [key-code 'end]))
  (check-equal? (outline-row-label (send (outline) get-selected)) "Beta")
  (send (outline) on-char (new key-event% [key-code 'home]))
  (check-equal? (outline-row-label (send (outline) get-selected)) "Title")
  ;; Return, dispatched through the panel as Folders' Return is (#273's on-subwindow-char)
  (send p on-subwindow-char (outline) (new key-event% [key-code #\return]))
  (check-equal? (send b get-start-position) (doc-heading-start (outline-row-data (row-for "Title")))))

(test-case "the Outline's selection follows the caret's section"
  (define b (note "# Title\n\nIntro.\n\n## Alpha\n\nAlpha body.\n\n## Beta\n\nBeta body.\n"))
  (set-current-buffer! b)
  (send (panel) refresh-outline!)
  (define beta-start (doc-heading-start (outline-row-data (row-for "Beta"))))
  (send b set-position beta-start)
  (run-hook 'status-changed)
  (check-equal? (outline-row-label (send (outline) get-selected)) "Beta")
  (send b set-position 0)
  (run-hook 'status-changed)
  (check-equal? (outline-row-label (send (outline) get-selected)) "Title" "back at the top, the first section again"))
