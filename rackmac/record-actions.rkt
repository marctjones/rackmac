#lang racket/base
;; Record Actions (#121, E7.M2): Tools > Start Recording and Stop Recording capture the
;; commands a person runs, from the keyboard, a menu, the toolbar or the palette, as a list
;; of command names. Recording is by command, not by key, so a recording still does the same
;; thing after its keys are rebound. Playing (#122), saving as a named command (#123) and the
;; Record/Stop/Play buttons (#124) build on what this module exports.
;;
;; A recording is a list of steps, oldest first. A step is `read`/`write`-able, so #123 can
;; store it in a settings file:
;;   'name                       run the command `name`
;;   (list 'extend-selection 'name)   run it with Shift held: a motion that extends the selection
;; To replay one step (#122):
;;   (parameterize ([extending-selection? (step-extends-selection? s)]) (run-command (step-command s)))
;;
;; What is not recorded, and why:
;; - Start and Stop Recording themselves.
;; - The Command Palette and Keyboard Shortcuts dialogs: the command picked in them is
;;   recorded instead, so a replay runs it without opening the dialog.
;; - Undo and Redo. Typed text is not a command and is not recorded, so on replay Undo would
;;   undo whatever edit happens to be last, not the one it undid while recording. The cost:
;;   a command undone while recording stays in the recording.
;; - Commands that another command runs (Markdown Enter runs Newline): replaying the outer
;;   command runs them again.
;; - Commands that fail: replaying them would fail too.
;; Other extensions (the Play command of #122) exclude their own commands with
;; `exclude-from-recording!`.
;;
;; Limitations: typing is not recorded (a recording is commands only). A command that asks
;; for something (Go to Line, Set Language, Find) is recorded by name and asks again on
;; replay. Commands an init file or extension runs while recording are recorded like any other.
(require "command.rkt" "hook.rkt" "owner.rkt" "editor.rkt")
(provide recording? recording-steps last-recording
         step-command step-extends-selection?
         exclude-from-recording! excluded-from-recording?)

(define excluded
  (make-hasheq (map (lambda (n) (cons n #t))
                    '(start-recording stop-recording command-palette show-cheat-sheet undo redo))))

(define (exclude-from-recording! name)
  (define was (hash-ref excluded name #f))
  (hash-set! excluded name #t)
  (register-undo! 'record-exclusion (lambda () (unless was (hash-remove! excluded name)))))

(define (excluded-from-recording? name) (hash-ref excluded name #f))

(define (step-command s) (if (symbol? s) s (cadr s)))
(define (step-extends-selection? s) (and (pair? s) (eq? (car s) 'extend-selection)))

;; The recording in progress: its steps, newest first. A fresh box per recording, so a step
;; that commits after Stop (a command that stopped the recording itself) cannot land in it.
(define session #f)
(define last-steps '())

(define (recording?) (and session #t))
(define (recording-steps) (if session (reverse (unbox session)) '()))
(define (last-recording) last-steps)

(define ((recorder this) name)
  (and (not (excluded-from-recording? name))
       (let ([step (if (extending-selection?) (list 'extend-selection name) name)])
         (lambda ()
           (when (eq? session this)
             (set-box! this (cons step (unbox this)))
             (run-hook 'recording-changed))))))

(define-command (start-recording)
  #:icon "history"   ; the drawn set has no record/stop glyphs yet (#124 adds buttons)
  #:aliases ("record actions" "record macro" "start macro")
  #:help "Remember the commands you run from now on, to repeat them later."
  #:title "Start Recording" #:menu "Tools" #:menu-order 40 #:category "Tools"
  #:when (lambda () (not (recording?)))
  (cond
    [(recording?) (message "Already recording")]
    [else
     (define this (box '()))
     (set! session this)
     (set-command-recorder! (recorder this))
     (message "Recording: run the commands to repeat, then choose Stop Recording")
     (run-hook 'recording-changed)]))

(define-command (stop-recording)
  #:icon "close"
  #:aliases ("stop macro" "end recording" "finish recording")
  #:help "Stop remembering commands and keep what was recorded."
  #:title "Stop Recording" #:menu "Tools" #:menu-order 41 #:category "Tools"
  #:when recording?
  (cond
    [(not (recording?)) (message "Not recording")]
    [else
     (define steps (recording-steps))
     (set! session #f)
     (set-command-recorder! #f)
     ;; An empty recording (Stop right after Start) keeps the previous one.
     (cond [(null? steps) (message "Nothing was recorded")]
           [else (set! last-steps steps)
                 (message "Recorded ~a command~a" (length steps) (if (= (length steps) 1) "" "s"))])
     (run-hook 'recording-changed)]))
