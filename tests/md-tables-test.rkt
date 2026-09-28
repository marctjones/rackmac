#lang racket/base
;; Pipe-table editing (#343 md-tables, #414 md-table-editing, #415 md-table-sort,
;; docs/REPLAN.md E14.M3 Tables): Tab/Shift-Tab realign and navigate, Enter adds/removes a row,
;; Insert/Delete Row/Column restructure the table (header and alignment row always handled), and
;; Sort Table by Column sorts the data rows only. Driven through the real (hidden) window and
;; keymaps, the same way tests/md-lists-test.rkt drives list editing -- md-lists.rkt is required
;; here too, the same way it requires itself, so table-tab/table-shift-tab/table-enter's fallback
;; commands (markdown-indent/markdown-outdent/markdown-enter) are registered.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/string
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/frame.rkt"
         "../rackmac/editor.rkt" "../rackmac/buffer.rkt" "../rackmac/platform.rkt"
         "../rackmac/md-lists.rkt" "../rackmac/md-tables.rkt" "../rackmac/md-table-model.rkt"
         "../rackmac-markdown/main.rkt")

(define f (make-main-frame))

(define (note text)
  (define b (new-buffer! "table.md" #:mode 'markdown-mode))
  (send b insert text)
  (send b clear-undos)
  (send b set-modified #f)
  (set-current-buffer! b)
  b)
(define (text b) (send b get-text))
(define (sel b) (selection-string b))

;; The position of `needle`'s first occurrence in `b`'s text (a plain, non-regexp search).
(define (pos-of b needle)
  (define m (regexp-match-positions (regexp-quote needle) (send b get-text)))
  (caar m))

;; A small fixture: two columns, the second right-aligned, deliberately unaligned as typed, and
;; its canonically-aligned form (#343). `-table` variants have no trailing newline (what
;; render-table itself produces); the plain names are what a note file holds (one trailing `\n`),
;; which every edit below preserves untouched since it sits outside the table's own span.
(define fixture-table "| Name | Age |\n|---|---:|\n| Bob | 5 |\n| Alexandra | 42 |")
(define fixture (string-append fixture-table "\n"))
(define aligned-table "| Name      | Age |\n| --------- | --: |\n| Bob       |   5 |\n| Alexandra |  42 |")
(define aligned (string-append aligned-table "\n"))

;; ---- #343: alignment on Tab ---------------------------------------------------------------------

(test-case "Tab realigns the table's columns and selects the next cell"
  (define b (note fixture))
  (send b set-position 3)                  ; inside "Name"
  (run-command 'table-tab)
  (check-equal? (text b) aligned)
  (check-equal? (sel b) "Age" "the next cell (Age) is selected, Word/Excel-style"))

(test-case "Tab in an already-aligned table only moves the caret (no spurious undo step)"
  (define b (note aligned))
  (send b set-position 3)
  (send b set-modified #f)
  (run-command 'table-tab)
  (check-equal? (text b) aligned)
  (check-false (send b is-modified?) "realigning an already-aligned table is a no-op edit"))

(test-case "Aligning is idempotent: re-parsing and re-rendering reproduces the same text"
  (define doc (parse-document aligned-table #:extensions all-extensions))
  (define t (table-at-t (table-at-caret doc 0)))
  (define header (extract-header t aligned-table))
  (define rows (extract-rows t aligned-table))
  (define-values (text2 hs rs) (render-table header rows (table-alignments t)))
  (check-equal? text2 aligned-table))

(test-case "Alignment padding doesn't change what an HTML/export renderer sees (#343 export unchanged)"
  (define html-before (document->html (parse-document fixture-table #:extensions all-extensions)))
  (define html-after (document->html (parse-document aligned-table #:extensions all-extensions)))
  (check-equal? html-before html-after "only whitespace changed, not any cell's content"))

;; ---- #414: Tab/Shift-Tab navigation, Enter, Insert/Delete Row and Column -----------------------

(test-case "Shift-Tab moves to the previous cell"
  (define b (note aligned))
  (send b set-position (add1 (pos-of b "Bob")))
  (run-command 'table-shift-tab)
  (check-equal? (sel b) "Age" "back into the header's last cell")
  (check-equal? (text b) aligned))

(test-case "Shift-Tab at the very first cell stays put"
  (define b (note aligned))
  (send b set-position 3)                  ; inside "Name", the first cell
  (run-command 'table-shift-tab)
  (check-equal? (sel b) "Name")
  (check-equal? (text b) aligned))

(test-case "Tab in the last cell of the last row starts a new row (Word/Excel convention)"
  (define b (note aligned))
  (send b set-position (sub1 (send b last-position)))  ; inside "42", the very last cell
  (run-command 'table-tab)
  (check-equal? (text b)
                (string-append "| Name      | Age |\n| --------- | --: |\n| Bob       |   5 |"
                               "\n| Alexandra |  42 |\n|           |     |\n"))
  (check-equal? (sel b) "" "the new row's first (blank) cell"))

(test-case "Enter adds a new row below the current one"
  (define b (note aligned))
  (send b set-position 3)                  ; header
  (run-command 'table-enter)
  (check-equal? (text b)
                (string-append "| Name      | Age |\n| --------- | --: |\n|           |     |"
                               "\n| Bob       |   5 |\n| Alexandra |  42 |\n"))
  (check-equal? (sel b) ""))

(test-case "Enter on an already-blank last row removes it instead of piling up another"
  (define b (note aligned))
  (send b set-position (pos-of b "Alexandra"))
  (run-command 'table-enter)                     ; adds a blank row after Alexandra, now the last one
  (send b set-position (sub1 (send b last-position)))  ; still inside the table, on that blank row
  (run-command 'table-enter)                     ; blank last row -> removed, not duplicated
  (check-equal? (text b) aligned))

(test-case "Insert Row Above / Below"
  (define b (note aligned))
  (send b set-position (pos-of b "Bob"))
  (run-command 'table-insert-row-above)
  (check-equal? (text b)
                (string-append "| Name      | Age |\n| --------- | --: |\n|           |     |"
                               "\n| Bob       |   5 |\n| Alexandra |  42 |\n"))
  (define b2 (note aligned))
  (send b2 set-position (pos-of b2 "Bob"))
  (run-command 'table-insert-row-below)
  (check-equal? (text b2)
                (string-append "| Name      | Age |\n| --------- | --: |\n| Bob       |   5 |"
                               "\n|           |     |\n| Alexandra |  42 |\n")))

(test-case "Delete Row removes the current data row; the header and alignment row are untouched"
  (define b (note aligned))
  (send b set-position (pos-of b "Bob"))
  (run-command 'table-delete-row)
  (check-equal? (text b) "| Name      | Age |\n| --------- | --: |\n| Alexandra |  42 |\n"))

(test-case "Delete Row on the header is a no-op; deleting every row leaves header+delimiter"
  (define b (note aligned))
  (send b set-position 3)                  ; header
  (send b set-modified #f)
  (run-command 'table-delete-row)
  (check-false (send b is-modified?) "no row to delete from the header")
  (send b set-position (pos-of b "Bob"))
  (run-command 'table-delete-row)
  (send b set-position (pos-of b "Alexandra"))
  (run-command 'table-delete-row)
  (check-equal? (text b) "| Name | Age |\n| ---- | --: |\n"))

(test-case "Insert Column Left / Right widens every row, including the alignment row"
  (define b (note aligned))
  (send b set-position (pos-of b "Name"))
  (run-command 'table-insert-column-left)
  (check-equal? (text b)
                (string-append "|     | Name      | Age |\n| --- | --------- | --: |"
                               "\n|     | Bob       |   5 |\n|     | Alexandra |  42 |\n"))
  (define b2 (note aligned))
  (send b2 set-position (pos-of b2 "Name"))
  (run-command 'table-insert-column-right)
  (check-equal? (text b2)
                (string-append "| Name      |     | Age |\n| --------- | --- | --: |"
                               "\n| Bob       |     |   5 |\n| Alexandra |     |  42 |\n")))

(test-case "Delete Column removes the current column; a table's last column can't be deleted"
  (define b (note aligned))
  (send b set-position (pos-of b "Age"))
  (run-command 'table-delete-column)
  (check-equal? (text b) "| Name      |\n| --------- |\n| Bob       |\n| Alexandra |\n")
  (send b set-modified #f)
  (run-command 'table-delete-column)
  (check-false (send b is-modified?) "the table's only remaining column stays"))

(test-case "Each structural command is one undo step"
  (define b (note aligned))
  (send b set-position (pos-of b "Bob"))
  (run-command 'table-insert-row-above)
  (send b undo)
  (check-equal? (text b) aligned "one undo step for Insert Row")
  (send b set-position (pos-of b "Age"))
  (run-command 'table-delete-column)
  (send b undo)
  (check-equal? (text b) aligned "one undo step for Delete Column"))

;; ---- #415: Sort Table by Column -----------------------------------------------------------------

(define sort-fixture "| Name | Score |\n|---|---|\n| bob | 2 |\n| Ann | 3 |\n| ann | 1 |\n| Zed | 3 |\n")

(test-case "Sort Table by Column sorts ascending, case-insensitively and stably"
  (define b (note sort-fixture))
  (send b set-position (pos-of b "Name"))   ; caret in the header names the column
  (run-command 'table-sort-column)
  ;; the header and alignment row never move; the data rows are alphabetized, and "Ann" before
  ;; "ann" (both compare equal case-insensitively) keeps its original relative order -- stable
  (check-equal? (text b)
                "| Name | Score |\n| ---- | ----- |\n| Ann  | 3     |\n| ann  | 1     |\n| bob  | 2     |\n| Zed  | 3     |\n")
  (check-equal? (sel b) "Name" "the caret stays on the sorted column"))

(test-case "Sorting the same column again reverses the order"
  (define b (note sort-fixture))
  (send b set-position (pos-of b "Name"))
  (run-command 'table-sort-column)
  (run-command 'table-sort-column)
  (check-equal? (text b)
                "| Name | Score |\n| ---- | ----- |\n| Zed  | 3     |\n| bob  | 2     |\n| Ann  | 3     |\n| ann  | 1     |\n"
                "descending, still stable among ties"))

(test-case "Sort Table by Column works from any row's cell in that column, not just the top"
  (define b (note sort-fixture))
  (send b set-position (pos-of b "Zed"))    ; caret on the LAST data row's column
  (run-command 'table-sort-column)
  (check-equal? (text b)
                "| Name | Score |\n| ---- | ----- |\n| Ann  | 3     |\n| ann  | 1     |\n| bob  | 2     |\n| Zed  | 3     |\n"))

(test-case "Sort Table by Column is one undo step"
  (define b (note sort-fixture))
  (send b clear-undos)
  (send b set-position (pos-of b "Name"))
  (run-command 'table-sort-column)
  (send b undo)
  (check-equal? (text b) sort-fixture "one undo step"))

;; ---- edge cases: ragged/malformed tables, any column count/alignment ----------------------------

(define ragged "| A | B | C |\n|---|---|---|\n| 1 | 2 | 3 |\n| x |\n")

(test-case "A ragged row (fewer cells than the header) degrades gracefully -- no crash, padded"
  (define b (note ragged))
  (send b set-position (pos-of b "x"))
  (run-command 'table-tab)                  ; realign: must not crash on the short row
  (check-true (string-contains? (text b) "| x   |     |     |")))

(test-case "Every command tolerates a ragged table without crashing"
  (for ([cmd '(table-tab table-shift-tab table-enter table-insert-row-above table-insert-row-below
               table-delete-row table-insert-column-left table-insert-column-right
               table-delete-column table-sort-column)])
    (define b (note ragged))
    (send b set-position (pos-of b "x"))
    (run-command cmd)))

(test-case "A one-column table"
  (define b (note "| Only |\n|---|\n| a |\n| b |\n"))
  (send b set-position (pos-of b "a"))
  (run-command 'table-tab)
  (check-equal? (text b) "| Only |\n| ---- |\n| a    |\n| b    |\n")
  (send b set-modified #f)
  (run-command 'table-delete-column)
  (check-false (send b is-modified?)))

(test-case "A table with every alignment kind (none/left/center/right)"
  (define b (note "|A|B|C|D|\n|---|:---|:---:|---:|\n|1|2|3|4|\n"))
  (send b set-position 1)
  (run-command 'table-tab)
  (check-equal? (text b) "| A   | B   |  C  |   D |\n| --- | :-- | :-: | --: |\n| 1   | 2   |  3  |   4 |\n"))

;; ---- scoping: outside a table, everything falls through unchanged -------------------------------

(test-case "Outside a table, Tab/Shift-Tab/Enter still behave like plain list/editor commands"
  (define b (note "- one\n- two"))
  (send b set-position 5)
  (run-command 'table-enter)
  (check-equal? (text b) "- one\n- \n- two" "table-enter falls through to markdown-enter (list Enter)")
  (send b set-position 8)
  (run-command 'table-tab)
  (check-equal? (text b) "- one\n  - \n- two" "table-tab falls through to markdown-indent")
  (define b2 (note "plain"))
  (send b2 set-position 0)
  (run-command 'table-tab)
  (check-equal? (text b2) "  plain" "table-tab falls through to plain Tab outside Markdown too"))

(test-case "Insert/Delete Row/Column and Sort are disabled outside a table"
  (define b (note "plain text, no table here"))
  (send b set-position 3)
  (for ([name '(table-insert-row-above table-insert-row-below table-delete-row
                table-insert-column-left table-insert-column-right table-delete-column
                table-sort-column)])
    (check-false (command-enabled? (find-command name)) (format "~a should be disabled" name))))

(test-case "Insert Row is enabled with the caret inside a pipe table"
  (define b (note fixture))
  (send b set-position 3)
  (check-true (command-enabled? (find-command 'table-insert-row-above))))

;; ---- nested tables, undo of Tab, and key dispatch through the real keymap -----------------------

(test-case "A table inside a block quote or list item is not edited (its container prefix would be lost)"
  (for ([src '("> | a | b |\n> |---|---|\n> | 1 | 2 |" "- | a | b |\n  |---|---|\n  | 1 | 2 |")])
    (define doc (parse-document src #:extensions all-extensions))
    (check-false (table-at-caret doc 4) src))
  (define b (note "> | a | b |\n> |---|---|\n> | 1 | 2 |"))
  (send b set-position 4)
  (check-false (command-enabled? (find-command 'table-sort-column)))
  (define before (text b))
  (run-command 'table-tab)                   ; falls through to the plain Tab behavior
  (check-false (string-contains? (text b) "\n|") "the quote prefix on later lines survives")
  (check-true (string-prefix? (text b) "> ") (format "still quoted: ~s vs ~s" (text b) before)))

(test-case "Tab realigning an unaligned table is one undo step"
  (define b (note fixture))
  (send b set-position 3)
  (run-command 'table-tab)
  (send b undo)
  (check-equal? (text b) fixture))

(define (kev code #:shift [shift #f])
  (new key-event% [key-code code] [shift-down shift]))

(test-case "Tab, Shift-Tab and Enter dispatch through markdown-mode's own keymap into the table"
  (parameterize ([current-platform 'mac])
    (define b (note fixture))
    (send b set-position 3)
    (send b on-char (kev #\tab))
    (check-equal? (text b) aligned)
    (check-equal? (sel b) "Age")
    (send b on-char (kev #\tab #:shift #t))
    (check-equal? (sel b) "Name")
    (send b on-char (kev #\return))
    (check-true (string-contains? (text b) "|           |     |\n| Bob") "Enter added a row below the header")))
