#lang racket/base
;; Paste from a spreadsheet (#416, rackmac/paste-table.rkt through rackmac/paste-dispatch.rkt):
;; a copied range -- HTML <table> from Excel or Sheets, or well-formed tab-separated text --
;; pastes into a note as a GFM pipe table, one undo step, and pipes in cells read back
;; unchanged through the project's own Markdown parser. Everything that is not a range (one
;; cell, one row, ragged lines, prose, Word text around a table, text copied inside Rackmac,
;; a code document) pastes exactly as before. The rich pasteboard is a parameter here, so
;; these run with canned Excel/Sheets fragments; plain text goes through the real clipboard.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/string racket/file
         "../rackmac/paste-table.rkt" "../rackmac/paste-dispatch.rkt" "../rackmac/pasteboard.rkt"
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/editor.rkt" "../rackmac/hook.rkt"
         "../rackmac-markdown/main.rkt")

(void (putenv "RACKMAC_HOME" (path->string (make-temporary-file "rackmac-paste-table~a" 'directory))))

(define (doc text [pos (string-length text)] #:mode [mode 'markdown-mode])
  (define b (new-buffer! "paste-table" #:mode mode))
  (send b insert text) (send b clear-undos) (send b set-position pos)
  (set-current-buffer! b)
  b)
(define (txt b) (send b get-text))

;; Pastes into `b` with `plain` as the clipboard's text and `html` (or nothing) as its HTML.
(define (paste! b plain #:html [html #f])
  (send the-clipboard set-clipboard-string plain 0)
  (parameterize ([current-pasteboard-reader
                  (lambda (type) (and html (equal? type "public.html") (string->bytes/utf-8 html)))])
    (run-command 'paste)))

;; The cells of the first table in `md`, as the project's parser reads them (via its HTML).
(define (parsed-cells md)
  (define html (document->html (parse-document md #:extensions gfm-extensions) #:unsafe? #t))
  (for/list ([row (in-list (regexp-match* #px"(?s:<tr>(.*?)</tr>)" html #:match-select cadr))])
    (for/list ([c (in-list (regexp-match* #px"(?s:<t[dh][^>]*>(.*?)</t[dh]>)" row #:match-select cadr))])
      (regexp-replace* #rx"&amp;" (regexp-replace* #rx"&lt;" (regexp-replace* #rx"&gt;" c ">") "<") "\\&"))))

;; Shaped like Excel for Mac's public.html for a 3x2 range (trimmed: Excel adds more styles).
(define excel-html #<<HTML
<html xmlns:o="urn:schemas-microsoft-com:office:office"
xmlns:x="urn:schemas-microsoft-com:office:excel"
xmlns="http://www.w3.org/TR/REC-html40">
<head>
<meta http-equiv=Content-Type content="text/html; charset=utf-8">
<meta name=ProgId content=Excel.Sheet>
<style>
<!--table
	{mso-displayed-decimal-separator:"\.";}
td	{padding-top:1px; color:black;}
-->
</style>
</head>
<body link="#0563C1" vlink="#954F72">
<!--[if gte mso 9]><xml><x:ExcelWorkbook><x:ActiveSheet>0</x:ActiveSheet></x:ExcelWorkbook></xml><![endif]-->
<table border=0 cellpadding=0 cellspacing=0 width=174 style='border-collapse:
 collapse;width:130pt'>
<!--StartFragment-->
 <col width=87 span=2 style='width:65pt'>
 <tr height=21 style='height:16.0pt'>
  <td height=21 width=87 style='height:16.0pt;width:65pt'>Matter</td>
  <td width=87 style='width:65pt'>Hours</td>
 </tr>
 <tr height=21 style='height:16.0pt'>
  <td height=21 style='height:16.0pt'>Smith &amp; Co</td>
  <td align=right>12.5</td>
 </tr>
 <tr height=21 style='height:16.0pt'>
  <td height=21 style='height:16.0pt'>Jones<br style='mso-data-placement:same-cell' />appeal</td>
  <td align=right>3</td>
 </tr>
<!--EndFragment-->
</table>
</body>
</html>
HTML
  )

(define excel-plain "Matter\tHours\r\nSmith & Co\t12.5\r\n\"Jones\nappeal\"\t3\r\n")

;; Shaped like Google Sheets in Chrome (a wrapper element, inline styles, <tbody>).
(define sheets-html
  (string-append
   "<meta charset='utf-8'><google-sheets-html-origin><style type=\"text/css\"><!--td {border: 1px solid #cccccc;}--></style>"
   "<table xmlns=\"http://www.w3.org/1999/xhtml\" cellspacing=\"0\" cellpadding=\"0\" dir=\"ltr\" border=\"1\" "
   "style=\"table-layout:fixed;font-size:10pt\" data-sheets-root=\"1\"><colgroup><col width=\"100\"/><col width=\"100\"/></colgroup>"
   "<tbody><tr style=\"height:21px;\"><td style=\"overflow:hidden;\">Name</td><td style=\"overflow:hidden;\">Status</td></tr>"
   "<tr style=\"height:21px;\"><td>Ann</td><td data-sheets-value=\"{&quot;1&quot;:2}\">Open</td></tr></tbody></table>"
   "</google-sheets-html-origin>"))

;; ---- HTML <table> ------------------------------------------------------------------------

(test-case "an Excel range pastes as a pipe table, header first"
  (define b (doc ""))
  (paste! b excel-plain #:html excel-html)
  (check-equal? (txt b)
                (string-append "| Matter | Hours |\n| --- | --- |\n| Smith & Co | 12.5 |\n"
                               "| Jones<br>appeal | 3 |\n"))
  (check-equal? (parsed-cells (txt b))
                '(("Matter" "Hours") ("Smith & Co" "12.5") ("Jones<br>appeal" "3"))))

(test-case "a Google Sheets range pastes as a pipe table"
  (define b (doc ""))
  (paste! b "Name\tStatus\nAnn\tOpen" #:html sheets-html)
  (check-equal? (txt b) "| Name | Status |\n| --- | --- |\n| Ann | Open |\n"))

(test-case "the paste is one undo step and the caret lands after the table"
  (define b (doc "Intro\n" 6))
  (paste! b excel-plain #:html excel-html)
  (check-true (string-prefix? (txt b) "Intro\n\n| Matter | Hours |"))
  (check-equal? (send b get-start-position) (string-length (txt b)))
  (send b undo)
  (check-equal? (txt b) "Intro\n" "one undo step"))

(test-case "a paste over a selection replaces it with the table, still one undo step"
  (define b (doc "Before\nreplace me\nAfter"))
  (send b set-position 7 17)
  (paste! b "a\tb\nc\td")
  (check-equal? (txt b) "Before\n\n| a | b |\n| --- | --- |\n| c | d |\n\nAfter")
  (send b undo)
  (check-equal? (txt b) "Before\nreplace me\nAfter"))

(test-case "a table pasted mid-line is set off by blank lines, so no text joins it"
  (define b (doc "left right" 5))
  (paste! b "a\tb\nc\td")
  (check-equal? (txt b) "left \n\n| a | b |\n| --- | --- |\n| c | d |\n\nright")
  (check-equal? (parsed-cells (txt b)) '(("a" "b") ("c" "d"))))

(test-case "a single Excel cell (a one-cell <table>) pastes as plain text"
  (define b (doc ""))
  (paste! b "Smith" #:html "<html><body><table><tr><td>Smith</td></tr></table></body></html>")
  (check-equal? (txt b) "Smith"))

(test-case "one row or one column of a range pastes as plain text, as before"
  (define row (doc ""))
  (paste! row "a\tb\tc" #:html "<table><tr><td>a</td><td>b</td><td>c</td></tr></table>")
  (check-equal? (txt row) "a\tb\tc")
  (define col (doc ""))
  (paste! col "a\nb\nc" #:html "<table><tr><td>a</td></tr><tr><td>b</td></tr><tr><td>c</td></tr></table>")
  (check-equal? (txt col) "a\nb\nc"))

(test-case "Word-style HTML with prose around a table is not a range (left for rich paste)"
  (define b (doc ""))
  (define plain "Terms follow.\nParty\tRole\nAnn\tBuyer")
  (paste! b plain #:html (string-append "<html><body><p>Terms follow.</p><table><tr><td>Party</td><td>Role</td></tr>"
                                        "<tr><td>Ann</td><td>Buyer</td></tr></table></body></html>"))
  (check-equal? (txt b) plain))

(test-case "HTML from a web page with no table leaves the plain paste alone, tabs and all"
  (define b (doc ""))
  (paste! b "one\ttwo\nthree\tfour" #:html "<p>one\ttwo<br>three\tfour</p>")
  (check-equal? (txt b) "one\ttwo\nthree\tfour"))

(test-case "merged cells spread out so every row keeps its width"
  (check-equal? (html->table-rows
                 (string-append "<table><tr><td colspan=2>Wide</td><td rowspan=\"2\">Tall</td></tr>"
                                "<tr><td>a</td><td>b</td></tr></table>"))
                '(("Wide" "" "Tall") ("a" "b" ""))))

(test-case "entities and whitespace in cells come out as the text the spreadsheet showed"
  (check-equal? (html->table-rows "<table><tr><td> A&nbsp;&amp;&#160;B </td><td>&lt;x&gt;\n  y&#x2014;</td></tr></table>")
                '(("A & B" "<x> y\u2014"))))

;; ---- tab-separated text ------------------------------------------------------------------

(test-case "tab-separated text with the same cell count on every line pastes as a table"
  (define b (doc ""))
  (paste! b "Name\tDue\tOwner\r\nBrief\tMay 1\tAnn\r\nReply\t\tBo\r\n")
  (check-equal? (txt b) "| Name | Due | Owner |\n| --- | --- | --- |\n| Brief | May 1 | Ann |\n| Reply |  | Bo |\n")
  (check-equal? (parsed-cells (txt b)) '(("Name" "Due" "Owner") ("Brief" "May 1" "Ann") ("Reply" "" "Bo"))))

(test-case "Excel's quoted multi-line cell is one cell, not a ragged line"
  (check-equal? (tsv->table-rows "Party\tAddress\nAnn\t\"1 Main St\nSpringfield\"\n")
                '(("Party" "Address") ("Ann" "1 Main St\nSpringfield")))
  (check-equal? (tsv->table-rows "Quote\tBy\n\"He said \"\"no\"\"\tthen left\"\tAnn")
                '(("Quote" "By") ("He said \"no\"\tthen left" "Ann"))))

(test-case "a cell that merely starts with a quote stays as written"
  (check-equal? (tsv->table-rows "Case\tYear\n\"Smith\" v. Jones\t1999")
                '(("Case" "Year") ("\"Smith\" v. Jones" "1999"))))

(test-case "ragged tab-separated text is not a table: it pastes as plain text"
  (define b (doc ""))
  (define ragged "Name\tDue\tOwner\nBrief\tMay 1\nReply\tJune\tBo")
  (paste! b ragged)
  (check-equal? (txt b) ragged)
  (check-false (tsv->table-rows "a\tb\n\nc\td") "a blank line in the middle breaks the range")
  (check-false (tsv->table-rows "a\tb") "one line is not a range")
  (check-false (tsv->table-rows "a\nb\nc") "no tabs, no table")
  (check-false (tsv->table-rows "\tfoo\n\tbar") "tab-indented lines from an editor are not a range")
  (check-false (tsv->table-rows "foo\t\nbar\t") "nor are lines that all end in a tab"))

(test-case "tab-indented text copied from another editor pastes as plain text"
  (define b (doc ""))
  (paste! b "\tFirst point\n\tSecond point\n")
  (check-equal? (txt b) "\tFirst point\n\tSecond point\n"))

(test-case "a single cell or ordinary text pastes exactly as before"
  (define one (doc "x "))
  (paste! one "Smith")
  (check-equal? (txt one) "x Smith")
  (define prose (doc ""))
  (paste! prose "First line.\nSecond line.\n")
  (check-equal? (txt prose) "First line.\nSecond line.\n"))

(test-case "tabbed text copied inside Rackmac pastes back as it was"
  (define src (doc "a\tb\nc\td" 0))
  (send src set-position 0 (send src last-position))
  (run-command 'copy)
  (define dst (doc ""))
  (parameterize ([current-pasteboard-reader (lambda (type) #f)])
    (run-command 'paste))
  (check-equal? (txt dst) "a\tb\nc\td"))

(test-case "code documents and plain-text files keep the tabs"
  (define code (doc "" #:mode 'racket-mode))
  (paste! code "a\tb\nc\td")
  (check-equal? (txt code) "a\tb\nc\td")
  (define txt-file (doc ""  #:mode 'text-mode))
  (send txt-file set-path! (build-path (find-system-path 'temp-dir) "notes.tsv"))
  (paste! txt-file "a\tb\nc\td")
  (check-equal? (txt txt-file) "a\tb\nc\td"))

(test-case "an untitled document is a note: it gets the table"
  (define b (doc "" #:mode 'text-mode))
  (paste! b "e\tf\ng\th")
  (check-equal? (txt b) "| e | f |\n| --- | --- |\n| g | h |\n"))

;; ---- pipes in cells ----------------------------------------------------------------------

(test-case "a literal pipe in a cell is escaped and reads back as the same cell"
  (define b (doc ""))
  (paste! b "Clause\tNote\nA|B\tx | y\n")
  (check-equal? (txt b) "| Clause | Note |\n| --- | --- |\n| A\\|B | x \\| y |\n")
  (check-equal? (parsed-cells (txt b)) '(("Clause" "Note") ("A|B" "x | y"))))

(test-case "backslashes before a pipe survive too (every cell round-trips)"
  (define cells '("a\\|b" "\\" "|" "||" "C:\\dir|x" "end\\" "\\\\|"))
  (define rows (list cells (map (lambda (c) (string-append "r" c)) cells)))
  (check-equal? (parsed-cells (table-rows->markdown rows)) rows))

(test-case "an HTML cell with a pipe round-trips as well"
  (define b (doc ""))
  (paste! b "" #:html "<table><tr><td>Key</td><td>Value</td></tr><tr><td>a|b</td><td>1</td></tr></table>")
  (check-equal? (parsed-cells (txt b)) '(("Key" "Value") ("a|b" "1"))))

;; ---- the dispatch ------------------------------------------------------------------------

(test-case "a failing paste converter is skipped, never losing the paste"
  (define (broken b pos) (error "boom"))
  (add-paste-converter! broken #:priority 1000)
  (define b (doc ""))
  (define reported '())
  (parameterize ([error-reporter (lambda (who e) (set! reported (cons who reported)))])
    (paste! b "plain"))
  (remove-paste-converter! broken)
  (check-equal? reported '(paste-converter) "the failure is reported")
  (check-equal? (txt b) "plain"))
