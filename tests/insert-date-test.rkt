#lang racket/base
;; Insert Date (#352): ISO dates at the caret with a fixed clock, replacing a selection, one
;; undo step, reachable from the Edit menu, the palette and Word's shortcut.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/date "../rackmac/insert-date.rkt" "../rackmac/command.rkt"
         "../rackmac/commands.rkt" "../rackmac/editor.rkt" "../rackmac/keymap.rkt")

;; 2026-09-30 14:05 local time.
(define fixed (find-seconds 0 5 14 30 9 2026))
(define (doc text [start 0] [end start])
  (define b (new-buffer! "dates" #:mode 'markdown-mode))
  (send b insert text) (send b clear-undos) (send b set-position start end)
  (set-current-buffer! b) b)

(test-case "dates are ISO, zero-padded, from the clock"
  (check-equal? (date-string fixed) "2026-09-30")
  (check-equal? (date-time-string fixed) "2026-09-30 14:05")
  (check-equal? (date-string (find-seconds 0 0 9 3 1 2027)) "2027-01-03"))

(test-case "Insert Date types today's date at the caret"
  (define b (doc "Call on " 8))
  (parameterize ([current-clock (lambda () fixed)]) (run-command 'insert-date))
  (check-equal? (send b get-text) "Call on 2026-09-30"))

(test-case "it replaces a selection, and one Undo takes it back"
  (define b (doc "Due DATE here" 4 8))
  (parameterize ([current-clock (lambda () fixed)]) (run-command 'insert-date-time))
  (check-equal? (send b get-text) "Due 2026-09-30 14:05 here")
  (send b undo)
  (check-equal? (send b get-text) "Due DATE here"))

(test-case "reachable: Edit menu, palette words, Word's shortcut"
  (define c (find-command 'insert-date))
  (check-equal? (command-menu c) "Edit")
  (check-not-false (member "today" (command-aliases c)))
  (check-not-false (command-shortcut 'insert-date)))
