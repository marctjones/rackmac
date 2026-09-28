#lang racket/base
;; Scribble as a Language (#419, docs/PUBLISHING-DESIGN.md M1): `*.scrbl` files, and any file
;; whose first line is `#lang scribble/...`, open as "Scribble" -- coloring that tells `@`
;; forms from prose, `@;` comments for Toggle Comment, and an Enter that indents the body of an
;; open `@name{` / `@name[` form. Preview and build are separate work (#420).
;;
;; Coloring uses the `scribble-inside-lexer` that ships with Racket (syntax-color-lib): a
;; Scribble file's body is prose, and only `@` forms switch into Racket, so the plain
;; `scribble-lexer` (which starts in Racket) would color prose as code. The `#lang` line is
;; taken off first and colored by itself. The E19 plumbing (#310: module-lexer dispatch per
;; `#lang`, drracket:indentation) does not exist yet, so this module is a per-Language
;; highlighter of the same shape as `highlight-racket!`; #310 can later replace both without
;; touching the Language.
;;
;; Everything that reads text is a pure function (`scribble-spans`, `scribble-newline-indent`)
;; so it is tested without a window; the GUI half is the Language record and one command.
(require racket/class
         syntax-color/scribble-lexer
         "mode.rkt" "keymap.rkt" "command.rkt" "editor.rkt" "highlight.rkt")
(provide scribble-spans scribble-newline-indent highlight-scribble! scribble-lang-line-rx)

;; ---- coloring ------------------------------------------------------------------------------

(define scribble-lang-line-rx #px"^#lang\\s+scribble(?:/|\\s|$)")

;; A list of (start end key) spans, 0-based, half-open, for the parts of `text` that are not
;; plain prose. Keys are the theme keys highlight.rkt understands.
(define (scribble-spans text)
  (define lang-len (let ([m (regexp-match #px"^#lang[^\n]*" text)]) (if m (string-length (car m)) 0)))
  (define in (open-input-string text))
  (port-count-lines! in)
  (define spans (if (> lang-len 0) (list (list 0 lang-len 'keyword)) '()))
  (when (> lang-len 0) (read-string lang-len in))
  (with-handlers ([exn:fail? void])       ; a lexer surprise leaves the rest uncolored, never raises
    (let loop ([mode #f] [after-@? #f] [last-end lang-len])
      (define-values (lexeme type paren start end backup new-mode) (scribble-inside-lexer in 0 mode))
      (unless (or (eof-object? lexeme) (not start) (not end) (<= end (add1 last-end)))
        (define kind (if (hash? type) (hash-ref type 'type #f) type))
        (define commented? (and (hash? type) (hash-ref type 'comment? #f)))
        (define guess (and (hash? type) (hash-ref type 'semantic-type-guess #f)))
        (define at? (and (eq? kind 'parenthesis) (equal? lexeme "@")))
        (define key
          (cond [(or commented? (eq? kind 'comment)) 'comment]
                [at? 'keyword]
                [(and (eq? kind 'symbol) (or after-@? (eq? guess 'keyword))) 'keyword]
                [(eq? kind 'string) 'string]
                [(memq kind '(constant hash-colon-keyword)) 'constant]
                [(eq? kind 'error) 'error]
                [else #f]))
        (when key (set! spans (cons (list (sub1 start) (sub1 end) key) spans)))
        (loop new-mode at? (sub1 end)))))
  (reverse spans))

(define (highlight-scribble! t)
  (apply-highlight-spans! t (scribble-spans (send t document-text #:keep-positions? #t))))

;; ---- indentation ---------------------------------------------------------------------------

;; The indentation a new line should get when Enter is pressed at `pos` in `text`: one
;; `unit` deeper than the line where the innermost open `@name{...}` / `@name[...]` /
;; `@(...)` form began, the same as that form's own line when the next character closes it,
;; and the current line's indentation when no form is open. Text braces always count (Scribble
;; requires them balanced); square brackets and parentheses only count when they open a form
;; (right after `@name` or `@`), so a stray "(" in prose does not indent the rest of the file.
;; Inside a form's Racket part, strings are skipped and every bracket counts.
(define (scribble-newline-indent text pos unit)
  (define n (min pos (string-length text)))
  (define (line-indent-at i)               ; leading whitespace of the line containing index i
    (define s (let back ([j i]) (if (and (> j 0) (not (char=? (string-ref text (sub1 j)) #\newline))) (back (sub1 j)) j)))
    (let fwd ([j s]) (if (and (< j (string-length text)) (memv (string-ref text j) '(#\space #\tab))) (fwd (add1 j)) (substring text s j))))
  (define (after-at-name? i)               ; is index i right after `@` or `@name`?
    (define s (let back ([j i]) (if (and (> j 0) (not (memv (string-ref text (sub1 j)) '(#\newline #\space #\tab #\@ #\{ #\} #\[ #\] #\( #\) #\" #\|)))) (back (sub1 j)) j)))
    (and (> s 0) (char=? (string-ref text (sub1 s)) #\@)))
  (define (opener-context? i) (or (char=? (string-ref text i) #\{) (after-at-name? i)))
  ;; stack entries: (list kind indent), kind 'text | 'code | 'raw
  (define stack
    (let loop ([i 0] [stack '()] [datum-end -1])
      (cond
        [(>= i n) stack]
        [else
         (define c (string-ref text i))
         (define kind (and (pair? stack) (car (car stack))))
         (cond
           [(eq? kind 'raw)                                  ; verbatim until "}|"
            (if (and (char=? c #\}) (< (add1 i) n) (char=? (string-ref text (add1 i)) #\|))
                (loop (+ i 2) (cdr stack) -1)
                (loop (add1 i) stack -1))]
           [(and (char=? c #\@) (< (add1 i) n) (char=? (string-ref text (add1 i)) #\;))   ; comment to end of line
            (let skip ([j i]) (if (or (>= j n) (char=? (string-ref text j) #\newline)) (loop j stack -1) (skip (add1 j))))]
           [(and (char=? c #\@) (< (add1 i) n) (char=? (string-ref text (add1 i)) #\@))  ; an escaped @
            (loop (+ i 2) stack -1)]
           [(and (eq? kind 'code) (char=? c #\"))            ; a string in a form's Racket part
            (let skip ([j (add1 i)])
              (cond [(>= j n) (loop j stack -1)]
                    [(char=? (string-ref text j) #\\) (skip (+ j 2))]
                    [(char=? (string-ref text j) #\") (loop (add1 j) stack -1)]
                    [else (skip (add1 j))]))]
           [(and (char=? c #\{) (> i 0) (char=? (string-ref text (sub1 i)) #\|) (memq kind '(#f text)))
            (loop (add1 i) (cons (list 'raw (line-indent-at i)) stack) -1)]     ; `@name|{ ... }|`
           [(char=? c #\{)
            (define text? (or (memq kind '(#f text)) (opener-context? i) (= i datum-end)))
            (loop (add1 i) (cons (list (if text? 'text 'code) (line-indent-at i)) stack) -1)]
           [(memv c '(#\[ #\())
            (if (or (eq? kind 'code) (and (char=? c #\[) (after-at-name? i)) (and (char=? c #\() (> i 0) (char=? (string-ref text (sub1 i)) #\@)))
                (loop (add1 i) (cons (list 'code (line-indent-at i)) stack) -1)
                (loop (add1 i) stack -1))]
           [(memv c '(#\} #\] #\)))
            (cond [(and (pair? stack) (or (char=? c #\}) (eq? kind 'code)))
                   (loop (add1 i) (cdr stack) (if (char=? c #\]) (add1 i) -1))]
                  [else (loop (add1 i) stack -1)])]
           [else (loop (add1 i) stack -1)])])))
  (define next-nonblank
    (let fwd ([j n])
      (cond [(>= j (string-length text)) #f]
            [(memv (string-ref text j) '(#\space #\tab)) (fwd (add1 j))]
            [else (string-ref text j)])))
  (cond
    [(null? stack) (line-indent-at n)]
    [(memv next-nonblank '(#\} #\] #\))) (cadr (car stack))]
    [else (string-append (cadr (car stack)) unit)]))

;; ---- the Language ----------------------------------------------------------------------------

(define-command (scribble-newline)
  #:title "New Line in Scribble" #:aliases ("scribble newline" "indent inside form")
  #:help "Start a new line, indented one level inside an open @ form."
  #:when (lambda () (eq? (send (current-buffer) get-mode) 'scribble-mode))
  (define b (current-buffer))
  (define s (send b get-start-position))
  (define text (send b document-text #:keep-positions? #t))
  (define indent (scribble-newline-indent text s (send b local-ref 'indent-string "  ")))
  (send b begin-edit-sequence)
  (send b insert (string-append "\n" indent) s (send b get-end-position))
  (send b end-edit-sequence))

(define scribble-keymap (make-keymap/pairs 'scribble-mode (list (cons "Enter" 'scribble-newline))))

;; A child of prog-mode so Toggle Comment and the indent commands apply (they are gated on it),
;; but wrapped like prose, since a Scribble file is mostly sentences.
(define-mode scribble-mode
  #:label "Scribble"
  #:parent 'prog-mode
  #:files '("*.scrbl")
  #:first-line scribble-lang-line-rx
  #:keymap scribble-keymap
  #:locals '((wrap-lines . #t) (indent-string . "  ") (comment-start . "@;"))
  #:highlighter highlight-scribble!
  #:doc "Scribble documents: @ forms are colored apart from the prose, and @; comments.")
