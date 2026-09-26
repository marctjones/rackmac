#lang racket/base
;; Time budgets for performance tests. Shared CI runners (GitHub sets CI=true) run several times
;; slower than a developer Mac, so a budget stretches by `ci-slack` there; a real regression
;; (quadratic work, a whole-document restyle per keystroke) still blows through it.
(provide ci-slack budget)
(define ci-slack (if (getenv "CI") 5 1))
(define (budget ms) (* ci-slack ms))
