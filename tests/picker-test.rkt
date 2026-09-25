#lang racket/base
;; Drives the real picker dialog with timers: type a query, press Enter, check the result.
;; A watchdog closes the dialog so a regression fails instead of hanging.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/list "../rackmac/picker.rkt")

(define items '(("Save" "⌘S" save) ("Save As…" "⇧⌘S" save-as) ("Select All" "⌘A" select-all) ("Undo" "⌘Z" undo)))

(define (dialog) (for/first ([w (get-top-level-windows)] #:when (is-a? w dialog%)) w))
(define (enter) (new key-event% [key-code #\return]))

;; Polls until the modal dialog is actually up (no fixed delay), runs the script once, and
;; has a watchdog so a regression fails instead of hanging.
(define (run-pick script)
  (define done? #f)
  (define step
    (new timer% [interval 30]
         [notify-callback (lambda ()
                            (define d (dialog))
                            (when (and d (not done?) (send d is-shown?))
                              (set! done? #t)
                              (send step stop)
                              (script d (first (send d get-children)) (second (send d get-children)))))]))
  (define watchdog (new timer% [notify-callback (lambda () (define d (dialog)) (when d (send d show #f)))]))
  (send watchdog start 8000 #t)
  (begin0 (pick "Test" items #:detail-heading "Shortcut")
          (send step stop)
          (send watchdog stop)))

(test-case "typing filters, Enter chooses the top match"
  (check-equal?
   (run-pick (lambda (d tf lb)
               (send tf set-value "sela")
               (send tf command (new control-event% [event-type 'text-field]))
               (check-equal? (send lb get-number) 1 "only Select All matches")
               (send d on-subwindow-char tf (enter))))
   'select-all))

(test-case "Down moves the selection"
  (check-equal?
   (run-pick (lambda (d tf lb)
               (send d on-subwindow-char tf (new key-event% [key-code 'down]))
               (send d on-subwindow-char tf (enter))))
   'save-as))

(test-case "Escape cancels"
  (check-false (run-pick (lambda (d tf lb) (send d on-subwindow-char tf (new key-event% [key-code 'escape]))))))

(test-case "no match then Enter returns #f"
  (check-false
   (run-pick (lambda (d tf lb)
               (send tf set-value "zzzz")
               (send tf command (new control-event% [event-type 'text-field]))
               (send d on-subwindow-char tf (enter))))))
