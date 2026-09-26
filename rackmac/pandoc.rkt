#lang racket/base
;; Finding pandoc (#278), which converts notes to and from Word (#280, #281). A double-clicked
;; Rackmac.app does not inherit the shell's PATH, so the usual install locations are tried by
;; absolute path first, then PATH. Pandoc 3.0 or later is required. The answer is cached until
;; reset-pandoc! (after the user installs pandoc). Nothing here raises: a missing or broken
;; pandoc is a status, and the Export/Import commands grey out with a hint.
(require racket/list racket/string racket/port racket/system)
(provide find-pandoc pandoc-status pandoc-available? pandoc-version-of reset-pandoc!
         pandoc-candidates pandoc-minimum pandoc-install-hint)

(define pandoc-minimum '(3 0))

(define pandoc-install-hint
  "Word export and import need pandoc 3 or later. Install it from pandoc.org, or with Homebrew: brew install pandoc.")

;; Where to look, in order. A parameter of thunks so tests can supply their own.
(define pandoc-candidates
  (make-parameter
   (list (lambda () (string->path "/opt/homebrew/bin/pandoc"))     ; Homebrew on Apple silicon
         (lambda () (string->path "/usr/local/bin/pandoc"))        ; Homebrew on Intel, the installer
         (lambda () (find-executable-path "pandoc")))))            ; PATH, when there is one

;; "pandoc 3.1.2" (first line of --version) -> '(3 1 2); #f when it can't be read. Waits at
;; most two seconds, so a hung binary can't stall the app.
(define (pandoc-version-of path)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (define-values (sp out in err) (subprocess #f #f #f path "--version"))
    (close-output-port in)
    (define result (sync/timeout 2 sp))
    (define text (if result (port->string out) ""))
    (unless result (subprocess-kill sp #t))
    (close-input-port out) (close-input-port err)
    (define m (regexp-match #px"^pandoc(?:\\.exe)? ([0-9]+(?:\\.[0-9]+)*)" text))
    (and m (map string->number (string-split (cadr m) ".")))))

(define (version>=? v min)
  (let loop ([v v] [m min])
    (cond [(null? m) #t]
          [(null? v) (loop '(0) m)]
          [(> (car v) (car m)) #t]
          [(< (car v) (car m)) #f]
          [else (loop (cdr v) (cdr m))])))

;; 'ok with the path and version, 'too-old with the best one found, or 'missing.
(define cache #f)
(define (reset-pandoc!) (set! cache #f))

(define (pandoc-status)
  (unless cache
    (set! cache
          (let loop ([cs (pandoc-candidates)] [old #f])
            (cond
              [(null? cs) (or old (list 'missing))]
              [else
               (define p (with-handlers ([exn:fail? (lambda (e) #f)]) ((car cs))))
               (define v (and p (file-exists? p) (memq 'execute (file-or-directory-permissions p))
                              (pandoc-version-of p)))
               (cond
                 [(not v) (loop (cdr cs) old)]
                 [(version>=? v pandoc-minimum) (list 'ok p v)]
                 [else (loop (cdr cs) (or old (list 'too-old p v)))])]))))
  cache)

(define (pandoc-available?) (eq? (car (pandoc-status)) 'ok))
(define (find-pandoc) (and (pandoc-available?) (cadr (pandoc-status))))
