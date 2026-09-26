#lang racket/base
;; Regression: starting with no file arguments must build the window and its hidden
;; placeholder document without recursing (hooks fired while creating the first buffer call
;; `current-buffer`). Kept in its own file so no other test has created a buffer first.
;; #277/#288: there is no Scratch Pad here any more -- the start screen is what a person
;; with no documents actually sees; see tests/lib-start-screen-test.rkt.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base
         "../rackmac/commands.rkt" "../rackmac/editor.rkt" "../rackmac/frame.rkt")

(test-case "no-argument startup terminates and shows the start screen, not a document"
  (define done (make-semaphore))
  (define result #f)
  (define t (thread (lambda ()
                      (set! result (make-main-frame))
                      (semaphore-post done))))
  (check-not-false (sync/timeout 10 done) "make-main-frame returned instead of looping")
  (when result
    (check-true (placeholder-buffer? (current-buffer)) "no real document was created")
    (check-equal? (length (all-buffers)) 1 "exactly one (hidden) buffer was created")
    (check-true (no-document-open?))
    (send result show #f))
  (kill-thread t))
