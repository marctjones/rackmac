#lang racket/base
;; Built-in commands. They use exactly the public `define-command` that init files use.
;; Bindings follow current desktop conventions, with per-platform layers where macOS
;; and Windows differ (#:keys/mac, #:keys/windows).
(require racket/class racket/gui/base racket/list racket/string racket/file racket/path
         "command.rkt" "keymap.rkt" "mode.rkt" "hook.rkt" "editor.rkt" "input.rkt"
         "theme.rkt" "picker.rkt" "frame.rkt" "eval.rkt" "platform.rkt" "modes.rkt" "owner.rkt" "fuzzy.rkt" "glossary.rkt")
(provide save-buffer! confirm-quit? palette-items palette-matches command-description
         confirm-discard-changes
         builtin-command-names)

(define (t) (current-buffer))
(define (ext?) (extending-selection?))

(define-syntax-rule (edit-group b body ...)
  (let ([buf b])
    (send buf begin-edit-sequence)
    (begin0 (let () body ...) (send buf end-edit-sequence))))

;; Paragraph (line) range covered by the selection; a selection that ends at the very
;; start of a line does not count that line.
(define (selected-lines b)
  (define s (send b get-start-position))
  (define e (send b get-end-position))
  (define e* (if (and (> e s) (= e (send b paragraph-start-position (send b position-paragraph e)))) (sub1 e) e))
  (values (send b position-paragraph s) (send b position-paragraph e*)))

(define (line-text b p)
  (send b get-text (send b paragraph-start-position p) (send b paragraph-end-position p)))

;; ---- files ---------------------------------------------------------------

(define (ask-save b)     ; -> 'save 'discard 'cancel
  (case (message-box/custom "Rackmac" (format "Save changes to ~a?" (send b get-name))
                            "Save" "Don't Save" "Cancel" (ui-parent) '(caution default=1) 3)
    [(1) 'save] [(2) 'discard] [else 'cancel]))

(define (save-buffer-as! b)
  (define dir (and (send b get-path) (let-values ([(base n d?) (split-path (send b get-path))]) base)))
  (define p (put-file "Save as" (ui-parent) dir (send b get-name)))
  (and p
       (begin (send b save-to! p)
              (send b set-mode! (or (mode-for-path p) (send b get-mode)))
              (message "Saved ~a" p)
              #t)))

(define (save-buffer! b)
  (cond [(send b get-path)
         (send b save-to! (send b get-path))
         (message "Saved ~a" (path->string (send b get-path)))
         #t]
        [else (save-buffer-as! b)]))

;; #t when it is fine to discard/close `b` (saving first if the user asks).
(define (confirm-close-buffer? b)
  (or (not (send b is-modified?))
      (case (ask-save b)
        [(save) (save-buffer! b)]
        [(discard) #t]
        [else #f])))

(define (confirm-quit?)
  (for/and ([b (in-list (unsaved-buffers))])
    (set-current-buffer! b)
    (confirm-close-buffer? b)))

(define-command (new-buffer)
  #:aliases ("new document" "new file" "create buffer" "new tab")
  #:help "Start a new empty document in a new tab."
  #:title "New Document" #:menu "File" #:menu-order 10 #:keys ("Mod-n" "Mod-t")
  #:doc "Create an empty buffer."
  (set-current-buffer! (new-buffer! "untitled")))

(define-command (open-file)
  #:aliases ("find-file" "open document" "visit file" "open file")
  #:help "Choose a file on your computer to open in a tab."
  #:title "Open…" #:menu "File" #:menu-order 11 #:keys ("Mod-o")
  #:doc "Choose one or more files to open."
  (define ps (get-file-list "Open" (ui-parent)))
  (when ps
    (for ([p ps]) (set-current-buffer! (open-file! p)))))

(define (project-root)
  (define b (t))
  (define start (if (send b get-path)
                    (let-values ([(base n d?) (split-path (send b get-path))]) base)
                    (current-directory)))
  (or (let loop ([d (simplify-path start)])
        (cond [(directory-exists? (build-path d ".git")) d]
              [else (define-values (base n dir?) (split-path d))
                    (and (path? base) (loop base))]))
      start))

(define skipped-dirs '(".git" "node_modules" "compiled" ".svn" ".hg" "__pycache__"))

(define-command (quick-open)
  #:aliases ("find file in project" "projectile" "fuzzy open" "go to file")
  #:help "Type part of a file name to open it from the current project."
  #:title "Quick Open…" #:menu "File" #:menu-order 12 #:keys ("Mod-Shift-o")
  #:doc "Fuzzy-find a file under the project root (the enclosing git repo, or the file's folder)."
  (define root (project-root))
  (cond
    [(member (path->string (simplify-path root)) (list "/" (path->string (find-system-path 'home-dir))))
     (message "Quick Open needs a project folder: open a file inside one first.")]
    [else
     (define started (current-inexact-milliseconds))
     (define files
       (for/list ([p (in-directory root (lambda (d) (not (member (path->string (file-name-from-path d)) skipped-dirs))))]
                  [_ (in-range 20000)]
                  #:when (and (file-exists? p)
                              (< (- (current-inexact-milliseconds) started) 2500)))
         (path->string (find-relative-path root p))))
     (define choice (pick (format "Quick Open — ~a" root) (for/list ([f files]) (list f "" f))))
     (when choice (set-current-buffer! (open-file! (build-path root choice))))]))

(define-command (save)
  #:aliases ("save-buffer" "write file" "save document")
  #:help "Save the document to its file (asks for a name the first time)."
  #:title "Save" #:menu "File" #:menu-order 20 #:keys ("Mod-s")
  #:doc "Write the buffer to its file, asking for a name if it has none."
  (save-buffer! (t)))

(define-command (save-as)
  #:aliases ("write-file" "save a copy" "rename file")
  #:help "Save the document under a new name or location."
  #:title "Save As…" #:menu "File" #:menu-order 21 #:keys ("Mod-Shift-s") #:keys/windows ("F12")
  (save-buffer-as! (t)))

(define-command (close-buffer)
  #:aliases ("kill-buffer" "close document" "close file")
  #:help "Close this tab, asking to save unsaved changes first."
  #:title "Close Tab" #:menu "File" #:menu-order 22 #:keys ("Mod-w") #:keys/windows ("Ctrl-F4")
  #:doc "Close the current buffer, offering to save unsaved changes."
  (define b (t))
  (when (confirm-close-buffer? b) (kill-buffer! b)))

(define (cycle-buffer delta)
  (define bs (visible-buffers))
  (define i (or (index-of bs (t)) 0))
  (set-current-buffer! (list-ref bs (modulo (+ i delta) (length bs)))))

(define-command (next-buffer)
  #:aliases ("next-buffer" "switch tab" "other-buffer" "next document")
  #:help "Switch to the next tab."
  #:title "Next Tab" #:menu "File" #:menu-order 30
  #:keys ("Ctrl-Tab") #:keys/mac ("Mod-Alt-Right" "Mod-Shift-]") #:keys/windows ("Ctrl-PageDown")
  (cycle-buffer 1))

(define-command (previous-buffer)
  #:aliases ("previous-buffer" "prev tab" "previous document")
  #:help "Switch to the previous tab."
  #:title "Previous Tab" #:menu "File" #:menu-order 31
  #:keys ("Ctrl-Shift-Tab") #:keys/mac ("Mod-Alt-Left" "Mod-Shift-[") #:keys/windows ("Ctrl-PageUp")
  (cycle-buffer -1))

;; Asks before throwing away unsaved edits. A parameter so tests (and scripts) can answer.
(define confirm-discard-changes
  (make-parameter
   (lambda (b)
     (eq? 1 (message-box/custom "Rackmac"
                                (format "Discard your changes to ~a and reload it from disk?" (send b get-name))
                                "Reload" "Cancel" #f (ui-parent) '(caution default=2) 2)))))

(define-command (reload-from-disk)
  #:aliases ("revert-buffer" "revert" "reload file" "discard changes")
  #:help "Read the document again from its file, discarding unsaved changes."
  #:title "Reload from Disk" #:menu "File" #:menu-order 24
  (define b (t))
  (cond
    [(not (send b get-path)) (message "~a has not been saved to a file yet." (send b get-name))]
    [(not (file-exists? (send b get-path))) (message "~a no longer exists on disk." (send b get-path))]
    [(and (send b is-modified?) (not ((confirm-discard-changes) b))) (void)]
    [else (reload-buffer! b) (message "Reloaded ~a" (send b get-name))]))

(define-command (save-all)
  #:aliases ("save-some-buffers" "save everything")
  #:help "Save every open document that has unsaved changes."
  #:title "Save All" #:menu "File" #:menu-order 26 #:keys/mac ("Mod-Alt-s")
  (define bs (unsaved-buffers))
  (define saved (for/sum ([b bs]) (if (save-buffer! b) 1 0)))
  (message (if (null? bs) "Nothing to save." (format "Saved ~a of ~a document~a." saved (length bs) (if (= 1 (length bs)) "" "s")))))

(define-command (reopen-closed-tab)
  #:aliases ("undo close tab" "restore tab" "reopen tab")
  #:help "Open the tab you closed most recently again."
  #:title "Reopen Closed Tab" #:menu "File" #:menu-order 23 #:keys ("Mod-Shift-t")
  (unless (reopen-closed-tab!) (message "No closed tabs to reopen.")))

;; Cmd/Ctrl+1 ... 8 go to that tab, and 9 to the last one, as in Chrome.
(for ([n (in-range 1 10)])
  (define name (string->symbol (format "go-to-tab-~a" n)))
  (register-command! name
                     (lambda ()
                       (define bs (visible-buffers))
                       (when (pair? bs)
                         (set-current-buffer! (if (= n 9) (last bs) (list-ref bs (min (sub1 n) (sub1 (length bs))))))))
                     #:title (if (= n 9) "Go to Last Tab" (format "Go to Tab ~a" n))
                     #:aliases (list (format "tab ~a" n) "switch tab")
                     #:help (if (= n 9) "Switch to the last tab." (format "Switch to tab number ~a." n))
                     #:keys (list (format "Mod-~a" n))))

(define-command (print-document)
  #:aliases ("print" "print-buffer" "printout")
  #:help "Print the document."
  #:title "Print…" #:menu "File" #:menu-order 25 #:keys ("Mod-p")
  (send (t) print #t #t 'standard (ui-parent)))

(define init-template #<<TEMPLATE
#lang rackmac
;; Rackmac init file. `#lang rackmac` is racket/base plus the whole extension API, so
;; nothing needs requiring. This file loads at startup and on "Reload Init File"; anything
;; it registers is unloaded and replaced when you reload. Extra files in the `ext/` folder
;; next to this one are loaded after it.
(require racket/date)

(extension-info #:name "My init" #:requires-api 1
                #:doc "Personal customizations.")

;; A command: shows up in the palette (Mod-Shift-P) and can be given a key.
;; Key strings are checked when this file is compiled, so a typo is reported right here.
(define-command (insert-date)
  #:title "Insert Date"
  #:doc "Insert today's date at the cursor."
  (insert-text (date->string (current-date) #t)))

;; (bind-key! "Mod-Shift-i" 'insert-date)

;; Hooks run when things happen:
;; (add-hook! 'after-save (lambda (buffer) (message "saved ~a" (send buffer get-name))))
TEMPLATE
  )

(define-command (open-init-file)
  #:aliases ("init file" "init.el" "open init file" "config" "settings file" "customize")
  #:help "Open the file that customizes Rackmac with Racket code."
  #:title "Customize with Code" #:menu "File" #:menu-order 40 #:keys ("Mod-,")
  #:doc "Open (creating from a template if needed) the init file that customizes Rackmac."
  (define p (init-file-path))
  (unless (file-exists? p)
    (make-directory* (config-dir))
    (display-to-file init-template p))
  (set-current-buffer! (open-file! p)))

(define-command (reload-init)
  #:aliases ("reload init" "reload init file" "load-file init" "reload config")
  #:help "Run your customization files again, replacing what they registered before."
  #:title "Reload Extensions" #:menu "File" #:menu-order 41
  (load-init!))

(define-command (list-extensions)
  #:aliases ("list packages" "installed extensions" "add-ons" "list-packages")
  #:help "Show which customization files are loaded and what each one added."
  #:title "List Extensions" #:menu "Help" #:menu-order 13
  #:doc "Show the loaded extension files and what each registered."
  (define exts (loaded-extensions))
  (show-text-buffer!
   "Extensions"
   (if (null? exts)
       (format "No extensions loaded.\n\nPut Racket files in ~a (init.rkt) or its ext/ folder.\n"
               (path->string (config-dir)))
       (string-append
        (string-join
         (for/list ([e (in-list exts)])
           (define info (extension-meta e))
           (format "~a~a\n  file: ~a\n  requires API: ~a\n  registered: ~a\n~a"
                   (or (hash-ref info 'name #f) (extension-name e))
                   (let ([v (hash-ref info 'version #f)]) (if v (format " ~a" v) ""))
                   (extension-path e)
                   (or (hash-ref info 'requires-api #f) "unspecified")
                   (let ([c (extension-counts e)])
                     (format "~a command(s), ~a key binding(s), ~a hook(s), ~a mode(s)"
                             (hash-ref c 'command 0) (hash-ref c 'key 0)
                             (hash-ref c 'hook 0) (hash-ref c 'mode 0)))
                   (let ([d (hash-ref info 'doc "")]) (if (string=? d "") "" (format "  ~a\n" d)))))
         "\n")
        "\n"))))

(define-command (quit)
  #:aliases ("exit" "kill-emacs" "close app" "quit application")
  #:help "Close Rackmac, asking to save unsaved changes first."
  #:title "Quit" #:menu "File" #:menu-order 50 #:keys/mac ("Mod-q") #:keys/windows ("Alt-F4")
  (when (confirm-quit?) (exit 0)))

;; ---- editing -------------------------------------------------------------

(define-command (undo)
  #:aliases ("undo-tree" "history" "revert change")
  #:help "Undo the last change."
  #:title "Undo" #:menu "Edit" #:menu-order 10 #:keys ("Mod-z")
  (send (t) undo))

(define-command (redo)
  #:aliases ("undo-redo" "redo change")
  #:help "Redo a change you undid."
  #:title "Redo" #:menu "Edit" #:menu-order 11
  #:keys/mac ("Mod-Shift-z") #:keys/windows ("Ctrl-y" "Ctrl-Shift-z")
  (send (t) redo))

(define-command (cut)
  #:aliases ("kill-region" "kill" "cut selection")
  #:help "Remove the selected text and put it on the clipboard."
  #:title "Cut" #:menu "Edit" #:menu-order 20 #:keys ("Mod-x")
  (send (t) cut))
(define-command (copy)
  #:aliases ("kill-ring-save" "copy selection")
  #:help "Copy the selected text to the clipboard."
  #:title "Copy" #:menu "Edit" #:menu-order 21 #:keys ("Mod-c")
  (send (t) copy))
(define-command (paste)
  #:aliases ("yank" "paste clipboard")
  #:help "Insert the clipboard contents at the cursor."
  #:title "Paste" #:menu "Edit" #:menu-order 22 #:keys ("Mod-v")
  (send (t) paste))
(define-command (select-all)
  #:aliases ("mark-whole-buffer" "select everything")
  #:help "Select the whole document."
  #:title "Select All" #:menu "Edit" #:menu-order 23 #:keys ("Mod-a")
  (send (t) set-position 0 (send (t) last-position)))
(define-command (select-line)
  #:aliases ("mark line" "select current line")
  #:help "Select the current line."
  #:title "Select Line" #:menu "Edit" #:menu-order 24 #:keys ("Mod-l")
  (define b (t))
  (define-values (p1 p2) (selected-lines b))
  (send b set-position (send b paragraph-start-position p1)
        (min (send b last-position) (add1 (send b paragraph-end-position p2)))))

(define-command (find)
  #:aliases ("isearch-forward" "search" "find in document")
  #:help "Search for text in this document."
  #:title "Find…" #:menu "Edit" #:menu-order 30 #:keys ("Mod-f")
  (show-find-bar! #f))
(define-command (replace)
  #:aliases ("query-replace" "replace-string" "find and replace" "substitute")
  #:help "Find text and replace it with something else."
  #:title "Find and Replace…" #:menu "Edit" #:menu-order 31
  #:keys/mac ("Mod-Alt-f") #:keys/windows ("Ctrl-h")
  (show-find-bar! #t))
(define-command (find-next)
  #:aliases ("isearch-repeat-forward" "next match" "search again")
  #:help "Jump to the next match."
  #:title "Find Next" #:menu "Edit" #:menu-order 32 #:keys/mac ("Mod-g") #:keys/windows ("F3")
  (find! 'forward))
(define-command (find-previous)
  #:aliases ("isearch-repeat-backward" "previous match")
  #:help "Jump to the previous match."
  #:title "Find Previous" #:menu "Edit" #:menu-order 33
  #:keys/mac ("Mod-Shift-g") #:keys/windows ("Shift-F3")
  (find! 'backward))

(define-command (goto-line)
  #:aliases ("goto-line" "jump to line" "line number")
  #:help "Move the cursor to a line number."
  #:title "Go to Line…" #:menu "Edit" #:menu-order 34 #:keys ("Ctrl-g")
  (define s (get-text-from-user "Go to line" "Line number:" (ui-parent)))
  (define n (and s (string->number (string-trim s))))
  (when (and n (exact-positive-integer? n))
    (goto-line! n)))

;; Lines --------------------------------------------------------------------

(define-command (toggle-comment)
  #:aliases ("comment-dwim" "comment-region" "uncomment")
  #:help "Turn the selected lines into comments, or back into code."
  #:title "Toggle Comment" #:menu "Edit" #:menu-order 40 #:keys ("Mod-/")
  #:doc "Comment or uncomment the selected lines using the mode's comment syntax."
  (define b (t))
  (define cs (send b local-ref 'comment-start #f))
  (cond
    [(not cs) (message "No comment syntax for ~a" (send b get-mode))]
    [else
     (define-values (p1 p2) (selected-lines b))
     (define lines (for/list ([p (in-range p1 (add1 p2))]) p))
     (define nonblank (filter (lambda (p) (not (string=? (string-trim (line-text b p)) ""))) lines))
     (define all-commented?
       (and (pair? nonblank)
            (for/and ([p nonblank]) (string-prefix? (string-trim (line-text b p) #:right? #f) cs))))
     (define indent
       (if (null? nonblank) 0
           (apply min (for/list ([p nonblank])
                        (define txt (line-text b p))
                        (- (string-length txt) (string-length (string-trim txt #:right? #f)))))))
     (edit-group b
       (for ([p (in-list (reverse lines))])       ; bottom-up so earlier positions stay valid
         (define start (send b paragraph-start-position p))
         (define txt (line-text b p))
         (cond
           [(string=? (string-trim txt) "") (void)]      ; leave blank lines alone
           [all-commented?
            (define lead (- (string-length txt) (string-length (string-trim txt #:right? #f))))
            (define after (+ start lead (string-length cs)))
            (define space? (and (< after (send b paragraph-end-position p))
                                (string=? (send b get-text after (add1 after)) " ")))
            (send b delete (+ start lead) (if space? (add1 after) after))]
           [else (send b insert (string-append cs " ") (+ start indent))])))]))

(define-command (duplicate-line)
  #:aliases ("copy line" "duplicate")
  #:help "Copy the current line (or the selected lines) just below."
  #:title "Duplicate Line" #:menu "Edit" #:menu-order 41 #:keys ("Mod-Shift-d")
  (define b (t))
  (define-values (p1 p2) (selected-lines b))
  (define a (send b paragraph-start-position p1))
  (define e (send b paragraph-end-position p2))
  (define block (send b get-text a e))
  (edit-group b (send b insert (string-append "\n" block) e))
  (send b set-position (+ e 1)))

(define-command (delete-line)
  #:aliases ("kill-whole-line" "kill line" "remove line")
  #:help "Delete the current line (or the selected lines)."
  #:title "Delete Line" #:menu "Edit" #:menu-order 42 #:keys ("Mod-Shift-k")
  (define b (t))
  (define-values (p1 p2) (selected-lines b))
  (define last (send b last-paragraph))
  (define a (send b paragraph-start-position p1))
  (define e (send b paragraph-end-position p2))
  (edit-group b
    (cond [(< p2 last) (send b delete a (add1 e))]
          [(> p1 0) (send b delete (sub1 a) e)]
          [else (send b delete a e)])))

(define (move-lines! dir)
  (define b (t))
  (define-values (p1 p2) (selected-lines b))
  (define last (send b last-paragraph))
  (define s (send b get-start-position))
  (define e (send b get-end-position))
  (define a (send b paragraph-start-position p1))
  (define z (send b paragraph-end-position p2))
  (define block (send b get-text a z))
  (cond
    [(and (= dir 1) (< p2 last))
     (define c (send b paragraph-end-position (add1 p2)))
     (define next (send b get-text (add1 z) c))
     (edit-group b
       (send b delete a c)
       (send b insert (string-append next "\n" block) a))
     (define shift (add1 (string-length next)))
     (send b set-position (+ s shift) (+ e shift))]
    [(and (= dir -1) (> p1 0))
     (define ps (send b paragraph-start-position (sub1 p1)))
     (define prev (send b get-text ps (sub1 a)))
     (edit-group b
       (send b delete ps z)
       (send b insert (string-append block "\n" prev) ps))
     (define shift (add1 (string-length prev)))
     (send b set-position (- s shift) (- e shift))]))

(define-command (move-line-up)
  #:aliases ("transpose-lines" "swap line up")
  #:help "Move the current line up by one."
  #:title "Move Line Up" #:menu "Edit" #:menu-order 43 #:keys ("Alt-Up")
  (move-lines! -1))
(define-command (move-line-down)
  #:aliases ("transpose-lines" "swap line down")
  #:help "Move the current line down by one."
  #:title "Move Line Down" #:menu "Edit" #:menu-order 44 #:keys ("Alt-Down")
  (move-lines! 1))

(define (indent-string b) (send b local-ref 'indent-string "  "))

(define-command (indent-or-insert)
  #:aliases ("tab" "insert tab" "indent")
  #:help "Indent the selected lines, or insert an indent at the cursor."
  #:title "Insert Indent" #:keys ("Tab")
  #:doc "Tab: indent the selected lines, or insert the mode's indent at the cursor."
  (define b (t))
  (define-values (p1 p2) (selected-lines b))
  (if (> p2 p1)
      (indent-selected-lines!)
      (send b insert (indent-string b))))

(define (indent-selected-lines!)
  (define b (t))
  (define-values (p1 p2) (selected-lines b))
  (edit-group b
    (for ([p (in-range p2 (sub1 p1) -1)])
      (unless (string=? (line-text b p) "")
        (send b insert (indent-string b) (send b paragraph-start-position p))))))

(define-command (indent-lines)
  #:aliases ("indent-rigidly" "indent region")
  #:help "Indent the selected lines."
  #:title "Indent Lines" #:menu "Edit" #:menu-order 45 #:keys ("Mod-]")
  (indent-selected-lines!))

(define-command (outdent-lines)
  #:aliases ("unindent" "dedent")
  #:help "Remove one level of indent from the selected lines."
  #:title "Outdent Lines" #:menu "Edit" #:menu-order 46 #:keys ("Mod-[" "Shift-Tab")
  (define b (t))
  (define ind (indent-string b))
  (define-values (p1 p2) (selected-lines b))
  (edit-group b
    (for ([p (in-range p2 (sub1 p1) -1)])
      (define start (send b paragraph-start-position p))
      (define txt (line-text b p))
      (cond [(string-prefix? txt ind) (send b delete start (+ start (string-length ind)))]
            [(string-prefix? txt "\t") (send b delete start (add1 start))]
            [else
             (define n (min (string-length ind) (- (string-length txt) (string-length (string-trim txt #:right? #f)))))
             (when (> n 0) (send b delete start (+ start n)))]))))

(define-command (newline-and-indent)
  #:aliases ("newline" "return" "enter")
  #:help "Start a new line that keeps the current indentation."
  #:title "Newline and Indent" #:keys ("Enter")
  #:doc "Insert a newline that keeps the current line's indentation."
  (define b (t))
  (define p (send b position-paragraph (send b get-start-position)))
  (define txt (line-text b p))
  (define lead (car (regexp-match #px"^[ \t]*" txt)))
  (edit-group b
    (send b insert (string-append "\n" lead) (send b get-start-position) (send b get-end-position))))

;; Motion (Shift extends the selection automatically; see input.rkt) ----------

(define-command (word-left)
  #:aliases ("backward-word" "previous word")
  #:help "Move the cursor to the start of the previous word."
  #:title "Word Left" #:keys/mac ("Alt-Left") #:keys/windows ("Ctrl-Left")
  (send (t) move-position 'left (ext?) 'word))
(define-command (word-right)
  #:aliases ("forward-word" "next word")
  #:help "Move the cursor to the end of the next word."
  #:title "Word Right" #:keys/mac ("Alt-Right") #:keys/windows ("Ctrl-Right")
  (send (t) move-position 'right (ext?) 'word))
(define-command (line-start)
  #:aliases ("beginning-of-line" "home")
  #:help "Move the cursor to the start of the line."
  #:title "Line Start" #:keys ("Home") #:keys/mac ("Mod-Left")
  (send (t) move-position 'left (ext?) 'line))
(define-command (line-end)
  #:aliases ("end-of-line" "end")
  #:help "Move the cursor to the end of the line."
  #:title "Line End" #:keys ("End") #:keys/mac ("Mod-Right")
  (send (t) move-position 'right (ext?) 'line))
(define-command (doc-start)
  #:aliases ("beginning-of-buffer" "top of document")
  #:help "Move the cursor to the start of the document."
  #:title "Document Start" #:keys/mac ("Mod-Up") #:keys/windows ("Ctrl-Home")
  (define b (t))
  (if (ext?) (send b set-position 0 (send b get-end-position)) (send b set-position 0)))
(define-command (doc-end)
  #:aliases ("end-of-buffer" "bottom of document")
  #:help "Move the cursor to the end of the document."
  #:title "Document End" #:keys/mac ("Mod-Down") #:keys/windows ("Ctrl-End")
  (define b (t))
  (if (ext?)
      (send b set-position (send b get-start-position) (send b last-position))
      (send b set-position (send b last-position))))
(define-command (page-up)
  #:aliases ("scroll-down-command" "previous page")
  #:help "Move up by one screen."
  #:title "Page Up" #:keys ("PageUp")
  (send (t) move-position 'up (ext?) 'page))
(define-command (page-down)
  #:aliases ("scroll-up-command" "next page")
  #:help "Move down by one screen."
  #:title "Page Down" #:keys ("PageDown")
  (send (t) move-position 'down (ext?) 'page))

(define (delete-by! dir kind)
  (define b (t))
  (when (= (send b get-start-position) (send b get-end-position))
    (send b move-position dir #t kind))
  (send b delete))

(define-command (delete-word-back)
  #:aliases ("backward-kill-word")
  #:help "Delete the word before the cursor."
  #:title "Delete Word Back" #:keys/mac ("Alt-Backspace") #:keys/windows ("Ctrl-Backspace")
  (delete-by! 'left 'word))
(define-command (delete-word-forward)
  #:aliases ("kill-word")
  #:help "Delete the word after the cursor."
  #:title "Delete Word Forward" #:keys/mac ("Alt-Delete") #:keys/windows ("Ctrl-Delete")
  (delete-by! 'right 'word))
(define-command (delete-to-line-start)
  #:aliases ("backward-kill-line")
  #:help "Delete from the cursor back to the start of the line."
  #:title "Delete to Line Start" #:keys/mac ("Mod-Backspace")
  (delete-by! 'left 'line))

;; ---- view ----------------------------------------------------------------

(define (restyle!)
  (for ([b (all-buffers)]) (send b rehighlight!))
  (run-hook 'theme-changed))

(define-command (zoom-in)
  #:aliases ("text-scale-increase" "bigger text" "increase font size")
  #:help "Make the text bigger."
  #:title "Zoom In" #:menu "View" #:menu-order 10 #:keys ("Mod-=" "Mod-Shift-=")
  (set-font-size! (add1 font-size)) (run-hook 'theme-changed))
(define-command (zoom-out)
  #:aliases ("text-scale-decrease" "smaller text" "decrease font size")
  #:help "Make the text smaller."
  #:title "Zoom Out" #:menu "View" #:menu-order 11 #:keys ("Mod--")
  (set-font-size! (sub1 font-size)) (run-hook 'theme-changed))
(define-command (zoom-reset)
  #:aliases ("text-scale-adjust" "reset zoom" "default font size")
  #:help "Return the text to its normal size."
  #:title "Actual Size" #:menu "View" #:menu-order 12 #:keys ("Mod-0")
  (set-font-size! (if (mac?) 14 12)) (run-hook 'theme-changed))

(define-command (toggle-word-wrap)
  #:aliases ("visual-line-mode" "truncate-lines" "line wrap")
  #:help "Wrap long lines to fit the window, or let them run off the edge."
  #:title "Toggle Word Wrap" #:menu "View" #:menu-order 20 #:keys/windows ("Alt-z")
  (define b (t))
  (send b auto-wrap (not (send b auto-wrap))))

(define-command (toggle-full-screen)
  #:aliases ("fullscreen" "toggle-frame-fullscreen" "maximize")
  #:help "Fill the whole screen with the window, or return to normal."
  #:title "Toggle Full Screen" #:menu "View" #:menu-order 22
  #:keys/mac ("Ctrl-Mod-f") #:keys/windows ("F11")
  (define f (main-frame))
  (when f (send f fullscreen (not (send f is-fullscreened?)))))

(define-command (toggle-theme)
  #:aliases ("load-theme" "dark mode" "light mode" "appearance")
  #:help "Switch between the dark and light color themes."
  #:title "Toggle Dark/Light Theme" #:menu "View" #:menu-order 21
  (toggle-theme!) (restyle!))

(define-command (show-messages)
  #:aliases ("view-echo-area-messages" "messages" "*Messages*" "show messages" "log" "errors")
  #:help "Open the log of messages and errors."
  #:title "Show Activity Log" #:menu "View" #:menu-order 30
  #:doc "Open the Activity log (Emacs: *Messages*). Errors from commands, hooks and extensions land here."
  (show-messages!))

(define (palette-items)
  (define recents (filter values (map find-command (recent-commands))))
  (define ordered (append recents (filter (lambda (c) (not (memq c recents))) (all-commands))))
  (for/list ([c (in-list ordered)])
    (list (command-title c) (or (command-shortcut (command-name c)) "") (command-name c)
          (command-search-fields c))))

;; What typing `q` in the palette finds, best first. (The palette dialog uses the same text.)
(define (palette-matches q)
  (map caddr (fuzzy-filter* q (palette-items) pick-item-fields)))

(define-command (command-palette)
  #:aliases ("M-x" "execute-extended-command" "run command" "search commands")
  #:help "Search every command by name and run it."
  #:title "Command Palette…" #:menu "View" #:menu-order 40 #:keys ("Mod-Shift-p") #:keys/windows ("Alt-q")
  #:doc "Search every command by its name, an alias (including its Emacs name) or its shortcut. Recently used commands come first."
  (define choice (pick "Command Palette" (palette-items) #:detail-heading "Shortcut"))
  (run-hook 'focus-editor)
  (when choice (run-command/safe choice)))

(define-command (set-major-mode)
  #:aliases ("major mode" "set-major-mode" "language mode" "change language" "syntax")
  #:help "Choose what kind of document this is, for coloring and shortcuts."
  #:title "Set Language…" #:menu "View" #:menu-order 41
  (define items (for/list ([m (all-modes 'major)])
                  (list (mode-display-name (mode-name m)) (mode-doc m) (mode-name m)
                        (symbol->string (mode-name m)))))
  (define choice (pick "Language" items #:detail-heading "About"))
  (when choice (send (t) set-mode! choice)))

;; ---- tools ---------------------------------------------------------------

(define (current-line-text b)
  (line-text b (send b position-paragraph (send b get-start-position))))

(define-command (eval-selection)
  #:aliases ("eval-region" "evaluate selection" "evaluate" "eval-last-sexp" "run code")
  #:help "Run the selected Racket code, or the current line."
  #:title "Run Selection" #:menu "Tools" #:menu-order 10 #:keys ("Mod-Enter")
  #:doc "Evaluate the selected Racket code (or the current line) in the running editor."
  (define b (t))
  (define code (let ([s (selection-string b)]) (if (string=? s "") (current-line-text b) s)))
  (define r (eval-string code))
  (message "~a" (if (string=? r "") "(no output)" r)))

(define-command (eval-buffer)
  #:aliases ("eval-buffer" "evaluate buffer" "evaluate document" "run file")
  #:help "Run the whole document as Racket code."
  #:title "Run Document" #:menu "Tools" #:menu-order 11 #:keys ("Mod-Shift-Enter")
  (define r (eval-string (buffer-string)))
  (message "~a" (if (string=? r "") "Evaluated buffer" r)))

;; ---- help ----------------------------------------------------------------

(define (show-text-buffer! name text)
  (define b (or (for/first ([x (all-buffers)] #:when (equal? (send x get-name) name)) x)
                (new-buffer! name)))
  (send b lock #f)
  (send b erase)
  (send b insert text)
  (send b set-position 0)
  (send b set-modified #f)
  (send b lock #t)
  (send b set-shown! #t)
  (set-current-buffer! b))

(define-command (describe-key)
  #:aliases ("describe-key" "help key" "which command is this key")
  #:help "Press a key to see which command it runs."
  #:title "What Does This Key Do?" #:menu "Help" #:menu-order 10
  #:doc "Press a key to see which command it runs."
  (request-describe-key!))

(define-command (list-keybindings)
  #:aliases ("describe-bindings" "list keybindings" "keybindings" "shortcuts" "key map" "cheat sheet")
  #:help "List every shortcut."
  #:keys/windows ("F1") #:title "Keyboard Shortcuts" #:menu "Help" #:menu-order 11
  (define (title-of name) (let ([c (find-command name)]) (if c (command-title c) (symbol->string name))))
  (define rows
    (sort (for/list ([b (keymap-bindings global-keymap)])
            (cons (key-sequence->string (car b)) (cadr b)))
          string-ci<? #:key (lambda (r) (title-of (cdr r)))))
  (show-text-buffer!
   "Keyboard Shortcuts"
   (string-append "Keyboard shortcuts\n\n"
                  (string-join (for/list ([r rows])
                                 (format "~a  ~a" (~pad (car r) 16)
                                         (let ([c (find-command (cdr r))]) (if c (command-title c) (cdr r)))))
                               "\n")
                  "\n")))

(define (~pad s n) (string-append s (make-string (max 1 (- n (string-length s))) #\space)))

(define (command-description name)
  (define c (find-command name))
  (string-append
   (format "~a  (~a)\n\n" (command-title c) (command-name c))
   (if (string=? (command-help c) "") "" (string-append (command-help c) "\n\n"))
   (if (null? (command-aliases c)) "" (format "Also known as: ~a\n" (string-join (command-aliases c) ", ")))
   (format "Shortcut: ~a\n" (or (command-shortcut name) "none"))
   (if (string=? (command-doc c) "") "" (string-append "\n" (command-doc c) "\n"))))

(define-command (describe-command)
  #:aliases ("describe-function" "describe command" "explain command" "help command" "apropos")
  #:help "Read what a command does."
  #:title "Explain a Command…" #:menu "Help" #:menu-order 12
  (define choice (pick "Describe Command" (palette-items) #:detail-heading "Shortcut"))
  (when choice (show-text-buffer! "Help" (command-description choice))))

(define-command (show-glossary)
  #:aliases ("glossary" "emacs terms" "vocabulary" "what is a buffer")
  #:help "Show what Rackmac calls each Emacs term."
  #:title "Glossary: Emacs Terms" #:menu "Help" #:menu-order 14
  (show-text-buffer! "Glossary" (glossary-text)))

(define-command (about)
  #:aliases ("about-emacs" "version")
  #:help "Show information about Rackmac."
  #:title "About Rackmac" #:menu "Help" #:menu-order 20
  (message "Rackmac: an Emacs-style editor scripted in Racket. Commands: ~a"
           (length (all-commands))))

;; Names of every command defined above; a test pins this list so a rename cannot slip through.
(define builtin-command-names (map command-name (all-commands)))
