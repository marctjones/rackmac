#lang racket/base
;; The startup smoke check (#286, rackmac/smoke.rkt) that RACKMAC_SMOKE=1 runs in place of
;; showing the window, here in-process against the real (hidden) window: every check passes
;; for a good start, and each failure is reported rather than raised. The same checks run
;; against the built Rackmac.app in tools/build-mac-app.rkt --smoke and in CI.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/file racket/string racket/list racket/runtime-path
         "../rackmac/smoke.rkt" "../rackmac/eval.rkt" "../rackmac/editor.rkt"
         "../rackmac/frame.rkt" "../rackmac/pandoc.rkt" "../rackmac/settings.rkt"
         "../rackmac/commands.rkt" "../rackmac/library/start-screen.rkt")

(define-runtime-path root "..")
(current-library-collection-paths (cons root (current-library-collection-paths)))

(define dir (make-temporary-file "rackmac-smoke~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))
(setting-set! 'library-folders '())

;; A fake pandoc 3, so the test does not depend on the machine's.
(define fake-pandoc (build-path dir "pandoc"))
(with-output-to-file fake-pandoc (lambda () (printf "#!/bin/sh\necho 'pandoc 3.1.2'\n")))
(file-or-directory-permissions fake-pandoc #o755)

(define note (build-path dir "Note.md"))
(display-to-file "# Note\n" note)

(define f (make-main-frame))     ; hidden: show is never called
(set-current-buffer! (open-file! note))

(define (smoke)
  (define out (open-output-string))
  (define ok? (parameterize ([pandoc-candidates (list (lambda () fake-pandoc))])
                (reset-pandoc!)
                (run-smoke! f (list (path->string note)) out)))
  (values ok? (string-split (get-output-string out) "\n")))

(define (line-for lines name)
  (findf (lambda (l) (string-prefix? l (format "smoke: ~a " name))) lines))

(test-case "a good start passes every check and ends with ok"
  (display-to-file (string-append "#lang rackmac\n(require racket/date)\n"
                                  "(define-command (smoke-test-cmd) (message \"hi\"))\n")
                   (build-path dir "init.rkt") #:exists 'truncate)
  (make-directory* (build-path dir "ext"))
  (display-to-file "#lang racket/base\n(require rackmac/api)\n(add-hook! 'echo void)\n"
                   (build-path dir "ext" "extra.rkt") #:exists 'truncate)
  (load-init!)
  (define-values (ok? lines) (smoke))
  (check-true ok? (string-join lines "\n"))
  (check-equal? (last lines) "ok")
  (for ([name '("window" "files" "init" "extensions" "pandoc" "markdown" "getting-started")])
    (check-regexp-match #rx" ok " (or (line-for lines name) "") name))
  (check-regexp-match #rx"1 command registered" (line-for lines "init"))
  (check-regexp-match #rx"version 3[.]1[.]2" (line-for lines "pandoc"))
  (check-false (send f is-shown?) "the smoke check never shows the window")
  (check-true (file-exists? (build-path dir "Getting started.md"))))

(test-case "a broken init file, a missing pandoc or an unopened file fail with a reason"
  (display-to-file "#lang rackmac\n(this is not defined)\n" (build-path dir "init.rkt") #:exists 'truncate)
  (load-init!)
  (define out (open-output-string))
  (define ok? (parameterize ([pandoc-candidates '()])
                (reset-pandoc!)
                (run-smoke! f (list (path->string (build-path dir "never-opened.md"))) out)))
  (define lines (string-split (get-output-string out) "\n"))
  (check-false ok?)
  (check-equal? (last lines) "FAIL")
  (check-regexp-match #rx"^smoke: init FAIL .*init.rkt did not load: init.rkt failed" (line-for lines "init"))
  (check-regexp-match #rx"^smoke: pandoc FAIL not found" (line-for lines "pandoc"))
  (check-regexp-match #rx"^smoke: files FAIL not open" (line-for lines "files"))
  (check-regexp-match #rx"^smoke: markdown ok" (line-for lines "markdown")))

(test-case "RACKMAC_SMOKE turns the mode on"
  (define old (getenv "RACKMAC_SMOKE"))
  (putenv "RACKMAC_SMOKE" "1")
  (check-true (smoke-requested?))
  (if old (putenv "RACKMAC_SMOKE" old) (environment-variables-set! (current-environment-variables) #"RACKMAC_SMOKE" #f))
  (unless old (check-false (smoke-requested?))))

(reset-pandoc!)
