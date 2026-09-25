#lang racket/base
;; Subsequence fuzzy matching for the picker. Lower score is better; #f means no match.
(provide fuzzy-score fuzzy-filter fuzzy-filter* field-score)

(define (fuzzy-score query text)
  (define q (string-downcase query))
  (define t (string-downcase text))
  (define qn (string-length q))
  (define tn (string-length t))
  (cond
    [(zero? qn) 0]
    [else
     (let loop ([qi 0] [ti 0] [score 0] [last -2])
       (cond
         [(= qi qn) (+ score (* 0.01 tn))]                    ; prefer shorter candidates
         [(>= ti tn) #f]
         [(char=? (string-ref q qi) (string-ref t ti))
          (define word-start? (or (zero? ti) (memv (string-ref t (sub1 ti)) '(#\space #\- #\_ #\/ #\.))))
          (define bonus (+ (if (= ti (add1 last)) -3 0)      ; consecutive
                           (if word-start? -2 0)))
          (loop (add1 qi) (add1 ti) (+ score ti bonus) ti)]   ; earlier matches score lower
         [else (loop qi (add1 ti) score last)]))]))

;; Scores one field against a query. Exact match beats prefix, prefix beats a contiguous
;; substring, and any of those beats letters scattered through the field. Lower is better.
(define (field-score query field)
  (define q (string-downcase query))
  (define f (string-downcase field))
  (define n (string-length f))
  (cond
    [(string=? q "") 0]
    [(string=? q f) -1000]
    [(and (<= (string-length q) n) (string=? q (substring f 0 (string-length q)))) (+ -500 (* 0.01 n))]
    [(regexp-match-positions (regexp-quote q) f) => (lambda (m) (+ -200 (caar m) (* 0.01 n)))]
    [(fuzzy-score q f) => (lambda (sc) (+ 1 (max 0 sc)))]
    [else #f]))

;; Each item offers several searchable fields (title, name, aliases...); the best one counts.
(define (fuzzy-filter* query items ->fields [limit 200])
  (define scored
    (for*/list ([it (in-list items)]
                [best (in-value (for/fold ([b #f]) ([f (in-list (->fields it))])
                                  (define sc (field-score query f))
                                  (if (and sc (or (not b) (< sc b))) sc b)))]
                #:when best)
      (cons best it)))
  (define sorted (sort scored < #:key car))
  (map cdr (if (> (length sorted) limit) (for/list ([x sorted] [_ (in-range limit)]) x) sorted)))

;; items: any list; ->string extracts the text to match. Returns best matches first.
(define (fuzzy-filter query items ->string [limit 200])
  (fuzzy-filter* query items (lambda (it) (list (->string it))) limit))
