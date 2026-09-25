#lang info
(define collection "rackmac-markdown")
(define deps '("base"))
;; commonmark-lib is the differential-test oracle (design §5, §0), used only by
;; tests/oracle-test.rkt, which skips cleanly when it is absent; never a runtime dependency.
(define build-deps '("rackunit-lib" "commonmark-lib"))
(define pkg-desc "Rackmac's own pure-Racket CommonMark implementation")
(define pkg-authors '("marctjones"))
(define license 'MIT)
(define test-omit-paths '("tests/fixtures"))
