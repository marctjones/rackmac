#lang racket/base
;; The status-bar segment registry (no GUI). Segments sit right of the message area, in the
;; order they were added; #:priority says which are dropped first when the bar is too
;; narrow to show them all (lower drops first). Unloaded with the extension that added
;; them, the same way `rackmac/toolbar.rkt` items are.
(require "owner.rkt" "hook.rkt")
(provide (struct-out status-segment) add-status-segment! remove-status-segment! status-segments)

;; name: a symbol identifying the segment (unique; adding the same name again replaces it).
;; thunk: (-> (or/c string? #f)); #f hides the segment right now (e.g. no selection to show).
;; command: a command name (symbol) to run on click, or #f when the segment is not clickable.
;; hint: shown in the message area on hover; #f falls back to the command's title.
;; priority: lower segments are dropped first when the bar is too narrow for all of them.
(struct status-segment (name thunk command hint priority) #:transparent)

(define segments '())          ; insertion order

(define (status-segments) segments)

(define (changed!) (run-hook 'status-segments-changed))

(define (add-status-segment! name thunk #:command [command #f] #:hint [hint #f] #:priority [priority 0])
  (unless (symbol? name) (raise-argument-error 'add-status-segment! "symbol?" name))
  (define old segments)
  (set! segments (append (filter (lambda (s) (not (eq? (status-segment-name s) name))) segments)
                        (list (status-segment name thunk command hint priority))))
  (register-undo! 'status-segment (lambda () (set! segments old) (changed!)))
  (changed!))

(define (remove-status-segment! name)
  (define old segments)
  (set! segments (filter (lambda (s) (not (eq? (status-segment-name s) name))) segments))
  (register-undo! 'status-segment (lambda () (set! segments old) (changed!)))
  (changed!))
