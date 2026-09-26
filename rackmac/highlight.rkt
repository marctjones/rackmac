#lang racket/base
;; Simple syntax coloring. Styles are applied outside the undo history and the
;; modified flag is restored, so highlighting never shows up as an edit.
(require racket/class racket/gui/base racket/list racket/string
         syntax-color/racket-lexer "theme.rkt")
(provide highlight-racket! highlight-markdown! clear-highlight!)

(define (delta-for key)
  (define d (make-object style-delta%))
  (case key
    [(comment) (send d set-delta-foreground (theme-color 'comment)) (send d set-style-on 'italic)]
    [(heading) (send d set-delta-foreground (theme-color 'heading)) (send d set-weight-on 'bold)]
    [(error) (send d set-delta-foreground (theme-color 'error))]
    ;; inline code in a note: the code face on the serif page, a little smaller to match x-heights
    ;; (a multiplier, since size-add cannot be negative)
    [(code) (send d set-delta-foreground (theme-color 'string)) (send d set-delta-face mono-face 'modern)
            (send d set-size-mult 0.93)]
    [else (send d set-delta-foreground (theme-color key))])
  d)

(define (with-styling t proc)
  (define was-modified? (send t is-modified?))
  (send t begin-edit-sequence #f #f)
  (proc)
  (send t end-edit-sequence)
  (send t set-modified was-modified?))

;; Back to the document's base style: "Prose" for notes, "Standard" for code.
(define (clear-highlight! t)
  (send t change-style (send editor-style-list find-named-style (send t default-style-name)) 0 'end))

(define racket-forms
  (for/hash ([s '("define" "define-values" "define-syntax" "define-syntax-rule" "lambda" "λ" "let" "let*"
                  "letrec" "let-values" "if" "cond" "case" "when" "unless" "begin" "set!" "and" "or"
                  "require" "provide" "struct" "class" "module" "for" "for/list" "for/fold" "for*"
                  "match" "with-handlers" "parameterize" "quote" "quasiquote" "define-command"
                  "define-mode" "else")])
    (values s #t)))

(define (highlight-racket! t)
  (define text (send t get-text))
  (with-styling t
    (lambda ()
      (clear-highlight! t)
      (define in (open-input-string text))
      (port-count-lines! in)
      (let loop ()
        (define-values (lexeme type paren start end) (racket-lexer in))
        (unless (eof-object? lexeme)
          (define key
            (case type
              [(comment sexp-comment) 'comment]
              [(string) 'string]
              [(constant hash-colon-keyword) 'constant]
              [(error) 'error]
              [(symbol) (and (hash-ref racket-forms lexeme #f) 'keyword)]
              [else #f]))
          (when (and key start end)
            (send t change-style (delta-for key) (sub1 start) (sub1 end)))
          (loop))))))

(define (highlight-markdown! t)
  (define text (send t get-text))
  (with-styling t
    (lambda ()
      (clear-highlight! t)
      (for ([m (in-list (regexp-match-positions* #px"(?m:^#{1,6} .*$)" text))])
        (send t change-style (delta-for 'heading) (car m) (cdr m)))
      (for ([m (in-list (regexp-match-positions* #px"`[^`\n]+`" text))])
        (send t change-style (delta-for 'code) (car m) (cdr m))))))
