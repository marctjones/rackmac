#lang racket/base
;; Word export and import through pandoc (#280, #281): a note survives Markdown → Word →
;; Markdown with its headings, lists, task lists, tables and links; pandoc's errors reach the
;; user as its own words; the commands grey out without pandoc and never overwrite a note.
;; Tests that need pandoc skip cleanly when it is not installed (docs/UI-DESIGN.md §5.4).
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/file racket/class racket/string
         "../rackmac/office.rkt" "../rackmac/pandoc.rkt" "../rackmac/command.rkt"
         "../rackmac/commands.rkt" "../rackmac/editor.rkt" "../rackmac/hook.rkt")

(void (putenv "RACKMAC_HOME" (path->string (make-temporary-file "rackmac-office~a" 'directory))))
(define dir (make-temporary-file "rackmac-office-docs~a" 'directory))
(define have-pandoc? (pandoc-available?))
(unless have-pandoc? (printf "office-test: pandoc 3 not installed; conversion tests skipped\n"))

(define note (string-append
              "# Harbor Street lease\n\n## Open points\n\n"
              "- first bullet\n- second bullet\n\n1. one\n2. two\n\n"
              "- [ ] send the redline\n- [x] confirm the date\n\n"
              "| Clause | Status |\n|---|---|\n| 12 | open |\n\n"
              "See [the lease](https://example.com/lease).\n"))

(when have-pandoc?
  (test-case "a note round-trips through Word with its structure"
    (define docx (build-path dir "Harbor.docx"))
    (define-values (ok? err) (export-docx! note docx))
    (check-true ok? err)
    (check-true (> (file-size docx) 1000) "a real .docx was written")
    (define back (build-path dir "Harbor back.md"))
    (define-values (ok2? err2) (import-docx! docx back))
    (check-true ok2? err2)
    (define md (file->string back))
    (for ([want (list #rx"# Harbor Street lease" #rx"## Open points" #rx"- first bullet"
                      #rx"1\\. +one" #rx"\\[ \\] send the redline" #rx"\\[x\\] confirm the date"
                      #rx"\\| *12 *\\| *open *\\|" #rx"\\[the lease\\]\\(https://example.com/lease\\)")])
      (check-true (regexp-match? want md) (format "~a missing from:\n~a" (object-name want) md))))

  (test-case "pandoc's own error text is passed through plainly"
    (define bad (build-path dir "corrupt-template.docx"))          ; not a zip: pandoc refuses it
    (with-output-to-file bad #:exists 'truncate (lambda () (display "not a Word file")))
    (define-values (ok? err) (export-docx! note (build-path dir "x.docx") #:template (path->string bad)))
    (check-false ok?)
    (check-true (> (string-length err) 0) "an error message, not silence"))

  (test-case "Export to Word writes the file beside the note and says where"
    (define b (new-buffer! "Exported note.md" #:mode 'markdown-mode))
    (send b insert note)
    (set-current-buffer! b)
    (define said '())
    (add-hook! 'echo (lambda (s) (set! said (cons s said))))
    (define out (build-path dir "Exported note.docx"))
    (parameterize ([ask-export-path (lambda (suggested d) (check-equal? (path->string suggested) "Exported note.docx") out)]
                   [reveal-after-export void])
      (run-command 'export-word))
    (check-true (file-exists? out))
    (check-true (for/or ([s said]) (regexp-match? #rx"Exported to" s))))

  (test-case "Import Word Document opens the converted note and never overwrites one"
    (define docx (build-path dir "Brief.docx"))
    (export-docx! "# Brief\n\nText.\n" docx)
    (with-output-to-file (build-path dir "Brief.md") (lambda () (display "keep me")))
    (parameterize ([ask-import-path (lambda () docx)])
      (run-command 'import-word))
    (check-equal? (file->string (build-path dir "Brief.md")) "keep me" "the existing note is untouched")
    (check-true (file-exists? (build-path dir "Brief 2.md")))
    (check-true (regexp-match? #rx"# Brief" (send (current-buffer) get-text)))))

(test-case "the import target never overwrites (pure; no pandoc needed)"
  (define in (build-path dir "Memo.docx"))
  (check-equal? (import-target in) (build-path dir "Memo.md"))
  (with-output-to-file (build-path dir "Memo.md") #:exists 'truncate (lambda () (display "x")))
  (check-equal? (import-target in) (build-path dir "Memo 2.md")))

(test-case "import accepts tracked changes and leaves out comments, stated in the arguments"
  (define args (pandoc-import-args (string->path "a.docx") (string->path "a.md") (string->path "a_files")))
  (check-not-false (member "--track-changes=accept" args))
  (check-not-false (member "--extract-media=a_files" args)))

(test-case "the Word template is passed only when it exists"
  (define t (build-path dir "firm.docx"))
  (with-output-to-file t #:exists 'truncate (lambda () (display "x")))
  (check-not-false (member (string-append "--reference-doc=" (path->string t))
                           (pandoc-export-args (string->path "o.docx") (path->string t))))
  (check-false (for/or ([a (pandoc-export-args (string->path "o.docx") "/no/such.docx")]) (string-prefix? a "--reference-doc"))))

(test-case "without pandoc the commands are greyed out, and the hint says how to install it"
  (parameterize ([pandoc-candidates '()])
    (reset-pandoc!)
    (check-false (command-enabled? (find-command 'export-word)))
    (check-false (command-enabled? (find-command 'import-word)))
    (define-values (ok? err) (export-docx! "x" (build-path dir "x.docx")))
    (check-false ok?)
    (check-true (regexp-match? #rx"brew install pandoc" err)))
  (reset-pandoc!))
