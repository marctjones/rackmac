#lang racket/base
;; #78: crash and kill test. Rackmac's editor core runs in a real subprocess -- never the GUI,
;; never main.rkt, nothing shown or focused -- driven by rackmac/recovery-worker.rkt (the
;; "headless core entry point"). It edits a document, waits for the autosave timer to write a
;; snapshot, and is then killed with a real SIGKILL (subprocess-kill's force? argument); a
;; second subprocess relaunches the same core and must recover the unsaved text from disk.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/file racket/port racket/runtime-path racket/string)

(define-runtime-path worker-path "../rackmac/recovery-worker.rkt")
;; Not (find-system-path 'run-file): under `raco test` that names the `raco` launcher, not a
;; plain `racket` that can run a single .rkt file as a script.
(define racket-exe (or (find-executable-path (string->path "racket"))
                       (error 'crash-test "could not find the racket executable on PATH")))

(define dir (make-temporary-file "rackmac-crash~a" 'directory))

(define (with-home thunk)
  (define envs (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! envs #"RACKMAC_HOME" (path->bytes dir))
  (parameterize ([current-environment-variables envs]) (thunk)))

;; Runs the worker in "edit" mode, waits for it to print "autosaved" (proof the debounced
;; autosave timer actually fired), then kills it with a real SIGKILL -- no cleanup, no
;; graceful shutdown, exactly what a crash looks like.
(define (edit-then-kill! path text interval)
  (with-home
   (lambda ()
     (define-values (sp out in err)
       (subprocess #f #f #f racket-exe worker-path "edit" path text (number->string interval)))
     (close-output-port in)
     (define line (read-line out))
     (check-equal? line "autosaved" "the worker's autosave timer fired before it was killed")
     (subprocess-kill sp #t)               ; force? = #t: SIGKILL on Unix/macOS
     (subprocess-wait sp)))
  (void))

;; Relaunches the worker in "recover" mode and returns the list of recovered documents' text.
(define (recover!)
  (with-home
   (lambda ()
     (define-values (sp out in err) (subprocess #f #f #f racket-exe worker-path "recover"))
     (close-output-port in)
     (define output (port->string out))
     (subprocess-wait sp)
     (define stderr-text (port->string err))
     (check-equal? (subprocess-status sp) 0 (format "recovery subprocess failed: ~a" stderr-text))
     (map cadr (regexp-match* #px"(?s:---RECOVERED---\n(.*?)\n---END---)" output #:match-select values)))))

(test-case "kill -9 while autosaved, then relaunch: the text comes back"
  (define path (path->string (build-path dir "crashed.md")))
  (edit-then-kill! path "text that must survive a crash" 0.2)
  (define recovered (recover!))
  (check-equal? (length recovered) 1 "exactly one document had unsaved work to recover")
  (check-true (string-contains? (car recovered) "text that must survive a crash")))

(test-case "recovering twice in a row is safe (idempotent once discarded/restored)"
  ;; The first recover! in the previous test-case restored and left the snapshot on disk
  ;; (restore keeps the file, matching #76's "Don't Save keeps it" rule) -- so recovering
  ;; again must still find it and must not error.
  (define recovered (recover!))
  (check-equal? (length recovered) 1 "the still-unsaved restored document is offered again"))
