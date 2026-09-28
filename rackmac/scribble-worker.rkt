#lang racket/base
;; The Scribble build worker (#420, docs/PUBLISHING-DESIGN.md principle 4). A Scribble document
;; is a program, so it is never loaded into Rackmac's own process: rackmac/scribble-build.rkt
;; starts this file in a separate `racket` process, which loads the document and renders it to
;; HTML inside racket/sandbox, and writes one result line on stdout:
;;
;;   racket scribble-worker.rkt <doc.scrbl> <out-dir> <seconds> <megabytes> [<read-root> ...]
;;   -> RACKMAC-RESULT (ok "<entry file name>")
;;   -> RACKMAC-RESULT (fail <kind> "<message>" "<source>"|#f <line>|#f)   kind: time memory error
;;
;; Inside the sandbox the document may:
;;   - read its own folder (subfolders included), any <read-root> (the Library folder holding
;;     it), and the installed Racket collections (as compiled code: only those get the original
;;     code inspector, so the document itself cannot reach ffi/unsafe or unsafe operations);
;;   - read and write <out-dir>, the only place it can write;
;;   - ask whether any path exists (collection lookup and make-directory* need this).
;; It may not write elsewhere, run programs, use the network, create links, or exit this
;; process. Time and memory are limited per step (loading, then rendering) by the sandbox; the
;; parent also kills this whole process at a wall-clock deadline and above a resident-memory
;; ceiling, since the sandbox cannot see memory that C libraries allocate.
;;
;; Standard libraries only, never a rackmac module: an installed `racket` runs this file on its
;; own, and in the app bundle `define-runtime-path` carries this one file.
(require racket/sandbox racket/path racket/list racket/string)

(define result-marker "RACKMAC-RESULT ")

;; The first location worth showing: a read or syntax error's own srcloc, else the innermost
;; stack frame in a file under one of `roots` (the document's folder).
(define (exn-location e roots)
  (define (under-roots? src)
    (and (path? src)
         (let ([s (path->string src)])
           (for/or ([r (in-list roots)]) (string-prefix? s (path->string (path->directory-path r)))))))
  (define (from-srcloc l)
    (and (srcloc? l) (under-roots? (srcloc-source l)) (srcloc-line l)
         (list (path->string (srcloc-source l)) (srcloc-line l))))
  (define (from-syntax s)
    (and (syntax? s) (under-roots? (syntax-source s)) (syntax-line s)
         (list (path->string (syntax-source s)) (syntax-line s))))
  (or (and (exn:srclocs? e) (ormap from-srcloc ((exn:srclocs-accessor e) e)))
      (and (exn:fail:syntax? e) (ormap from-syntax (exn:fail:syntax-exprs e)))
      (and (exn? e)
           (for/or ([frame (in-list (continuation-mark-set->context (exn-continuation-marks e)))])
             (from-srcloc (cdr frame))))
      (list #f #f)))

(define (classify e)
  (cond
    [(and (exn:fail:resource? e) (eq? (exn:fail:resource-resource e) 'time)) 'time]
    [(exn:fail:resource? e) 'memory]
    [(and (exn:fail:sandbox-terminated? e)
          (eq? (exn:fail:sandbox-terminated-reason e) 'out-of-memory)) 'memory]
    [else 'error]))

(define (failure-message e kind secs mb)
  (define raw (if (exn? e) (exn-message e) (format "~e" e)))
  (define msg
    (case kind
      [(time) (format "stopped after ~a seconds (the time limit for building a preview)" secs)]
      [(memory) (format "stopped after using more than ~a MB (the memory limit for building a preview)" mb)]
      [else
       (cond
         [(and (exn:fail:sandbox-terminated? e) (eq? (exn:fail:sandbox-terminated-reason e) 'exited))
          "the document called exit"]
         [(regexp-match? #rx"^doc: undefined" raw)
          "this file does not define a Scribble document (no `doc`); does it start with #lang scribble/manual or #lang scribble/base?"]
         [else raw])]))
  (if (> (string-length msg) 4000) (string-append (substring msg 0 4000) " …") msg))

(define (build doc-arg out-arg secs mb read-roots)
  (define doc (simple-form-path doc-arg))
  (define out (simple-form-path out-arg))
  (define-values (dir name _d?) (split-path doc))
  (define entry (path-replace-extension name #".html"))
  ;; A parent guard that forbids links: the default sandbox guard has no link guard, and a link
  ;; in the output folder could point anywhere.
  (define no-links
    (make-security-guard (current-security-guard)
                         (lambda (who path modes) (void))
                         (lambda (who host port mode) (void))
                         (lambda (who path target) (error who "Preview does not allow creating links"))))
  (parameterize ([current-security-guard no-links]
                 [current-directory dir]                ; relative image paths, as `raco scribble` run there
                 [sandbox-gui-available #f]
                 [sandbox-output #f]                    ; the document's printing is discarded
                 [sandbox-error-output #f]
                 [sandbox-input #f]
                 [sandbox-memory-limit mb]
                 [sandbox-eval-limits (list secs mb)]
                 [sandbox-path-permissions
                  (append `((exists ,(byte-regexp #""))           ; any path, on any platform
                            (read ,dir)
                            (write ,out))
                          (for/list ([r (in-list read-roots)]) `(read ,(simple-form-path r))))])
    (define ev (make-module-evaluator doc))
    (dynamic-wind
     void
     (lambda ()
       (ev `((dynamic-require 'scribble/render 'render)
             (list doc) (list ,(path->string name)) #:dest-dir ,(path->string out)))
       (unless (file-exists? (build-path out entry))
         (error 'preview "Scribble finished but wrote no ~a" entry))
       (list 'ok (path->string entry)))
     (lambda () (kill-evaluator ev)))))

(module+ main
  (define out (current-output-port))
  (define args (vector->list (current-command-line-arguments)))
  (define result
    (cond
      [(< (length args) 4)
       (list 'fail 'error "usage: scribble-worker.rkt doc out-dir seconds megabytes [read-root ...]" #f #f)]
      [else
       (define-values (doc dir secs mb roots)
         (values (first args) (second args) (string->number (third args)) (string->number (fourth args))
                 (drop args 4)))
       (define doc-dir (let-values ([(d n _) (split-path (simple-form-path doc))]) d))
       (with-handlers ([(lambda (e) #t)
                        (lambda (e)
                          (define kind (classify e))
                          (define loc (if (eq? kind 'error) (exn-location e (cons doc-dir roots)) (list #f #f)))
                          (list* 'fail kind (failure-message e kind secs mb) loc))])
         (build doc dir secs mb roots))]))
  (fprintf out "~a~s\n" result-marker result)
  (flush-output out))
