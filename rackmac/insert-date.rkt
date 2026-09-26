#lang racket/base
;; Insert Date (#352): today's date at the caret in one keystroke, for the date line every
;; meeting and call note starts with. ISO form (2026-09-30), which the Library index and
;; task dates (#295) read; Insert Date and Time adds the time. The shortcut follows Word:
;; Alt+Shift+D on Windows, ⌃⇧D on the Mac (⇧⌘D is Duplicate Line).
(require racket/class racket/format "command.rkt" "editor.rkt")
(provide current-clock date-string date-time-string)

;; Seconds since the epoch; a parameter so tests can fix the clock.
(define current-clock (make-parameter current-seconds))

(define (two n) (~r n #:min-width 2 #:pad-string "0"))
(define (date-string [secs ((current-clock))])
  (define d (seconds->date secs))
  (format "~a-~a-~a" (date-year d) (two (date-month d)) (two (date-day d))))
(define (date-time-string [secs ((current-clock))])
  (define d (seconds->date secs))
  (format "~a ~a:~a" (date-string secs) (two (date-hour d)) (two (date-minute d))))

;; Replaces the selection (or inserts at the caret) as a single undo step.
(define (insert-at-selection! s)
  (define b (current-buffer))
  (define start (send b get-start-position))
  (define end (send b get-end-position))
  (send b begin-edit-sequence)
  (send b insert s start end)
  (send b end-edit-sequence))

(define-command (insert-date)
  #:icon "calendar"
  #:aliases ("today" "date" "insert today's date")
  #:help "Type today's date at the cursor, like 2026-09-30."
  #:title "Insert Date" #:menu "Edit" #:menu-order 50
  #:keys/mac ("Ctrl-Shift-d") #:keys/windows ("Alt-Shift-d")
  (insert-at-selection! (date-string)))

(define-command (insert-date-time)
  #:icon "calendar"
  #:aliases ("now" "time" "timestamp" "insert date and time")
  #:help "Type today's date and the time at the cursor, like 2026-09-30 14:30."
  #:title "Insert Date and Time" #:menu "Edit" #:menu-order 51
  (insert-at-selection! (date-time-string)))
