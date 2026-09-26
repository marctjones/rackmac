#lang racket/base
;; Extracts the extension examples of the GitHub Flavored Markdown spec (0.29) into
;; gfm-0.29-extensions.json, the same shape as spec-0.31.2.json plus "extension": each example
;; whose fence line names an extension (`example table`, `example strikethrough`, `example
;; autolink`, `example disabled` for task lists, `example tagfilter`). Examples are numbered as
;; in the spec (counting every example of the document), and `→` becomes a tab, as upstream's
;; own extractor (test/spec_tests.py) does. Run by hand; `raco test` does nothing here:
;;
;;   curl -sLO https://raw.githubusercontent.com/github/cmark-gfm/0.29.0.gfm.13/test/spec.txt
;;   racket rackmac-markdown/tests/spec/extract-gfm-examples.rkt spec.txt \
;;     > rackmac-markdown/tests/spec/gfm-0.29-extensions.json
(module+ main
  (require json racket/string racket/list)
  (define fence (make-string 32 #\`))
  (define lines (call-with-input-file (vector-ref (current-command-line-arguments) 0)
                  (lambda (in) (for/list ([l (in-lines in)]) l))))
  (define (untab s) (string-replace s "→" "\t"))
  (define examples
    (let loop ([ls lines] [n 1] [line-no 1] [section ""] [acc '()])
      (cond
        [(null? ls) (reverse acc)]
        [(regexp-match #px"^#+ (.*)$" (car ls))
         => (lambda (m) (loop (cdr ls) n (add1 line-no) (cadr m) acc))]
        [(regexp-match (pregexp (string-append "^" fence " example ?(.*)$")) (car ls))
         => (lambda (m)
              (define ext (string-trim (cadr m)))
              (define-values (md-lines rest1) (splitf-at (cdr ls) (lambda (l) (not (equal? l ".")))))
              (define-values (html-lines rest2) (splitf-at (cdr rest1) (lambda (l) (not (equal? l fence)))))
              (define consumed (+ 3 (length md-lines) (length html-lines)))
              (define (joined ls) (if (null? ls) "" (string-append (string-join ls "\n") "\n")))
              (loop (cdr rest2) (add1 n) (+ line-no consumed) section
                    (if (equal? ext "")
                        acc
                        (cons (hasheq 'markdown (untab (joined md-lines)) 'html (untab (joined html-lines))
                                      'example n 'start_line line-no 'end_line (+ line-no consumed -1)
                                      'section section 'extension ext)
                              acc))))]
        [else (loop (cdr ls) n (add1 line-no) section acc)])))
  (write-json examples)
  (newline))
