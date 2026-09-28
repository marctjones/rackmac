#lang racket/base
;; Preview (#420, epic E22 Publishing): build the current Scribble document to HTML with
;; rackmac/scribble-build.rkt, which runs it in a separate, sandboxed `racket` process. The
;; command says where the page is; opening it in the browser and rebuilding on save are #421.
;;
;; The trust rule (docs/PUBLISHING-DESIGN.md principle 4): building runs the document's code,
;; so it happens only when asked for (this command; nothing here runs on open or on save), and
;; a file outside every Library folder asks first. Declining runs nothing. A yes is remembered
;; for that file until Rackmac quits, so rebuilding does not ask again; it is never saved.
;;
;; The build runs on a thread; its result comes back to the GUI thread with queue-callback.
;; Failures go to the Activity log through report-error!, never raised into the UI.
;;
;; For now Preview applies to any document whose file ends in .scrbl; the Scribble Language
;; (#419) will be how people reach it.
(require racket/class racket/gui/base racket/path racket/file racket/string
         "command.rkt" "editor.rkt" "hook.rkt" "library/folders.rkt" "scribble-build.rkt")
(provide preview-document! confirm-run-untrusted-preview preview-building?
         enclosing-library-folder forget-preview-approvals! format-preview-failure)

;; "X is not in your Library. Run it?" -> #t to run. A parameter so tests can answer.
(define confirm-run-untrusted-preview
  (make-parameter
   (lambda (path)
     (eq? 1 (message-box/custom
             "Rackmac"
             (format (string-append "“~a” is not in your Library.\n\n"
                                    "Preview runs the code in this document to build it. "
                                    "Only preview documents you trust.")
                     (file-name-from-path path))
             "Run Preview" "Cancel" #f (ui-parent) '(caution default=2) 2)))))

;; Resolves links on both sides (on macOS the temporary folder is itself behind a link), falling
;; back to the plain complete path for a folder that does not exist.
(define (normalize p)
  (with-handlers ([exn:fail? (lambda (e) (simplify-path (path->complete-path p)))])
    (normalize-path p)))

;; The Library folder holding `path`, or #f.
(define (enclosing-library-folder path)
  (define f (path->string (normalize path)))
  (for/or ([lib (in-list (library-folder-paths))])
    (define d (path->string (path->directory-path (normalize lib))))
    (and (string-prefix? f d) lib)))

(define approved (make-hash))       ; normalized path string -> #t, for this session only
(define (forget-preview-approvals!) (hash-clear! approved))

(define building (make-hash))       ; normalized path string -> #t while a build runs
(define (preview-building? p) (hash-ref building (path->string (normalize p)) #f))

(define last-output (make-hash))    ; normalized path string -> the previous build's folder

(define (trusted? path key)
  (or (enclosing-library-folder path)
      (hash-ref approved key #f)
      (and ((confirm-run-untrusted-preview) path)
           (begin (hash-set! approved key #t) #t))))

;; "report.scrbl, line 3: missing closing `}`" -- the message without Racket's own
;; "/full/path:3:0: " prefix, which repeats the location.
(define (format-preview-failure name r)
  (define src (scribble-failed-source r))
  (define msg
    (let ([m (scribble-failed-message r)])
      (if src (regexp-replace (pregexp (string-append "^" (regexp-quote src) ":[0-9]+:[0-9]+: ")) m "") m)))
  (define where (if src (path->string (file-name-from-path src)) name))
  (if (scribble-failed-line r)
      (format "~a, line ~a: ~a" where (scribble-failed-line r) msg)
      (format "~a: ~a" where msg)))

(define (report! key name r stale?)
  (hash-remove! building key)
  (cond
    [(scribble-built? r)
     (define old (hash-ref last-output key #f))
     (hash-set! last-output key (scribble-built-dir r))
     (when (and old (not (equal? old (scribble-built-dir r))))
       (with-handlers ([exn:fail? void]) (delete-directory/files old)))
     (message "Preview of ~a is ready: ~a~a" name (path->string (scribble-built-entry r))
              (if stale? " (built from the saved file; save to include your latest changes)" ""))]
    [else (report-error! 'Preview (format-preview-failure name r))]))

;; Builds `b`'s file. Returns the building thread, or #f when nothing was started (not a
;; Scribble file, not saved yet, already building, or the person declined).
(define (preview-document! b)
  (define p (send b get-path))
  (define name (send b get-name))
  (cond
    [(not (scrbl-path? p)) (message "Preview works on Scribble documents (.scrbl files).") #f]
    [(not (file-exists? p)) (message "Save ~a before previewing it." name) #f]
    [else
     (define key (path->string (normalize p)))
     (cond
       [(hash-ref building key #f) (message "The preview of ~a is still being built." name) #f]
       [(not (trusted? p key)) (message "Preview cancelled; nothing in ~a was run." name) #f]
       [else
        (define lib (enclosing-library-folder p))
        (define stale? (send b is-modified?))
        (hash-set! building key #t)
        (message "Building the preview of ~a…" name)
        (thread
         (lambda ()
           (define r
             (with-handlers ([(lambda (e) #t)
                              (lambda (e) (scribble-failed 'setup (if (exn? e) (exn-message e) (format "~e" e)) #f #f))])
               (build-scribble p #:read-roots (if lib (list lib) '()))))
           (queue-callback (lambda () (report! key name r stale?)))))])]))

(define-command (preview-document)
  #:when (lambda () (scrbl-path? (send (current-buffer) get-path)))
  #:aliases ("preview" "build preview" "preview web page" "build html" "render document")
  #:help "Build this Scribble document as a web page, running its code in a separate, limited process."
  #:title "Preview"
  #:doc "Builds the document to HTML in a temporary folder and says where the page is. The document's code runs in a separate process that can only write to that folder and is stopped if it runs too long or uses too much memory. A file outside your Library asks before running."
  (void (preview-document! (current-buffer))))
