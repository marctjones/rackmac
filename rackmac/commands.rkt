#lang racket/base
;; Built-in commands. They use exactly the public `define-command` that init files use.
;; Bindings follow current desktop conventions, with per-platform layers where macOS
;; and Windows differ (#:keys/mac, #:keys/windows).
(require racket/class racket/gui/base racket/list racket/string racket/file racket/path
         "command.rkt" "keymap.rkt" "mode.rkt" "hook.rkt" "editor.rkt" "input.rkt"
         "theme.rkt" "picker.rkt" "frame.rkt" "eval.rkt" "platform.rkt" "modes.rkt" "owner.rkt" "fuzzy.rkt"
         "fileio.rkt" "ui/palette.rkt" "settings.rkt" "appearance.rkt")
(provide save-buffer! confirm-quit? palette-items palette-matches command-description
         confirm-discard-changes confirm-save-changes
         builtin-command-names reveal-argv launch!)

(define (t) (current-buffer))
(define (ext?) (extending-selection?))

;; run-code-only (#288): a code Language is one whose chain includes prog-mode, the mirror of
;; status-defaults.rkt's `prose-mode?` (text-mode). Run Selection/Run Document, Toggle Comment
;; and Indent/Outdent Lines are for code only; a note's Tab and Enter serve lists instead
;; (md-lists-enter, a later issue) and ⌘Return does nothing (Run Selection/Document are not
;; even bound outside a code Language's own keymap -- see #:key-keymap code-keymap below).
(define (code-language? [b (t)]) (and (memq 'prog-mode (map mode-name (mode-chain (send b get-mode)))) #t))

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

;; "Save changes to X?" -> 'save, 'discard or 'cancel. A parameter so tests and scripts
;; can answer without the native dialog.
(define confirm-save-changes
  (make-parameter
   (lambda (b)
     (case (message-box/custom "Rackmac" (format "Save changes to ~a?" (send b get-name))
                               "Save" "Don't Save" "Cancel" (ui-parent) '(caution default=1) 3)
       [(1) 'save] [(2) 'discard] [else 'cancel]))))
(define (ask-save b) ((confirm-save-changes) b))

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

;; 'ok (nothing to lose, or saved), 'discard (Don't Save) or #f (Cancel, or the save failed).
(define (ask-close b)
  (cond [(not (send b is-modified?)) 'ok]
        [else (case (ask-save b)
                [(save) (and (save-buffer! b) 'ok)]
                [(discard) 'discard]
                [else #f])]))

;; #t when it is fine to discard/close `b` (saving first if the user asks).
;; Don't Save means discard, as in Word and Pages: recovery drops its snapshot too
;; (recovery.rkt); only a crash or a kill leaves one behind.
(define (confirm-close-buffer? b)
  (case (ask-close b)
    [(ok) #t]
    [(discard) (run-hook 'changes-discarded b) #t]
    [else #f]))

;; Don't Save answers are only acted on once the whole quit is confirmed: a Cancel on a later
;; document keeps every document open, and those must keep their recovery snapshots (#76).
(define (confirm-quit?)
  (define discarded '())
  (define ok?
    (for/and ([b (in-list (unsaved-buffers))])
      (set-current-buffer! b)
      (case (ask-close b)
        [(ok) #t]
        [(discard) (set! discarded (cons b discarded)) #t]
        [else #f])))
  (when ok? (for ([b (in-list (reverse discarded))]) (run-hook 'changes-discarded b)))
  ok?)

;; #276 lib-new-note: Cmd+N now makes a note (rackmac/library/new-note.rkt); this keeps its
;; old behavior (an empty, mode-less tab, useful for a quick Racket or Python script) reachable
;; under its old symbol, so nothing that calls it by name breaks, moved to Tools and renamed.
(define-command (new-document)
  #:icon "language"
  #:aliases ("new document" "new file" "new tab" "new code file" "new script")
  #:help "Start a new empty code file in a new tab."
  #:title "New Code File…" #:menu "Tools" #:menu-order 21 #:category "Tools"
  #:doc "Create an empty document with no Library folder or file yet -- for a quick script. Notes use New Note instead."
  (set-current-buffer! (new-buffer! "untitled")))

(define-command (open-file)
  #:icon "open"
  #:aliases ("open document" "visit file" "open file")
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
  #:icon "search"
  #:aliases ("find file in project" "fuzzy open" "go to file")
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
  #:when (lambda () (or (send (t) is-modified?) (not (send (t) get-path))))
  #:icon "save"
  #:aliases ("write file" "save document")
  #:help "Save the document to its file (asks for a name the first time)."
  #:title "Save" #:menu "File" #:menu-order 20 #:keys ("Mod-s")
  #:doc "Write the document to its file, asking for a name if it has none."
  (save-buffer! (t)))

(define-command (save-as)
  #:icon "save-as"
  #:aliases ("save a copy" "rename file")
  #:help "Save the document under a new name or location."
  #:title "Save As…" #:menu "File" #:menu-order 21 #:keys ("Mod-Shift-s") #:keys/windows ("F12")
  (save-buffer-as! (t)))

(define-command (close-tab)
  #:icon "close"
  #:aliases ("close document" "close file")
  #:help "Close this tab, asking to save unsaved changes first."
  #:title "Close Tab" #:menu "File" #:menu-order 22 #:keys ("Mod-w") #:keys/windows ("Ctrl-F4")
  #:doc "Close the current document, offering to save unsaved changes."
  (define b (t))
  (when (confirm-close-buffer? b) (kill-buffer! b)))

;; RM-071: the tab context menu's Close, Close Others and Close Tabs to the Right. The tab
;; strip makes the right-clicked tab current before showing the menu (document-tabs% in
;; frame.rkt), so, like Close Tab above, these simply act on (current-buffer).
(define (close-tabs! bs) (for ([b bs]) (when (confirm-close-buffer? b) (kill-buffer! b))))

(define-command (close-other-tabs)
  #:when (lambda () (> (length (visible-buffers)) 1))
  #:icon "close"
  #:aliases ("close other tabs" "close others")
  #:help "Close every open document except this one, asking to save unsaved changes first."
  #:title "Close Other Tabs"
  (close-tabs! (remq (t) (visible-buffers))))

(define-command (close-tabs-to-right)
  #:when (lambda () (define i (index-of (visible-buffers) (t))) (and i (< i (sub1 (length (visible-buffers))))))
  #:icon "close"
  #:aliases ("close tabs to the right" "close right tabs")
  #:help "Close every open document to the right of this one, asking to save unsaved changes first."
  #:title "Close Tabs to the Right"
  (define bs (visible-buffers))
  (define i (index-of bs (t)))
  (when i (close-tabs! (list-tail bs (add1 i)))))

;; RM-071: Copy Path and Reveal in Finder/Explorer. `reveal-argv` is factored out (pure, no
;; process started) so tests can check the built command line for both platforms.
(define-command (copy-tab-path)
  #:when (lambda () (and (send (t) get-path) #t))
  #:icon "copy"
  #:aliases ("copy file path" "copy full path")
  #:help "Copy this document's file path to the clipboard."
  #:title "Copy Path"
  (define p (send (t) get-path))
  (when p
    (send the-clipboard set-clipboard-string (path->string p) (current-milliseconds))
    (message "Copied path: ~a" (path->string p))))

;; The argv for showing `path` in the platform's file manager, one entry per process
;; argument (the first is the executable name, resolved with find-executable-path).
(define (reveal-argv path)
  (cond [(windows?) (list "explorer" (format "/select,~a" (path->string path)))]
        [(mac?) (list "open" "-R" (path->string path))]
        [else (list "xdg-open" (path->string (let-values ([(base name dir?) (split-path path)]) base)))]))

;; subprocess returns 4 values (process, stdout, stdin, stderr); the pipes are closed right
;; away since nothing reads or writes them. Factored so a test can run it with a harmless
;; argv and prove the arity is right, without popping an actual Finder/Explorer window.
(define (launch! argv)
  (define exe (find-executable-path (string->path (car argv))))
  (cond
    [exe
     (define-values (proc out in err) (apply subprocess #f #f #f exe (cdr argv)))
     (close-input-port out) (close-output-port in) (close-input-port err)
     #t]
    [else #f]))

(define-command (reveal-in-file-manager)
  #:when (lambda () (and (send (t) get-path) #t))
  #:icon "open"
  #:aliases ("reveal in finder" "show in explorer" "open containing folder" "reveal in explorer")
  #:help "Show this document's file in Finder or File Explorer."
  #:title (if (windows?) "Reveal in File Explorer" "Reveal in Finder")
  (define p (send (t) get-path))
  (when p
    (define argv (reveal-argv p))
    (unless (launch! argv) (message "Could not find ~a to reveal the file." (car argv)))))

(define (cycle-buffer delta)
  (define bs (visible-buffers))
  (define i (or (index-of bs (t)) 0))
  (set-current-buffer! (list-ref bs (modulo (+ i delta) (length bs)))))

(define-command (next-tab)
  #:icon "chevron-right"
  #:aliases ("switch tab" "next document")
  #:help "Switch to the next tab."
  #:title "Next Tab" #:menu "File" #:menu-order 30
  #:keys ("Ctrl-Tab") #:keys/mac ("Mod-Alt-Right" "Mod-Shift-]") #:keys/windows ("Ctrl-PageDown")
  (cycle-buffer 1))

(define-command (previous-tab)
  #:icon "chevron-left"
  #:aliases ("prev tab" "previous document")
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
  #:when (lambda () (and (send (t) get-path) #t))
  #:icon "history"
  #:aliases ("revert" "reload file" "discard changes")
  #:help "Read the document again from its file, discarding unsaved changes."
  #:title "Reload from Disk" #:menu "File" #:menu-order 24
  (define b (t))
  (cond
    [(not (send b get-path)) (message "~a has not been saved to a file yet." (send b get-name))]
    [(not (file-exists? (send b get-path))) (message "~a no longer exists on disk." (send b get-path))]
    [(and (send b is-modified?) (not ((confirm-discard-changes) b))) (void)]
    [else (reload-buffer! b) (message "Reloaded ~a" (send b get-name))]))

;; The status bar's line-ending segment (RM-062) opens this; "current" marks what the
;; document already uses so the picker's Detail column shows it.
(define eol-choices '(("\n" . "LF (Unix, macOS)") ("\r\n" . "CRLF (Windows)") ("\r" . "CR (Classic Mac)")))

(define-command (set-line-endings)
  #:aliases ("line endings" "convert line endings" "crlf" "eol")
  #:help "Choose which line-ending characters this document is saved with."
  #:title "Line Endings…"
  #:doc "Sets the document-local `eol` used by save; the file is rewritten with it next Save."
  (define b (t))
  (define current (send b local-ref 'eol "\n"))
  (define items (for/list ([p eol-choices])
                  (list (cdr p) (if (equal? (car p) current) "current" "") (car p))))
  (define choice (pick "Line Endings" items #:detail-heading "In use"))
  (when (and choice (not (equal? choice current)))
    (send b local-set! 'eol choice)
    (send b set-modified #t)
    (run-hook 'status-changed)
    (message "Line endings: ~a (saved on next Save)" (eol-label choice))))

;; The status bar's encoding segment (RM-087) opens this for now; changing the encoding
;; from here is left for a later issue (#87 stays open for "save as UTF-8").
(define-command (show-encoding)
  #:aliases ("file encoding" "character encoding")
  #:help "Show the character encoding this document is saved with."
  #:title "File Encoding"
  (define b (t))
  (message "~a: ~a" (send b get-name) (encoding-label (send b local-ref 'encoding 'utf-8))))

(define-command (save-all)
  #:when (lambda () (pair? (unsaved-buffers)))
  #:icon "save"
  #:aliases ("save everything" "save all documents")
  #:help "Save every open document that has unsaved changes."
  #:title "Save All" #:menu "File" #:menu-order 26 #:keys/mac ("Mod-Alt-s")
  (define bs (unsaved-buffers))
  (define saved (for/sum ([b bs]) (if (save-buffer! b) 1 0)))
  (message (if (null? bs) "Nothing to save." (format "Saved ~a of ~a document~a." saved (length bs) (if (= 1 (length bs)) "" "s")))))

(define-command (reopen-closed-tab)
  #:icon "history"
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
  #:icon "print"
  #:aliases ("print" "printout")
  #:help "Print the document."
  #:title "Print…" #:menu "File" #:menu-order 25 #:keys ("Mod-p")
  (send (t) print #t #t 'standard (ui-parent)))

(define init-template #<<TEMPLATE
#lang rackmac
;; Rackmac init file. `#lang rackmac` is racket/base plus the whole extension API, so
;; nothing needs requiring. This file loads at startup and on "Reload Extensions"; anything
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
;; (add-hook! 'after-save (lambda (b) (message "saved ~a" (send b get-name))))
TEMPLATE
  )

;; #289 (menu-tools): these three move off the File/Help menus into Tools > Extensions
;; (rackmac/tools-menu.rkt builds that submenu from the command registry, by name). ⌘, moved
;; to the Settings dialog's `open-settings` already (#291, rackmac/ui/settings-dialog.rkt).
;; #:menu #f keeps them out of the top-level menu loop in frame.rkt while leaving them
;; registered (so the submenu, the palette and #lang rackmac scripts can still run them by name).
(define-command (customize-with-code)
  #:icon "settings"
  #:aliases ("init file" "open init file" "config" "settings file" "customize" "edit as code")
  #:help "Open the file that customizes Rackmac with Racket code."
  #:title "Customize with Code" #:category "Extensions" #:menu #f
  #:doc "Open (creating from a template if needed) the init file that customizes Rackmac."
  (define p (init-file-path))
  (unless (file-exists? p)
    (make-directory* (config-dir))
    (display-to-file init-template p))
  (set-current-buffer! (open-file! p)))

(define-command (reload-init)
  #:icon "extensions"
  #:aliases ("reload init" "reload init file" "reload config")
  #:help "Run your customization files again, replacing what they registered before."
  #:title "Reload Extensions" #:category "Extensions" #:menu #f
  (load-init!))

(define-command (list-extensions)
  #:icon "extensions"
  #:aliases ("list packages" "installed extensions" "add-ons")
  #:help "Show which customization files are loaded and what each one added."
  #:title "List Extensions" #:category "Extensions" #:menu #f
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
  #:icon "x"
  #:aliases ("exit" "close app" "quit application")
  #:help "Close Rackmac, asking to save unsaved changes first."
  #:title "Quit" #:menu "File" #:menu-order 50 #:keys/mac ("Mod-q") #:keys/windows ("Alt-F4")
  (when (confirm-quit?) (exit 0)))

;; ---- editing -------------------------------------------------------------

(define-command (undo)
  #:when (lambda () (send (t) can-do-edit-operation? 'undo))
  #:icon "undo"
  #:aliases ("history" "revert change")
  #:help "Undo the last change."
  #:title "Undo" #:menu "Edit" #:menu-order 10 #:keys ("Mod-z")
  (send (t) undo))

(define-command (redo)
  #:when (lambda () (send (t) can-do-edit-operation? 'redo))
  #:icon "redo"
  #:aliases ("redo change")
  #:help "Redo a change you undid."
  #:title "Redo" #:menu "Edit" #:menu-order 11
  #:keys/mac ("Mod-Shift-z") #:keys/windows ("Ctrl-y" "Ctrl-Shift-z")
  (send (t) redo))

(define-command (cut)
  #:when (lambda () (send (t) can-do-edit-operation? 'cut))
  #:icon "cut"
  #:aliases ("cut selection")
  #:help "Remove the selected text and put it on the clipboard."
  #:title "Cut" #:menu "Edit" #:menu-order 20 #:keys ("Mod-x")
  (send (t) cut))
(define-command (copy)
  #:when (lambda () (send (t) can-do-edit-operation? 'copy))
  #:icon "copy"
  #:aliases ("copy selection")
  #:help "Copy the selected text to the clipboard."
  #:title "Copy" #:menu "Edit" #:menu-order 21 #:keys ("Mod-c")
  (send (t) copy))
(define-command (paste)
  #:when (lambda () (send (t) can-do-edit-operation? 'paste))
  #:icon "paste"
  #:aliases ("paste clipboard")
  #:help "Insert the clipboard contents at the cursor."
  #:title "Paste" #:menu "Edit" #:menu-order 22 #:keys ("Mod-v")
  (send (t) paste))
(define-command (select-all)
  #:icon "select-all"
  #:aliases ("select everything")
  #:help "Select the whole document."
  #:title "Select All" #:menu "Edit" #:menu-order 23 #:keys ("Mod-a")
  (send (t) set-position 0 (send (t) last-position)))
(define-command (select-line)
  #:icon "select-all"
  #:aliases ("select current line")
  #:help "Select the current line."
  #:title "Select Line" #:menu "Edit" #:menu-order 24 #:keys ("Mod-l")
  (define b (t))
  (define-values (p1 p2) (selected-lines b))
  (send b set-position (send b paragraph-start-position p1)
        (min (send b last-position) (add1 (send b paragraph-end-position p2)))))

(define-command (find)
  #:icon "find"
  #:aliases ("search" "find in document")
  #:help "Search for text in this document."
  #:title "Find…" #:menu "Edit" #:menu-order 30 #:keys ("Mod-f")
  (show-find-bar! #f))
(define-command (replace)
  #:icon "replace"
  #:aliases ("find and replace" "substitute")
  #:help "Find text and replace it with something else."
  #:title "Find and Replace…" #:menu "Edit" #:menu-order 31
  #:keys/mac ("Mod-Alt-f") #:keys/windows ("Ctrl-h")
  (show-find-bar! #t))
(define-command (find-next)
  #:icon "arrow-down"
  #:aliases ("next match" "search again")
  #:help "Jump to the next match."
  #:title "Find Next" #:menu "Edit" #:menu-order 32 #:keys/mac ("Mod-g") #:keys/windows ("F3")
  (find! 'forward))
(define-command (find-previous)
  #:icon "arrow-up"
  #:aliases ("previous match")
  #:help "Jump to the previous match."
  #:title "Find Previous" #:menu "Edit" #:menu-order 33
  #:keys/mac ("Mod-Shift-g") #:keys/windows ("Shift-F3")
  (find! 'backward))

(define-command (goto-line)
  #:icon "goto"
  #:aliases ("jump to line" "line number" "go to line")
  #:help "Move the cursor to a line number."
  #:title "Go to Line…" #:menu "Edit" #:menu-order 34 #:keys ("Ctrl-g")
  (define s (get-text-from-user "Go to line" "Line number:" (ui-parent)))
  (define n (and s (string->number (string-trim s))))
  (when (and n (exact-positive-integer? n))
    (goto-line! n)))

;; Lines --------------------------------------------------------------------

(define-command (toggle-comment)
  #:when code-language?
  #:icon "comment"
  #:aliases ("uncomment")
  #:help "Turn the selected lines into comments, or back into code."
  #:title "Toggle Comment" #:menu "Edit" #:menu-order 40 #:keys ("Mod-/")
  #:doc "Comment or uncomment the selected lines using the mode's comment syntax."
  (define b (t))
  (define cs (send b local-ref 'comment-start #f))
  (cond
    [(not cs) (message "No comment syntax for ~a" (mode-display-name (send b get-mode)))]
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
  #:icon "duplicate"
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
  #:icon "delete-line"
  #:aliases ("remove line" "delete this line")
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
  #:icon "arrow-up"
  #:aliases ("swap line up")
  #:help "Move the current line up by one."
  #:title "Move Line Up" #:menu "Edit" #:menu-order 43 #:keys ("Alt-Up")
  (move-lines! -1))
(define-command (move-line-down)
  #:icon "arrow-down"
  #:aliases ("swap line down")
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
  #:when code-language?
  #:icon "indent"
  #:aliases ("indent region")
  #:help "Indent the selected lines."
  #:title "Indent Lines" #:menu "Edit" #:menu-order 45 #:keys ("Mod-]")
  (indent-selected-lines!))

(define-command (outdent-lines)
  #:when code-language?
  #:icon "outdent"
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
  #:aliases ("previous word")
  #:help "Move the cursor to the start of the previous word."
  #:title "Word Left" #:keys/mac ("Alt-Left") #:keys/windows ("Ctrl-Left")
  (send (t) move-position 'left (ext?) 'word))
(define-command (word-right)
  #:aliases ("next word")
  #:help "Move the cursor to the end of the next word."
  #:title "Word Right" #:keys/mac ("Alt-Right") #:keys/windows ("Ctrl-Right")
  (send (t) move-position 'right (ext?) 'word))
(define-command (line-start)
  #:aliases ("home")
  #:help "Move the cursor to the start of the line."
  #:title "Line Start" #:keys ("Home") #:keys/mac ("Mod-Left")
  (send (t) move-position 'left (ext?) 'line))
(define-command (line-end)
  #:aliases ("end")
  #:help "Move the cursor to the end of the line."
  #:title "Line End" #:keys ("End") #:keys/mac ("Mod-Right")
  (send (t) move-position 'right (ext?) 'line))
(define-command (doc-start)
  #:aliases ("top of document")
  #:help "Move the cursor to the start of the document."
  #:title "Document Start" #:keys/mac ("Mod-Up") #:keys/windows ("Ctrl-Home")
  (define b (t))
  (if (ext?) (send b set-position 0 (send b get-end-position)) (send b set-position 0)))
(define-command (doc-end)
  #:aliases ("bottom of document")
  #:help "Move the cursor to the end of the document."
  #:title "Document End" #:keys/mac ("Mod-Down") #:keys/windows ("Ctrl-End")
  (define b (t))
  (if (ext?)
      (send b set-position (send b get-start-position) (send b last-position))
      (send b set-position (send b last-position))))
(define-command (page-up)
  #:aliases ("previous page")
  #:help "Move up by one screen."
  #:title "Page Up" #:keys ("PageUp")
  (send (t) move-position 'up (ext?) 'page))
(define-command (page-down)
  #:aliases ("next page")
  #:help "Move down by one screen."
  #:title "Page Down" #:keys ("PageDown")
  (send (t) move-position 'down (ext?) 'page))

(define (delete-by! dir kind)
  (define b (t))
  (when (= (send b get-start-position) (send b get-end-position))
    (send b move-position dir #t kind))
  (send b delete))

(define-command (delete-word-back)
  #:aliases ("delete previous word")
  #:help "Delete the word before the cursor."
  #:title "Delete Word Back" #:keys/mac ("Alt-Backspace") #:keys/windows ("Ctrl-Backspace")
  (delete-by! 'left 'word))
(define-command (delete-word-forward)
  #:aliases ("delete next word")
  #:help "Delete the word after the cursor."
  #:title "Delete Word Forward" #:keys/mac ("Alt-Delete") #:keys/windows ("Ctrl-Delete")
  (delete-by! 'right 'word))
(define-command (delete-to-line-start)
  #:aliases ("delete to start of line")
  #:help "Delete from the cursor back to the start of the line."
  #:title "Delete to Line Start" #:keys/mac ("Mod-Backspace")
  (delete-by! 'left 'line))

;; ---- view ----------------------------------------------------------------

(define (restyle!)
  (for ([b (all-buffers)]) (send b rehighlight!))
  (run-hook 'theme-changed))

(define-command (zoom-in)
  #:icon "zoom-in"
  #:aliases ("bigger text" "increase font size")
  #:help "Make the text bigger."
  #:title "Zoom In" #:menu "View" #:menu-order 10 #:keys ("Mod-=" "Mod-Shift-=")
  (set-font-size! (add1 font-size)) (run-hook 'theme-changed))
(define-command (zoom-out)
  #:icon "zoom-out"
  #:aliases ("smaller text" "decrease font size")
  #:help "Make the text smaller."
  #:title "Zoom Out" #:menu "View" #:menu-order 11 #:keys ("Mod--")
  (set-font-size! (sub1 font-size)) (run-hook 'theme-changed))
(define-command (zoom-reset)
  #:icon "zoom-reset"
  #:aliases ("reset zoom" "default font size")
  #:help "Return the text to its normal size."
  #:title "Actual Size" #:menu "View" #:menu-order 12 #:keys ("Mod-0")
  (set-font-size! (default-font-size)) (run-hook 'theme-changed))

(define-command (toggle-word-wrap)
  #:icon "wrap"
  #:aliases ("line wrap")
  #:help "Wrap long lines to fit the window, or let them run off the edge."
  #:title "Toggle Word Wrap" #:menu "View" #:menu-order 20 #:keys/windows ("Alt-z")
  #:checked (lambda () (and (send (t) auto-wrap) #t))
  (define b (t))
  (send b auto-wrap (not (send b auto-wrap))))

(define-command (toggle-toolbar)
  #:aliases ("show toolbar" "hide toolbar")
  #:help "Show or hide the row of buttons above the tabs."
  #:icon "more"
  #:title "Show Toolbar" #:menu "View" #:menu-order 23
  #:checked toolbar-shown?
  (set-toolbar-shown! (not (toolbar-shown?))))

(define-command (toggle-full-screen)
  #:icon "maximize"
  #:aliases ("fullscreen" "maximize")
  #:help "Fill the whole screen with the window, or return to normal."
  #:title "Toggle Full Screen" #:menu "View" #:menu-order 22
  #:keys/mac ("Ctrl-Mod-f") #:keys/windows ("F11")
  (define f (main-frame))
  (when f (send f fullscreen (not (send f is-fullscreened?)))))

(define-command (toggle-theme)
  #:icon "theme"
  #:aliases ("dark mode" "light mode" "appearance")
  #:help "Switch between the dark and light color themes."
  #:title "Toggle Dark/Light Theme" #:menu "View" #:menu-order 21
  ;; Records an explicit choice in the Editor Theme setting (#254), which restyles through
  ;; appearance.rkt; the opposite of what is showing now, whatever the setting was.
  (setting-set! 'editor-theme (if (eq? (current-theme-name) 'dark) 'light 'dark)))

(define-command (show-activity-log)
  #:icon "activity"
  #:aliases ("messages" "show messages" "log" "errors")
  #:help "Open the log of messages and errors."
  #:title "Show Activity Log" #:menu "View" #:menu-order 30
  #:doc "Open the Activity log. Errors from commands, hooks and extensions land here."
  (show-messages!))

;; Each item: (list title shortcut name search-fields category). `category` (RM-030) sits
;; last, past what pick-item-fields searches, so it never skews ranking (see command.rkt's
;; command-category-label); ui/palette.rkt's #:cells reorders it for display.
(define (palette-items)
  (define recents (filter values (map find-command (recent-commands))))
  (define ordered (append recents (filter (lambda (c) (not (memq c recents))) (all-commands))))
  (for/list ([c (in-list ordered)])
    (list (command-title c) (or (command-shortcut (command-name c)) "") (command-name c)
          (command-search-fields c) (command-category-label c))))

;; What typing `q` in the palette finds, best first. (The palette dialog uses the same text.)
(define (palette-matches q)
  (map caddr (fuzzy-filter* q (palette-items) pick-item-fields)))

(define-command (command-palette)
  #:icon "palette"
  #:aliases ("run command" "search commands")
  #:help "Search every command by name and run it."
  #:title "Command Palette…" #:menu "View" #:menu-order 40 #:keys ("Mod-Shift-p") #:keys/windows ("Alt-q")
  #:doc "Search every command by its name, an alias or its shortcut. Recently used commands come first."
  (define choice (palette-pick "Command Palette" (palette-items)))
  (run-hook 'focus-editor)
  (when choice (run-command/safe choice)))

(define-command (set-language)
  #:icon "language"
  #:aliases ("language mode" "change language" "syntax")
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

(define-command (run-selection)
  #:when code-language?
  #:icon "run"
  #:aliases ("evaluate selection" "evaluate" "run code")
  #:help "Run the selected Racket code, or the current line."
  #:title "Run Selection" #:menu "Tools" #:menu-order 10
  #:keys ("Mod-Enter") #:key-keymap code-keymap
  #:doc "Evaluate the selected Racket code (or the current line) in the running editor."
  (define b (t))
  (define code (let ([s (selection-string b)]) (if (string=? s "") (current-line-text b) s)))
  (define r (eval-string code))
  (message "~a" (if (string=? r "") "(no output)" r)))

(define-command (run-document)
  #:when code-language?
  #:icon "run-all"
  #:aliases ("evaluate document" "run file")
  #:help "Run the whole document as Racket code."
  #:title "Run Document" #:menu "Tools" #:menu-order 11
  #:keys ("Mod-Shift-Enter") #:key-keymap code-keymap
  (define r (eval-string (buffer-string)))
  (message "~a" (if (string=? r "") "Evaluated document" r)))

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
  #:icon "keyboard"
  #:aliases ("help key" "which command is this key")
  #:help "Press a key to see which command it runs."
  #:title "What Does This Key Do?" #:menu "Help" #:menu-order 10
  #:doc "Press a key to see which command it runs."
  (request-describe-key!))

;; RM-039: a searchable, filterable dialog grouped by category, showing both platforms'
;; shortcuts (ui/palette.rkt's cheat-sheet-pick, built on cheatsheet.rkt's shortcut-rows).
;; Enter runs the selected command. Keeps the "Keyboard Shortcuts" title and the F1 shortcut
;; that list-keybindings (below) used to have.
(define-command (show-cheat-sheet)
  #:icon "keyboard"
  #:aliases ("list keybindings" "keybindings" "shortcuts" "cheat sheet")
  #:help "Search every shortcut, grouped by category, for both platforms."
  #:keys/windows ("F1") #:title "Keyboard Shortcuts" #:menu "Help" #:menu-order 11
  #:doc "A searchable list of every default shortcut on macOS and Windows, grouped by category. Enter runs the selected command."
  (define choice (cheat-sheet-pick))
  (run-hook 'focus-editor)
  (when choice (run-command/safe choice)))

;; The same information as plain text, for copying or searching in an editor. Keeps its
;; symbol (scripts and key bindings may refer to it) now that show-cheat-sheet, above, is the
;; searchable dialog Help > Keyboard Shortcuts opens.
(define-command (list-keybindings)
  #:icon "keyboard"
  #:aliases ("shortcuts as text" "export shortcuts" "plain text shortcuts")
  #:help "List every shortcut as plain text."
  #:title "Shortcuts as Text" #:menu "Help" #:menu-order 15
  (define (title-of name) (let ([c (find-command name)]) (if c (command-title c) (symbol->string name))))
  (define rows
    (sort (for/list ([b (keymap-bindings global-keymap)])
            (cons (key-sequence->string (car b)) (cadr b)))
          string-ci<? #:key (lambda (r) (title-of (cdr r)))))
  (show-text-buffer!
   "Shortcuts as Text"
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
  #:icon "help"
  #:aliases ("describe command" "explain command" "help command")
  #:help "Read what a command does."
  #:title "Explain a Command…" #:menu "Help" #:menu-order 12
  (define choice (palette-pick "Describe Command" (palette-items)))
  (when choice (show-text-buffer! "Help" (command-description choice))))

(define-command (about)
  #:icon "info"
  #:aliases ("version")
  #:help "Show information about Rackmac."
  #:title "About Rackmac" #:menu "Help" #:menu-order 20
  (message "Rackmac: a notes and documents editor scripted in Racket. Commands: ~a"
           (length (all-commands))))

;; Names of every command defined above; a test pins this list so a rename cannot slip through.
(define builtin-command-names (map command-name (all-commands)))
