#lang racket/base
;; Build a Scribble document to HTML (#420, epic E22 Publishing). A `.scrbl` file is a program,
;; so building it runs its code (docs/PUBLISHING-DESIGN.md principle 4). It never runs in
;; Rackmac's own process: `build-scribble` starts rackmac/scribble-worker.rkt in a separate
;; `racket` process, which loads and renders the document inside racket/sandbox (read only its
;; own folder and the Racket collections, write only the output folder, no programs, network,
;; FFI or links; per-step time and memory limits). This side adds the hard stops the sandbox
;; cannot give from the inside:
;;   - a wall-clock deadline for the whole process (the limit plus a start-up allowance), after
;;     which the process group gets SIGKILL;
;;   - a resident-memory ceiling, polled with ps, after which it gets SIGKILL too (C libraries
;;     such as racket/draw allocate outside the sandbox's accounting, and macOS does not
;;     enforce RLIMIT_AS);
;;   - the worker's stdout and stderr are drained into capped buffers, so a chatty document
;;     cannot fill a pipe and look like a hang.
;; HTML only: Scribble's PDF path needs LaTeX, which is not a dependency.
;;
;; Pure: no GUI, never raises for a bad document. The result is a `scribble-built` (the output
;; folder and its entry file) or a `scribble-failed` (a kind, a message, and the source file and
;; line when Racket reports one). The Preview command (rackmac/scribble-preview.rkt) reports it.
(require racket/file racket/list racket/path racket/port racket/string racket/runtime-path
         (only-in compiler/find-exe find-exe))
(provide build-scribble scrbl-path?
         (struct-out scribble-built) (struct-out scribble-failed)
         scribble-racket-candidates find-scribble-racket scribble-worker-path
         preview-time-limit preview-memory-limit preview-startup-allowance preview-rss-ceiling-mb
         preview-output-root
         racket-install-hint)

(struct scribble-built (dir entry) #:transparent)                  ; paths; entry is inside dir
(struct scribble-failed (kind message source line) #:transparent)  ; kind: time memory error setup

(define (scrbl-path? p)
  (and p (regexp-match? #rx"[.][sS][cC][rR][bB][lL]$" (if (path? p) (path->string p) p))))

;; ---- limits -----------------------------------------------------------------------------------

;; Seconds for each step inside the sandbox (loading, then rendering), and megabytes of Racket
;; memory. Generous for a real document; a runaway one is stopped well before it hurts.
(define preview-time-limit (make-parameter 30))
(define preview-memory-limit (make-parameter 512))
;; Starting `racket` and loading the sandbox takes about half a second on a quiet machine; the
;; process as a whole gets both steps plus this before it is killed.
(define preview-startup-allowance (make-parameter 20))
;; Resident memory above which the whole process is killed: the sandbox limit, doubled for the
;; collector's working room, plus Racket's own ~200 MB baseline and slack.
(define (preview-rss-ceiling-mb mb) (+ (* 2 mb) 256))

;; Where fresh output folders are made; #f means the system's temporary folder.
(define preview-output-root (make-parameter #f))

;; ---- finding racket ---------------------------------------------------------------------------

(define racket-install-hint
  "Preview needs Racket installed (racket-lang.org, or Homebrew: brew install --cask racket).")

;; Where to look, in order; thunks, so tests can supply their own. Only an executable named
;; `racket` counts: inside Rackmac.app `find-exe` names the app itself, which must never be
;; started with a document's path as an argument.
(define scribble-racket-candidates
  (make-parameter
   (list (lambda () (find-exe))                                      ; the running installation
         (lambda () (string->path "/opt/homebrew/bin/racket"))
         (lambda () (string->path "/usr/local/bin/racket"))
         (lambda () (find-executable-path "racket")))))

(define (find-scribble-racket)
  (for/or ([c (in-list (scribble-racket-candidates))])
    (define p (with-handlers ([exn:fail? (lambda (e) #f)]) (c)))
    (and p
         (let ([p (if (string? p) (string->path p) p)])
           (and (file-exists? p)
                (member (path->string (file-name-from-path p)) '("racket" "racket.exe" "Racket.exe"))
                (memq 'execute (file-or-directory-permissions p))
                p)))))

(define-runtime-path default-worker "scribble-worker.rkt")
;; A parameter so tests can run a stand-in that ignores every limit, to prove the hard stops.
(define scribble-worker-path (make-parameter default-worker))

;; ---- the process ------------------------------------------------------------------------------

(define output-cap (* 64 1024))

;; Reads `in` to its end on a thread, keeping at most `output-cap` bytes; the rest is discarded
;; (still read, so the writer never blocks on a full pipe).
(define (drain in)
  (define keep (open-output-bytes))
  (define kept 0)
  (define buf (make-bytes 4096))
  (define t
    (thread
     (lambda ()
       (let loop ()
         (define n (read-bytes-avail! buf in))
         (unless (eof-object? n)
           (when (< kept output-cap)
             (define k (min n (- output-cap kept)))
             (write-bytes buf keep 0 k)
             (set! kept (+ kept k)))
           (loop)))
       (close-input-port in))))
  ;; Bounded: once the worker is gone its pipes close, but nothing here may wait forever.
  (lambda () (sync/timeout 5 t) (bytes->string/utf-8 (get-output-bytes keep) #\?)))

;; Resident set size of `pid` in MB, or #f when ps cannot say (the process is gone).
(define (process-rss-mb pid)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (define-values (sp out in err)
      (parameterize ([subprocess-group-enabled #f])
        (subprocess #f #f #f "/bin/ps" "-o" "rss=" "-p" (number->string pid))))
    (close-output-port in)
    (define text (if (sync/timeout 2 sp) (port->string out) (begin (subprocess-kill sp #t) "")))
    (close-input-port out) (close-input-port err)
    (subprocess-wait sp)
    (define kb (string->number (string-trim text)))
    (and kb (/ kb 1024.0))))

(define (kill! sp)
  (subprocess-kill sp #t)          ; SIGKILL; the worker leads its own process group
  (subprocess-wait sp))

;; The worker's result line: `(ok "entry.html")` or `(fail kind "message" source line)`.
(define (parse-result text)
  (define line
    (for/last ([l (in-list (string-split text "\n"))] #:when (string-prefix? l "RACKMAC-RESULT "))
      (substring l (string-length "RACKMAC-RESULT "))))
  (define v (and line
                 (with-handlers ([exn:fail? (lambda (e) #f)])
                   (parameterize ([read-accept-reader #f] [read-accept-lang #f] [read-accept-compiled #f])
                     (read (open-input-string line))))))
  (cond
    [(and (list? v) (= (length v) 2) (eq? (car v) 'ok) (string? (cadr v))) v]
    [(and (list? v) (= (length v) 5) (eq? (car v) 'fail)
          (memq (list-ref v 1) '(time memory error))
          (string? (list-ref v 2))
          (or (not (list-ref v 3)) (string? (list-ref v 3)))
          (or (not (list-ref v 4)) (exact-positive-integer? (list-ref v 4))))
     v]
    [else #f]))

;; The entry file, only if it is a plain file directly inside `dir` (never a link).
(define (checked-entry dir name)
  (define p (build-path dir name))
  (and (equal? (path->string (file-name-from-path p)) name)
       (not (link-exists? p))
       (file-exists? p)
       p))

;; ---- the build --------------------------------------------------------------------------------

;; Builds `src` to HTML in `dest` (a fresh temporary folder when not given; removed again if the
;; build fails). `read-roots` are extra folders the document may read (the Library folder that
;; holds it). Blocks until the build ends; call it off the GUI thread.
(define (build-scribble src
                        #:dest [dest #f]
                        #:read-roots [read-roots '()]
                        #:time-limit [secs (preview-time-limit)]
                        #:memory-limit [mb (preview-memory-limit)])
  (define racket (find-scribble-racket))
  (define src* (and (path-string? src) (simple-form-path src)))
  (cond
    [(not racket) (scribble-failed 'setup racket-install-hint #f #f)]
    [(not (and src* (file-exists? src*)))
     (scribble-failed 'setup (format "~a does not exist" src) #f #f)]
    [else
     (define made-dest? (not dest))
     (define out (simple-form-path
                  (or dest (make-temporary-directory "rackmac-preview-~a" #:base-dir (preview-output-root)))))
     (make-directory* out)
     (define-values (dir name _d?) (split-path src*))
     (define result
       (with-handlers ([exn:fail? (lambda (e) (scribble-failed 'setup (exn-message e) #f #f))])
         (run-worker racket src* dir out secs mb read-roots)))
     (when (and made-dest? (scribble-failed? result))
       (with-handlers ([exn:fail? void]) (delete-directory/files out)))
     result]))

;; The worker's environment: only what Racket itself needs to start and find its libraries. The app's
;; own environment can hold secrets (an API key fallback, tokens), and a document is a program that
;; could read them with getenv and put them in its HTML.
(define kept-environment-rx #rx#"^(PATH|HOME|TMPDIR|USER|LANG|LC_[A-Z_]*|PLT.*)$")
(define (scrubbed-environment)
  (define src (current-environment-variables))
  (define env (make-environment-variables))
  (for ([name (in-list (environment-variables-names src))]
        #:when (regexp-match? kept-environment-rx name))
    (environment-variables-set! env name (environment-variables-ref src name)))
  env)

(define (run-worker racket src dir out secs mb read-roots)
  (define-values (sp stdout stdin stderr)
    (parameterize ([current-directory dir]
                   [current-environment-variables (scrubbed-environment)]
                   [subprocess-group-enabled #t]
                   [current-subprocess-custodian-mode 'kill])
      (apply subprocess #f #f #f racket (scribble-worker-path)
             (path->string src) (path->string out) (number->string secs) (number->string mb)
             (map (lambda (r) (if (path? r) (path->string r) r)) read-roots))))
  (close-output-port stdin)
  (define out-text (drain stdout))
  (define err-text (drain stderr))
  (define deadline (+ (current-inexact-milliseconds) (* 1000 (+ (* 2 secs) (preview-startup-allowance)))))
  (define ceiling (preview-rss-ceiling-mb mb))
  ;; 'done, 'time or 'memory
  (define ending
    (let loop ()
      (cond
        [(sync/timeout 0.25 sp) 'done]
        [(> (current-inexact-milliseconds) deadline) (kill! sp) 'time]
        [(let ([rss (process-rss-mb (subprocess-pid sp))]) (and rss (> rss ceiling))) (kill! sp) 'memory]
        [else (loop)])))
  (define stdout-text (out-text))
  (define stderr-text (err-text))
  (case ending
    [(time) (scribble-failed 'time (format "stopped after ~a seconds (the time limit for building a preview)"
                                           (+ (* 2 secs) (preview-startup-allowance)))
                             #f #f)]
    [(memory) (scribble-failed 'memory (format "stopped after using more than ~a MB of memory" ceiling) #f #f)]
    [else
     (define r (parse-result stdout-text))
     (cond
       [(not r)
        (define tail (string-trim stderr-text))
        (scribble-failed 'setup
                         (if (string=? tail "")
                             (format "the preview process ended without a result (exit status ~a)"
                                     (subprocess-status sp))
                             (if (> (string-length tail) 1000) (string-append (substring tail 0 1000) " …") tail))
                         #f #f)]
       [(eq? (car r) 'ok)
        (define entry (checked-entry out (cadr r)))
        (if entry
            (scribble-built out entry)
            (scribble-failed 'setup (format "the preview's page ~a is missing" (cadr r)) #f #f))]
       [else
        (define-values (kind msg source line) (apply values (cdr r)))
        (scribble-failed kind msg source line)])]))
