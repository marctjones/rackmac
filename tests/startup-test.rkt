#lang racket/base
;; Regression: starting with no file arguments must build the window and a scratch
;; buffer without recursing (hooks fired while creating the first buffer call
;; `current-buffer`). Kept in its own file so no other test has created a buffer first.
(require rackunit racket/class racket/gui/base
         "../rackmac/commands.rkt" "../rackmac/editor.rkt" "../rackmac/frame.rkt")

(test-case "no-argument startup terminates and shows a scratch buffer"
  (define done (make-semaphore))
  (define result #f)
  (define t (thread (lambda ()
                      (set! result (make-main-frame))
                      (semaphore-post done))))
  (check-not-false (sync/timeout 10 done) "make-main-frame returned instead of looping")
  (when result
    (check-equal? (send (current-buffer) get-name) "Scratch Pad")
    (check-equal? (length (all-buffers)) 1 "exactly one buffer was created")
    (send result show #f))
  (kill-thread t))
