#lang racket/base
;; The startup smoke test (#286). With RACKMAC_SMOKE=1 the app starts exactly as usual -- file
;; arguments opened, the main window built, init.rkt and ext/*.rkt loaded -- but instead of
;; showing the window it checks what a double-clicked Rackmac.app needs at runtime, prints one
;; line per check and exits 0 (all passed) or 1. The window is never shown. This is how the
;; built app bundle is verified headless (tools/build-mac-app.rkt --smoke, CI), including on a
;; PATH without Racket or pandoc.
;;
;; Run it with a throwaway RACKMAC_HOME: the Getting Started check writes that note into the
;; Library (the first Library folder, else RACKMAC_HOME) exactly as the Get Started button does.
(require racket/class racket/list racket/string
         "command.rkt" "editor.rkt" "eval.rkt" "owner.rkt" "pandoc.rkt" "platform.rkt"
         "markdown-lib.rkt")
(provide smoke-requested? smoke-checks run-smoke!)

(define (smoke-requested?) (and (getenv "RACKMAC_SMOKE") #t))

;; Each check is (list name ok? detail).

;; init.rkt was loaded, and the commands it defined landed in THIS app's registry: they are
;; counted through the running core's current-extension, so a second copy of rackmac/api (the
;; failure an embedded app risks) would count none.
(define (check-init)
  (define init (init-file-path))
  (define ext (findf (lambda (e) (equal? (extension-path e) init)) (loaded-extensions)))
  (define n (if ext (hash-ref (extension-counts ext) 'command 0) 0))
  (cond [(not (file-exists? init)) (list "init" #f (format "no init file at ~a" init))]
        [(not ext) (list "init" #f (format "~a did not load: ~a" init (last-activity)))]
        [(zero? n) (list "init" #f "init.rkt loaded but registered no command in the running app")]
        [else (list "init" #t (format "~a loaded, ~a command~a registered" init n (if (= n 1) "" "s")))]))

;; Every ext/*.rkt loaded too (these may register only hooks or keys, so no command count).
(define (check-extensions)
  (define dir (build-path (config-dir) "ext"))
  (define files (if (directory-exists? dir)
                    (filter (lambda (p) (regexp-match? #rx"[.]rkt$" (path->string p)))
                            (directory-list dir #:build? #t))
                    '()))
  (define loaded (map extension-path (loaded-extensions)))
  (define failed (filter (lambda (f) (not (member f loaded))) files))
  (cond [(pair? failed) (list "extensions" #f (format "~a did not load: ~a" (car failed) (last-activity)))]
        [else (list "extensions" #t (format "~a ext/ file~a loaded" (length files)
                                            (if (= 1 (length files)) "" "s")))]))

;; Why the file failed: load-extension! logs "<file> failed: <error>", possibly over many lines.
(define (last-activity)
  (define text (send (messages-buffer) get-text))
  (define starts (regexp-match-positions* #rx"(?m:^[^\n]* failed: )" text))
  (string-join (string-split (if (null? starts) text (substring text (car (last starts)))) "\n")
               " | "))

;; pandoc by absolute path (a double-clicked app has no shell PATH).
(define (check-pandoc)
  (define s (pandoc-status))
  (case (car s)
    [(ok) (list "pandoc" (absolute-path? (cadr s))
                (format "~a (version ~a)" (cadr s) (string-join (map number->string (caddr s)) ".")))]
    [(too-old) (list "pandoc" #f (format "~a is too old" (cadr s)))]
    [else (list "pandoc" #f "not found")]))

;; The Markdown library is present and parses.
(define (check-markdown)
  (define ok? (with-handlers ([exn:fail? (lambda (e) #f)])
                (define d (parse-document "# Heading\n\nSome *text*.\n"))
                (and (= 2 (length (document-blocks d))) (pair? (style-runs d)))))
  (list "markdown" (and ok? #t) (if ok? "rackmac-markdown parsed a note" "rackmac-markdown failed to parse")))

;; The bundled Getting Started note opens (its text lives in the app, not in a file beside it).
(define (check-getting-started)
  (with-handlers ([exn:fail? (lambda (e) (list "getting-started" #f (exn-message e)))])
    (run-command 'open-getting-started)
    (define b (current-buffer))
    (define ok? (string-prefix? (send b get-text) "# Getting Started with Rackmac"))
    (list "getting-started" ok? (format "~a" (send b get-path)))))

;; Every file named on the command line is open.
(define (check-files files)
  (define missing (for/list ([f (in-list files)]
                             #:unless (find-buffer-by-path (simplify-path (path->complete-path f))))
                    f))
  (list "files" (null? missing)
        (if (null? missing) (format "~a opened" (length files)) (format "not open: ~a" missing))))

;; The window was built and is still hidden.
(define (check-window frame)
  (define hidden? (not (send frame is-shown?)))
  (list "window" hidden? (if hidden? "built, not shown" "shown")))

(define (smoke-checks frame files)
  (list (check-window frame) (check-files files) (check-init) (check-extensions)
        (check-pandoc) (check-markdown)
        (check-getting-started)))

;; Prints the report to `out` and returns #t when every check passed.
(define (run-smoke! frame files [out (current-output-port)])
  (define results (smoke-checks frame files))
  (for ([r (in-list results)])
    (fprintf out "smoke: ~a ~a ~a\n" (first r) (if (second r) "ok" "FAIL") (third r)))
  (define ok? (andmap second results))
  (fprintf out "~a\n" (if ok? "ok" "FAIL"))
  (flush-output out)
  ok?)
