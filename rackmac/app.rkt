#lang racket/base
;; Application startup.
(require racket/class racket/gui/base
         "commands.rkt" "toolbar-defaults.rkt" "status-defaults.rkt" "context-defaults.rkt"
         "command.rkt" "editor.rkt" "frame.rkt" "eval.rkt" "theme.rkt" "hook.rkt"
         "library/recents.rkt" "library/open-recent.rkt" "appearance.rkt" "office.rkt" "recovery.rkt")
(provide main)

(define (main args)
  (enable-recent-tracking!)          ; #274: recents.rktd, off until a real run asks for it
  (enable-autosave-recovery!)        ; #75: the autosave timer, off until a real run asks for it
  ;; Cmd+Q on macOS and Finder "Open With" arrive through these handlers.
  (application-quit-handler (lambda () (run-command/safe 'quit)))
  (application-file-handler (lambda (p) (set-current-buffer! (open-file! p))))
  (for ([a (in-list args)]) (set-current-buffer! (open-file! a)))
  (define f (make-main-frame))
  (recover-on-launch!)               ; #77: offer back anything a previous crash left behind
  (load-init!)
  (send f show #t)
  (focus-editor!)                    ; focus set while the window was hidden does not stick
  (refresh-appearance!)              ; #254: the system appearance is only reliable once the app is up
  (yield 'wait))
