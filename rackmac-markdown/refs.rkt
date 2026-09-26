#lang racket/base
;; Link reference labels, destinations and titles (design §1.4, §2.2): label normalization for
;; the refmap, and the scanners the block phase (reference definitions) and the inline phase
;; (inline and reference links) share, so both decode exactly alike (backslash escapes and
;; entity references; spec "Links" and "Link reference definitions").
(require racket/string "chars.rkt" "entities.rkt")
(provide normalize-label
         scan-link-label scan-link-destination scan-link-title skip-spnl
         max-label-length)

;; Unicode case fold, internal whitespace collapsed to one space, ends trimmed (spec, "Links":
;; matching of reference labels).
(define (normalize-label s)
  (string-foldcase (string-join (string-split s) " ")))

;; A link label holds at most 999 characters between its brackets (spec, "Links").
(define max-label-length 999)

;; s[pos] must be `[`. Returns the position just after the matching `]`, or #f: no unescaped
;; `[` inside, at most 999 characters inside, a backslash escapes the next character.
(define (scan-link-label s pos end)
  (let loop ([i (add1 pos)])
    (cond
      [(>= i end) #f]
      [(> (- i pos 1) max-label-length) #f]
      [else
       (define c (string-ref s i))
       (cond
         [(eqv? c #\\) (if (< (add1 i) end) (loop (+ i 2)) #f)]
         [(eqv? c #\[) #f]
         [(eqv? c #\]) (add1 i)]
         [else (loop (add1 i))])])))

;; Skips spaces and tabs, at most one line ending, then spaces and tabs again.
(define (skip-spnl s pos end)
  (define (skip-sp i) (if (and (< i end) (space-or-tab? (string-ref s i))) (skip-sp (add1 i)) i))
  (define a (skip-sp pos))
  (if (and (< a end) (eqv? (string-ref s a) #\newline)) (skip-sp (add1 a)) a))

(define (ascii-control? c) (let ([n (char->integer c)]) (or (< n 32) (= n 127))))

;; Reads a link destination at `pos`. Returns (values decoded next-pos) where [pos, next-pos) is
;; the destination's source text (with its angle brackets, if any), or (values #f pos). Angle
;; form: `<...>` without unescaped `<`, `>` or line ending. Bare form: no spaces or control
;; characters, parentheses balanced (nesting capped at 32, as cmark does, which keeps runs of
;; unclosed `(` linear); it may be empty only when `allow-empty?` and it stops at `)`.
(define (scan-link-destination s pos end #:allow-empty? [allow-empty? #t])
  (cond
    [(>= pos end) (values #f pos)]
    [(eqv? (string-ref s pos) #\<)
     (let loop ([j (add1 pos)])
       (cond
         [(>= j end) (values #f pos)]
         [else
          (define c (string-ref s j))
          (cond
            [(eqv? c #\>) (values (unescape-string (substring s (add1 pos) j)) (add1 j))]
            [(and (eqv? c #\\) (< (add1 j) end) (not (eqv? (string-ref s (add1 j)) #\newline)))
             (loop (+ j 2))]
            [(memv c '(#\< #\newline)) (values #f pos)]
            [else (loop (add1 j))])]))]
    [else
     (let loop ([j pos] [depth 0])
       (define (finish)
         (cond
           [(not (= depth 0)) (values #f pos)]
           [(= j pos) (if (and allow-empty? (< j end) (eqv? (string-ref s j) #\)))
                          (values "" j)
                          (values #f pos))]
           [else (values (unescape-string (substring s pos j)) j)]))
       (cond
         [(>= j end) (finish)]
         [else
          (define c (string-ref s j))
          (cond
            [(and (eqv? c #\\) (< (add1 j) end) (ascii-punctuation? (string-ref s (add1 j))))
             (loop (+ j 2) depth)]
            [(eqv? c #\()
             (if (>= depth 32) (values #f pos) (loop (add1 j) (add1 depth)))]
            [(eqv? c #\)) (if (= depth 0) (finish) (loop (add1 j) (sub1 depth)))]
            [(or (eqv? c #\space) (ascii-control? c)) (finish)]
            [else (loop (add1 j) depth)])]))]))

;; Reads a link title at `pos`: "...", '...' or (...), backslash escapes allowed, a (...) title
;; may not contain an unescaped `(`. Returns (values decoded next-pos) or (values #f pos).
(define (scan-link-title s pos end)
  (cond
    [(>= pos end) (values #f pos)]
    [else
     (define open (string-ref s pos))
     (define close (case open [(#\") #\"] [(#\') #\'] [(#\() #\)] [else #f]))
     (cond
       [(not close) (values #f pos)]
       [else
        (let loop ([j (add1 pos)])
          (cond
            [(>= j end) (values #f pos)]
            [else
             (define c (string-ref s j))
             (cond
               [(and (eqv? c #\\) (< (add1 j) end)) (loop (+ j 2))]
               [(eqv? c close) (values (unescape-string (substring s (add1 pos) j)) (add1 j))]
               [(and (eqv? open #\() (eqv? c #\()) (values #f pos)]
               [else (loop (add1 j))])]))])]))
