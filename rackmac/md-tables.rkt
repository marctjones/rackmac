#lang racket/base
;; Pipe-table editing commands (#343 md-tables, #414 md-table-editing, #415 md-table-sort,
;; docs/REPLAN.md E14.M3 Tables): Tab/Shift-Tab/Enter act on a table the way md-lists.rkt's do on
;; a list item -- realign or restructure it, then fall through BY NAME to the plain list-or-editor
;; command outside one -- and Insert/Delete Row/Column and Sort Table by Column are `#:when`-
;; gated commands for the palette and the Format menu. rackmac/modes.rkt's markdown-keymap binds
;; "Tab"/"Shift-Tab"/"Enter" to this module's `table-tab`/`table-shift-tab`/`table-enter` instead
;; of md-lists.rkt's `markdown-indent`/`markdown-outdent`/`markdown-enter` directly, the same
;; by-name wiring md-lists.rkt itself already uses ahead of the plain editor commands -- so a list
;; inside a table cell is not a scenario this has to handle (GFM table cells hold inline content
;; only), but a table elsewhere in a Markdown document still falls through to list behavior
;; exactly as before.
;;
;; All the table structure/text logic (finding the table at the caret, rendering it back to
;; canonical GFM, the row/column/sort transforms) lives in rackmac/md-table-model.rkt, pure and
;; independently tested; this module is the GUI/command glue over it, following md-lists.rkt and
;; outline-structure.rkt's own split. Every command applies its whole change as ONE edit -- the
;; table's old [start, end) span replaced by its freshly rendered text -- through md-doc.rkt's
;; apply-md-edits!, so each is one undo step, and skips the edit entirely when the text would not
;; actually change (Tab in an already-aligned table just moves the caret, like Sort Lines leaves
;; an already-sorted selection's undo history alone, rackmac/selection-tools.rkt).
(require racket/class racket/list
         "command.rkt" "editor.rkt" "md-doc.rkt" "md-view-commands.rkt" "md-table-model.rkt"
         "md-lists.rkt"                  ; registers the fallbacks table-tab/-shift-tab/-enter run by name
         "../rackmac-markdown/main.rkt")

;; ---- shared glue ------------------------------------------------------------------------------

;; The table at the buffer's caret, or #f. Both the fallback-by-name commands (Tab/Shift-Tab/
;; Enter) and the #:when guards below use this same query.
(define (caret-table b)
  (and (markdown-document? b)
       (table-at-caret (current-md-document b) (send b get-start-position))))

(define (table-context? [b (current-buffer)]) (and (caret-table b) #t))

;; Replaces table `t`'s whole span in `b` with `header`/`rows` (under `aligns`) freshly rendered,
;; as one undo step -- skipped when nothing would change -- then selects `target-row`/
;; `target-col`'s content (Word/Excel's Tab-selects-the-cell convention).
(define (apply-table! b t text header rows aligns target-row target-col)
  (define-values (new-text header-spans row-spans) (render-table header rows aligns))
  (define b-start (block-start t)) (define b-end (block-end t))
  (define old-text (substring text b-start b-end))
  (unless (equal? old-text new-text)
    (apply-md-edits! b (list (edit b-start b-end new-text))))
  (define span (if (eq? target-row 'header) (list-ref header-spans target-col)
                    (list-ref (list-ref row-spans target-row) target-col)))
  (send b set-position (+ b-start (car span)) (+ b-start (cdr span))))

;; Runs `proc` (header rows aligns row col -> (values new-header new-rows new-aligns target-row
;; target-col)) on the table at the caret and applies its result; #f, doing nothing, outside one.
(define (act-on-table! proc)
  (define b (current-buffer))
  (define ta (caret-table b))
  (and ta
       (let* ([t (table-at-t ta)]
              [doc (current-md-document b)]
              [text (document-text doc)]
              [header (extract-header t text)]
              [rows (extract-rows t text)]
              [aligns (table-alignments t)])
         (define-values (nh nr na tr tc) (proc header rows aligns (table-at-row ta) (table-at-col ta)))
         (apply-table! b t text nh nr na tr tc)
         #t)))

;; ---- Tab / Shift-Tab / Enter (#343, #414) ------------------------------------------------------

(define-command (table-tab)
  #:title "Next Table Cell" #:aliases ("next table cell" "table tab")
  #:help "Move to the table's next cell, realigning its columns; Tab in the last cell of the last row starts a new one."
  #:when markdown-document?
  (unless (act-on-table!
           (lambda (header rows aligns row col)
             (define ncols (length header)) (define R (length rows))
             (define-values (tr tc grow?) (tab-target ncols R row col 1))
             (values header (if grow? (append rows (list (blank-row ncols))) rows) aligns tr tc)))
    (run-command 'markdown-indent)))

(define-command (table-shift-tab)
  #:title "Previous Table Cell" #:aliases ("previous table cell" "table shift tab")
  #:help "Move to the table's previous cell, realigning its columns."
  #:when markdown-document?
  (unless (act-on-table!
           (lambda (header rows aligns row col)
             (define ncols (length header)) (define R (length rows))
             (define-values (tr tc grow?) (tab-target ncols R row col -1))
             (values header rows aligns tr tc)))
    (run-command 'markdown-outdent)))

(define-command (table-enter)
  #:title "New Table Row" #:aliases ("new table row" "table enter")
  #:help "Add a new table row below the current one; on an already-blank last row, removes it instead."
  #:when markdown-document?
  (unless (act-on-table!
           (lambda (header rows aligns row col)
             (define ncols (length header))
             (cond
               [(and (integer? row) (= row (sub1 (length rows))) (row-blank? (list-ref rows row)))
                (define new-rows (take rows row))
                (values header new-rows aligns (if (null? new-rows) 'header (sub1 (length new-rows))) col)]
               [else
                (define at (add1 (if (integer? row) row -1)))
                (values header (list-insert rows at (blank-row ncols)) aligns at 0)])))
    (run-command 'markdown-enter)))

;; ---- Insert/Delete Row and Column (#414) -------------------------------------------------------

(define-command (table-insert-row-above)
  #:title "Insert Row Above" #:menu "Format" #:menu-order 60
  #:aliases ("insert table row above" "insert row above")
  #:help "Insert a blank table row above the current one."
  #:when table-context?
  (act-on-table! insert-row-above))

(define-command (table-insert-row-below)
  #:title "Insert Row Below" #:menu "Format" #:menu-order 61
  #:aliases ("insert table row below" "insert row below")
  #:help "Insert a blank table row below the current one."
  #:when table-context?
  (act-on-table! insert-row-below))

(define-command (table-delete-row)
  #:title "Delete Row" #:menu "Format" #:menu-order 64
  #:aliases ("delete table row" "remove table row")
  #:help "Delete the table's current row."
  #:when table-context?
  (act-on-table! delete-row))

(define-command (table-insert-column-left)
  #:title "Insert Column Left" #:menu "Format" #:menu-order 62
  #:aliases ("insert table column left" "insert column left")
  #:help "Insert a blank table column to the left of the current one."
  #:when table-context?
  (act-on-table! insert-column-left))

(define-command (table-insert-column-right)
  #:title "Insert Column Right" #:menu "Format" #:menu-order 63
  #:aliases ("insert table column right" "insert column right")
  #:help "Insert a blank table column to the right of the current one."
  #:when table-context?
  (act-on-table! insert-column-right))

(define-command (table-delete-column)
  #:title "Delete Column" #:menu "Format" #:menu-order 65
  #:aliases ("delete table column" "remove table column")
  #:help "Delete the table's current column."
  #:when table-context?
  (act-on-table! delete-column))

;; ---- Sort Table by Column (#415) ---------------------------------------------------------------

(define-command (table-sort-column)
  #:title "Sort Table by Column" #:menu "Format" #:menu-order 66
  #:aliases ("sort table" "sort table by column" "sort table column")
  #:help "Sort the table's rows by the column under the caret; run again to reverse the order."
  #:when table-context?
  (act-on-table! sort-by-column))
