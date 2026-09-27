#lang racket/base
;; Promote/Demote heading (⌘[ / ⌘]) and Move Section Up/Down (⌥↑ / ⌥↓) (#299, docs/UI-DESIGN.md
;; "Promote / Demote heading", "Move Section Up / Down"; docs/REPLAN.md E17.M2 outline-structure):
;; each is one undo step and falls through to the plain Outdent/Indent Lines and Move Line Up/Down
;; elsewhere, the same way md-lists.rkt's Enter/Tab/Shift-Tab fall through outside a list item.
;; Driven through the real registry and real (hidden) keymaps, plus direct unit tests of
;; md-outline.rkt's pure sibling/subtree model.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/frame.rkt"
         "../rackmac/editor.rkt" "../rackmac/buffer.rkt" "../rackmac/platform.rkt"
         "../rackmac/outline-structure.rkt" "../rackmac/md-outline.rkt"
         "../rackmac-markdown/main.rkt")

(define f (make-main-frame))

(define (note text)
  (define b (new-buffer! "outline.md" #:mode 'markdown-mode))
  (send b insert text)
  (send b clear-undos)
  (send b set-modified #f)
  (set-current-buffer! b)
  b)
(define (text b) (send b get-text))

;; ---- md-outline.rkt: the pure heading model (no buffer, no GUI) -------------------------------

(test-case "document-outline, siblings and subtree spans"
  (define full "# A\n## A1\n## A2\n# B\n## B1\n")
  (define doc (parse-document full))
  (define outline (document-outline doc))
  (check-equal? (map outline-heading-level outline) '(1 2 2 1 2))
  (define-values (A A1 A2 B B1) (apply values outline))
  (check-eq? (previous-sibling outline A2) A1)
  (check-false (previous-sibling outline A1) "A1 is A's first child, not a sibling of A")
  (check-eq? (next-sibling outline A) B)
  (check-false (next-sibling outline A2) "A2 is A's last child: nothing to move past")
  (define doc-end (string-length full))
  (check-equal? (heading-subtree-end outline A doc-end) (outline-heading-start B)
                "A's subtree includes its children, up to the next top-level heading")
  (check-equal? (heading-subtree-end outline A2 doc-end) (outline-heading-start B))
  (check-equal? (heading-subtree-end outline B1 doc-end) doc-end "the last heading's subtree runs to the end"))

;; ---- Promote / Demote -----------------------------------------------------------------------

(test-case "Demote increases a heading's level; Promote decreases it; each is one undo step"
  (define b (note "# Title\nbody"))
  (send b set-position 3)                  ; inside "Title"
  (run-command 'demote-heading)
  (check-equal? (text b) "## Title\nbody")
  (send b undo)
  (check-equal? (text b) "# Title\nbody")
  (check-false (send b can-do-edit-operation? 'undo) "one edit, one undo step")
  (run-command 'demote-heading)
  (run-command 'promote-heading)
  (check-equal? (text b) "# Title\nbody"))

(test-case "Demote on a setext heading (multiple edits: an insert and an underline removal) is one undo step"
  (define b (note "Title\n-----\nbody"))    ; a setext H2
  (send b set-position 2)
  (run-command 'demote-heading)             ; H2 -> H3: setext has no level 3, so it becomes ATX
  (check-equal? (text b) "### Title\nbody")
  (send b undo)
  (check-equal? (text b) "Title\n-----\nbody" "one undo step reverts both the insert and the removed underline")
  (check-false (send b can-do-edit-operation? 'undo)))

(test-case "Promote at H1 is a no-op (nothing higher than a level 1 heading)"
  (define b (note "# Title"))
  (run-command 'promote-heading)
  (check-equal? (text b) "# Title")
  (check-false (send b is-modified?) "no edit at all -- not even an undo step"))

(test-case "Demote at H6 is a no-op (nothing lower than a level 6 heading)"
  (define b (note "###### Title"))
  (run-command 'demote-heading)
  (check-equal? (text b) "###### Title")
  (check-false (send b is-modified?)))

(test-case "a selection spanning several headings demotes/promotes every one, as one undo step"
  (define b (note "## A\n### B\ntext"))
  (send b set-position 0 (send b last-position))
  (run-command 'demote-heading)
  (check-equal? (text b) "### A\n#### B\ntext")
  (send b undo)
  (check-equal? (text b) "## A\n### B\ntext" "one undo step for both headings")
  (check-false (send b can-do-edit-operation? 'undo) "one edit list, one undo step"))

(test-case "a selection spanning headings clamps only the ones already at the boundary"
  (define b (note "# A\n###### B\ntext"))
  (send b set-position 0 (send b last-position))
  (run-command 'demote-heading)
  (check-equal? (text b) "## A\n###### B\ntext" "A demotes; B (already H6) is left alone"))

(test-case "Promote/Demote off a heading line fall through to Outdent/Indent Lines"
  (define b (note "  plain"))
  (send b set-position 2)
  (run-command 'promote-heading)
  (check-equal? (text b) "plain")
  (run-command 'demote-heading)
  (check-equal? (text b) "  plain"))

(test-case "outside Markdown, Promote/Demote fall through unchanged"
  (define b (new-buffer! "t.rkt" #:mode 'racket-mode))
  (send b insert "  (+ 1 2)")
  (set-current-buffer! b)
  (send b set-position 2)
  (run-command 'promote-heading)
  (check-equal? (text b) "(+ 1 2)"))

;; ---- Move Section Up / Down -------------------------------------------------------------------

(test-case "Move Section Down moves a heading, with its subtree, past the next sibling"
  (define b (note "# A\n## A1\ntext\n# B\nmore\n"))
  (send b set-position 2)                  ; on "# A"'s own line
  (run-command 'move-section-down)
  (check-equal? (text b) "# B\nmore\n# A\n## A1\ntext\n" "the child heading A1 moved as part of A")
  (send b undo)
  (check-equal? (text b) "# A\n## A1\ntext\n# B\nmore\n" "one undo step")
  (check-false (send b can-do-edit-operation? 'undo) "one edit, one undo step"))

(test-case "Move Section Up moves a heading, with its subtree, past the previous sibling, as one undo step"
  (define b (note "# A\ntext\n# B\n## B1\nmore\n"))
  (send b set-position (+ (string-length "# A\ntext\n") 2))    ; on "# B"'s own line
  (run-command 'move-section-up)
  (check-equal? (text b) "# B\n## B1\nmore\n# A\ntext\n" "the child heading B1 moved as part of B")
  (send b undo)
  (check-equal? (text b) "# A\ntext\n# B\n## B1\nmore\n")
  (check-false (send b can-do-edit-operation? 'undo) "one edit, one undo step"))

(test-case "Move Section Down gives the moved-in section its own line when the document had no final newline"
  (define b (note "# A\ntext\n# B\nmore"))                     ; no trailing newline
  (send b set-position 2)                                     ; on "# A"'s own line
  (run-command 'move-section-down)
  (check-equal? (text b) "# B\nmore\n# A\ntext\n" "B does not run into A's text"))

(test-case "Move Section Up gives the moved-in section its own line when the document had no final newline"
  (define b (note "# A\ntext\n# B\nmore"))                     ; no trailing newline
  (send b set-position (+ (string-length "# A\ntext\n") 2))    ; on "# B"'s own line
  (run-command 'move-section-up)
  (check-equal? (text b) "# B\nmore\n# A\ntext\n" "B does not run into A's text"))

(test-case "Move Section Up at the top of the document is a no-op"
  (define b (note "# A\ntext\n# B\nmore\n"))
  (send b set-position 1)
  (run-command 'move-section-up)
  (check-equal? (text b) "# A\ntext\n# B\nmore\n")
  (check-false (send b is-modified?)))

(test-case "Move Section Down at the bottom of the document is a no-op"
  (define b (note "# A\ntext\n# B\nmore\n"))
  (send b set-position (+ (string-length "# A\ntext\n") 1))
  (run-command 'move-section-down)
  (check-equal? (text b) "# A\ntext\n# B\nmore\n")
  (check-false (send b is-modified?)))

(test-case "Move Section Up on a section's first child is a no-op (no sibling in its own section)"
  (define b (note "# A\n## A1\n# B\n## B1\nend\n"))
  (send b set-position (+ (string-length "# A\n## A1\n# B\n") 1))    ; on "## B1"
  (run-command 'move-section-up)
  (check-equal? (text b) "# A\n## A1\n# B\n## B1\nend\n")
  (check-false (send b is-modified?)))

(test-case "Move Section Up/Down off a heading line fall through to Move Line"
  (define b (note "one\ntwo\nthree"))
  (send b set-position 5)                  ; inside "two"; no headings anywhere
  (run-command 'move-section-down)
  (check-equal? (text b) "one\nthree\ntwo")
  (run-command 'move-section-up)
  (check-equal? (text b) "one\ntwo\nthree"))

(test-case "outside Markdown, Move Section falls through unchanged"
  (define b (new-buffer! "t2.rkt" #:mode 'racket-mode))
  (send b insert "one\ntwo")
  (set-current-buffer! b)
  (send b set-position 1)
  (run-command 'move-section-down)
  (check-equal? (text b) "two\none"))

;; ---- key dispatch through markdown-mode's own keymap -------------------------------------------

(define (kev code #:cmd [cmd #f] #:alt [alt #f])
  (new key-event% [key-code code] [meta-down cmd] [alt-down alt]))

(test-case "⌘[/⌘] and ⌥↑/⌥↓ dispatch through markdown-mode's own keymap, ahead of the global one"
  (parameterize ([current-platform 'mac])
    (define b (note "## Title\ntext"))
    (send b set-position 3)
    (send b on-char (kev #\] #:cmd #t))
    (check-equal? (text b) "### Title\ntext" "⌘] demotes")
    (send b on-char (kev #\[ #:cmd #t))
    (check-equal? (text b) "## Title\ntext" "⌘[ promotes")
    (define b2 (note "# A\ntext\n# B\nmore\n"))
    (send b2 set-position 2)
    (send b2 on-char (kev 'down #:alt #t))
    (check-equal? (text b2) "# B\nmore\n# A\ntext\n" "⌥↓ moves the section down")))
