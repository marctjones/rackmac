#lang racket/base
;; Line index (§1.1): line-start offsets for offset<->line/col conversion, and a physical-line
;; iterator over the source string (start, content-end, terminator-length) that the block parser
;; walks one line at a time. Line endings: \n, \r\n, and lone \r are all accepted as terminators
;; (the design normalizes to \n on load; this module tolerates the others for other callers and
;; for spec text).
(provide build-line-index offset->line+col line+col->offset
         source-lines line-record-start line-record-content-end line-record-end)

;; A vector of line-start offsets, index 0 is always 0 (or the whole vector is #(0) for "").
(define (build-line-index source)
  (define len (string-length source))
  (define starts (list 0))
  (let loop ([i 0] [starts starts])
    (cond
      [(>= i len) (list->vector (reverse starts))]
      [else
       (define ch (string-ref source i))
       (cond
         [(eqv? ch #\newline) (loop (add1 i) (cons (add1 i) starts))]
         [(eqv? ch #\return)
          (define next (add1 i))
          (define skip (if (and (< next len) (eqv? (string-ref source next) #\newline)) 2 1))
          (loop (+ i skip) (cons (+ i skip) starts))]
         [else (loop (add1 i) starts)])])))

;; Binary search: the greatest index i such that (vector-ref starts i) <= offset.
(define (line-index-of starts offset)
  (let loop ([lo 0] [hi (sub1 (vector-length starts))])
    (if (>= lo hi)
        lo
        (let ([mid (add1 (quotient (+ lo hi) 2))])
          (if (<= (vector-ref starts mid) offset)
              (loop mid hi)
              (loop lo (sub1 mid)))))))

;; 0-based line and column (code points; a tab counts as one character here, per §1.1: "columns
;; count code points and a tab as one character" -- tab expansion only matters inside the block
;; parser, not in this consumer-facing conversion).
(define (offset->line+col starts offset)
  (define line (line-index-of starts offset))
  (values line (- offset (vector-ref starts line))))

(define (line+col->offset starts line col)
  (+ (vector-ref starts line) col))

;; A physical line record: (start content-end end) offsets, where content-end excludes the line
;; terminator and end includes it (end = content-end for the last line if it has no terminator).
(struct line-record (start content-end end) #:transparent)

;; Returns a list of line-records covering the whole source, in order. An empty source yields
;; a single empty line record (start=end=0) so the block parser always has at least one line.
(define (source-lines source)
  (define len (string-length source))
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i len)
       (reverse (if (null? acc) (cons (line-record 0 0 0) acc) acc))]
      [else
       (define content-end
         (let scan ([j i])
           (cond [(>= j len) j]
                 [(eqv? (string-ref source j) #\newline) j]
                 [(eqv? (string-ref source j) #\return) j]
                 [else (scan (add1 j))])))
       (define end
         (cond
           [(>= content-end len) content-end]
           [(eqv? (string-ref source content-end) #\return)
            (if (and (< (add1 content-end) len) (eqv? (string-ref source (add1 content-end)) #\newline))
                (+ content-end 2)
                (add1 content-end))]
           [else (add1 content-end)]))
       (loop end (cons (line-record i content-end end) acc))])))
