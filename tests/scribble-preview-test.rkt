#lang racket/base
;; The Preview command (#420): builds the current .scrbl in a sandboxed subprocess and reports
;; to the Activity log; a file outside every Library folder asks first, declining runs nothing,
;; and nothing runs on open or on save (docs/PUBLISHING-DESIGN.md principle 4). The asking
;; dialog is a parameter, answered here. No window is created, no browser opened.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/file racket/class racket/path racket/string racket/port racket/system
         racket/gui/base
         "../rackmac/scribble-preview.rkt" "../rackmac/scribble-build.rkt"
         "../rackmac/library/folders.rkt" "../rackmac/settings.rkt" "../rackmac/editor.rkt"
         "../rackmac/command.rkt")

(define home (make-temporary-directory "rackmac-preview-test-~a"))
(void (putenv "RACKMAC_HOME" (path->string home)))
(define lib (build-path home "Library"))
(define outside (build-path home "Downloads"))
(make-directory* lib)
(make-directory* outside)
(setting-set! 'library-folders '())
(add-library-folder-path! lib)

(define (doc! dir name body)
  (define p (build-path dir name))
  (display-to-file body p #:exists 'truncate/replace)
  p)
(define good "#lang scribble/base\n@title{Minutes}\nAgreed.\n")

(define (activity) (send (messages-buffer) get-text))
(define (activity-since mark) (substring (activity) mark))

;; Starts the build and waits for its result to reach the GUI thread.
(define (preview-and-wait! b)
  (define t (preview-document! b))
  (when t
    (thread-wait t)
    (let loop ([n 0])
      (yield)
      (when (and (preview-building? (send b get-path)) (< n 500)) (sleep 0.01) (loop (add1 n)))))
  t)

;; A racket "finder" that counts how often anything tried to start a build.
(define spawns 0)
(define counting (list (lambda () (set! spawns (add1 spawns)) #f)))

(define (never-ask p) (error 'test "asked about ~a, which is in the Library" p))

(define (close-all!) (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b)))

(test-case "Preview applies to .scrbl documents only"
  (define b (open-file! (doc! lib "a.scrbl" good)))
  (set-current-buffer! b)
  (check-true (command-enabled? (find-command 'preview-document)))
  (define m (open-file! (doc! lib "a.md" "# note\n")))
  (set-current-buffer! m)
  (check-false (command-enabled? (find-command 'preview-document)))
  (check-false (preview-document! m) "and running it on a note starts nothing")
  (close-all!))

(test-case "a document in the Library builds without asking, and the page is reported"
  (define p (doc! lib "minutes.scrbl" good))
  (define b (open-file! p))
  (set-current-buffer! b)
  (define mark (string-length (activity)))
  (parameterize ([confirm-run-untrusted-preview never-ask])
    (check-not-false (preview-and-wait! b)))
  (define log (activity-since mark))
  (define m (regexp-match #rx"Preview of minutes.scrbl is ready: ([^\n]+)" log))
  (check-not-false m log)
  (when m
    (check-true (file-exists? (cadr m)))
    (check-regexp-match #rx"Minutes" (file->string (cadr m)))
    ;; A second build replaces the first one's folder.
    (parameterize ([confirm-run-untrusted-preview never-ask]) (preview-and-wait! b))
    (define m2 (regexp-match #rx"Preview of minutes.scrbl is ready: ([^\n]+)" (activity-since (+ mark (string-length log)))))
    (check-not-false m2)
    (when m2
      (check-true (file-exists? (cadr m2)))
      (check-false (file-exists? (cadr m)) "the previous build's folder is removed")
      (delete-directory/files (path-only (cadr m2)))))
  (close-all!))

(test-case "a document outside the Library asks first; declining runs nothing"
  (define p (doc! outside "downloaded.scrbl" good))
  (define b (open-file! p))
  (set-current-buffer! b)
  (define asked '())
  (set! spawns 0)
  (parameterize ([confirm-run-untrusted-preview (lambda (q) (set! asked (cons q asked)) #f)]
                 [scribble-racket-candidates counting])
    (check-false (preview-document! b))
    (run-command 'preview-document))
  (check-equal? (length asked) 2)
  (check-equal? (path->string (car asked)) (path->string p))
  (check-equal? spawns 0 "nothing was started")
  (check-regexp-match #rx"nothing in downloaded.scrbl was run" (activity))
  (close-all!))

(test-case "saying yes builds it, and is remembered for this file until quit"
  (forget-preview-approvals!)
  (define p (doc! outside "trusted-once.scrbl" good))
  (define b (open-file! p))
  (set-current-buffer! b)
  (define asks 0)
  (define mark (string-length (activity)))
  (parameterize ([confirm-run-untrusted-preview (lambda (q) (set! asks (add1 asks)) #t)])
    (preview-and-wait! b)
    (preview-and-wait! b))
  (check-equal? asks 1)
  (define ms (regexp-match* #rx"Preview of trusted-once.scrbl is ready: ([^\n]+)" (activity-since mark)
                            #:match-select cadr))
  (check-equal? (length ms) 2)
  (for ([m ms]) (when (file-exists? m) (delete-directory/files (path-only m))))
  (forget-preview-approvals!)
  (close-all!))

(test-case "a build failure goes to the Activity log with the file and line"
  (define p (doc! lib "broken.scrbl" "#lang scribble/manual\n@title{Fine}\n\n@section{Not closed\n"))
  (define b (open-file! p))
  (set-current-buffer! b)
  (define mark (string-length (activity)))
  (parameterize ([confirm-run-untrusted-preview never-ask]) (preview-and-wait! b))
  (define log (activity-since mark))
  (check-regexp-match #rx"Preview: broken.scrbl, line 4: missing closing" log)
  (check-false (regexp-match? (regexp-quote (path->string (simple-form-path p))) log)
               "Racket's own path prefix is not repeated")
  (close-all!))

(test-case "no Racket to run it with is reported, not raised"
  (define b (open-file! (doc! lib "no-racket.scrbl" good)))
  (set-current-buffer! b)
  (define mark (string-length (activity)))
  (parameterize ([confirm-run-untrusted-preview never-ask] [scribble-racket-candidates '()])
    (preview-and-wait! b))
  (check-regexp-match #rx"Preview: no-racket.scrbl: Preview needs Racket installed" (activity-since mark))
  (close-all!))

(test-case "unsaved changes: the saved file is built, and the message says so"
  (define b (open-file! (doc! lib "edited.scrbl" good)))
  (set-current-buffer! b)
  (send b insert "more")
  (define mark (string-length (activity)))
  (parameterize ([confirm-run-untrusted-preview never-ask]) (preview-and-wait! b))
  (define log (activity-since mark))
  (check-regexp-match #rx"built from the saved file" log)
  (define m (regexp-match #rx"is ready: ([^ \n]+[.]html)" log))
  (when m (delete-directory/files (path-only (cadr m))))
  (send b set-modified #f)
  (close-all!))

(test-case "nothing runs on open or on save"
  (set! spawns 0)
  (parameterize ([scribble-racket-candidates counting]
                 [confirm-run-untrusted-preview (lambda (q) (error 'test "asked on open"))])
    (define b1 (open-file! (doc! lib "opened.scrbl" good)))
    (set-current-buffer! b1)
    (define b2 (open-file! (doc! outside "opened-outside.scrbl" good)))
    (set-current-buffer! b2)
    (send b2 insert " ")
    (send b2 save-to! (send b2 get-path))
    (for ([i 20]) (yield) (sleep 0.01)))
  (check-equal? spawns 0)
  (close-all!))

(test-case "the Library check follows links on both sides and is not fooled by a shared prefix"
  (define sibling (build-path home "Library-not"))           ; ".../Library" is a prefix of it
  (make-directory* sibling)
  (check-false (enclosing-library-folder (doc! sibling "x.scrbl" good)))
  (check-not-false (enclosing-library-folder (doc! lib "y.scrbl" good)))
  (define link (build-path home "lib-link"))
  (make-file-or-directory-link lib link)
  (check-not-false (enclosing-library-folder (build-path link "y.scrbl")) "a path through a link to the Library"))

(test-case "no worker processes are left behind"
  (sleep 0.2)
  (define ps (with-output-to-string (lambda () (system* "/bin/ps" "-axo" "command="))))
  (check-false (string-contains? ps (path->string (scribble-worker-path)))))

(delete-directory/files home)
