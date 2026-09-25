#lang racket/base
;; Link reference label normalization (design §1.4): Unicode case fold, internal whitespace
;; collapsed to a single space, leading/trailing whitespace stripped.
(require racket/string)
(provide normalize-label)

(define (normalize-label s)
  (string-foldcase (string-join (string-split s) " ")))
