#lang racket/base
;; Selection actions (#125-#129, docs/REPLAN.md E7.M3 "Selection actions", sub-milestone
;; "Text tools"): Change Case, Sort Lines, Swap Words/Lines, Wrap to Width and Trim Trailing
;; Whitespace. Unlike md-format.rkt's commands these are plain text transforms with no
;; Markdown-tree awareness -- they read and rewrite characters and lines the same way in a note
;; or a code file -- so they live in the Edit menu (not Format, which only prose documents show,
;; frame.rkt) and carry no `#:when markdown-document?` guard. They still go through md-doc.rkt's
;; `apply-md-edits!` (the same edit-application mechanism md-format.rkt, md-lists.rkt and
;; outline-structure.rkt use) so each is one undo step and plays well with the incremental
;; restyler, rather than poking the buffer's `insert` directly.
;;
;; Menu-order 70+ is a fresh tens-decade after the "Spelling" submenu (60, spell.rkt) so the
;; group gets its own separator (frame.rkt: a new tens digit adds one). Change Case has three
;; variants, so it is its own submenu (the same register-submenu! shape as "Spelling"); its
;; items carry no #:menu of their own, so they are exempt from icons-test.rkt's "every menu
;; command needs an icon" rule the same way Check Spelling While Typing/Check Document Now are.
(require racket/class racket/gui/base racket/list racket/string
         "command.rkt" "editor.rkt" "frame.rkt" "settings.rkt" "md-doc.rkt" "../rackmac-markdown/main.rkt")

(define-setting wrap-width
  #:contract exact-positive-integer?
  #:default 80
  #:category "Notes"
  #:doc "Column width Wrap to Width hard-wraps the selected paragraph(s) to.")

;; ---- shared line/paragraph helpers ------------------------------------------------------------
;; Reimplemented here rather than imported: commands.rkt's `selected-lines`/`line-text` are
;; private to that module, and docs/DEVELOPMENT.md's collision rule keeps new features out of
;; commands.rkt, so this is the "own module" side of the same paragraph-range idiom.

(define (para-line-text b p)
  (send b document-text (send b paragraph-start-position p) (send b paragraph-end-position p) #:keep-positions? #t))

;; The paragraph (line) range covered by the selection; a selection that ends at the very start
;; of a line does not count that line (the same rule commands.rkt's selected-lines uses).
(define (selection-line-range b)
  (define s (send b get-start-position))
  (define e (send b get-end-position))
  (define e* (if (and (> e s) (= e (send b paragraph-start-position (send b position-paragraph e)))) (sub1 e) e))
  (values (send b position-paragraph s) (send b position-paragraph e*)))

(define (blank-line? s) (string=? (string-trim s) ""))

;; ---- Change Case (#125) ------------------------------------------------------------------------
;; The selection, or the word at the cursor -- the same "selection, or word at the cursor"
;; fallback md-format.rkt's toggle-emphasis! uses for Bold/Italic/etc, via buffer.rkt's own
;; word-bounds-at (the double-click word-selection logic).

(define (case-range b)
  (define-values (s e) (selection-range b))
  (if (= s e) (send b word-bounds-at s) (values s e)))

;; Case-mapping a string can change its length (e.g. German "ß" upcases to "SS"), so the new
;; caret/selection end is measured from the transformed text, not assumed equal to the old one.
(define (change-case! transform)
  (define b (current-buffer))
  (define-values (s e) (case-range b))
  (when (< s e)
    (define new-text (transform (send b document-text s e #:keep-positions? #t)))
    (apply-md-edits! b (list (edit s e new-text)))
    (send b set-position s (+ s (string-length new-text)))))

(define-command (change-case-upper)
  #:title "UPPERCASE"
  #:aliases ("uppercase" "upper case" "all caps" "shout")
  #:help "Change the selection, or the word at the cursor, to UPPERCASE."
  (change-case! string-upcase))

(define-command (change-case-lower)
  #:title "lowercase"
  #:aliases ("lowercase" "lower case")
  #:help "Change the selection, or the word at the cursor, to lowercase."
  (change-case! string-downcase))

(define-command (change-case-title)
  #:title "Title Case"
  #:aliases ("title case" "capitalize words" "capitalize each word")
  #:help "Change the selection, or the word at the cursor, to Title Case."
  (change-case! string-titlecase))

(define (change-case-menu-items) '(change-case-upper change-case-lower change-case-title))
(define (populate-change-case! m)
  (for ([name (in-list (change-case-menu-items))])
    (define c (find-command name))
    (define item (new menu-item% [label (command-menu-label name)] [parent m]
                      [callback (lambda (i e) (run-command/safe name))]))
    (send item enable (command-enabled? c))))
(register-submenu! "Change Case" #:menu "Edit" #:menu-order 75 populate-change-case!)

;; ---- Sort Lines (#126) --------------------------------------------------------------------------

(define-command (sort-lines)
  #:icon "replace"   ; the Workbench outline behind this name is literally a sort glyph
  #:title "Sort Lines" #:menu "Edit" #:menu-order 70
  #:aliases ("sort selection" "alphabetize" "sort alphabetically")
  #:help "Sort the selected lines alphabetically."
  ;; Case-insensitively, like Word's Sort and Excel's default: "Zebra" and "apple" land by
  ;; letter, not by case, which is what a reader expects from an alphabetized list of names.
  (define b (current-buffer))
  (define-values (p1 p2) (selection-line-range b))
  (when (> p2 p1)   ; nothing to reorder in a single line (also the no-selection fallback)
    (define lines (for/list ([p (in-range p1 (add1 p2))]) (para-line-text b p)))
    (define sorted (sort lines string-ci<?))
    (unless (equal? lines sorted)   ; already sorted: leave the document (and undo history) alone
      (define a (send b paragraph-start-position p1))
      (define z (send b paragraph-end-position p2))
      (apply-md-edits! b (list (edit a z (string-join sorted "\n"))))
      (send b set-position a z))))

;; ---- Swap Words and Swap Lines (#127) -------------------------------------------------------
;; Word-processor "transpose" commands: aliased as "transpose words"/"transpose lines" so the
;; palette finds them under that generic word-processing term (docs/DEVELOPMENT.md's no-Emacs
;; rule bars Emacs-specific vocabulary, not "transpose" itself, which predates and outlives
;; Emacs in general editing use). Two commands, not one: "words" and "lines" act at different
;; grains (a caret position vs. a line), so a single command would need a mode switch to tell
;; them apart, more surprising than two small, single-purpose ones.

(define (word-char? ch) (or (char-alphabetic? ch) (char-numeric? ch) (eqv? ch #\_)))

;; The (start . end) of the word ending at or before `i`, skipping any run of non-word
;; characters between it and `i`; #f if `i` has no word before it (e.g. the document start).
(define (word-end-before text i)
  (define j (let loop ([j i]) (if (and (> j 0) (not (word-char? (string-ref text (sub1 j))))) (loop (sub1 j)) j)))
  (and (> j 0) (word-char? (string-ref text (sub1 j)))
       (cons (let loop ([k j]) (if (and (> k 0) (word-char? (string-ref text (sub1 k)))) (loop (sub1 k)) k)) j)))

;; The (start . end) of the word starting at or after `i`, the mirror of word-end-before.
(define (word-start-after text i)
  (define len (string-length text))
  (define j (let loop ([j i]) (if (and (< j len) (not (word-char? (string-ref text j)))) (loop (add1 j)) j)))
  (and (< j len) (word-char? (string-ref text j))
       (cons j (let loop ([k j]) (if (and (< k len) (word-char? (string-ref text k))) (loop (add1 k)) k)))))

(define-command (swap-words)
  #:icon "run-all"
  #:title "Swap Words" #:menu "Edit" #:menu-order 73
  #:aliases ("transpose words" "swap word" "exchange words")
  #:help "Swap the word before the cursor with the word after it."
  (define b (current-buffer))
  (define text (send b document-text #:keep-positions? #t))
  (define pos0 (send b get-start-position))
  ;; A caret strictly inside a word counts as being past it, so the swap always trades two
  ;; whole words instead of splitting the one under the caret.
  (define-values (ws we) (send b word-bounds-at pos0))
  (define pos (if (< ws pos0 we) we pos0))
  (define left (word-end-before text pos))
  (define right (word-start-after text pos))
  (when (and left right)
    (define left-text (substring text (car left) (cdr left)))
    (define mid-text (substring text (cdr left) (car right)))
    (define right-text (substring text (car right) (cdr right)))
    (apply-md-edits! b (list (edit (car left) (cdr right) (string-append right-text mid-text left-text))))
    (define caret (+ (car left) (string-length right-text) (string-length mid-text) (string-length left-text)))
    (send b set-position caret caret)))

(define-command (swap-lines)
  #:icon "arrow-down"
  #:title "Swap Lines" #:menu "Edit" #:menu-order 74
  #:aliases ("transpose lines" "swap line" "exchange lines")
  #:help "Swap the current line with the line below it (or above it, at the last line)."
  (define b (current-buffer))
  (define last-p (send b last-paragraph))
  (define p (send b position-paragraph (send b get-start-position)))
  (define other (cond [(< p last-p) (add1 p)] [(> p 0) (sub1 p)] [else #f]))   ; #f: a one-line document
  (when other
    (define p1 (min p other)) (define p2 (max p other))
    (define line1 (para-line-text b p1)) (define line2 (para-line-text b p2))
    (define a (send b paragraph-start-position p1)) (define z (send b paragraph-end-position p2))
    (define mid (send b document-text (send b paragraph-end-position p1) (send b paragraph-start-position p2) #:keep-positions? #t))
    (apply-md-edits! b (list (edit a z (string-append line2 mid line1))))
    ;; The caret stays on the same row (p): whichever half of the swap landed there.
    (send b set-position (send b paragraph-start-position p))))

;; ---- Wrap to Width (#128) --------------------------------------------------------------------
;; Greedy word wrap of the selected paragraph(s) -- consecutive plain lines, stopping at a blank
;; line or a structural one (heading, list, quote, etc., below) -- to the `wrap-width` setting.
;; Absent a selection, it wraps the one paragraph the caret is in, the same "act on the current
;; line/paragraph when nothing is selected" fallback duplicate-line and friends use.

(define (words-of text) (filter (lambda (s) (not (string=? s ""))) (regexp-split #px"\\s+" (string-trim text))))

(define (wrap-paragraph-text text width)
  (define words (words-of text))
  (cond
    [(null? words) ""]
    [else
     (define-values (done last-line)
       (for/fold ([done '()] [cur (car words)]) ([w (in-list (cdr words))])
         (define candidate (string-append cur " " w))
         (if (<= (string-length candidate) width) (values done candidate) (values (cons cur done) w))))
     (string-join (reverse (cons last-line done)) "\n")]))

;; A heading, list item, blockquote, (4-space) code line, setext underline, thematic break,
;; fence or table row: joining it with a neighbor would corrupt the structure (a bullet
;; swallowed into the following paragraph, a heading's "#" merged with body text), and
;; wrapping it on its own could still split its marker from its text (a long heading breaking
;; into "#" and "Heading" on separate lines). So it is left alone entirely, the same as a blank
;; line: it breaks the paragraph it would otherwise join, and is never itself rewritten. Known
;; limitations: an over-width list item or heading is never rewrapped here, and a fence's
;; *contents* (not caught by this line-level check) still wrap like plain text.
(define structural-line-rx
  #px"^ {0,3}(#{1,6}([ \t]|$)|[-*+][ \t]|[0-9]{1,9}[.)][ \t]|>|[|]|[-=*_]{3,}[ \t]*$|```|~~~)|^ {4,}\\S")
(define (structural-line? s) (regexp-match? structural-line-rx s))
;; Either kind of line that a paragraph must not be joined across: a real paragraph break.
(define (boundary-line? s) (or (blank-line? s) (structural-line? s)))

;; The contiguous run of plain paragraphs around `p` (its own paragraph if both neighbors are
;; blank or structural, or the document's edges).
(define (expand-to-paragraph b p)
  (define last-p (send b last-paragraph))
  (define p1 (let loop ([q p]) (if (and (> q 0) (not (boundary-line? (para-line-text b (sub1 q))))) (loop (sub1 q)) q)))
  (define p2 (let loop ([q p]) (if (and (< q last-p) (not (boundary-line? (para-line-text b (add1 q))))) (loop (add1 q)) q)))
  (cons p1 p2))

;; The paragraph range to wrap, as (p1 . p2), or #f (a selection-less caret on a blank or
;; structural line -- a heading or list item is never expanded into its neighbors).
(define (wrap-target-lines b)
  (define-values (s e) (selection-range b))
  (cond
    [(> e s) (define-values (p1 p2) (selection-line-range b)) (cons p1 p2)]
    [else (define p (send b position-paragraph s))
          (and (not (boundary-line? (para-line-text b p))) (expand-to-paragraph b p))]))

;; Consecutive plain (non-blank, non-structural) paragraphs within [p1, p2], grouped so each
;; group is wrapped as its own paragraph; blank and structural lines break the run and are
;; skipped, joining nothing and never rewritten themselves.
(define (paragraph-groups b p1 p2)
  (define (flush cur groups) (if (null? cur) groups (cons (reverse cur) groups)))
  (let loop ([p p1] [cur '()] [groups '()])
    (cond
      [(> p p2) (reverse (flush cur groups))]
      [(boundary-line? (para-line-text b p)) (loop (add1 p) '() (flush cur groups))]
      [else (loop (add1 p) (cons p cur) groups)])))

(define-command (wrap-to-width)
  #:icon "wrap"   ; the pilcrow (¶) glyph behind "wrap" already means "paragraph" here
  #:title "Wrap to Width" #:menu "Edit" #:menu-order 71
  #:aliases ("wrap text" "wrap paragraph" "hard wrap" "fill paragraph" "reflow paragraph")
  #:help "Hard-wrap the selected paragraph(s) to the configured column width."
  (define b (current-buffer))
  (define range (wrap-target-lines b))
  (define width (setting-ref 'wrap-width))
  (define edits
    (if (not range) '()
        (filter-map
         (lambda (g)
           (define a (send b paragraph-start-position (car g))) (define z (send b paragraph-end-position (last g)))
           (define joined (string-join (for/list ([q (in-list g)]) (para-line-text b q)) " "))
           (define wrapped (wrap-paragraph-text joined width))
           ;; Already wrapped (or short enough): skip it, the same "leave it alone" rule Sort
           ;; Lines uses, so re-running this on unchanged text is not a spurious undo step.
           (and (not (equal? wrapped (send b document-text a z #:keep-positions? #t))) (edit a z wrapped)))
         (paragraph-groups b (car range) (cdr range)))))
  (unless (null? edits)
    (define s0 (edit-start (car edits))) (define e0 (edit-end (last edits)))
    (apply-md-edits! b edits)
    ;; s0/e0 are exactly the first/last edit's own old bounds (a full-range replacement, unlike
    ;; md-format.rkt's insertions strictly inside the selection), so the bias is the other way
    ;; around from that convention: 'before keeps the start where the replacement begins, 'after
    ;; carries the end past everything the edits inserted.
    (send b set-position (map-position edits s0 'before) (map-position edits e0 'after))))

;; ---- Trim Trailing Whitespace (#129) ----------------------------------------------------------
;; Scope, since the issue does not say: the selected lines, like the other line-based commands
;; above; a collapsed caret (nothing selected) trims the whole document, the same breadth
;; Select All gives a bare caret, rather than a no-op or "just this line" (a document-wide cleanup
;; is the more useful reading of running this with nothing selected).

(define (trailing-ws-end text)
  (let loop ([i (string-length text)]) (if (and (> i 0) (char-whitespace? (string-ref text (sub1 i)))) (loop (sub1 i)) i)))

(define-command (trim-trailing-whitespace)
  #:icon "delete-line"
  #:title "Trim Trailing Whitespace" #:menu "Edit" #:menu-order 72
  #:aliases ("trim whitespace" "trim trailing spaces" "remove trailing spaces" "clean up whitespace")
  #:help "Remove trailing whitespace from each selected line, or the whole document if nothing is selected."
  (define b (current-buffer))
  (define-values (s e) (selection-range b))
  (define-values (p1 p2) (if (= s e) (values 0 (send b last-paragraph)) (selection-line-range b)))
  (define edits
    (filter-map
     (lambda (p)
       (define txt (para-line-text b p))
       (define cut (trailing-ws-end txt))
       (and (< cut (string-length txt))
            (edit (+ (send b paragraph-start-position p) cut) (send b paragraph-end-position p) "")))
     (range p1 (add1 p2))))
  (unless (null? edits)
    (define ns (map-position edits s 'after)) (define ne (map-position edits e 'before))
    (apply-md-edits! b edits)
    (send b set-position ns ne)))
