#lang racket/base
;; Scribble as a Language (#419, rackmac/lang-scribble.rkt): chosen by extension or by a first
;; line of `#lang scribble/...`, listed in Set Language and the status bar, colors `@` forms
;; apart from prose, and Toggle Comment and Enter understand `@`.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file racket/list
         "../rackmac/editor.rkt" "../rackmac/command.rkt" "../rackmac/commands.rkt"
         "../rackmac/keymap.rkt" "../rackmac/mode.rkt" "../rackmac/modes.rkt"
         "../rackmac/status.rkt" "../rackmac/status-defaults.rkt"
         "../rackmac/lang-scribble.rkt")

(define dir (make-temporary-file "rackmac-scribble~a" 'directory))
(define (write-file! name text) (define p (build-path dir name)) (display-to-file text p) p)

(define (fresh! text #:mode [m 'scribble-mode] #:sel [sel #f])
  (define b (new-buffer! "t.scrbl" #:mode m))
  (set-current-buffer! b)
  (send b insert text)
  (if sel (send b set-position (car sel) (cdr sel)) (send b set-position 0))
  b)

;; The status bar's own text for the current document.
(define (status-texts)
  (for*/list ([seg (in-list (status-segments))]
              [t (in-value ((status-segment-thunk seg)))]
              #:when (string? t))
    t))

;; ---- choosing the Language ----------------------------------------------------------------

(test-case "*.scrbl is Scribble, *.rkt is still Racket"
  (check-eq? (mode-for-path (build-path dir "a.scrbl")) 'scribble-mode)
  (check-eq? (mode-for-path (build-path dir "a.rkt")) 'racket-mode)
  (check-eq? (mode-for-path (build-path dir "a.md")) 'markdown-mode))

(test-case "a first line of #lang scribble/... makes Scribble, whatever the extension"
  (for ([line '("#lang scribble/manual" "#lang scribble/base" "#lang scribble/text" "#lang scribble/lp2"
                "#lang   scribble/doc" "#lang scribble")])
    (check-eq? (mode-for-path (build-path dir "n.txt") line) 'scribble-mode line))
  (check-eq? (mode-for-path (build-path dir "n.rkt") "#lang scribble/manual") 'scribble-mode
             "the #lang line outranks the extension")
  (check-false (mode-for-path (build-path dir "n.txt") "#lang racket/base"))
  (check-false (mode-for-path (build-path dir "n.txt") "#lang scribbler") "not a prefix match")
  (check-false (mode-for-path (build-path dir "n.txt") "#lang at-exp racket/base")))

(test-case "opening a file picks the Language from its first line"
  (define named (open-file! (write-file! "notes.txt" "#lang scribble/manual\n@title{Hi}\n")))
  (check-eq? (send named get-mode) 'scribble-mode)
  (define ext (open-file! (write-file! "doc.scrbl" "@title{Hi}\n")))
  (check-eq? (send ext get-mode) 'scribble-mode)
  (define racket (open-file! (write-file! "prog.rkt" "#lang racket/base\n(+ 1 2)\n")))
  (check-eq? (send racket get-mode) 'racket-mode)
  (define plain (open-file! (write-file! "plain.txt" "hello\n")))
  (check-eq? (send plain get-mode) 'text-mode)
  (define p (send named get-path))          ; reloading keeps the Language
  (display-to-file "#lang scribble/base\n@section{Two}\n" p #:exists 'truncate)
  (reload-buffer! named)
  (check-eq? (send named get-mode) 'scribble-mode)
  (for ([b (list named ext racket plain)]) (kill-buffer! b)))

(test-case "Scribble is listed for Set Language, and the status bar names it"
  (check-not-false (memq 'scribble-mode (map mode-name (all-modes 'major))))
  (check-equal? (mode-display-name 'scribble-mode) "Scribble")
  (check-regexp-match #rx"@" (mode-doc (find-mode 'scribble-mode)))
  (define b (fresh! "@title{x}\n"))
  (check-not-false (member "Scribble" (status-texts))))

;; ---- coloring -----------------------------------------------------------------------------

(define (keys-at spans text needle)       ; the key of the span covering the first `needle`
  (define at (car (regexp-match-positions (regexp-quote needle) text)))
  (for/first ([s (in-list spans)] #:when (and (<= (car s) (car at)) (< (car at) (cadr s)))) (caddr s)))

(test-case "@ forms are colored, prose is not"
  (define text "#lang scribble/manual\n@; a note\n@title{Hello @emph{big} world}\nSome prose, (parens).\n@(define x \"str\")\n@itemlist[@item{one} #:style 'ordered]\n")
  (define spans (scribble-spans text))
  (check-equal? (keys-at spans text "#lang") 'keyword)
  (check-equal? (keys-at spans text "@; a") 'comment)
  (check-equal? (keys-at spans text "@title") 'keyword "the @")
  (check-equal? (keys-at spans text "title{") 'keyword "the command name")
  (check-false (keys-at spans text "Hello") "prose inside braces")
  (check-equal? (keys-at spans text "emph") 'keyword "a nested command")
  (check-false (keys-at spans text "Some prose") "prose between forms")
  (check-equal? (keys-at spans text "define") 'keyword)
  (check-equal? (keys-at spans text "\"str\"") 'string)
  (check-equal? (keys-at spans text "#:style") 'constant)
  (check-false (keys-at spans text "one")))

(test-case "a block comment colors all of its text as a comment; no #lang line also works"
  (define text "before @;{ hidden\nstill hidden } after\n")
  (define spans (scribble-spans text))
  (check-equal? (keys-at spans text "hidden") 'comment)
  (check-equal? (keys-at spans text "still") 'comment)
  (check-false (keys-at spans text "after"))
  (check-false (keys-at spans text "before")))

(test-case "spans stay inside the text and the lexer never raises on odd input"
  (for ([text '("" "@" "@{" "}}}" "@|{" "#lang" "@;" "@foo[\"unterminated" "\u3b1 @\u3b2{\u3b3}")])
    (for ([s (in-list (scribble-spans text))])
      (check-true (<= 0 (car s) (cadr s) (string-length text)) (format "~s ~s" text s)))))

(define (color-at b pos)
  (define snip (send b find-snip pos 'after))
  (define c (send (send snip get-style) get-foreground))
  (list (send c red) (send c green) (send c blue)))

(test-case "the Language's highlighter colors the editor, and is not an edit"
  (define b (fresh! "@title{Hello}\nplain words\n" #:mode 'text-mode))
  (send b set-modified #f)
  (send b set-mode! 'scribble-mode)
  (check-not-equal? (color-at b 1) (color-at b 15) "@title differs from prose")
  (check-false (send b is-modified?)))

;; ---- Toggle Comment and Enter --------------------------------------------------------------

(test-case "Toggle Comment writes and removes @; comments"
  (define b (fresh! "@title{A}\n\n  Some text\n" #:sel '(0 . 22)))
  (run-command 'toggle-comment)
  (check-equal? (send b get-text) "@; @title{A}\n\n@;   Some text\n")
  (send b set-position 0 (string-length (send b get-text)))
  (run-command 'toggle-comment)
  (check-equal? (send b get-text) "@title{A}\n\n  Some text\n"))

(define (indent text [pos (string-length text)]) (scribble-newline-indent text pos "  "))

(test-case "Enter indents inside an open @ form, from the line the form began on"
  (check-equal? (indent "@section{Intro") "  ")
  (check-equal? (indent "@itemlist[") "  ")
  (check-equal? (indent "@itemlist[\n  @item{one") "    ")
  (check-equal? (indent "@itemlist[\n  @item{one}\n  @item{two}") "  " "inside the list, after a closed item")
  (check-equal? (indent "@itemlist[\n  @item{one}\n  @item{two}\n]") "" "after the list closes")
  (check-equal? (indent "@(define (f x)") "  " "a Racket form")
  (check-equal? (indent "  @title[#:tag \"x\"]{Hi") "    " "a form with arguments, then a body")
  (check-equal? (indent "@para{one\n  two") "  " "the body's own lines keep its indent"))

(test-case "Enter keeps the line's indentation outside a form, and outdents before a closer"
  (check-equal? (indent "") "")
  (check-equal? (indent "Some prose") "")
  (check-equal? (indent "  indented prose") "  ")
  (check-equal? (indent "@title{Done}") "")
  (check-equal? (indent "@section{Intro}" 14) "" "the next character closes the form")
  (check-equal? (indent "\n\n  x\n" 1) "" "on a blank line"))

(test-case "prose that only looks like a form does not indent"
  (check-equal? (indent "a (parenthesis and a [bracket") "")
  (check-equal? (indent "email@@example.com {and text}") "" "an escaped @ and balanced braces")
  (check-equal? (indent "@; @section{commented out") "")
  (check-equal? (indent "@code|{ raw { text }|") "" "verbatim text is skipped")
  (check-equal? (indent "@f[\"a { string\"") "  " "a brace inside a string does not count"))

(test-case "Enter in a Scribble document is bound to the indenting command and inserts the indent"
  (define b (fresh! "@section{Intro" #:sel '(14 . 14)))
  (define-values (kind name) (lookup-key (send b get-keymaps) (parse-key-sequence "Enter")))
  (check-equal? (list kind name) '(command scribble-newline))
  (run-command 'scribble-newline)
  (check-equal? (send b get-text) "@section{Intro\n  ")
  (check-equal? (send b get-start-position) (string-length (send b get-text)))
  (send b undo)
  (check-equal? (send b get-text) "@section{Intro" "one undo step")
  (define md (new-buffer! "n.md" #:mode 'markdown-mode))
  (define-values (k2 n2) (lookup-key (send md get-keymaps) (parse-key-sequence "Enter")))
  (check-not-equal? n2 'scribble-newline "only in Scribble"))

(delete-directory/files dir)
