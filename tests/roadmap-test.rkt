#lang racket/base
;; The roadmap data must be valid, and ROADMAP.md must be regenerated whenever it changes.
(require rackunit racket/file racket/runtime-path "../tools/roadmap.rkt")
(define-runtime-path md "../ROADMAP.md")

(define rm (load-roadmap))

(test-case "roadmap data validates (unique keys, known sizes/statuses, dependencies exist)"
  (check-equal? (validate rm) '()))

(test-case "ROADMAP.md is up to date with docs/roadmap.rktd (run: racket tools/roadmap.rkt)"
  (check-equal? (file->string md) (render rm)))
