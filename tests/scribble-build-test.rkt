#lang racket/base
;; Building a Scribble document to HTML in a sandboxed subprocess (#420). No GUI, no network,
;; no browser. The limits are proved at both levels:
;;   - the sandbox inside the worker stops an infinite loop and a memory bomb, and refuses
;;     writes and reads outside the permitted folders, programs, the network, FFI, unsafe
;;     operations, links and exit;
;;   - the parent's hard stops (wall-clock deadline, resident-memory ceiling, SIGKILL to the
;;     whole process group) are proved with a stand-in worker that ignores every limit.
;; Every test's processes are gone when it ends; the last test checks with ps.
(require rackunit racket/file racket/list racket/path racket/port racket/string racket/system
         racket/os
         "../rackmac/scribble-build.rkt")

(define root (make-temporary-directory "rackmac-scribble-test-~a"))
(define docs (build-path root "docs"))        ; the documents' folder: readable, not writable
(define elsewhere (build-path root "elsewhere"))  ; outside every permitted folder
(make-directory* docs)
(make-directory* elsewhere)

(define (doc! name body)
  (define p (build-path docs name))
  (display-to-file body p #:exists 'truncate/replace)
  p)

(define secret (build-path elsewhere "secret.txt"))
(display-to-file "the-secret-value" secret)

(define (cleanup! r)
  (when (scribble-built? r) (delete-directory/files (scribble-built-dir r))))
(define (entry-text r) (file->string (scribble-built-entry r)))

(define-syntax-rule (check-failed r kind rx)
  (let ([v r])
    (check-true (scribble-failed? v) (format "expected a failure, got ~e" v))
    (when (scribble-failed? v)
      (check-eq? (scribble-failed-kind v) kind (scribble-failed-message v))
      (check-regexp-match rx (scribble-failed-message v)))))

(define-syntax-rule (timed body) (let ([t0 (current-inexact-milliseconds)])
                                   (define v body)
                                   (values v (/ (- (current-inexact-milliseconds) t0) 1000.0))))

;; ---- success ----------------------------------------------------------------------------------

(test-case "a valid document builds to an HTML folder with its entry file"
  (define p (doc! "report.scrbl"
                  "#lang scribble/manual\n@title{Quarterly Report}\n@section{Summary}\nRevenue was @bold{up}.\n"))
  (define r (build-scribble p))
  (check-true (scribble-built? r) (format "~e" r))
  (when (scribble-built? r)
    (check-equal? (path->string (file-name-from-path (scribble-built-entry r))) "report.html")
    (check-true (directory-exists? (scribble-built-dir r)))
    (check-equal? (simplify-path (path-only (scribble-built-entry r)))
                  (simplify-path (path->directory-path (scribble-built-dir r))))
    (check-regexp-match #rx"Quarterly Report" (entry-text r))
    (check-regexp-match #rx"Summary" (entry-text r))
    (check-true (file-exists? (build-path (scribble-built-dir r) "scribble.css")) "helper files come too"))
  (cleanup! r))

(test-case "the document runs in another process, never this one"
  (define p (doc! "pid.scrbl"
                  "#lang scribble/base\n@(require racket/os)\n@title{Pid}\nPID=@(number->string (getpid))=\n"))
  (define r (build-scribble p))
  (check-true (scribble-built? r) (format "~e" r))
  (when (scribble-built? r)
    (define m (regexp-match #rx"PID=([0-9]+)=" (entry-text r)))
    (check-not-false m)
    (check-not-equal? (string->number (cadr m)) (getpid) "the page was rendered by a different process"))
  (check-false (module-declared? p #f) "the document was never declared in this process")
  (cleanup! r))

(test-case "a document may read files in its own folder, and write only to the output"
  (display-to-file "data-from-beside-the-doc" (build-path docs "data.txt") #:exists 'truncate/replace)
  (define p (doc! "reads-beside.scrbl"
                  "#lang scribble/base\n@title{Data}\n@(file->string \"data.txt\")\n@(require racket/file)\n"))
  (define r (build-scribble p))
  (check-true (scribble-built? r) (format "~e" r))
  (when (scribble-built? r) (check-regexp-match #rx"data-from-beside-the-doc" (entry-text r)))
  (cleanup! r))

(test-case "an explicit output folder is used, and a read root outside the document's folder is honored"
  (define dest (build-path root "chosen-out"))
  (define p (doc! "reads-root.scrbl"
                  (format "#lang scribble/base\n@(require racket/file)\n@title{R}\n@(file->string ~s)\n"
                          (path->string secret))))
  (define r (build-scribble p #:dest dest #:read-roots (list elsewhere)))
  (check-true (scribble-built? r) (format "~e" r))
  (when (scribble-built? r)
    (check-equal? (simplify-path (scribble-built-dir r)) (simplify-path dest))
    (check-regexp-match #rx"the-secret-value" (entry-text r)))
  (cleanup! r))

;; ---- errors, with file and line ---------------------------------------------------------------

(test-case "a syntax error is reported with its file and line"
  (define p (doc! "broken.scrbl" "#lang scribble/manual\n@title{Fine}\n\n@section{Not closed\n\nText.\n"))
  (define r (build-scribble p))
  (check-failed r 'error #rx"closing")
  (when (scribble-failed? r)
    (check-equal? (scribble-failed-source r) (path->string (simple-form-path p)))
    (check-equal? (scribble-failed-line r) 4)))

(test-case "an unbound name is reported with its line"
  (define p (doc! "unbound.scrbl" "#lang scribble/manual\n@title{T}\n\n@(no-such-function 1)\n"))
  (define r (build-scribble p))
  (check-failed r 'error #rx"no-such-function")
  (when (scribble-failed? r) (check-equal? (scribble-failed-line r) 4)))

;; Racket CS keeps no stack frame with a line for code like this (the function is inlined), so
;; a run-time error names the message only; the Preview command adds the file name.
(test-case "a run-time error is reported with its message"
  (define p (doc! "runtime.scrbl"
                  "#lang scribble/manual\n@title{T}\n@(define (first-of x)\n   (car x))\n@(first-of 5)\n"))
  (define r (build-scribble p))
  (check-failed r 'error #rx"car: contract violation"))

(test-case "a file that is not a Scribble document says so"
  (define p (doc! "plain.scrbl" "#lang racket/base\n(define x 1)\n"))
  (check-failed (build-scribble p) 'error #rx"does not define a Scribble document"))

(test-case "a missing file is a setup failure, not an exception"
  (check-failed (build-scribble (build-path docs "nope.scrbl")) 'setup #rx"does not exist"))

(test-case "a failed build leaves no temporary output folder behind; a good one leaves one"
  (define outs (build-path root "outs"))
  (make-directory* outs)
  (parameterize ([preview-output-root outs])
    (build-scribble (doc! "broken2.scrbl" "#lang scribble/manual\n@title{x\n"))
    (check-equal? (directory-list outs) '())
    (define r (build-scribble (doc! "fine2.scrbl" "#lang scribble/base\n@title{fine}\n")))
    (check-true (scribble-built? r))
    (check-equal? (length (directory-list outs)) 1)
    (cleanup! r)))

;; ---- limits inside the sandbox ------------------------------------------------------------------

(test-case "an infinite loop is stopped by the time limit and reported, not hung"
  (define p (doc! "loop.scrbl" "#lang scribble/manual\n@title{Loop}\n@(let loop () (loop))\n"))
  (define-values (r secs) (timed (build-scribble p #:time-limit 3)))
  (check-failed r 'time #rx"3 seconds")
  ;; Stopped by the sandbox at 3 s (plus start-up); the parent's own deadline would be 26 s.
  (check-true (< secs 20) (format "took ~a s" secs)))

(test-case "a memory bomb is stopped by the memory limit and reported"
  (define p (doc! "bomb.scrbl"
                  "#lang scribble/manual\n@title{Bomb}\n@(let loop ([l '()]) (loop (cons (make-bytes 1000000 1) l)))\n"))
  (define-values (r secs) (timed (build-scribble p #:memory-limit 200)))
  (check-failed r 'memory #rx"200 MB")
  (check-true (< secs 30) (format "took ~a s" secs)))

;; ---- what a document may not do -----------------------------------------------------------------

(define escape-target (build-path elsewhere "written.txt"))

(test-case "writing outside the output folder is refused"
  (define p (doc! "write-out.scrbl"
                  (format "#lang scribble/base\n@(with-output-to-file ~s (lambda () (display 1)))\n"
                          (path->string escape-target))))
  (check-failed (build-scribble p) 'error #rx"access denied")
  (check-false (file-exists? escape-target)))

(test-case "writing into the document's own folder is refused too"
  (define target (build-path docs "planted.txt"))
  (define p (doc! "write-beside.scrbl"
                  "#lang scribble/base\n@(with-output-to-file \"planted.txt\" (lambda () (display 1)))\n"))
  (check-failed (build-scribble p) 'error #rx"access denied")
  (check-false (file-exists? target)))

(test-case "reading outside the permitted folders is refused"
  (define p (doc! "read-out.scrbl"
                  (format "#lang scribble/base\n@(require racket/file)\n@(file->string ~s)\n" (path->string secret))))
  (check-failed (build-scribble p) 'error #rx"access denied"))

(test-case "reading the home folder is refused"
  (define p (doc! "read-home.scrbl"
                  "#lang scribble/base\n@(format \"~a\" (directory-list (find-system-path 'home-dir)))\n"))
  (check-failed (build-scribble p) 'error #rx"access denied"))

(test-case "running a program is refused"
  (define marker (build-path elsewhere "ran.txt"))
  (define p (doc! "exec.scrbl"
                  (format "#lang scribble/base\n@(require racket/system)\n@(format \"~~a\" (system ~s))\n"
                          (format "touch '~a'" (path->string marker)))))
  (check-failed (build-scribble p) 'error #rx"execute. access denied")
  (check-false (file-exists? marker)))

(test-case "the network is refused"
  (define p (doc! "net.scrbl"
                  "#lang scribble/base\n@(require racket/tcp)\n@(let-values ([(i o) (tcp-connect \"127.0.0.1\" 9)]) \"x\")\n"))
  (check-failed (build-scribble p) 'error #rx"network access denied"))

(test-case "the FFI is refused, so the file rules cannot be bypassed through C"
  (define marker (build-path elsewhere "ffi.txt"))
  (define p (doc! "ffi.scrbl"
                  (format (string-append "#lang scribble/base\n@(require ffi/unsafe)\n"
                                         "@(format \"~~a\" ((get-ffi-obj \"system\" #f (_fun _string -> _int)) ~s))\n")
                          (format "touch '~a'" (path->string marker)))))
  (check-failed (build-scribble p) 'error #rx"code inspector")
  (check-false (file-exists? marker)))

(test-case "unsafe operations are refused"
  (define p (doc! "unsafe.scrbl" "#lang scribble/base\n@(require racket/unsafe/ops)\n@(format \"~a\" (unsafe-car 5))\n"))
  (check-failed (build-scribble p) 'error #rx"code inspector"))

(test-case "a planted compiled helper that uses the FFI is refused"
  (define helper (build-path docs "helper.rkt"))
  (define marker (build-path elsewhere "zo.txt"))
  (display-to-file (format (string-append "#lang racket/base\n(require ffi/unsafe)\n(provide go)\n"
                                          "(define (go) ((get-ffi-obj \"system\" #f (_fun _string -> _int)) ~s))\n")
                           (format "touch '~a'" (path->string marker)))
                   helper #:exists 'truncate/replace)
  (check-true (system* (find-executable-path "raco") "make" (path->string helper)) "compiled outside the sandbox")
  (define p (doc! "zo.scrbl" "#lang scribble/base\n@(require \"helper.rkt\")\n@(format \"~a\" (go))\n"))
  (check-failed (build-scribble p) 'error #rx"code inspector")
  (check-false (file-exists? marker)))

(test-case "making a link, even inside the output folder, is refused"
  (define dest (build-path root "link-out"))
  (define p (doc! "link.scrbl"
                  (format "#lang scribble/base\n@(make-file-or-directory-link ~s ~s)\n"
                          (path->string secret) (path->string (build-path dest "l")))))
  (check-failed (build-scribble p #:dest dest) 'error #rx"links")
  (check-false (link-exists? (build-path dest "l"))))

(test-case "exit ends only the document, and is reported"
  (define p (doc! "exit.scrbl" "#lang scribble/base\n@(exit 0)\n"))
  (check-failed (build-scribble p) 'error #rx"exit"))

(test-case "a document that prints a lot neither hangs nor floods the result"
  (define p (doc! "chatty.scrbl"
                  "#lang scribble/base\n@title{Chatty}\n@(let () (for ([i 20000]) (printf \"noise ~a\\n\" i) (eprintf \"err ~a\\n\" i)) \"done\")\n"))
  (define r (build-scribble p))
  (check-true (scribble-built? r) (format "~e" r))
  (cleanup! r))

;; ---- the parent's hard stops, with a stand-in worker that ignores every limit ------------------

(define fakes (build-path root "fakes"))
(make-directory* fakes)
(define (fake! name body)
  (define p (build-path fakes name))
  (display-to-file (string-append "#lang racket/base\n" body "\n") p #:exists 'truncate/replace)
  p)

(define plain-doc (doc! "plain-ok.scrbl" "#lang scribble/base\n@title{x}\n"))

;; ps lines (pid and command) mentioning `needle`, other than ps itself.
(define (processes-matching needle)
  (define text (with-output-to-string (lambda () (system* "/bin/ps" "-axo" "pid=,command="))))
  (for/list ([l (in-list (string-split text "\n"))]
             #:when (and (string-contains? l needle) (not (string-contains? l "/bin/ps"))))
    l))

(test-case "the parent kills a worker that ignores the time limit, and its whole process group"
  ;; The stand-in starts a grandchild (a long sleep with a unique argument), then spins.
  (define fake (fake! "spin.rkt"
                      "(require racket/system)\n(void (process* \"/bin/sleep\" \"4242.420\"))\n(let loop () (loop))"))
  (define-values (r secs)
    (timed (parameterize ([scribble-worker-path fake] [preview-startup-allowance 2])
             (build-scribble plain-doc #:time-limit 1))))
  (check-failed r 'time #rx"seconds")
  (check-true (< secs 15) (format "took ~a s" secs))        ; deadline is 2*1 + 2 = 4 s
  (sleep 0.2)
  (check-equal? (processes-matching (path->string fake)) '() "the worker is gone")
  (check-equal? (processes-matching "4242.420") '() "its child is gone too"))

(test-case "the parent kills a worker whose memory passes the ceiling"
  ;; 50 MB limit -> 356 MB resident ceiling. The stand-in takes 600 MB and holds it (so even a
  ;; slow ps sees it), then gives up by itself after 20 s, so a broken ceiling cannot take this
  ;; machine down; the test fails if it gets that far.
  (define fake (fake! "hog.rkt"
                      (string-append "(define l (for/list ([i 600]) (make-bytes 1000000 1)))\n"
                                     "(sleep 20)\n"
                                     "(printf \"RACKMAC-RESULT (fail error \\\"hog finished ~a\\\" #f #f)\\n\" (length l))")))
  (define-values (r secs)
    (timed (parameterize ([scribble-worker-path fake])
             (build-scribble plain-doc #:memory-limit 50))))
  (check-failed r 'memory #rx"356 MB")
  (check-true (< secs 30) (format "took ~a s" secs))
  (sleep 0.2)
  (check-equal? (processes-matching (path->string fake)) '()))

(test-case "a worker that floods stdout and stderr cannot hang the build"
  (define fake (fake! "flood.rkt"
                      (string-append "(for ([i 200000]) (printf \"out ~a\\n\" i) (eprintf \"err ~a\\n\" i))\n"
                                     "(printf \"RACKMAC-RESULT (fail error \\\"flooded\\\" #f #f)\\n\")")))
  (define-values (r secs) (timed (parameterize ([scribble-worker-path fake]) (build-scribble plain-doc))))
  ;; The result line comes after 64 KB of noise, so it is past the cap and not believed.
  (check-true (scribble-failed? r))
  (check-true (< secs 30) (format "took ~a s" secs)))

(test-case "a worker that dies without a result is a setup failure with its error text"
  (define fake (fake! "crash.rkt" "(error 'worker \"exploded\")"))
  (check-failed (parameterize ([scribble-worker-path fake]) (build-scribble plain-doc)) 'setup #rx"exploded"))

(test-case "a forged result naming a file outside the output folder is not believed"
  (define fake (fake! "forge.rkt" "(printf \"RACKMAC-RESULT (ok \\\"../../etc/passwd\\\")\\n\")"))
  (check-failed (parameterize ([scribble-worker-path fake]) (build-scribble plain-doc)) 'setup #rx"missing"))

;; ---- finding racket ---------------------------------------------------------------------------

(test-case "no Racket installed is a setup failure with a hint"
  (check-failed (parameterize ([scribble-racket-candidates '()]) (build-scribble plain-doc)) 'setup #rx"needs Racket"))

(test-case "an executable not named racket (the app's own binary) is never used"
  (define not-racket (build-path fakes "Rackmac"))
  (copy-file (find-executable-path "racket") not-racket #t)
  (check-false (parameterize ([scribble-racket-candidates (list (lambda () not-racket))]) (find-scribble-racket))))

(test-case "scrbl-path? recognizes Scribble files only"
  (check-true (scrbl-path? "/a/b.scrbl"))
  (check-true (scrbl-path? (string->path "/a/B.SCRBL")))
  (check-false (scrbl-path? "/a/b.md"))
  (check-false (scrbl-path? #f)))

;; ---- hygiene ----------------------------------------------------------------------------------

(test-case "no worker processes are left behind"
  (sleep 0.2)
  (check-equal? (processes-matching (path->string (scribble-worker-path))) '())
  (check-equal? (processes-matching (path->string fakes)) '()))

(delete-directory/files root)
