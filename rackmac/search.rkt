#lang racket/base
;; Pure find/replace matching: no text%, no window, so it is tested directly (tests/search-test.rkt)
;; and reused by rackmac/ui/find-bar.rkt for the count, stepping and Replace All. Literal queries
;; are matched via a case-folded regexp (Racket's (?i:...) does fold non-ASCII letters); whole word
;; is a post-hoc boundary check using char-alphabetic?/char-numeric?, because regexp's own \b and
;; [:alpha:] are ASCII-only and would misjudge a boundary next to an accented letter.
(require racket/list racket/string)
(provide (struct-out find-error) (struct-out replace-result)
         find-cap compile-find-pattern find-matches step-match-index replace-all-string format-count)

;; Above this many matches, the UI shows "10,000+ matches" instead of scanning further use.
(define find-cap 10000)

;; A regex that failed to compile, or (in find-matches/replace-all-string) is only valid in
;; #:regex? mode: the message is shown verbatim in the find row's count area.
(struct find-error (message) #:transparent)

;; The result of Replace All: the whole new text and how many matches were replaced.
(struct replace-result (text count) #:transparent)

(define (word-char? c) (or (char-alphabetic? c) (char-numeric? c) (eqv? c #\_)))

(define (boundary-ok? text start end)
  (and (or (= start 0) (not (word-char? (string-ref text (sub1 start)))))
       (or (= end (string-length text)) (not (word-char? (string-ref text end))))))

;; -> (or/c pregexp? find-error?). `query` is used literally unless #:regex? is true.
(define (compile-find-pattern query #:case? [case? #f] #:regex? [regex? #f])
  (define src (if regex? query (regexp-quote query)))
  (define wrapped (if case? src (string-append "(?i:" src ")")))
  (with-handlers ([exn:fail? (lambda (e) (find-error "Invalid pattern"))])
    (pregexp wrapped)))

;; -> (or/c (listof (cons/c exact-nonnegative-integer? exact-nonnegative-integer?)) find-error?)
;; Matches are non-overlapping, in order, capped at `limit`. Zero-width matches (a bare "a*" or
;; similar) are dropped so stepping can never get stuck on the same position.
(define (find-matches text query #:case? [case? #f] #:word? [word? #f] #:regex? [regex? #f] #:limit [limit find-cap])
  (cond
    [(string=? query "") '()]
    [else
     (define pat (compile-find-pattern query #:case? case? #:regex? regex?))
     (cond
       [(find-error? pat) pat]
       [else
        (with-handlers ([exn:fail? (lambda (e) (find-error "Invalid pattern"))])
          (define raw (regexp-match-positions* pat text))
          (define nonzero (filter (lambda (p) (> (cdr p) (car p))) raw))
          (define kept (if word? (filter (lambda (p) (boundary-ok? text (car p) (cdr p))) nonzero) nonzero))
          (if (> (length kept) limit) (take kept limit) kept))])]))

;; From `anchor` (a buffer position), the index into `matches` that Next/Previous should land
;; on, and whether getting there wrapped around the ends of the list. 'forward includes a match
;; starting exactly at `anchor` (so typing lands on a match right under the caret); 'backward
;; is strict so pressing it again does not reselect the match the caret is already inside.
(define (step-match-index matches anchor dir)
  (define n (length matches))
  (cond
    [(zero? n) (values #f #f)]
    [(eq? dir 'forward)
     (define i (for/or ([m (in-list matches)] [idx (in-naturals)]) (and (>= (car m) anchor) idx)))
     (if i (values i #f) (values 0 #t))]
    [else
     (define i (for/last ([m (in-list matches)] [idx (in-naturals)] #:when (< (car m) anchor)) idx))
     (if i (values i #f) (values (sub1 n) #t))]))

;; Replace every match of `query` in `text` with `replacement` in one pass over the ORIGINAL
;; text (never the mutating, re-searched text), so a replacement that contains the query cannot
;; loop. In #:regex? mode, `replacement` may use \1.. \9 group references and \\ / & the way
;; regexp-replace does (that escaping is what regexp-replace-quote produces for literal mode).
(define (replace-all-string text query replacement #:case? [case? #f] #:word? [word? #f] #:regex? [regex? #f])
  (cond
    [(string=? query "") (replace-result text 0)]
    [else
     (define pat (compile-find-pattern query #:case? case? #:regex? regex?))
     (cond
       [(find-error? pat) pat]
       [else
        (define matches (find-matches text query #:case? case? #:word? word? #:regex? regex? #:limit +inf.0))
        (cond
          [(find-error? matches) matches]
          [(null? matches) (replace-result text 0)]
          [else
           (define repl (if regex? replacement (regexp-replace-quote replacement)))
           (define out
             (let loop ([pos 0] [ms matches] [acc '()])
               (cond
                 [(null? ms) (apply string-append (reverse (cons (substring text pos) acc)))]
                 [else
                  (define m (car ms))
                  (define piece (regexp-replace pat (substring text (car m) (cdr m)) repl))
                  (loop (cdr m) (cdr ms) (list* piece (substring text pos (car m)) acc))])))
           (replace-result out (length matches))])])]))

;; "12" -> "12", "10000" -> "10,000+" once at the cap (there may be more; we stopped counting).
(define (format-count n)
  (define grouped (regexp-replace* #px"(?<=\\d)(?=(\\d{3})+(?!\\d))" (number->string n) ","))
  (if (>= n find-cap) (string-append grouped "+") grouped))
