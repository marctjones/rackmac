#lang racket/base
;; New Note (#276 lib-new-note): Cmd+N makes "Untitled N.md" on disk in the Library folder,
;; opens it in Markdown, asks to add a folder first if there is none, and offers to rename it
;; to its first heading after the first save.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/file racket/class racket/path racket/list
         "../rackmac/library/folders.rkt" "../rackmac/library/new-note.rkt"
         "../rackmac/settings.rkt" "../rackmac/editor.rkt" "../rackmac/command.rkt"
         "../rackmac/platform.rkt")

(define dir (make-temporary-file "rackmac-newnote~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))
(setting-set! 'library-folders '())

;; Each test gets its own fresh Library folder, so file names never collide across test cases.
(define lib-counter 0)
(define (fresh-lib!)
  (set! lib-counter (add1 lib-counter))
  (define d (build-path dir (format "Notes~a" lib-counter)))
  (make-directory* d)
  (setting-set! 'library-folders '())
  (add-library-folder-path! d)
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  d)

(test-case "New Note creates Untitled N.md on disk in the Library folder, opened as Markdown"
  (define lib (fresh-lib!))
  (run-command 'new-note)
  (define b (current-buffer))
  (check-equal? (send b get-name) "Untitled 1.md")
  (check-eq? (send b get-mode) 'markdown-mode)
  (check-true (file-exists? (build-path lib "Untitled 1.md"))))

(test-case "a second New Note picks the next free number"
  (define lib (fresh-lib!))
  (display-to-file "" (build-path lib "Untitled 1.md") #:exists 'truncate)
  (run-command 'new-note)
  (check-equal? (send (current-buffer) get-name) "Untitled 2.md"))

(test-case "New Note also skips a number already used by an open (unsaved) tab"
  (fresh-lib!)
  (new-buffer! "Untitled 1.md")
  (run-command 'new-note)
  (check-equal? (send (current-buffer) get-name) "Untitled 2.md"))

(test-case "with no Library folder, New Note offers to add one; declining cancels it"
  (define lib (fresh-lib!))
  (setting-set! 'library-folders '())
  (parameterize ([confirm-add-folder-first? (lambda () #f)])
    (run-command 'new-note))
  (check-false (regexp-match? #rx"^Untitled" (send (current-buffer) get-name)))
  (check-equal? (directory-list lib) '() "no file was created"))

(test-case "accepting the offer to add a folder lets New Note proceed"
  (fresh-lib!)
  (setting-set! 'library-folders '())
  (define picked (build-path dir "PickedFolder"))
  (make-directory* picked)
  (parameterize ([confirm-add-folder-first? (lambda () #t)]
                 [pick-folder-directory (lambda () picked)])
    (run-command 'new-note))
  (check-equal? (send (current-buffer) get-name) "Untitled 1.md")
  (check-true (file-exists? (build-path picked "Untitled 1.md"))))

;; ---- first-save heading rename ------------------------------------------------------------

(test-case "the first save proposes the first heading as the file name"
  (define lib (fresh-lib!))
  (run-command 'new-note)
  (define b (current-buffer))
  (send b insert "# My Great Note\n\nSome text.")
  (parameterize ([confirm-rename-to-heading? (lambda (old new) (check-equal? new "My Great Note.md") #t)])
    (send b save-to! (send b get-path)))
  (check-equal? (send b get-name) "My Great Note.md")
  (check-true (file-exists? (build-path lib "My Great Note.md")))
  (check-false (file-exists? (build-path lib "Untitled 1.md"))))

(test-case "declining the rename keeps the original name"
  (fresh-lib!)
  (run-command 'new-note)
  (define b (current-buffer))
  (send b insert "# Another Note\n")
  (parameterize ([confirm-rename-to-heading? (lambda (old new) #f)])
    (send b save-to! (send b get-path)))
  (check-equal? (send b get-name) "Untitled 1.md"))

(test-case "no heading yet: nothing is proposed, and saving again never asks a second time"
  (fresh-lib!)
  (run-command 'new-note)
  (define b (current-buffer))
  (send b insert "just a paragraph, no heading")
  (define asked? #f)
  (parameterize ([confirm-rename-to-heading? (lambda (old new) (set! asked? #t) #t)])
    (send b save-to! (send b get-path)))
  (check-false asked?)
  (check-equal? (send b get-name) "Untitled 1.md")
  ;; Even if a heading shows up later, the offer was already used on the first save.
  (send b insert "\n# Late Heading" (send b last-position))
  (parameterize ([confirm-rename-to-heading? (lambda (old new) (set! asked? #t) #t)])
    (send b save-to! (send b get-path)))
  (check-false asked?)
  (check-equal? (send b get-name) "Untitled 1.md"))

(test-case "a document not made by New Note is never offered a rename"
  (define lib (fresh-lib!))
  (define p (build-path lib "Untitled 1.md"))
  (display-to-file "# Heading" p #:exists 'truncate)
  (define b (open-file! p))
  (define asked? #f)
  (parameterize ([confirm-rename-to-heading? (lambda (old new) (set! asked? #t) #t)])
    (send b save-to! p))
  (check-false asked?)
  (check-equal? (send b get-name) "Untitled 1.md"))

(test-case "sanitize-note-filename strips characters a filesystem would reject"
  (check-equal? (sanitize-note-filename "Roe v. Doe: Motion/Order?") "Roe v. Doe Motion Order")
  (check-false (sanitize-note-filename "   ")))

(test-case "first-heading-title finds the first ATX heading, ignoring plain text before it"
  (fresh-lib!)
  (run-command 'new-note)
  (define b (current-buffer))
  (send b insert "Not a heading\n## Second Try\nmore text")
  (check-equal? (first-heading-title b) "Second Try"))
