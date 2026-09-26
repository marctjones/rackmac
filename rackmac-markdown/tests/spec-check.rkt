#lang racket/base
;; The spec runner's known-failures consistency checks (design #319), factored out as pure
;; functions over result tuples so tests/spec-check-test.rkt can exercise the "a listed example
;; now passes" failure path with synthetic data -- the real known-failures.rktd has nothing left
;; in it to trigger that path on demand. Kept separate from tests/spec-test.rkt (which does the
;; expensive work of reading and running the whole spec suite) so requiring it for a unit test
;; does not also re-run that suite.
;; Result tuples are (example-number exact? markdown expected actual struct-ok?), the shape
;; tests/spec-test.rkt builds per example.
(provide stale-known-failures unlisted-failures)

;; A "stale" entry is listed in known-failures but currently passes -- it should be removed.
(define (stale-known-failures results known-failures)
  (for/list ([r (in-list results)] #:when (and (cadr r) (hash-ref known-failures (car r) #f)))
    (car r)))

;; The complementary check: an example that fails and is NOT listed in known-failures is a
;; regression.
(define (unlisted-failures results known-failures)
  (for/list ([r (in-list results)] #:unless (or (cadr r) (hash-ref known-failures (car r) #f)))
    (car r)))
