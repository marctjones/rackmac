#lang racket/base
;; The pure model behind #343 (pipe-table alignment on Tab), #414 (row/column insert-delete and
;; cell navigation) and #415 (sort table by column), docs/REPLAN.md E14.M3 Tables. Pure (no GUI,
;; no buffer dependency, the same shape as md-outline.rkt) so rackmac/md-tables.rkt's commands --
;; and this module's own tests -- share ONE "find the table at a position, and rebuild its text"
;; implementation instead of three. That sharing is the whole reason the three issues are one
;; module: alignment, structural edits and sorting all call `render-table`, so they can never
;; disagree about column widths or produce a table one of the others would reflow differently.
;;
;; Tables here are read straight from rackmac-markdown's parsed AST (mdlib-ext's `table`/
;; `table-cell`, already GFM-aware): a table's rows are already padded or cut to its header's
;; width by the parser (ast.rkt), so a malformed, ragged source table (a row with fewer cells
;; than the header) parses into a perfectly rectangular `header`/`rows` here -- nothing in this
;; module has to special-case it. Every command works on plain strings (`header`: a list of
;; ncols raw cell texts; `rows`: a list of those lists) taken verbatim from the source (escaped
;; pipes and inline markup kept as written) and produces a fresh `render-table` string plus the
;; buffer offsets of every cell's content, never touching a cell's text itself -- so nothing here
;; can change what a cell means, only where the `|`s and blank rows/columns fall. That also means
;; the change is inert to anything that reads the Markdown by its own parser (a Word/PDF
;; exporter): parsers trim cell whitespace the same way, so realigning columns can't change what
;; they see (#343's "export unchanged").
(require racket/list "../rackmac-markdown/main.rkt")
(provide (struct-out table-at) table-at-caret
         extract-header extract-rows render-table
         tab-target row-blank? list-insert blank-row
         insert-row-above insert-row-below delete-row
         insert-column-left insert-column-right delete-column
         column-ascending? sort-by-column)

;; ============================================================================================
;; Finding the table at a position
;; ============================================================================================

;; `t`: the table AST node. `row`: 'header, 'delimiter, or a 0-based index into (table-rows t).
;; `col`: the 0-based column index the position falls in.
(struct table-at (t row col) #:transparent)

;; The top-level `table` block whose span contains `pos` (its end included, block-at's own
;; convention), or #f. Tables nested in a block quote or list item are deliberately not found:
;; a table's span starts after its container prefix (`> `), so replacing it wholesale would drop
;; that prefix from every line but the first. Top-level only is what md-outline.rkt does for
;; headings too (see #413 for the nested-container seam); a nested table just gets the plain
;; Tab/Enter behavior. This is a location helper, not a second table parser: structure and
;; content come entirely from the library's own `table` node.
(define (find-table doc pos)
  (for/first ([k (in-list (document-children doc))]
              #:when (and (table? k) (<= (block-start k) pos (block-end k))))
    k))

(define (line-start-of text p)
  (let loop ([i p]) (if (and (> i 0) (not (eqv? (string-ref text (sub1 i)) #\newline))) (loop (sub1 i)) i)))
(define (line-end-of text p)
  (define n (string-length text))
  (let loop ([i p]) (if (and (< i n) (not (eqv? (string-ref text i) #\newline))) (loop (add1 i)) i)))
(define (skip-ws text s e)
  (let loop ([i s]) (if (and (< i e) (memv (string-ref text i) '(#\space #\tab))) (loop (add1 i)) i)))
(define (count-newlines text s e)
  (for/sum ([i (in-range s (min e (string-length text)))] #:when (eqv? (string-ref text i) #\newline)) 1))

;; The column a real (non-padding) cell list's containment tests put `pos` in: the first cell
;; whose end reaches `pos` (so a caret in a cell's own span, or in the trimmed gap just before
;; it -- the space or `|` a user's caret naturally lands on -- both count as that cell), else the
;; last column.
(define (column-of-cells cells pos ncols)
  (or (for/first ([c (in-list cells)] [i (in-naturals)] #:when (<= pos (block-end c))) i)
      (sub1 ncols)))

;; The delimiter row has no cell nodes (finalize-table keeps only its alignments), so its column
;; is counted directly from the `|` characters on that one line -- always plain `-`, `:`, spaces
;; and pipes, so no escape-awareness is needed the way a content cell would.
(define (column-of-delimiter text ls le pos ncols)
  (define ts (skip-ws text ls le))
  (define lead? (and (< ts le) (eqv? (string-ref text ts) #\|)))
  (define n (for/sum ([i (in-range ls (max ls (min pos le)))] #:when (eqv? (string-ref text i) #\|)) 1))
  (max 0 (min (if lead? (sub1 n) n) (sub1 ncols))))

;; The pipe table at buffer position `pos` in parsed document `doc`, or #f outside one. A table's
;; rows are contiguous source lines by construction (GFM pipe tables end at the first line that
;; doesn't fit), so which row `pos` is on is just a line count from the table's start: line 0 is
;; the header, line 1 the delimiter row, line 2+ a data row.
(define (table-at-caret doc pos)
  (define text (document-text doc))
  (define t (find-table doc pos))
  (and t
       (let* ([ncols (length (table-alignments t))]
              [rows (table-rows t)]
              [line (count-newlines text (block-start t) pos)])
         (cond
           [(= line 0) (table-at t 'header (column-of-cells (table-head t) pos ncols))]
           [(or (= line 1) (null? rows))
            (table-at t 'delimiter
                      (column-of-delimiter text (line-start-of text pos) (line-end-of text pos) pos ncols))]
           [else
            (define ri (min (- line 2) (sub1 (length rows))))
            (table-at t ri (column-of-cells (list-ref rows ri) pos ncols))]))))

;; ============================================================================================
;; Reading and rendering
;; ============================================================================================

;; The table's cell texts verbatim from the source (escapes, inline markup and all) -- never the
;; parser's de-escaped `content`, since that's what has to go back between fresh `|`s unchanged.
(define (extract-header t text)
  (for/list ([c (in-list (table-head t))]) (substring text (block-start c) (block-end c))))
(define (extract-rows t text)
  (for/list ([r (in-list (table-rows t))])
    (for/list ([c (in-list r)]) (substring text (block-start c) (block-end c)))))

;; Splits `extra` spaces around `s` for column width `width` under alignment `a`.
(define (pad-cell s width a)
  (define extra (max 0 (- width (string-length s))))
  (case a
    [(right) (values (make-string extra #\space) "")]
    [(center) (let ([l (quotient extra 2)]) (values (make-string l #\space) (make-string (- extra l) #\space)))]
    [else (values "" (make-string extra #\space))]))

;; A delimiter cell of `w` characters (at least 3, so there's room for a leading and/or trailing
;; `:` and at least one `-`) matching alignment `a`.
(define (delim-cell-text w a)
  (case a
    [(left) (string-append ":" (make-string (sub1 w) #\-))]
    [(right) (string-append (make-string (sub1 w) #\-) ":")]
    [(center) (string-append ":" (make-string (max 1 (- w 2)) #\-) ":")]
    [else (make-string w #\-)]))

;; One rendered row "| c1 | c2 | ... |" whose first character sits at absolute position `pos0` in
;; the text `render-table` is building. Returns the row's own text and, for each cell, the
;; (start . end) span of its real content (never the alignment padding), as absolute positions
;; in that same text -- what every command in md-tables.rkt selects after an edit.
(define (render-row cells widths aligns pos0)
  (for/fold ([text "|"] [pos (add1 pos0)] [spans '()] #:result (values text (reverse spans)))
            ([c (in-list cells)] [w (in-list widths)] [a (in-list aligns)])
    (define-values (lp rp) (pad-cell c w a))
    (define seg (string-append " " lp c rp " |"))
    (define s0 (+ pos 1 (string-length lp)))
    (define s1 (+ s0 (string-length c)))
    (values (string-append text seg) (+ pos (string-length seg)) (cons (cons s0 s1) spans))))

;; Renders `header`/`rows` (each a list of ncols raw cell-text strings) under `aligns` into
;; canonical, column-aligned GFM table text: every column padded to its widest cell (at least 3
;; characters). Returns the text, the header's per-cell content spans, and each row's. Idempotent
;; -- re-rendering the header/rows read back out of its own output reproduces the same text byte
;; for byte -- which is #343's round-trip: aligning an already-aligned table is a no-op.
(define (render-table header rows aligns)
  (define ncols (length aligns))
  (define widths
    (for/list ([i (in-range ncols)])
      (apply max 3 (for/list ([r (in-list (cons header rows))]) (string-length (list-ref r i))))))
  (define delim-cells (for/list ([w (in-list widths)] [a (in-list aligns)]) (delim-cell-text w a)))
  (define-values (header-text header-spans) (render-row header widths aligns 0))
  (define delim-pos (add1 (string-length header-text)))
  (define-values (delim-text delim-spans) (render-row delim-cells widths aligns delim-pos))
  (define-values (rows-text row-spans final-pos)
    (for/fold ([txt ""] [spans '()] [pos (+ delim-pos (string-length delim-text))])
              ([r (in-list rows)])
      (define-values (line-text line-spans) (render-row r widths aligns (add1 pos)))
      (values (string-append txt "\n" line-text) (cons line-spans spans) (+ pos 1 (string-length line-text)))))
  (values (string-append header-text "\n" delim-text rows-text) header-spans (reverse row-spans)))

;; ============================================================================================
;; Cell navigation: Tab / Shift-Tab (#343, #414)
;; ============================================================================================

;; Inserts `x` at index `i` of `lst`.
(define (list-insert lst i x)
  (define-values (a b) (split-at lst i))
  (append a (list x) b))

;; The (values target-row target-col grow?) Tab (`dir` 1) or Shift-Tab (`dir` -1) moves to from
;; `row`/`col` of a table with `ncols` columns and `R` data rows: cell to cell along the header,
;; then every data row in turn; Tab past the very last cell asks for a fresh blank row (`grow?`,
;; the Word/Excel convention); Shift-Tab before the very first cell just stays there. The
;; delimiter row isn't part of this sequence (a caret there is a rare direct click, not typing
;; flow), so it jumps straight to its nearer neighbor instead of counting cells.
(define (tab-target ncols R row col dir)
  (cond
    [(eq? row 'delimiter)
     (if (> dir 0)
         (if (> R 0) (values 0 0 #f) (values R 0 #t))
         (values 'header (sub1 ncols) #f))]
    [else
     (define flat (if (eq? row 'header) col (+ ncols (* row ncols) col)))
     (define total (* ncols (add1 R)))
     (define nf (+ flat dir))
     (cond
       [(< nf 0) (values 'header 0 #f)]
       [(>= nf total) (values R 0 #t)]
       [(< nf ncols) (values 'header nf #f)]
       [else (values (quotient (- nf ncols) ncols) (remainder (- nf ncols) ncols) #f)])]))

;; ============================================================================================
;; Row and column structure (#414)
;; ============================================================================================

(define (row-blank? row) (for/and ([c (in-list row)]) (string=? c "")))

(define (blank-row ncols) (make-list ncols ""))

(define (insert-row-above header rows aligns row col)
  (define at (max 0 (if (integer? row) row -1)))
  (values header (list-insert rows at (blank-row (length header))) aligns at col))

(define (insert-row-below header rows aligns row col)
  (define at (add1 (if (integer? row) row -1)))
  (values header (list-insert rows at (blank-row (length header))) aligns at col))

;; No-op on the header/delimiter (there's no row there to delete) and on an already-empty table.
(define (delete-row header rows aligns row col)
  (cond
    [(or (not (integer? row)) (null? rows)) (values header rows aligns row col)]
    [else
     (define new-rows (append (take rows row) (drop rows (add1 row))))
     (define target (if (null? new-rows) 'header (min row (sub1 (length new-rows)))))
     (values header new-rows aligns target col)]))

(define (insert-column header rows aligns row at)
  (values (list-insert header at "")
          (for/list ([r (in-list rows)]) (list-insert r at ""))
          (list-insert aligns at #f)
          (if (integer? row) row 'header)
          at))

(define (insert-column-left header rows aligns row col) (insert-column header rows aligns row col))
(define (insert-column-right header rows aligns row col) (insert-column header rows aligns row (add1 col)))

;; No-op on a table's last remaining column: a table always has at least one.
(define (delete-column header rows aligns row col)
  (define ncols (length header))
  (cond
    [(<= ncols 1) (values header rows aligns row col)]
    [else
     (define (rm lst) (append (take lst col) (drop lst (add1 col))))
     (define new-header (rm header))
     (values new-header (for/list ([r (in-list rows)]) (rm r)) (rm aligns)
             (if (integer? row) row 'header) (min col (sub1 (length new-header))))]))

;; ============================================================================================
;; Sort Table by Column (#415)
;; ============================================================================================

;; Whether `rows`, compared case-insensitively on column `col`, are already non-decreasing --
;; used to toggle the sort direction without remembering anything between commands: running the
;; command again on a column already sorted ascending by it reverses to descending, matching the
;; common spreadsheet toggle.
(define (column-ascending? rows col)
  (define keys (for/list ([r (in-list rows)]) (list-ref r col)))
  (for/and ([a (in-list keys)] [b (in-list (cdr keys))]) (not (string-ci<? b a))))

;; Sorts `rows` by column `col`, case-insensitively and stably (ties keep their relative order --
;; Racket's `sort` is a stable mergesort regardless of which way the comparator points, so this
;; holds for descending too). Header and rows are otherwise untouched.
(define (sort-by-column header rows aligns row col)
  (define descending? (column-ascending? rows col))
  (define cmp (if descending? string-ci>? string-ci<?))
  (define sorted (sort rows cmp #:key (lambda (r) (list-ref r col))))
  (values header sorted aligns (if (integer? row) row 'header) col))
