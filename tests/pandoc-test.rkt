#lang racket/base
;; Finding pandoc (#278): absolute install locations before PATH, version 3 or later, cached,
;; and never an error when pandoc is missing, too old, or hangs. Fake pandocs are shell scripts.
(require rackunit racket/file racket/list racket/system "../rackmac/pandoc.rkt")

(define dir (make-temporary-file "rackmac-pandoc~a" 'directory))
(define (fake! name body)
  (define p (build-path dir name))
  (with-output-to-file p #:exists 'truncate (lambda () (printf "#!/bin/sh\n~a\n" body)))
  (file-or-directory-permissions p #o755)
  p)
(define new (fake! "pandoc-new" "echo 'pandoc 3.1.2'; echo 'Features: +server'"))
(define old (fake! "pandoc-old" "echo 'pandoc 2.19.2'"))
(define junk (fake! "pandoc-junk" "echo 'not pandoc at all'"))
(define hung (fake! "pandoc-hung" "sleep 30"))
(define (candidates . ps) (for/list ([p ps]) (lambda () p)))
(define-syntax-rule (with-candidates (p ...) body ...)
  (parameterize ([pandoc-candidates (candidates p ...)]) (reset-pandoc!) body ...))

(test-case "reads the version from --version"
  (check-equal? (pandoc-version-of new) '(3 1 2))
  (check-equal? (pandoc-version-of old) '(2 19 2))
  (check-false (pandoc-version-of junk))
  (check-false (pandoc-version-of (build-path dir "no-such-file"))))

(test-case "the first good candidate wins; order is respected"
  (with-candidates (new old)
    (check-true (pandoc-available?))
    (check-equal? (find-pandoc) new)
    (check-equal? (pandoc-status) (list 'ok new '(3 1 2)))))

(test-case "a too-old pandoc is reported as such, and a newer one later in the list still wins"
  (with-candidates (old)
    (check-false (pandoc-available?))
    (check-false (find-pandoc))
    (check-equal? (car (pandoc-status)) 'too-old))
  (with-candidates (old new)
    (check-equal? (find-pandoc) new)))

(test-case "missing, unreadable or hung pandoc is a status, never an error"
  (with-candidates ((build-path dir "absent") junk)
    (check-equal? (pandoc-status) '(missing)))
  (parameterize ([pandoc-candidates (list (lambda () (error "boom")))])
    (reset-pandoc!)
    (check-equal? (pandoc-status) '(missing)))
  (define t0 (current-inexact-milliseconds))
  (with-candidates (hung new)
    (check-equal? (find-pandoc) new "a hung binary is skipped"))
  (check-true (< (- (current-inexact-milliseconds) t0) 5000) "within the 2 s version timeout"))

(test-case "the answer is cached until reset (installing pandoc later is picked up after reset)"
  (define calls 0)
  (parameterize ([pandoc-candidates (list (lambda () (set! calls (add1 calls)) new))])
    (reset-pandoc!)
    (pandoc-status) (pandoc-status)
    (check-equal? calls 1)
    (reset-pandoc!) (pandoc-status)
    (check-equal? calls 2)))

(test-case "absolute locations work with no PATH at all (a double-clicked app has none)"
  (define saved (getenv "PATH"))
  (putenv "PATH" "")
  (with-candidates (new) (check-equal? (find-pandoc) new))
  (putenv "PATH" saved))

(test-case "the built-in candidates try Homebrew's absolute paths before PATH"
  (define ps (for/list ([c (pandoc-candidates)]) (c)))
  (check-equal? (map path->string (take ps 2)) '("/opt/homebrew/bin/pandoc" "/usr/local/bin/pandoc")))

(test-case "the install hint names pandoc 3 and how to get it"
  (check-true (regexp-match? #rx"pandoc 3" pandoc-install-hint))
  (check-true (regexp-match? #rx"brew install pandoc" pandoc-install-hint)))
