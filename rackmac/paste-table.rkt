#lang racket/base
;; Paste from a spreadsheet (#416): a range copied in Excel, Numbers or Google Sheets arrives
;; in a note as a Markdown (GFM) pipe table instead of tab-separated text. A paste converter
;; (rackmac/paste-dispatch.rkt) at priority 100, above any general rich-text conversion.
;;
;; What counts as a copied range, deliberately narrow so an ordinary paste never changes:
;; - The clipboard's HTML is one <table> and nothing else but whitespace (Excel, Numbers and
;;   Sheets write exactly that; Word prose around a table is not a range).
;; - Without HTML, the plain text is tab-separated with the same number of cells on every line
;;   (Excel's quoting of cells that hold a line break or tab is understood).
;; - Either way, at least two rows and two columns: a single cell, a single row or a single
;;   column pastes as plain text, as before (Excel puts a one-cell <table> even for one cell).
;; - Only in Markdown notes and untitled documents; code, .txt, .tsv and .csv files keep the
;;   tabs. Text copied inside Rackmac itself is never converted.
;; The conversion is done here rather than through pandoc: it needs no install, and pandoc's
;; GFM writer falls back to raw HTML for tables it considers complex.
(require racket/class racket/gui/base racket/list racket/string
         "paste-dispatch.rkt" "pasteboard.rkt" "hook.rkt" "mode.rkt")
(provide html->table-rows tsv->table-rows table-rows->markdown markdown-table-cell
         spreadsheet-paste-text paste-table-converter)

;; ---- HTML -> rows ------------------------------------------------------------------------

(define named-entities
  (hash "amp" "&" "lt" "<" "gt" ">" "quot" "\"" "apos" "'" "nbsp" "\u00A0"
        "ndash" "\u2013" "mdash" "\u2014" "lsquo" "\u2018" "rsquo" "\u2019" "ldquo" "\u201C"
        "rdquo" "\u201D" "hellip" "\u2026" "bull" "\u2022" "middot" "\u00B7" "deg" "\u00B0"
        "times" "\u00D7" "divide" "\u00F7" "copy" "\u00A9" "reg" "\u00AE" "trade" "\u2122"
        "sect" "\u00A7" "para" "\u00B6" "euro" "\u20AC" "pound" "\u00A3" "yen" "\u00A5"
        "cent" "\u00A2" "shy" ""))

(define (decode-entities s)
  (regexp-replace* #px"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);" s
                   (lambda (all name)
                     (define (from-code n)
                       (if (and n (< 0 n #x110000) (not (<= #xD800 n #xDFFF))) (string (integer->char n)) all))
                     (cond
                       [(regexp-match? #rx"^#[xX]" name) (from-code (string->number (substring name 2) 16))]
                       [(regexp-match? #rx"^#" name) (from-code (string->number (substring name 1)))]
                       [else (hash-ref named-entities name all)]))))

;; Everything that is never content: comments (Excel's <!--[if gte mso 9]>…<![endif]--> too),
;; declarations, and the head, style and script elements with what they hold.
(define (strip-non-content html)
  (for/fold ([s html]) ([rx (in-list (list #px"(?s:<!--.*?-->)" #px"<![^>]*>" #px"<\\?[^>]*>"
                                           #px"(?is:<head[\\s>].*?</head\\s*>)"
                                           #px"(?is:<style[\\s>].*?</style\\s*>)"
                                           #px"(?is:<script[\\s>].*?</script\\s*>)"
                                           #px"(?is:<title[\\s>].*?</title\\s*>)"))])
    (regexp-replace* rx s "")))

(define tag-rx #px"<(/?)([a-zA-Z][a-zA-Z0-9:_-]*)((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>")

(define (blank-text? s)
  (regexp-match? #px"^[\\s\u00A0]*$" (decode-entities (regexp-replace* tag-rx s ""))))

(define (span-attr attrs name)
  (define m (regexp-match (pregexp (string-append "(?i:\\b" name "\\s*=\\s*[\"']?\\s*([0-9]+))")) attrs))
  (define n (and m (string->number (cadr m))))
  (if (and n (>= n 1)) (min n 1000) 1))

(define break-mark #\u0000)   ; a line break inside a cell, until whitespace is collapsed

;; A cell's accumulated source -> its text: entities decoded, HTML whitespace collapsed,
;; line breaks (<br>, paragraphs) kept as "\n", blank lines at either end dropped.
(define (finish-cell raw)
  (define collapsed (regexp-replace* #px"[ \t\r\n\f]+" (decode-entities raw) " "))
  (define lines (for/list ([l (in-list (string-split collapsed (string break-mark) #:trim? #f))])
                  (string-trim (string-replace l "\u00A0" " "))))
  (define (drop-blank ls) (dropf ls (lambda (l) (string=? l ""))))
  (string-join (reverse (drop-blank (reverse (drop-blank lines)))) "\n"))

;; The clipboard's HTML -> rows of cell strings, when it is exactly one table (no nested
;; table, nothing but whitespace around it), else #f. Merged cells are spread out: the text
;; stays in the first cell and the others are empty, so every row has the same width.
(define (html->table-rows html)
  (define s (strip-non-content html))
  (define opens (regexp-match-positions* #px"(?i:<table[\\s>/])" s))
  (define close (regexp-match-positions #px"(?i:</table\\s*>)" s))
  (and (= (length opens) 1)
       (let* ([start (caar opens)]
              [end (if close (cdar close) (string-length s))])
         (and (or (not close) (> (caar close) start))
              (blank-text? (substring s 0 start))
              (blank-text? (substring s end))
              (grid->rows (scan-table (substring s start end)))))))

;; Walks the table's tags. Returns a list of rows, each a list of (text colspan rowspan).
(define (scan-table s)
  (define rows '()) (define row #f) (define cell #f) (define cell-attrs "")
  (define (close-cell!)
    (when cell
      (unless row (set! row '()))
      (set! row (cons (list (finish-cell (get-output-string cell))
                            (span-attr cell-attrs "colspan") (span-attr cell-attrs "rowspan"))
                      row))
      (set! cell #f)))
  (define (close-row!)
    (close-cell!)
    (when row (set! rows (cons (reverse row) rows)) (set! row #f)))
  (define (text! t) (when cell (write-string t cell)))
  (let loop ([pos 0])
    (define m (regexp-match-positions tag-rx s pos))
    (cond
      [(not m) (text! (substring s pos))]
      [else
       (text! (substring s pos (caar m)))
       (define close? (< (car (list-ref m 1)) (cdr (list-ref m 1))))
       (define name (string-downcase (substring s (car (list-ref m 2)) (cdr (list-ref m 2)))))
       (define attrs (substring s (car (list-ref m 3)) (cdr (list-ref m 3))))
       (case name
         [("tr") (close-row!) (unless close? (set! row '()))]
         [("td" "th") (close-cell!)
                      (unless close? (set! cell (open-output-string)) (set! cell-attrs attrs))]
         [("table") (when close? (close-row!))]
         [("br") (text! (string break-mark))]
         [("p" "div" "li" "h1" "h2" "h3" "h4" "h5" "h6") (text! (string break-mark))]
         [else (void)])
       (loop (cdar m))]))
  (close-row!)
  (reverse rows))

;; Rows of (text colspan rowspan) -> a rectangular list of rows of strings, or #f when empty.
(define (grid->rows rows)
  (define taken (make-hash))          ; (row . col) -> #t, filled by a rowspan/colspan above
  (define placed
    (for/list ([r (in-list rows)] [ri (in-naturals)])
      (let loop ([cells r] [col 0] [acc '()])
        (cond
          [(hash-ref taken (cons ri col) #f) (loop cells (add1 col) (cons "" acc))]
          [(null? cells) (reverse acc)]
          [else
           (define-values (text cs rs) (apply values (car cells)))
           (for* ([dr (in-range rs)] [dc (in-range cs)] #:unless (and (= dr 0) (= dc 0)))
             (hash-set! taken (cons (+ ri dr) (+ col dc)) #t))
           (loop (cdr cells) (+ col cs) (append (make-list (sub1 cs) "") (cons text acc)))]))))
  ;; A rowspan reaching past the last written row adds nothing: those rows don't exist.
  (define width (apply max 0 (map length placed)))
  (and (pair? placed) (> width 0)
       (for/list ([r (in-list placed)])
         (append r (make-list (- width (length r)) "")))))

;; ---- tab-separated text -> rows ----------------------------------------------------------

;; One record's fields, reading from `i`. A field that starts with a quote is a quoted field
;; (Excel and Sheets quote a cell holding a line break or a tab, doubling its quotes) only if
;; the closing quote is followed by a tab, a line end or the end, and the content needs
;; quoting; anything else is read as it stands, so `"Smith" v. Jones` stays itself.
(define (read-quoted s i)
  (define n (string-length s))
  (let loop ([j (add1 i)] [acc '()])
    (cond
      [(>= j n) #f]
      [(char=? (string-ref s j) #\")
       (cond
         [(and (< (add1 j) n) (char=? (string-ref s (add1 j)) #\")) (loop (+ j 2) (cons #\" acc))]
         [(or (= (add1 j) n) (memv (string-ref s (add1 j)) '(#\tab #\newline)))
          (define text (list->string (reverse acc)))
          (and (or (regexp-match? #rx"[\t\n\"]" text))
               (cons text (add1 j)))]
         [else #f])]
      [else (loop (add1 j) (cons (string-ref s j) acc))])))

(define (parse-tsv s)
  (define n (string-length s))
  (let loop ([i 0] [fields '()] [records '()])
    (define (field-end j) (let scan ([j j]) (if (or (= j n) (memv (string-ref s j) '(#\tab #\newline))) j (scan (add1 j)))))
    (define-values (text j)
      (let ([q (and (< i n) (char=? (string-ref s i) #\") (read-quoted s i))])
        (if q (values (car q) (cdr q)) (let ([e (field-end i)]) (values (substring s i e) e)))))
    (define fields* (cons text fields))
    (cond
      [(= j n) (reverse (cons (reverse fields*) records))]
      [(char=? (string-ref s j) #\tab) (loop (add1 j) fields* records)]
      [else (loop (add1 j) '() (cons (reverse fields*) records))])))

;; Plain text -> rows, when it is a well-formed tab-separated range: at least two lines, and
;; every line has the same number of cells, at least two. Otherwise #f (text that merely
;; contains tabs, ragged lines, a blank line in the middle). Lines that all start (or all end)
;; with a tab are indented text from an editor, not a range: an empty first or last column
;; is #f too. (A range whose edge column is empty still arrives through its HTML.)
(define (tsv->table-rows text)
  (define s (let ([s (regexp-replace* #rx"\r\n?" text "\n")])
              (if (and (positive? (string-length s)) (char=? (string-ref s (sub1 (string-length s))) #\newline))
                  (substring s 0 (sub1 (string-length s)))
                  s)))
  (and (regexp-match? #rx"\t" s)
       (let* ([rows (parse-tsv s)]
              [width (length (car rows))])
         (and (>= (length rows) 2) (>= width 2)
              (for/and ([r (in-list rows)]) (= (length r) width))
              (let ([trimmed (for/list ([r (in-list rows)]) (map string-trim r))])
                (define (empty-column? pick) (for/and ([r (in-list trimmed)]) (string=? (pick r) "")))
                (and (not (empty-column? car)) (not (empty-column? last))
                     trimmed))))))

;; ---- rows -> Markdown --------------------------------------------------------------------

;; A cell's text as GFM table-cell source that reads back as the same text: a `|` becomes
;; `\|`, and backslashes just before a `|` are doubled so they stay literal (a table row is
;; split wherever a pipe is not escaped). Line breaks inside a cell become <br>, as GFM
;; tables carry them.
(define (markdown-table-cell text)
  (define one-line (string-join (map string-trim (string-split text "\n" #:trim? #f)) "<br>"))
  (regexp-replace* #px"(\\\\*)\\|" one-line
                   (lambda (all slashes) (string-append slashes slashes "\\|"))))

;; The first row is the header, as a spreadsheet range's first row usually is.
(define (table-rows->markdown rows)
  (define width (length (car rows)))
  (define (line cells) (string-append "| " (string-join (map markdown-table-cell cells) " | ") " |"))
  (string-join (append (list (line (car rows))
                             (string-append "|" (string-join (make-list width " --- ") "|") "|"))
                       (map line (cdr rows)))
               "\n"))

;; The rows the clipboard holds as a range, or #f. HTML decides when there is any: HTML that
;; isn't a range (a web page, Word) means the plain text is not one either.
(define (clipboard-table-rows)
  (define (big-enough rows) (and rows (>= (length rows) 2) (>= (length (car rows)) 2) rows))
  (define html (pasteboard-html))
  (cond
    [html (big-enough (html->table-rows html))]
    [else
     (define text (pasteboard-text))
     (and text (not (app-copy? text)) (big-enough (tsv->table-rows text)))]))

;; ---- the converter -----------------------------------------------------------------------

;; What Rackmac itself last put on the clipboard: pasting it back is never a conversion. The
;; pasteboard's change count (macOS) tells it apart from the same text copied again elsewhere.
(define last-app-copy #f)
(define last-app-copy-count #f)
(add-hook! 'text-copied
           (lambda (buffer text)
             (set! last-app-copy (with-handlers ([exn:fail? (lambda (e) text)]) (pasteboard-text)))
             (set! last-app-copy-count (pasteboard-change-count))))
(define (app-copy? text)
  (and (equal? text last-app-copy)
       (let ([now (pasteboard-change-count)])
         (or (not now) (eqv? now last-app-copy-count)))))

(define (table-document? b)
  (define chain (map mode-name (mode-chain (send b get-mode))))
  (or (memq 'markdown-mode chain)
      (and (eq? (send b get-mode) 'text-mode) (not (send b get-path)))))

;; `table` inserted at `pos` in `b`, separated by blank lines from any text around it: a line
;; right before a table would be read as its header's paragraph, and one right after as a row.
(define (spreadsheet-paste-text b pos table)
  (define para (send b position-paragraph pos))
  (define pstart (send b paragraph-start-position para))
  (define pend (send b paragraph-end-position para))
  (define (line-text p) (send b get-text (send b paragraph-start-position p) (send b paragraph-end-position p)))
  (define (blank? s) (regexp-match? #px"^\\s*$" s))
  (define last-para (send b last-paragraph))
  (define before
    (cond [(> pos pstart) "\n\n"]
          [(and (> para 0) (not (blank? (line-text (sub1 para))))) "\n"]
          [else ""]))
  (define after
    (cond [(< pos pend) "\n\n"]
          [(and (< para last-para) (not (blank? (line-text (add1 para))))) "\n"]
          [(< para last-para) ""]
          [else "\n"]))
  (string-append before table after))

(define (paste-table-converter b pos)
  (and (table-document? b)
       (let ([rows (clipboard-table-rows)])
         (and rows (spreadsheet-paste-text b pos (table-rows->markdown rows))))))

(add-paste-converter! paste-table-converter #:priority 100)
