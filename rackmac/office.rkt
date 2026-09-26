#lang racket/base
;; To and from Word (#280, #281): File > Export to Word… and File > Import Word Document…,
;; through pandoc (rackmac/pandoc.rkt). Notes stay Markdown; these convert copies. The
;; conversions are plain functions so they can be tested without dialogs; the commands add the
;; dialogs (parameters, so tests answer them) and report pandoc's own error text plainly.
(require racket/class racket/gui/base racket/port racket/path racket/string racket/file racket/system
         "command.rkt" "editor.rkt" "pandoc.rkt" "settings.rkt" "platform.rkt")
(provide export-docx! import-docx! ask-export-path ask-import-path reveal-after-export
         pandoc-export-args pandoc-import-args import-target)

(define-setting word-template
  #:contract string?
  #:default ""
  #:category "Word and PDF"
  #:doc "A Word document whose styles exports use (pandoc's reference document). Empty: pandoc's own styles.")

;; pandoc reads [[Title|text]] wiki links with this extension (pandoc 3.x).
(define (pandoc-export-args out template)
  (append (list "-f" "gfm+wikilinks_title_after_pipe" "-t" "docx" "-o" (path->string out))
          (if (and template (not (string=? template "")) (file-exists? template))
              (list (string-append "--reference-doc=" template))
              '())))

;; Tracked changes are accepted (pandoc's default for docx, stated so it can't drift) and
;; Word comments are dropped: Markdown has no place for them. Images are extracted next to
;; the note, in "<name>_files".
(define (pandoc-import-args in out media-dir)
  (list "-f" "docx" "-t" "gfm" "--wrap=none" "--track-changes=accept"
        (string-append "--extract-media=" (path->string media-dir))
        "-o" (path->string out) (path->string in)))

;; Runs pandoc with `args`, feeding `input` on stdin. Returns (values ok? error-text); the
;; error text is pandoc's own stderr, trimmed, for the user to read.
(define (run-pandoc args [input #f] #:pandoc [pandoc (find-pandoc)])
  (cond
    [(not pandoc) (values #f pandoc-install-hint)]
    [else
     (with-handlers ([exn:fail? (lambda (e) (values #f (exn-message e)))])
       (define-values (sp out in err) (apply subprocess #f #f #f pandoc args))
       (when input (write-string input in))
       (close-output-port in)
       (define err-text (port->string err))
       (port->string out)
       (subprocess-wait sp)
       (close-input-port out) (close-input-port err)
       (if (zero? (subprocess-status sp))
           (values #t "")
           (values #f (string-trim err-text))))]))

(define (export-docx! markdown out #:template [template (setting-ref 'word-template)]
                      #:pandoc [pandoc (find-pandoc)])
  (run-pandoc (pandoc-export-args out template) markdown #:pandoc pandoc))

;; Converts `in` (.docx) to `out` (.md); media go to "<out name>_files" beside it.
(define (import-docx! in out #:pandoc [pandoc (find-pandoc)])
  (define-values (dir name _) (split-path (path->complete-path out)))
  (define media (build-path dir (string-append (path->string (path-replace-extension name #"")) "_files")))
  (run-pandoc (pandoc-import-args in out media) #:pandoc pandoc))

;; ---- commands --------------------------------------------------------------

;; "Brief.docx" → "Brief.md" beside it, or "Brief 2.md", "Brief 3.md"… so an import never
;; overwrites an existing note.
(define (import-target in)
  (define base (path->string (path-replace-extension in #"")))
  (let loop ([n 1])
    (define p (string->path (if (= n 1) (string-append base ".md") (format "~a ~a.md" base n))))
    (if (file-exists? p) (loop (add1 n)) p)))

(define (default-name b ext)
  (path-replace-extension (string->path (send b get-name)) ext))

;; Dialogs are parameters so tests can answer them (docs/DEVELOPMENT.md).
(define ask-export-path
  (make-parameter (lambda (suggested dir) (put-file "Export to Word" (ui-parent) dir (path->string suggested) "docx"))))
(define ask-import-path
  (make-parameter (lambda () (get-file "Import Word Document" (ui-parent) #f #f "docx"))))
(define reveal-after-export
  (make-parameter (lambda (p) (when (mac?) (void (process* "/usr/bin/open" "-R" (path->string p)))))))

(define (docs-dir-of b)
  (define p (send b get-path))
  (and p (let-values ([(dir name _) (split-path p)]) dir)))

(define-command (export-word)
  #:when pandoc-available?
  #:icon "save-as"
  #:aliases ("docx" "save as word" "export docx" "send to word")
  #:help "Save a copy of this note as a Word document (.docx), using pandoc."
  #:title "Export to Word…" #:menu "File" #:menu-order 27
  (define b (current-buffer))
  (define out ((ask-export-path) (default-name b #".docx") (docs-dir-of b)))
  (when out
    (define-values (ok? err) (export-docx! (send b get-text) out))
    (cond [ok? (message "Exported to ~a" (path->string out)) ((reveal-after-export) out)]
          [else (message "Word export failed: ~a" err)])))

(define-command (import-word)
  #:when pandoc-available?
  #:icon "open"
  #:aliases ("docx" "open word" "import docx" "convert word")
  #:help "Convert a Word document (.docx) into a Markdown note beside it and open it, using pandoc."
  #:title "Import Word Document…" #:menu "File" #:menu-order 14
  (define in ((ask-import-path)))
  (when in
    (define out (import-target in))
    (define-values (ok? err) (import-docx! in out))
    (cond [ok? (set-current-buffer! (open-file! out))
               (message "Imported ~a (tracked changes accepted, comments left out)" (file-name-from-path in))]
          [else (message "Word import failed: ~a" err)])))
