#lang racket/base
;; New Note (#276 lib-new-note): Cmd+N creates "Untitled N.md" on disk in the Library folder
;; and opens it in Markdown, so it gets the prose look (md-style.rkt's render-markdown!) and is
;; tracked by recents.rkt like any other file. Asks to add a Library folder first if there is
;; none. On the note's first save, if it now starts with a heading and is still named
;; "Untitled N.md", offers to rename the file to match (docs/UI-DESIGN.md S2.1/S7.3).
;;
;; The old New Document behavior (an empty, mode-less tab) moves to Tools > New Code File…,
;; keeping its command symbol `new-document` (rackmac/commands.rkt) so nothing that refers to
;; it by name breaks; this module only changes what Cmd+N does.
(require racket/class racket/gui/base racket/string racket/list racket/path racket/file
         "folders.rkt" "../command.rkt" "../editor.rkt" "../hook.rkt" "../owner.rkt")
(provide confirm-add-folder-first? confirm-rename-to-heading? next-untitled-path
         first-heading-title sanitize-note-filename)

;; "New Note needs a Library folder. Add one now?" -- a parameter (docs/DEVELOPMENT.md: dialogs
;; that ask the user something are parameters) so tests answer without the native dialog.
(define confirm-add-folder-first?
  (make-parameter
   (lambda ()
     (eq? 1 (message-box/custom "Rackmac" "New Note needs a Library folder. Add one now?"
                                "Add Folder…" "Cancel" #f (ui-parent) '(default=1) 2)))))

;; Offered once, right after the note's first save, when it now starts with a heading and
;; still carries its "Untitled N.md" name; default is to rename, as the note's own words are a
;; better name than a counter.
(define confirm-rename-to-heading?
  (make-parameter
   (lambda (old-name new-name)
     (eq? 1 (message-box/custom "Rackmac" (format "Name this note \"~a\" instead of \"~a\"?" new-name old-name)
                                "Rename" "Keep This Name" #f (ui-parent) '(default=1) 2)))))

;; The smallest N whose "Untitled N.md" is free in `folder`: not already a file there, and not
;; already the name of another open (unsaved or saved) tab.
(define (open-buffer-names)
  (for/list ([b (in-list (all-buffers))]) (send b get-name)))

(define (next-untitled-path folder)
  (define names (open-buffer-names))
  (let loop ([n 1])
    (define name (format "Untitled ~a.md" n))
    (define p (build-path folder name))
    (if (or (file-exists? p) (member name names)) (loop (add1 n)) p)))

;; The first ATX heading (# .. ######) among the first 40 lines, trimmed of its markers -- good
;; enough to catch "the first heading" a person just typed, without scanning a whole large note.
(define (first-heading-title b)
  (define end (min (send b last-position) 4000))
  (define text (send b get-text 0 end))
  (for/or ([line (in-list (string-split text "\n"))] [_ (in-range 40)])
    (define m (regexp-match #px"^#{1,6}[ \t]+(.+?)[ \t]*$" line))
    (and m (let ([t (string-trim (cadr m))]) (and (not (string=? t "")) t)))))

;; Filesystem-hostile characters become spaces; #f if nothing usable is left.
(define (sanitize-note-filename s)
  (define cleaned (string-trim (regexp-replace* #px"[/\\\\:*?\"<>|]" s " ")))
  (define collapsed (string-trim (regexp-replace* #px"\\s+" cleaned " ")))
  (and (not (string=? collapsed "")) collapsed))

(define (unique-sibling-path dir base ext)
  (let loop ([n 0])
    (define name (if (= n 0) (format "~a.~a" base ext) (format "~a ~a.~a" base n ext)))
    (define p (build-path dir name))
    (if (or (file-exists? p) (directory-exists? p)) (loop (add1 n)) p)))

;; Buffers eligible for the rename offer -- only ones New Note itself created, and only up to
;; their first save (removed from the table either way, so it is never offered twice).
(define pending-rename (make-weak-hasheq))

(define (maybe-offer-rename! b)
  (when (hash-ref pending-rename b #f)
    (hash-remove! pending-rename b)
    (define p (send b get-path))
    (when (and p (regexp-match? #px"^Untitled [0-9]+\\.md$" (path->string (file-name-from-path p))))
      (define heading (first-heading-title b))
      (define proposed (and heading (sanitize-note-filename heading)))
      (when proposed
        (define-values (dir old-name dir?) (split-path p))
        (define new-path (unique-sibling-path dir proposed "md"))
        (when ((confirm-rename-to-heading?) (path->string old-name) (path->string (file-name-from-path new-path)))
          (with-handlers ([exn:fail? (lambda (e) (report-error! 'new-note e))])
            (rename-file-or-directory p new-path)
            (send b set-path! new-path)
            (send b set-name! (path->string (file-name-from-path new-path)))))))))

;; Priority above the default (0) so this runs, and any rename lands, before recents.rkt's own
;; 'after-save hook records the path -- otherwise Recent would keep the old "Untitled N.md" name.
(add-hook! 'after-save maybe-offer-rename! #:priority 10)

(define-command (new-note)
  #:icon "new"
  #:aliases ("new note" "new markdown note" "new document")
  #:help "Create a new note in your Library."
  #:title "New Note" #:menu "File" #:menu-order 10 #:keys ("Mod-n" "Mod-t")
  #:doc "Create \"Untitled N.md\" in your first Library folder (offering to add one if you have none) and open it."
  (define folder
    (or (selected-library-folder)
        (and ((confirm-add-folder-first?))
             (begin (run-command/safe 'add-library-folder) (selected-library-folder)))))
  (cond
    [(not folder) (message "New Note needs a Library folder.")]
    [else
     (define p (next-untitled-path folder))
     (with-handlers ([exn:fail? (lambda (e) (report-error! 'new-note e) (message "Could not create a new note: ~a" (exn-message e)))])
       (display-to-file "" p #:exists 'error)
       (define b (open-file! p))
       (hash-set! pending-rename b #t)
       (set-current-buffer! b))]))
