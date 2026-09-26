#lang racket/base
;; A deterministic generator of note-like Markdown (design §0: "generated notes"), used by the
;; incremental property test and the keystroke budget until mdlib-bench vendors its fixtures:
;; headings, prose with emphasis, code spans, links (inline and reference), autolinks, entities
;; and escapes; bullet, ordered and nested lists; block quotes (with lazy lines); fenced and
;; indented code; thematic breaks; reference definitions, some defined after their use.
;; `(generate-notes target-lines seed)` returns a string of about `target-lines` lines (about 55
;; characters per line, so 5,500 lines is the §0 "301 KB, 5,526 lines" case).
(require racket/string racket/list)
(provide generate-notes)

(define words
  '("matter" "client" "draft" "review" "deadline" "memo" "filing" "court" "motion" "exhibit"
    "contract" "clause" "party" "notice" "hearing" "brief" "counsel" "record" "summary" "note"
    "meeting" "agenda" "budget" "invoice" "schedule" "witness" "statement" "appeal" "order"
    "the" "a" "of" "and" "to" "in" "for" "on" "with" "by" "from" "about" "before" "after"))

(define (generate-notes target-lines seed)
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng]) (random-seed seed))
  (define (rnd n) (random n rng))
  (define (pick xs) (list-ref xs (rnd (length xs))))
  (define (word) (pick words))
  (define (inline-bit)
    (case (rnd 16)
      [(0) (format "*~a ~a*" (word) (word))]
      [(1) (format "**~a**" (word))]
      [(2) (format "`~a()`" (word))]
      [(3) (format "[~a](https://example.com/~a \"~a\")" (word) (word) (word))]
      [(4) (format "[~a][ref~a]" (word) (rnd 40))]
      [(5) (format "<https://example.org/~a>" (word))]
      [(6) "&amp;"]
      [(7) "\\*"]
      [(8) (format "_~a_" (word))]
      [else (word)]))
  (define (sentence)
    (define n (+ 4 (rnd 8)))
    (string-append (string-titlecase (word)) " "
                   (string-join (for/list ([i (in-range n)]) (inline-bit)) " ") "."))
  (define (prose-line) (sentence))
  (define out '())
  (define count 0)
  (define (emit! . lines) (for ([l (in-list lines)]) (set! out (cons l out)) (set! count (add1 count))))
  (let loop ()
    (when (< count target-lines)
      (case (rnd 12)
        [(0) (emit! (format "~a ~a ~a" (make-string (+ 1 (rnd 3)) #\#) (string-titlecase (word)) (word)) "")]
        [(1 2 3) (for ([i (in-range (+ 1 (rnd 4)))]) (emit! (prose-line))) (emit! "")]
        [(4 5)
         (for ([i (in-range (+ 2 (rnd 5)))])
           (emit! (format "- ~a" (prose-line)))
           (when (= 0 (rnd 3))
             (for ([j (in-range (+ 1 (rnd 3)))]) (emit! (format "  - ~a" (sentence))))))
         (emit! "")]
        [(6)
         (for ([i (in-range (+ 2 (rnd 4)))]) (emit! (format "~a. ~a" (add1 i) (sentence))))
         (emit! "")]
        [(7)
         (emit! (format "> ~a" (prose-line)))
         (when (= 0 (rnd 2)) (emit! (sentence)))  ; a lazy continuation line
         (emit! (format "> ~a" (sentence)) "")]
        [(8)
         (emit! (format "```~a" (pick '("racket" "" "text"))))
         (for ([i (in-range (+ 1 (rnd 5)))]) (emit! (format "(define (~a x) (~a x))" (word) (word))))
         (emit! "```" "")]
        [(9) (emit! (format "    ~a ~a" (word) (word)) (format "    ~a" (word)) "")]
        [(10) (emit! "---" "")]
        [(11) (emit! (format "[ref~a]: https://example.net/~a \"~a\"" (rnd 40) (word) (word)) "")])
      (loop)))
  (string-append (string-join (reverse out) "\n") "\n"))
