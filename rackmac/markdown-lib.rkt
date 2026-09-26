#lang racket/base
;; The rackmac-markdown library, for the app's own modules (#285). In a checkout (and a --link
;; install) it is the sibling directory ../rackmac-markdown, exactly the file tests require by
;; relative path, so app and tests share one instance. When this directory is installed on its
;; own (copy install, `raco exe`), there is no such sibling, and it is the installed
;; `rackmac-markdown` collection instead. Decided at compile time.
(require (for-syntax racket/base))

(define-syntax (require+provide-markdown stx)
  ;; This file's directory: the load-relative directory while it is being compiled, else (e.g.
  ;; expanded from a string) the syntax source's directory.
  (define src (syntax-source stx))
  (define dir (or (current-load-relative-directory)
                  (and (path? src) (let-values ([(d n dir?) (split-path src)]) d))))
  (define sibling (and (path? dir) (build-path dir 'up "rackmac-markdown" "main.rkt")))
  (define mp (if (and sibling (file-exists? sibling)) "../rackmac-markdown/main.rkt" 'rackmac-markdown))
  (datum->syntax stx `(begin (require ,mp) (provide (all-from-out ,mp)))))

(require+provide-markdown)
