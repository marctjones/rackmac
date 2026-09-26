#lang racket/base
;; Application startup.
(require "no-front.rkt"                  ; first: RACKMAC_NO_FRONT must act before racket/gui loads
         racket/class racket/gui/base
         "commands.rkt" "toolbar-defaults.rkt" "status-defaults.rkt" "context-defaults.rkt"
         "command.rkt" "editor.rkt" "frame.rkt" "eval.rkt" "theme.rkt" "hook.rkt"
         "library/recents.rkt"
         "library/open-recent.rkt"
         "library/folders.rkt"
         "library/new-note.rkt"
         "library/start-screen.rkt"
         "appearance.rkt"
         "office.rkt"
         "recovery.rkt"
         "ui/settings-dialog.rkt"
         "tools-menu.rkt"
         "insert-date.rkt"
         "md-view.rkt"
         "md-view-commands.rkt"
         "md-links-open.rkt"
         "pdf-export.rkt"                ; #279: File > Export as PDF…
         ;; feature modules: one per line, so parallel work doesn't collide here
         "spell.rkt"
         "smoke.rkt"                     ; #286: RACKMAC_SMOKE=1 checks startup and exits, window unshown
         )
(provide main)

(define (main args)
  (enable-recent-tracking!)          ; #274: recents.rktd, off until a real run asks for it
  (enable-markdown-view-memory!)     ; #269: each note's view, remembered in recents.rktd
  (enable-autosave-recovery!)        ; #75: the autosave timer, off until a real run asks for it
  (enable-spell-checking!)           ; #351: the system spell checker; tests use a fake one
  ;; Cmd+Q on macOS and Finder "Open With" arrive through these handlers.
  (application-quit-handler (lambda () (run-command/safe 'quit)))
  (application-file-handler (lambda (p) (set-current-buffer! (open-file! p))))
  (for ([a (in-list args)]) (set-current-buffer! (open-file! a)))
  (define f (make-main-frame))
  (recover-on-launch!)               ; #77: offer back anything a previous crash left behind
  (maybe-skip-start-screen!)         ; #277: honors "skip the start screen" if nothing opened above
  (load-init!)
  (when (smoke-requested?) (exit (if (run-smoke! f args) 0 1)))
  (send f show #t)
  (focus-editor!)                    ; focus set while the window was hidden does not stick
  (refresh-appearance!)              ; #254: the system appearance is only reliable once the app is up
  (yield 'wait))

;; Installed launch (#285): `racket -l- rackmac/app [file ...]`. From a checkout, `racket main.rkt`.
(module+ main
  (main (vector->list (current-command-line-arguments))))
