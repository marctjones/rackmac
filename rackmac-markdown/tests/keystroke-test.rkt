#lang racket/base
;; The keystroke budget (design §3.1, mdlib-parser #321): one keystroke in a 300 KB, 5,500-line
;; note -- `parser-reparse!`, its change report, the inline parse and relocation of the leaves
;; the report names, and `style-runs` over the report's ranges (what `md-restyle-region` asks
;; for next) -- under 10 ms. Measured in CPU
;; time (`current-process-milliseconds`, GC included) because other processes may load the
;; machine; the mean over a run of keystrokes is printed. The CI assertion keeps design §5's 3x
;; margin so a slow runner does not flake; the printed mean is the number the budget is about.
(require racket/list rackunit
         "../main.rkt" "notes-gen.rkt")

(define text (generate-notes 5500 1))
(define keystrokes 100)

;; Types `keystrokes` characters one at a time at `pos`; returns the mean CPU ms per keystroke.
;; Each new text is built before its keystroke's clock starts: getting the text is the editor's
;; cost, not the parser's. (Per-keystroke readings are whole milliseconds; their sum over many
;; keystrokes still averages out.)
(define (type-at pos)
  (define p (make-parser #:extensions all-extensions))
  (define doc0 (parser-parse! p text))
  (for ([b (in-list (document-blocks doc0))]) (force-leaves b))
  (collect-garbage)
  (define-values (_ total)
    (for/fold ([t text] [total 0]) ([i (in-range keystrokes)])
      (define at (+ pos i))
      (define new (string-append (substring t 0 at) "x" (substring t at)))
      (define t0 (current-process-milliseconds))
      (define-values (doc rep) (parser-reparse! p new (edit at at "x")))
      (for ([b (in-list (change-report-inline-changed rep))]) (block-inlines b))
      (for ([r (in-list (change-report-ranges rep))]) (style-runs doc #:start (car r) #:end (cdr r)))
      (values new (+ total (- (current-process-milliseconds) t0)))))
  (/ total keystrokes 1.0))

(define (force-leaves b)
  (cond
    [(leaf-block? b) (block-inlines b)]
    [(block-quote? b) (for-each force-leaves (block-quote-children b))]
    [(list-block? b) (for-each force-leaves (list-block-children b))]
    [(list-item? b) (for-each force-leaves (list-item-children b))]
    [else (void)]))

;; The start of the paragraph after the first `fraction` of the text, a few characters in.
(define (paragraph-position fraction)
  (define doc (parse-document text))
  (define target (quotient (* fraction (string-length text)) 100))
  (define para (for/first ([b (in-list (document-blocks doc))] #:when (and (paragraph? b) (>= (block-start b) target))) b))
  (+ (block-start para) 3))

(test-case "a keystroke in a 300 KB, 5,500-line note costs under 10 ms (asserted with a 3x margin)"
  (printf "keystroke fixture: ~a characters, ~a lines\n" (string-length text)
          (for/sum ([c (in-string text)]) (if (eqv? c #\newline) 1 0)))
  (for ([fraction (in-list '(0 50 95))])
    (define ms (type-at (paragraph-position fraction)))
    (printf "keystroke at ~a% of the note: ~a ms CPU per keystroke (mean of ~a)\n" fraction
            (/ (round (* 10 ms)) 10.0) keystrokes)
    (check-true (< ms 30) (format "~a ms per keystroke at ~a%" ms fraction))))
