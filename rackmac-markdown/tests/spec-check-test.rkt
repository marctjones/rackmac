#lang racket/base
;; Tests the spec runner's own consistency checks (design #319: "the known-failures regression
;; check ... has never fired, so its failure path is untested") against synthetic result tuples,
;; since the real known-failures.rktd has nothing left in it to exercise the failure path with.
;; Result tuples are (example-number exact? markdown expected actual struct-ok?), the shape
;; tests/spec-test.rkt builds per example.
(require rackunit "spec-check.rkt")

(define (fake n exact?) (list n exact? "md" "expected" (if exact? "expected" "wrong") exact?))

(test-case "stale-known-failures: real data has none listed that now pass"
  ;; A passing example correctly absent from known-failures never counts as stale.
  (check-equal? (stale-known-failures (list (fake 1 #t)) (hasheqv)) '()))

(test-case "stale-known-failures: a listed example that now passes is reported"
  ;; Inject a fake "now passing" listed example (example 999, exact? #t) under a fake
  ;; known-failures hash that still lists it: the checker must report it as stale.
  (define results (list (fake 1 #f) (fake 999 #t)))
  (define known (hasheqv 999 "some stale reason"))
  (check-equal? (stale-known-failures results known) '(999)))

(test-case "stale-known-failures: a listed example that still fails is not reported"
  (define results (list (fake 999 #f)))
  (define known (hasheqv 999 "still fails"))
  (check-equal? (stale-known-failures results known) '()))

(test-case "unlisted-failures: a failing example not on the list is reported"
  (define results (list (fake 1 #t) (fake 2 #f)))
  (check-equal? (unlisted-failures results (hasheqv)) '(2)))

(test-case "unlisted-failures: a failing example that IS listed is not reported"
  (define results (list (fake 2 #f)))
  (check-equal? (unlisted-failures results (hasheqv 2 "known")) '()))
