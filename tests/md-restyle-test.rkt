#lang racket/base
;; Region restyle for Markdown notes (#266, docs/UI-DESIGN.md §5.3): each edit reparses through
;; the document's parser and restyles only what the change report names; the result always equals
;; a whole-document render; other styles elsewhere survive; styling is never an edit.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require "timing.rkt" rackunit racket/class racket/gui/base racket/list
         "../rackmac/editor.rkt" (only-in "../rackmac/buffer.rkt" large-file-threshold) "../rackmac/hook.rkt" "../rackmac/theme.rkt" "../rackmac/md-style.rkt"
         (only-in "../rackmac-markdown/main.rkt" document-text block-at block-start block-end)
         "../rackmac-markdown/tests/notes-gen.rkt")

(define (note text [name "restyle"])
  (define b (new-buffer! name #:mode 'markdown-mode))
  (send b insert text)
  (send b clear-undos)
  (send b set-modified #f)
  b)

;; Every restyle as (start . end), newest first, while `thunk` runs.
(define (restyles-during b thunk)
  (define seen '())
  (define (spy doc s e) (when (eq? doc b) (set! seen (cons (cons s e) seen))))
  (add-hook! 'document-restyled spy)
  (dynamic-wind void thunk (lambda () (remove-hook! 'document-restyled spy)))
  seen)

(define (paragraphs-in b r)
  (add1 (- (send b position-paragraph (cdr r)) (send b position-paragraph (car r)))))

;; The document's styles as a list of (length . style), adjacent equal styles merged.
(define (style-map b)
  (let loop ([s (send b find-first-snip)] [acc '()])
    (cond
      [(not s) (reverse acc)]
      [else
       (define st (send s get-style))
       (define n (send s get-count))
       (loop (send s next)
             (if (and (pair? acc) (eq? (cdar acc) st))
                 (cons (cons (+ n (caar acc)) st) (cdr acc))
                 (cons (cons n st) acc)))])))

(define (rendered-fresh text)
  (define b (note text "fresh"))
  (render-markdown! b)
  b)

(define big (generate-notes 5000 1))
(define big-note (note big "big"))

;; A position a few characters into the paragraph after `fraction` percent of the note.
(define (paragraph-position b fraction)
  (define doc (markdown-parser-document b))
  (define target (quotient (* fraction (send b last-position)) 100))
  (let loop ([p target])
    (define blk (block-at doc p))
    (if (and blk (= (send b position-paragraph (block-start blk)) (send b position-paragraph p))
             (> (- (block-end blk) (block-start blk)) 20)
             (char-alphabetic? (string-ref (send b get-text (+ 3 (block-start blk)) (+ 4 (block-start blk))) 0)))
        (+ 3 (block-start blk))
        (loop (add1 (send b paragraph-start-position (add1 (send b position-paragraph p))))))))

(test-case "a keystroke restyles only the paragraph it is in"
  (define pos (paragraph-position big-note 50))
  (define blk (block-at (markdown-parser-document big-note) pos))
  (define block-paragraphs (paragraphs-in big-note (cons (block-start blk) (block-end blk))))
  (define seen (restyles-during big-note (lambda () (send big-note insert "x" pos))))
  (check-equal? (length seen) 1 "one region")
  (define count (for/sum ([r (in-list seen)]) (paragraphs-in big-note r)))
  (printf "restyled paragraphs for one keystroke in a ~a-line note: ~a (the block has ~a)\n"
          (add1 (send big-note last-paragraph)) count block-paragraphs)
  (check-true (<= 1 count block-paragraphs))
  (send big-note delete pos (add1 pos))
  (check-equal? (send big-note get-text) big))

(test-case "typing in a 5,000-line note costs under 10 ms a keystroke (asserted with a 3x margin)"
  (define keystrokes 100)
  (for ([fraction (in-list '(5 50 95))])
    (define pos (paragraph-position big-note fraction))
    (collect-garbage)
    (define t0 (current-process-milliseconds))
    (for ([i (in-range keystrokes)]) (send big-note insert "x" (+ pos i)))
    (define typing (/ (- (current-process-milliseconds) t0) keystrokes 1.0))
    (define t1 (current-process-milliseconds))
    (for ([i (in-range keystrokes)]) (send big-note delete (+ pos (- keystrokes i 1)) (+ pos (- keystrokes i))))
    (define deleting (/ (- (current-process-milliseconds) t1) keystrokes 1.0))
    (printf "keystroke at ~a% of a 5,000-line note: typing ~a ms, Backspace ~a ms CPU (mean of ~a)\n"
            fraction typing deleting keystrokes)
    (check-true (< typing (budget 30)) (format "~a ms per typed character" typing))
    (check-true (< deleting (budget 30)) (format "~a ms per deleted character" deleting)))
  (check-equal? (send big-note get-text) big))

(test-case "opening a 5,000-line note renders it once, as a whole"
  (define b (new-buffer! "open" #:mode 'text-mode))
  (send b insert big)
  (collect-garbage)
  (define t0 (current-process-milliseconds))
  (define seen (restyles-during b (lambda () (send b set-mode! 'markdown-mode))))
  (printf "first render of a ~a KB, 5,000-line note: ~a ms CPU\n"
          (quotient (string-length big) 1000) (- (current-process-milliseconds) t0))
  (check-equal? seen (list (cons 0 (send b last-position)))))

(test-case "the region restyle always equals a whole-document render"
  (define text (generate-notes 80 7))
  (define b (note text))
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng]) (random-seed 11))
  (define snippets '("x" " " "\n" "\n\n" "# " "- " "> " "**" "*" "`" "```\n" "[a](b)" "1. " "  " "---\n"))
  (for ([round (in-range 60)])
    (define (one-edit!)
      (define n (send b last-position))
      (define at (random (add1 n) rng))
      (if (and (> n 0) (zero? (random 3 rng)))
          (send b delete at (min n (+ at 1 (random 12 rng))))
          (send b insert (list-ref snippets (random (length snippets) rng)) at)))
    (if (zero? (random 4 rng))
        ;; several edits in one sequence (Replace All, Undo) are restyled once, at its end
        (begin (send b begin-edit-sequence) (for ([k (in-range 3)]) (one-edit!)) (send b end-edit-sequence))
        (one-edit!))
    (define now (send b get-text))
    (check-equal? (document-text (markdown-parser-document b)) now "the parser follows the text")
    (check-equal? (style-map b) (style-map (rendered-fresh now)) (format "round ~a: ~s" round now))))

(test-case "styles from other sources outside the edited paragraph survive"
  (define b (note "# Notes\n\nFirst paragraph here.\n\nSecond paragraph here.\n"))
  (define mark (make-object style-delta%))
  (send mark set-delta-background "yellow")
  (send b change-style mark 10 15)        ; like a find highlight, in the first paragraph
  (define marked (send (send b find-snip 11 'after) get-style))
  (send b insert "More " 33)              ; typing in the second paragraph
  (check-eq? (send (send b find-snip 11 'after) get-style) marked))

(test-case "styling is never an edit: nothing to undo, not modified, undo restores the text"
  (define b (note "Plain line.\n"))
  (render-markdown! b)
  (check-false (send b is-modified?))
  (check-false (send b can-do-edit-operation? 'undo))
  (send b insert "# " 0)                   ; becomes a heading, restyled at once
  (check-equal? (send (send (send (send b find-snip 4 'after) get-style) get-font) get-weight) 'bold)
  (send b undo)
  (check-equal? (send b get-text) "Plain line.\n")
  (check-false (send b can-do-edit-operation? 'undo) "one edit, one undo: the restyle added none")
  (check-equal? (style-map b) (style-map (rendered-fresh "Plain line.\n")) "and the heading style is gone"))

(test-case "a whole-document restyle happens on open and Language change, not on typing"
  (define b (new-buffer! "lang" #:mode 'text-mode))
  (send b insert "- item\n")
  (define seen (restyles-during b (lambda () (send b set-mode! 'markdown-mode))))
  (check-equal? seen (list (cons 0 7)))
  (define typing (restyles-during b (lambda () (send b insert "s" 6))))
  (check-true (andmap (lambda (r) (< (- (cdr r) (car r)) 8)) typing))
  (send b set-mode! 'text-mode)
  (define base (send editor-style-list find-named-style "Prose"))
  (check-equal? (style-map b) (list (cons 8 base)) "back to plain prose")
  (define typing-plain (restyles-during b (lambda () (send b insert "# " 0))))
  (check-equal? typing-plain '() "Plain Text is not restyled by the parser"))

(test-case "large documents are not styled, and are styled again once they shrink"
  (parameterize ([large-file-threshold 40])
    (define b (note "# Title\n\nshort\n"))
    (send b insert (make-string 50 #\a) 15)
    (check-true (send b large?))
    (check-false (markdown-parser-document b) "no parser kept for a large document")
    (send b delete 15 65)
    (check-false (send b large?))
    (check-equal? (document-text (markdown-parser-document b)) "# Title\n\nshort\n")
    (check-equal? (style-map b) (style-map (rendered-fresh "# Title\n\nshort\n")))))
