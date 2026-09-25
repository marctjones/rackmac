#lang racket/base
;; The init file must register into the RUNNING editor's registry. If it were loaded
;; into a namespace that re-instantiated rackmac/api, its commands would land in a
;; second, invisible registry.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/file racket/path racket/runtime-path
         "../rackmac/command.rkt" "../rackmac/eval.rkt" "../rackmac/commands.rkt"
         "../rackmac/editor.rkt" "../rackmac/keymap.rkt" "../rackmac/hook.rkt")

(define-runtime-path root "..")
(current-library-collection-paths (cons root (current-library-collection-paths)))

(define dir (make-temporary-file "rackmac-home~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))

(define (write-init! . lines)
  (display-to-file (apply string-append lines) (build-path dir "init.rkt") #:exists 'truncate))

(test-case "init.rkt commands, keys and hooks land in the live editor"
  (write-init! "#lang racket/base\n(require rackmac/api)\n"
               "(define-command (it-init-cmd) #:title \"From Init\" #:keys (\"Mod-Shift-9\") (message \"ran\"))\n"
               "(bind-key! \"Ctrl-F8\" 'it-init-cmd)\n"
               "(bind-key! \"Ctrl-F7\" 'it-init-cmd #:mode 'racket-mode)\n")
  (load-init!)
  (check-not-false (find-command 'it-init-cmd))
  (check-equal? (command-title (find-command 'it-init-cmd)) "From Init")
  (check-not-false (command-shortcut 'it-init-cmd))
  (define echoed #f)
  (add-hook! 'echo (lambda (s) (set! echoed s)))
  (run-command 'it-init-cmd)
  (check-equal? echoed "ran"))

(test-case "a broken init file is reported, not fatal"
  (write-init! "#lang racket/base\n(this-is-not-bound)\n")
  (define echoed #f)
  (add-hook! 'echo (lambda (s) (set! echoed s)))
  (load-init!)
  (check-regexp-match #rx"init.rkt failed" echoed))

(test-case "eval-string shares state and the API"
  (check-equal? (eval-string "(+ 1 2)") "3")
  (eval-string "(define it-x 21)")
  (check-equal? (eval-string "(* it-x 2)") "42")
  (check-equal? (eval-string "(display \"hi\") 5") "hi\n5")
  (check-true (string? (eval-string "(send (current-buffer) get-name)")))
  (check-exn exn:fail? (lambda () (eval-string "(car 1)"))))

(test-case "no init file: quiet at startup, noted in the Activity log"
  (delete-file (build-path dir "init.rkt"))
  (define echoed #f)
  (add-hook! 'echo (lambda (s) (set! echoed s)))
  (load-init!)
  (check-false echoed "nothing in the status bar")
  (check-regexp-match #rx"No customization files yet. \"Customize with Code\"" (send (messages-buffer) get-text)))
