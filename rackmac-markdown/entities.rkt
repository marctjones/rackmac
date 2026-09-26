#lang racket/base
;; Named HTML entities, vendored from the WHATWG entities.json table (entities.rktd), and the
;; decoding CommonMark applies to text, link destinations and titles (spec, "Entity and numeric
;; character references" and "Backslash escapes"). CommonMark only recognizes the
;; semicolon-terminated form, so `entity-lookup` requires the trailing `;` in `name`.
(require racket/runtime-path "chars.rkt")
(provide entity-lookup entity-table match-entity unescape-string nul->replacement)

(define-runtime-path entities-data-path "entities.rktd")

;; Loaded once, lazily, so requiring this module has no I/O cost until an entity is looked up.
(define entity-table
  (let ([cache #f])
    (lambda ()
      (unless cache
        (set! cache (call-with-input-file entities-data-path read)))
      cache)))

;; name includes the trailing `;` (and excludes the leading `&`), e.g. "amp;", "frac34;".
;; Returns the decoded character string, or #f if `name` is not a known entity.
(define (entity-lookup name)
  (hash-ref (entity-table) name #f))

(define (ascii-digit? c) (and (char>=? c #\0) (char<=? c #\9)))
(define (ascii-hex? c) (or (ascii-digit? c) (and (char>=? c #\a) (char<=? c #\f))
                           (and (char>=? c #\A) (char<=? c #\F))))
(define (ascii-alpha? c) (or (and (char>=? c #\a) (char<=? c #\z)) (and (char>=? c #\A) (char<=? c #\Z))))
(define (ascii-alnum? c) (or (ascii-alpha? c) (ascii-digit? c)))

;; A code point from a numeric reference: 0, surrogates and values past U+10FFFF become U+FFFD.
(define (code-point->string n)
  (if (or (= n 0) (> n #x10FFFF) (and (>= n #xD800) (<= n #xDFFF)))
      (string (integer->char #xFFFD))
      (string (integer->char n))))

;; Tries to read an entity or numeric character reference at `pos` (where s[pos] is `&`), not
;; reading past `end`. Returns (values decoded-string end-position) or (values #f pos).
;; Forms: &name; (2..32 alnum chars, first a letter, known to the WHATWG table), &#d; (1..7
;; decimal digits), &#xh; (1..6 hex digits).
(define (match-entity s pos [end (string-length s)])
  (define (fail) (values #f pos))
  (define i (add1 pos))
  (cond
    [(>= i end) (fail)]
    [(eqv? (string-ref s i) #\#)
     (define j (add1 i))
     (define hex? (and (< j end) (memv (string-ref s j) '(#\x #\X))))
     (define digits-start (if hex? (add1 j) j))
     (define max-digits (if hex? 6 7))
     (define digit? (if hex? ascii-hex? ascii-digit?))
     (let loop ([k digits-start])
       (cond
         [(and (< k end) (digit? (string-ref s k)) (< (- k digits-start) max-digits)) (loop (add1 k))]
         [(and (> k digits-start) (< k end) (eqv? (string-ref s k) #\;))
          (values (code-point->string (string->number (substring s digits-start k) (if hex? 16 10)))
                  (add1 k))]
         [else (fail)]))]
    [(ascii-alpha? (string-ref s i))
     (let loop ([k (add1 i)])
       (cond
         [(and (< k end) (ascii-alnum? (string-ref s k)) (< (- k i) 32)) (loop (add1 k))]
         [(and (< k end) (eqv? (string-ref s k) #\;))
          (define decoded (entity-lookup (substring s i (add1 k))))
          (if decoded (values decoded (add1 k)) (fail))]
         [else (fail)]))]
    [else (fail)]))

;; Spec, "Insecure characters": U+0000 in decoded values and output becomes U+FFFD (the
;; document string, and with it every position, is left untouched).
(define (nul->replacement s)
  (if (for/or ([c (in-string s)]) (eqv? c #\nul))
      (list->string (for/list ([c (in-string s)]) (if (eqv? c #\nul) (integer->char #xFFFD) c)))
      s))

;; Decodes backslash escapes (before ASCII punctuation) and entity/numeric references in `s`,
;; as CommonMark does for link destinations, titles and fenced-code info strings.
(define (unescape-string s)
  (define len (string-length s))
  (cond
    [(not (for/or ([c (in-string s)]) (or (eqv? c #\\) (eqv? c #\&) (eqv? c #\nul)))) s]
    [else
     (define out (open-output-string))
     (let loop ([i 0])
       (when (< i len)
         (define c (string-ref s i))
         (cond
           [(and (eqv? c #\\) (< (add1 i) len) (ascii-punctuation? (string-ref s (add1 i))))
            (write-char (string-ref s (add1 i)) out)
            (loop (+ i 2))]
           [(eqv? c #\&)
            (define-values (decoded next) (match-entity s i len))
            (cond [decoded (write-string decoded out) (loop next)]
                  [else (write-char c out) (loop (add1 i))])]
           [else (write-char c out) (loop (add1 i))])))
     (nul->replacement (get-output-string out))]))
