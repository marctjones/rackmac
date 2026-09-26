#lang racket/base
;; Application startup.
(require racket/class racket/gui/base
         "commands.rkt" "toolbar-defaults.rkt" "status-defaults.rkt" "context-defaults.rkt"
         "command.rkt" "editor.rkt" "frame.rkt" "eval.rkt" "theme.rkt" "hook.rkt"
         "library/recents.rkt" "library/open-recent.rkt" "recovery.rkt")
(provide main)

;; The system appearance is only reliable once the app is up.
(define (refresh-system-theme!)
  (unless (getenv "RACKMAC_THEME")
    (define detected (detect-theme))
    (unless (eq? detected (current-theme-name))
      (set-theme! detected)
      (for ([b (in-list (all-buffers))]) (send b rehighlight!))
      (run-hook 'theme-changed))))

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
  (refresh-system-theme!)
  (yield 'wait))
