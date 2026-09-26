#lang racket/base
;; Headless subprocess core for #78 (the crash-and-kill test): no window, not even
;; app.rkt's make-main-frame -- just the editor model plus recovery.rkt's hooks. This is the
;; "headless core entry point" DEVELOPMENT.md asks for, so an automated agent never has to
;; launch the real GUI (even backgrounded) to prove a crash recovers unsaved text. Driven only
;; from tests/crash-test.rkt, as a subprocess with RACKMAC_HOME already set in its environment:
;;
;;   racket rackmac/recovery-worker.rkt edit <path> <text> <interval-seconds>
;;     Opens <path> (creating it if it doesn't exist yet), inserts <text>, waits for the
;;     autosave timer to write a snapshot, prints "autosaved" and blocks -- so the test can
;;     send SIGKILL to this very process mid-block, exactly like a real crash.
;;   racket rackmac/recovery-worker.rkt recover
;;     Restores every snapshot found under RACKMAC_HOME's recovery/ directory (as the real
;;     launch dialog would with every document checked) and prints each restored document's
;;     text, framed by markers that survive an embedded newline.
(require "no-front.rkt")
;; `void`d because a script run directly by `racket file.rkt` (unlike a required module)
;; prints every non-void top-level result, and register-process-global returns one.
(void (enable-no-front!))   ; belt and braces: this process must never take keyboard focus either

(module+ main
  (require racket/class racket/gui/base "editor.rkt" "recovery.rkt" "settings.rkt")

  (define (recover-all snaps) (for/list ([s snaps]) (cons (snapshot-id s) 'restore)))

  (define args (current-command-line-arguments))
  (case (vector-ref args 0)
    [("edit")
     (define path (vector-ref args 1))
     (define text (vector-ref args 2))
     (define interval (string->number (vector-ref args 3)))
     (enable-autosave-recovery!)
     (setting-set! 'autosave-interval interval)
     (define b (open-file! path))
     (send b insert text)
     (let wait-for-autosave ()
       (unless (buffer-recovery-id b) (sleep/yield 0.05) (wait-for-autosave)))
     (printf "autosaved\n")
     (flush-output)
     (let block-until-killed () (sleep/yield 1) (block-until-killed))]
    [("recover")
     (parameterize ([recovery-decide! recover-all]) (recover-on-launch!))
     (for ([b (in-list (all-buffers))] #:when (send b is-modified?))
       (printf "---RECOVERED---\n~a\n---END---\n" (send b get-text)))
     (flush-output)]
    [else (eprintf "usage: recovery-worker.rkt (edit <path> <text> <interval>) | recover\n") (exit 1)]))
