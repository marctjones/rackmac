#lang racket/base
;; Record Actions (#121): Start/Stop Recording capture commands by name, in order, through
;; the real dispatch (run-command, the key dispatcher, the palette). The acceptance
;; criterion is "survives rebinding": a recording names commands, not the keys pressed.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base
         "../rackmac/command.rkt" "../rackmac/commands.rkt" "../rackmac/editor.rkt"
         "../rackmac/keymap.rkt" "../rackmac/input.rkt" "../rackmac/hook.rkt"
         "../rackmac/platform.rkt" "../rackmac/record-actions.rkt")

(define (doc text)
  (define b (new-buffer! "record"))
  (set-current-buffer! b)
  (send b insert text)
  (send b set-position 0)
  b)

;; Runs `thunk` between Start and Stop Recording and returns what was recorded.
(define (record thunk)
  (run-command 'start-recording)
  (thunk)
  (run-command 'stop-recording)
  (last-recording))

(define ran '())                     ; test commands note themselves here
(define-command (rec-test-x) #:help "Test." (set! ran (cons 'rec-test-x ran)))
(define-command (rec-test-y) #:help "Test." (set! ran (cons 'rec-test-y ran)))
(define-command (rec-test-inner) #:help "Test." (set! ran (cons 'rec-test-inner ran)))
(define-command (rec-test-outer) #:help "Test." (run-command 'rec-test-inner))
(define-command (rec-test-fails) #:help "Test." (error 'rec-test-fails "on purpose"))
(define-command (rec-test-launcher) #:help "Test." (run-command/safe 'rec-test-x))
(define-command (rec-test-stops) #:help "Test." (run-command 'stop-recording))

(define (key-press code #:shift [shift? #f] #:word-mod [word? #f])
  (new key-event% [key-code code] [shift-down shift?]
       [alt-down (and word? (mac?))] [control-down (and word? (not (mac?)))]))

(test-case "commands are recorded in order; Stop finalizes the recording"
  (doc "one two three")
  (run-command 'start-recording)
  (check-true (recording?))
  (run-command 'select-all)
  (run-command 'word-right)
  (check-equal? (recording-steps) '(select-all word-right) "the recording in progress, oldest first")
  (run-command 'line-end)
  (run-command 'stop-recording)
  (check-false (recording?))
  (check-equal? (recording-steps) '())
  (check-equal? (last-recording) '(select-all word-right line-end)
                "Start and Stop Recording are not in it"))

(test-case "nothing is recorded while not recording"
  (define before (record (lambda () (run-command 'rec-test-x))))
  (run-command 'rec-test-y)
  (run-command 'select-all)
  (check-equal? (last-recording) before))

(test-case "survives rebinding: a recording names the command, not the key"
  (define b (doc "text"))
  (keymap-bind! global-keymap "F8" 'rec-test-x)
  (define steps (record (lambda () (check-true (dispatch-key-event b (key-press 'f8))))))
  (check-equal? steps '(rec-test-x))
  ;; Rebind the same key to another command: the key now runs Y...
  (keymap-bind! global-keymap "F8" 'rec-test-y)
  (set! ran '())
  (dispatch-key-event b (key-press 'f8))
  (check-equal? ran '(rec-test-y) "F8 now runs the other command")
  ;; ...and the recording still says X, and replaying it by name runs X.
  (check-equal? (last-recording) '(rec-test-x))
  (set! ran '())
  (for ([s (last-recording)]) (run-command (step-command s)))
  (check-equal? ran '(rec-test-x))
  (keymap-unbind! global-keymap "F8"))

(test-case "a Shift+motion key is recorded as extending the selection"
  (define b (doc "one two three"))
  (define steps (record (lambda ()
                          (dispatch-key-event b (key-press 'right #:word-mod #t))
                          (dispatch-key-event b (key-press 'right #:word-mod #t #:shift #t)))))
  (check-equal? steps '(word-right (extend-selection word-right)))
  (check-equal? (map step-command steps) '(word-right word-right))
  (check-equal? (map step-extends-selection? steps) '(#f #t)))

(test-case "a command's own inner commands are not recorded again"
  (set! ran '())
  (check-equal? (record (lambda () (run-command 'rec-test-outer) (run-command 'rec-test-inner)))
                '(rec-test-outer rec-test-inner)
                "the inner command is recorded only when run by itself")
  (check-equal? ran '(rec-test-inner rec-test-inner)))

(test-case "the command picked through an excluded launcher is recorded, not the launcher"
  (exclude-from-recording! 'rec-test-launcher)
  (check-true (excluded-from-recording? 'rec-test-launcher))
  (check-equal? (record (lambda () (run-command 'rec-test-launcher))) '(rec-test-x)))

(test-case "a command that fails is not recorded"
  (define steps (record (lambda ()
                          (parameterize ([error-reporter void]) (run-command/safe 'rec-test-fails))
                          (run-command 'rec-test-x))))
  (check-equal? steps '(rec-test-x)))

(test-case "Undo and Redo are not recorded"
  (define b (doc "abc"))
  (check-equal? (record (lambda ()
                          (run-command 'select-all)
                          (run-command 'undo)
                          (run-command 'redo)
                          (run-command 'rec-test-x)))
                '(select-all rec-test-x)))

(test-case "Start while recording keeps going; Stop while idle does nothing"
  (run-command 'start-recording)
  (run-command 'rec-test-x)
  (run-command 'start-recording)
  (check-equal? (recording-steps) '(rec-test-x) "a second Start does not throw the steps away")
  (run-command 'stop-recording)
  (define kept (last-recording))
  (run-command 'stop-recording)
  (check-equal? (last-recording) kept)
  (check-false (recording?)))

(test-case "an empty recording keeps the previous one"
  (define kept (record (lambda () (run-command 'rec-test-y))))
  (check-equal? (record void) kept))

(test-case "a command that stops the recording itself does not land in the finished recording"
  (define steps (record (lambda () (run-command 'rec-test-x) (run-command 'rec-test-stops))))
  (check-false (recording?))
  (check-equal? steps '(rec-test-x)))

(test-case "recording-changed fires on start, each step and stop"
  (define n 0)
  (define (spy) (set! n (add1 n)))
  (add-hook! 'recording-changed spy)
  (record (lambda () (run-command 'rec-test-x) (run-command 'rec-test-y)))
  (remove-hook! 'recording-changed spy)
  (check-equal? n 4))

(test-case "Start and Stop are Tools menu commands, each enabled only when it applies"
  (define start (find-command 'start-recording))
  (define stop (find-command 'stop-recording))
  (check-equal? (command-menu start) "Tools")
  (check-equal? (command-menu stop) "Tools")
  (check-true (command-enabled? start))
  (check-false (command-enabled? stop))
  (run-command 'start-recording)
  (check-false (command-enabled? start))
  (check-true (command-enabled? stop))
  (run-command 'stop-recording))

;; ---- the real Command Palette ----------------------------------------------------------

(define (dialog) (for/first ([w (get-top-level-windows)] #:when (is-a? w dialog%)) w))

;; Polls until the modal dialog opened by `thunk` is up, runs `script` once; a watchdog
;; closes it so a regression fails instead of hanging (as tests/palette-test.rkt does).
(define (run-dialog thunk script)
  (define done? #f)
  (define step
    (new timer% [interval 30]
         [notify-callback (lambda ()
                            (define d (dialog))
                            (when (and d (not done?) (send d is-shown?))
                              (set! done? #t)
                              (send step stop)
                              (script d)))]))
  (define watchdog (new timer% [notify-callback (lambda () (define d (dialog)) (when d (send d show #f)))]))
  (send watchdog start 8000 #t)
  (begin0 (thunk) (send step stop) (send watchdog stop)))

(test-case "a command run from the palette is recorded by itself, without the palette"
  (define b (doc "hello world"))
  (define steps
    (record (lambda ()
              (run-dialog
               (lambda () (run-command 'command-palette))
               (lambda (d)
                 (define tf (car (send d get-children)))
                 (send tf set-value "select all")
                 (send tf command (new control-event% [event-type 'text-field]))
                 (send d on-subwindow-char tf (new key-event% [key-code #\return])))))))
  (check-equal? steps '(select-all))
  (check-equal? (send b get-end-position) (send b last-position) "the palette did run it"))
