#lang racket/base
;; The Library sidebar (#273 lib-sidebar; docs/UI-DESIGN.md S2.1): the filter row, Recent and
;; Folders beside the tabs, View > Show Library (⌥⌘S, Apple Notes' Show Folders), and the
;; right-click actions from the context registry's `library` group. The painted widgets live
;; in rackmac/ui/sidebar.rkt (option (a) of #331: the bench, with editor-based lists); this
;; module fills them from the Library (folders.rkt) and the recent-files store (recents.rkt),
;; and registers the panel with rackmac/frame.rkt, which only places it and shows or hides it.
;;
;; Refresh (v0.3): a rescan when the window is activated, after our own saves and after our
;; own file actions; `filesystem-change-evt` watching is lib-watch (v0.4).
(require racket/class racket/gui/base racket/list racket/path racket/file racket/string
         mrlib/hierlist
         "folders.rkt" "recents.rkt" "open-recent.rkt"
         "../command.rkt" "../commands.rkt" "../editor.rkt" "../frame.rkt" "../hook.rkt"
         "../settings.rkt" "../platform.rkt" "../input.rkt" "../context-menu.rkt" "../owner.rkt"
         "../ui/sidebar.rkt" "../ui/context-menu.rkt")
(provide sidebar-panel% library-tree-extensions folder-children library-row-label
         library-context-groups library-target set-library-target!
         ask-library-name confirm-delete-permanently? move-to-trash-runner trash-argv
         empty-library-text)

;; ---- settings -----------------------------------------------------------------------------

(define-setting show-library
  #:contract boolean? #:default #t
  #:doc "Show the Library sidebar beside your documents."
  #:category "Library")

(define-setting library-width
  #:contract (lambda (v) (and (exact-integer? v) (<= 160 v 480))) #:default 240
  #:doc "The width of the Library sidebar, in points."
  #:category "Library")

(define-setting library-collapsed-sections
  #:contract (lambda (v) (and (list? v) (andmap symbol? v))) #:default '()
  #:doc "Library sections you have collapsed (recent, folders)."
  #:category "Library")

(define-setting library-show-all-files
  #:contract boolean? #:default #f
  #:doc "Show every file in Library folders, not only notes, text and code."
  #:category "Library")

;; ---- the folder tree, as data -------------------------------------------------------------

;; The file kinds the Folders tree shows (docs/UI-DESIGN.md S2.1); a setting shows all files.
(define library-tree-extensions '(#".md" #".markdown" #".txt" #".rkt" #".py" #".json" #".yaml" #".csv"))

(define (hidden-name? name) (regexp-match? #rx"^[.]" name))

;; A folder's subfolders and shown files, each sorted by name without regard to case. Hidden
;; (dot) entries and the same skip-list Quick Open uses (.git, node_modules...) never show; an
;; unreadable folder (permissions, an unmounted share) simply has no children.
(define (folder-children dir #:all? [all? (setting-ref 'library-show-all-files)])
  (define names
    (with-handlers ([exn:fail:filesystem? (lambda (e) '())])
      (map path->string (directory-list dir))))
  (define (full n) (build-path dir n))
  (define visible (filter (lambda (n) (not (or (hidden-name? n) (member n skip-library-dirs)))) names))
  (define (by-name l) (sort l string-ci<?))
  (values (map full (by-name (filter (lambda (n) (directory-exists? (full n))) visible)))
          (map full (by-name (filter (lambda (n)
                                       (and (file-exists? (full n))
                                            (or all? (member (path-get-extension n) library-tree-extensions))))
                                     visible)))))

(define (path-key p) (path->string (simplify-path (path->complete-path p))))
(define (base-name p) (path->string (file-name-from-path p)))

;; A row's label: the file's name, with "• " in front while an open document for it has unsaved
;; changes, as the tabs and the window title do.
(define (modified-path? p)
  (define b (find-buffer-by-path (simplify-path (path->complete-path p))))
  (and b (send b is-modified?)))
(define (library-row-label p) (string-append (if (modified-path? p) "• " "") (base-name p)))

(define empty-library-text
  "No folders yet. Add the folder where you keep your notes (OneDrive and SharePoint folders work).")

;; ---- what the right-click actions act on --------------------------------------------------
;; The row last selected or right-clicked in the sidebar: (list kind path) with kind 'file,
;; 'folder or 'root (a Library folder itself), or #f.
(define target #f)
(define (library-target) target)
(define (set-library-target! t) (set! target t))
(define (target-kind) (and target (car target)))
(define (target-path) (and target (cadr target)))
(define (target-folder)                   ; a file's actions that need a folder use its folder
  (case (target-kind)
    [(folder root) (target-path)]
    [(file) (path->string (path-only (target-path)))]
    [else #f]))
(define (target-on-disk?) (and target (or (file-exists? (target-path)) (directory-exists? (target-path)))))

;; Dialogs that ask something are parameters (docs/DEVELOPMENT.md), so tests answer them.
(define ask-library-name
  (make-parameter
   (lambda (title prompt initial)
     (get-text-from-user title prompt (ui-parent) initial))))

(define confirm-delete-permanently?
  (make-parameter
   (lambda (name)
     (eq? 1 (message-box/custom "Rackmac"
                                (format "Rackmac could not move \"~a\" to the Trash. Delete it permanently? This cannot be undone." name)
                                "Delete" "Cancel" #f (ui-parent) '(default=2 caution) 2)))))

;; macOS: the Finder moves the item to the Trash (so it can be put back). The path is passed as
;; an argument to the script, never spliced into its text.
(define (trash-argv p)
  (list "osascript"
        "-e" "on run argv"
        "-e" "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)"
        "-e" "end run"
        (path->string p)))

;; Returns #t when the item went to the Trash. A parameter so tests never drive the Finder.
(define move-to-trash-runner
  (make-parameter
   (lambda (p)
     (and (mac?)
          (let ([exe (find-executable-path "osascript")])
            (and exe
                 (let-values ([(proc out in err) (apply subprocess #f #f #f exe (cdr (trash-argv p)))])
                   (close-output-port in)
                   (subprocess-wait proc)
                   (close-input-port out) (close-input-port err)
                   (zero? (subprocess-status proc)))))))))

;; Open documents at (or under) `old` follow a rename to `new`.
(define (retarget-buffers! old new)
  (define o (path-key old))
  (for ([b (in-list (all-buffers))] #:when (send b get-path))
    (define bp (path-key (send b get-path)))
    (cond
      [(equal? bp o)
       (send b set-path! (simplify-path (path->complete-path new)))
       (send b set-name! (base-name new))]
      [(string-prefix? bp (string-append o "/"))
       (send b set-path! (build-path new (substring bp (add1 (string-length o)))))])))

(define (unique-child dir base [ext #f])
  (let loop ([n 0])
    (define name (string-append base (if (= n 0) "" (format " ~a" n)) (if ext (string-append "." ext) "")))
    (define p (build-path dir name))
    (if (or (file-exists? p) (directory-exists? p)) (loop (add1 n)) p)))

(define (library-changed!) (run-hook 'library-changed))

(define-command (new-note-here)
  #:when (lambda () (and (target-folder) (directory-exists? (target-folder))))
  #:icon "new"
  #:aliases ("new note in folder" "new note here")
  #:help "Create a new note in the folder chosen in the Library."
  #:title "New Note Here"
  (parameterize ([library-target-folder (target-folder)])
    (run-command 'new-note))
  (library-changed!))

(define-command (new-library-folder)
  #:when (lambda () (and (target-folder) (directory-exists? (target-folder))))
  #:icon "book"
  #:aliases ("new folder" "create folder" "add subfolder")
  #:help "Create a folder inside the folder chosen in the Library."
  #:title "New Folder…"
  (define parent (target-folder))
  (define name ((ask-library-name) "New Folder" "Name of the new folder:"
                                   (base-name (unique-child parent "New Folder"))))
  (define clean (and name (sanitize-name name)))
  (cond
    [(not clean) (void)]
    [(let ([p (build-path parent clean)]) (or (directory-exists? p) (file-exists? p)))
     (message "There is already something named \"~a\" there." clean)]
    [else
     (with-handlers ([exn:fail? (lambda (e) (message "Could not create the folder: ~a" (exn-message e)))])
       (make-directory (build-path parent clean))
       (message "Created folder ~a." clean))
     (library-changed!)]))

(define (sanitize-name s)
  (define t (string-trim (regexp-replace* #px"[/:\u0000]" s " ")))
  (and (not (string=? t "")) (not (member t '("." ".."))) t))

(define-command (rename-library-item)
  #:when (lambda () (and (memq (target-kind) '(file folder)) (target-on-disk?)))
  #:icon "edit"
  #:aliases ("rename file" "rename folder" "rename note")
  #:help "Rename the file or folder chosen in the Library."
  #:title "Rename…"
  (define kind (target-kind))   ; read now: the rename's buffers-changed refresh clears the target
  (define old (string->path (target-path)))
  (define name ((ask-library-name) "Rename" "New name:" (base-name old)))
  (define clean (and name (sanitize-name name)))
  (define new (and clean (build-path (path-only old) clean)))
  (cond
    [(or (not new) (equal? (path-key new) (path-key old))) (void)]
    [(or (file-exists? new) (directory-exists? new))
     (message "There is already something named \"~a\" there." clean)]
    [else
     (with-handlers ([exn:fail? (lambda (e) (message "Could not rename: ~a" (exn-message e)))])
       (rename-file-or-directory old new)
       (retarget-buffers! old new)
       (set-library-target! (list kind (path->string new)))
       (message "Renamed to ~a." clean))
     (library-changed!)]))

(define-command (reveal-library-item)
  #:when (lambda () (target-on-disk?))
  #:icon "open"
  #:aliases ("show in finder" "reveal in finder" "show in explorer" "open containing folder")
  #:help "Show the file or folder chosen in the Library in Finder or File Explorer."
  #:title (if (windows?) "Reveal in File Explorer" "Reveal in Finder")
  (define argv (reveal-argv (string->path (target-path))))
  (unless (launch! argv) (message "Could not find ~a to reveal the file." (car argv))))

(define-command (copy-library-path)
  #:when (lambda () (and target #t))
  #:icon "copy"
  #:aliases ("copy file path" "copy folder path")
  #:help "Copy the path of the file or folder chosen in the Library."
  #:title "Copy Path"
  (send the-clipboard set-clipboard-string (target-path) (current-milliseconds))
  (message "Copied path: ~a" (target-path)))

;; The Finder Trash when it works (so the file can be put back); otherwise, after a confirmation
;; naming the file, a permanent delete. A Library folder itself is never trashed from here --
;; Remove Folder… takes it out of the Library and leaves the files alone.
(define-command (trash-library-item)
  #:when (lambda () (and (memq (target-kind) '(file folder)) (target-on-disk?)))
  #:icon "close"
  #:aliases ("delete file" "delete note" "delete folder" "move to trash" "move to recycle bin")
  #:help "Move the file or folder chosen in the Library to the Trash."
  #:title (if (windows?) "Move to Recycle Bin" "Move to Trash")
  (define p (string->path (target-path)))
  (define name (base-name p))
  (define gone?
    (or ((move-to-trash-runner) p)
        (and ((confirm-delete-permanently?) name)
             (with-handlers ([exn:fail? (lambda (e) (message "Could not delete ~a: ~a" name (exn-message e)) #f)])
               (if (directory-exists? p) (delete-directory/files p) (delete-file p))
               #t))))
  (when gone?
    ;; Documents that were showing it close if they have nothing unsaved; one with unsaved
    ;; changes stays open, so nothing typed is lost.
    (define key (path-key p))
    (for ([b (in-list (all-buffers))] #:when (send b get-path))
      (define bp (path-key (send b get-path)))
      (when (and (or (equal? bp key) (string-prefix? bp (string-append key "/")))
                 (not (send b is-modified?)))
        (kill-buffer! b)))
    (set-library-target! #f)
    (message "Moved ~a to the Trash." name)
    (library-changed!)))

;; The right-click menu's rows: the registry's `library` group. The items carry the mode
;; 'library, which is no Language's name, so they never leak into a document's own menu
;; (context-items-for only returns items whose mode is in the document's Language chain).
(define library-commands
  '(new-note-here new-library-folder rename-library-item trash-library-item
    reveal-library-item copy-library-path))
(for ([c (in-list library-commands)]) (add-context-item! c #:group 'library #:mode 'library))

(define (library-context-groups)
  (define names (for/list ([it (in-list (context-items))] #:when (eq? (context-item-group it) 'library))
                  (context-item-command it)))
  ;; New / Rename, Trash / Reveal, Copy Path: separators like Finder's menu.
  (filter pair? (list (filter (lambda (n) (memq n '(new-note-here new-library-folder))) names)
                      (filter (lambda (n) (memq n '(rename-library-item trash-library-item))) names)
                      (filter (lambda (n) (not (memq n '(new-note-here new-library-folder rename-library-item trash-library-item)))) names))))

;; ---- the panel ----------------------------------------------------------------------------

(define (row-height)
  (define dc (new bitmap-dc% [bitmap (make-bitmap 1 1)]))
  (define-values (w h d a) (send dc get-text-extent "Xg" row-font))
  (+ (inexact->exact (ceiling h)) 6))

(define recent-shown-count 10)

(define sidebar-panel%
  (class horizontal-panel%
    (init [width (setting-ref 'library-width)])
    (super-new [spacing 0] [border 0] [min-width width] [stretchable-width #f])

    (define column (new vertical-panel% [parent this] [spacing 0] [border 0]))
    (new rule-column% [parent this])

    (define filter-row (new filter-row% [parent column]
                            [on-activate (lambda () (run-command/safe 'quick-open))]))
    (define recent-header (new section-header% [parent column] [label "Recent"]
                               [on-toggle (lambda () (toggle-section! 'recent))]))
    (define recent-list (new bench-list% [parent column]
                             [on-activate (lambda (i how) (activate! i how))]
                             [on-context (lambda (i x y) (context! recent-list i x y))]
                             [on-selected (lambda (i) (note-target! i))]))
    (send recent-list set-no-sublists #t)
    (send recent-list stretchable-height #f)
    (define folders-header (new section-header% [parent column] [label "Folders"]
                                [on-toggle (lambda () (toggle-section! 'folders))]))
    (define folders-list (new bench-list% [parent column]
                              [on-activate (lambda (i how) (activate! i how))]
                              [on-context (lambda (i x y) (context! folders-list i x y))]
                              [on-opened (lambda (i) (folder-opened! i))]
                              [on-closed (lambda (i) (folder-closed! i))]
                              [on-selected (lambda (i) (note-target! i))]))

    (define/public (get-filter-row) filter-row)
    (define/public (get-recent-list) recent-list)
    (define/public (get-folders-list) folders-list)

    ;; ---- sections: collapse by clicking the header; the state persists ----
    (define (collapsed? s) (memq s (setting-ref 'library-collapsed-sections)))
    (define/public (toggle-section! s)
      (define now (setting-ref 'library-collapsed-sections))
      (setting-set! 'library-collapsed-sections (if (memq s now) (remq s now) (cons s now)))
      (layout-sections!))
    (define (layout-sections!)
      (send recent-header set-collapsed! (and (collapsed? 'recent) #t))
      (send folders-header set-collapsed! (and (collapsed? 'folders) #t))
      (send column change-children
            (lambda (cs) (append (list filter-row recent-header)
                                 (if (collapsed? 'recent) '() (list recent-list))
                                 (list folders-header)
                                 (if (collapsed? 'folders) '() (list folders-list))))))

    ;; ---- activation ----
    ;; A mouse activation runs after the list has finished handling the click: opening a file
    ;; rebuilds Recent (buffers-changed), which must not delete the row the list is still
    ;; dispatching the click to.
    (define (activate! i how)
      (if (memq how '(click double))
          (queue-callback (lambda () (activate-now! i how)) #f)
          (activate-now! i how)))
    (define (activate-now! i how)
      (define d (bench-row-data i))
      (case (and d (car d))
        [(file)
         (define p (cadr d))
         (cond
           [(file-exists? p) (set-current-buffer! (open-file! p))]
           [else (message "~a is no longer there." (base-name p)) (refresh-all!)])]
        [(folder root)
         (when (memq how '(double key)) (send i toggle-open/closed))]
        [(add-folder) (run-command/safe 'add-library-folder)]
        [(missing) (message "~a was not found. Check that it is connected, or remove it with Remove Folder…." (cadr d))]
        [else (void)]))

    (define (note-target! i)
      (define d (and i (bench-row-data i)))
      (set-library-target! (and d (memq (car d) '(file folder root)) d)))

    ;; Right-click: the row under the pointer is selected (by the list) and becomes the target.
    (define (context! lst i x y)
      (note-target! i)
      (when (library-target)
        (send lst popup-menu (build-popup-menu (library-context-groups)) x y)))

    ;; ---- Recent ----
    (define/public (refresh-recent!)
      (define es (filter (lambda (e) (file-exists? (recent-entry-path e))) (recent-entries recent-shown-count)))
      (send recent-list clear-rows!)
      (cond
        [(null? es) (add-bench-row! recent-list "Notes you open appear here." #f #:selectable? #f)]
        [else
         (for ([e (in-list es)])
           (define label (entry-label e es))
           (add-bench-row! recent-list (string-append (if (modified-path? (recent-entry-path e)) "• " "") label)
                           (list 'file (recent-entry-path e))))])
      (send recent-list min-height (+ 8 (* (row-height) (max 1 (length es)))))
      (follow-current!))

    ;; ---- Folders (lazily filled: a folder's rows are made when it is first opened) ----
    (define expanded (make-hash))    ; path-key -> #t for every open folder row
    (define filled (make-hasheq))    ; folder item -> #t once its children exist
    (define folder-items (make-hash)) ; path-key -> item, for every row made so far

    (define (folder-opened! i)
      (define d (bench-row-data i))
      (hash-set! expanded (path-key (cadr d)) #t)
      (unless (hash-ref filled i #f)
        (hash-set! filled i #t)
        (fill-folder! i (cadr d))))
    (define (folder-closed! i)
      (hash-remove! expanded (path-key (cadr (bench-row-data i)))))

    (define (fill-folder! item dir)
      (define-values (dirs files) (folder-children dir))
      (for ([d (in-list dirs)])
        (hash-set! folder-items (path-key d)
                   (add-bench-row! item (base-name d) (list 'folder (path->string d)) #:folder? #t)))
      (for ([f (in-list files)])
        (hash-set! folder-items (path-key f)
                   (add-bench-row! item (library-row-label f) (list 'file (path->string f))))))

    (define shown-roots (make-hash))   ; path-key -> #t for every Library folder shown so far
    (define/public (refresh-folders!)
      (define keep-selected (let ([i (send folders-list get-selected)]) (and i (bench-row-data i))))
      (define roots (library-folder-paths))
      ;; A Library folder starts open the first time it appears (at launch, or when added);
      ;; after that it stays however the person left it.
      (define root-keys (map path-key roots))
      (for ([k (in-list (hash-keys shown-roots))] #:unless (member k root-keys))
        (hash-remove! shown-roots k))                  ; removed: opens again if re-added
      (for ([r (in-list roots)] #:unless (hash-ref shown-roots (path-key r) #f))
        (hash-set! shown-roots (path-key r) #t)
        (hash-set! expanded (path-key r) #t))
      (define reopen (sort (hash-keys expanded) < #:key string-length))   ; parents first
      (send folders-list clear-rows!)
      (hash-clear! filled)
      (hash-clear! folder-items)
      (hash-clear! expanded)
      (cond
        [(null? roots)
         (add-bench-row! folders-list empty-library-text #f #:selectable? #f #:wrap? #t)
         (add-bench-row! folders-list "Add Folder…" (list 'add-folder))]
        [else
         (for ([r (in-list roots)])
           (define exists? (directory-exists? r))
           (define label (if exists? (base-name r) (format "~a (not found)" (base-name r))))
           (define item (if exists?
                            (add-bench-row! folders-list label (list 'root r) #:folder? #t)
                            (add-bench-row! folders-list label (list 'missing r))))
           (hash-set! folder-items (path-key r) item))
         (for ([k (in-list reopen)])
           (define i (hash-ref folder-items k #f))
           (when (and i (is-a? i hierarchical-list-compound-item<%>)) (send i open)))])
      ;; keep the selection on the same path if it is still there
      (define again (and keep-selected (hash-ref folder-items (path-key (cadr keep-selected)) #f)))
      (if again (send folders-list select-quietly! again) (follow-current!)))

    ;; Rows whose document gained or lost unsaved changes get "•" (or lose it).
    (define/public (refresh-modified!)
      (for ([(k i) (in-hash folder-items)])
        (define d (bench-row-data i))
        (when (and d (eq? (car d) 'file))
          (define want (library-row-label (cadr d)))
          (unless (equal? want (bench-row-label i))
            (set-bench-row-label! i want))))
      (send folders-list restyle-selection!)
      (refresh-recent!))

    ;; The selection follows the current document, so a click on another row always opens it.
    (define/public (follow-current!)
      (define b (current-buffer))
      (define p (and b (send b get-path)))
      (define key (and p (path-key p)))
      (define (find-in lst)
        (and key (for/first ([i (in-list (send lst all-rows))]
                             #:when (let ([d (bench-row-data i)])
                                      (and d (eq? (car d) 'file) (equal? (path-key (cadr d)) key))))
                   i)))
      (define r (find-in recent-list))
      (unless (eq? r (send recent-list get-selected)) (send recent-list select-quietly! r))
      (define f (and key (hash-ref folder-items key #f)))
      (when (and f (not (eq? f (send folders-list get-selected))))
        (send folders-list select-quietly! f)))

    (define/public (refresh-all!) (refresh-folders!) (refresh-recent!))

    (define/public (refresh-colors!)
      (for ([c (list filter-row recent-header folders-header)]) (send c refresh))
      (send recent-list refresh-colors!)
      (send folders-list refresh-colors!)
      (refresh))
    (inherit refresh)

    ;; ---- keyboard ----
    ;; Tab: filter row -> Recent -> Folders -> the document; Shift+Tab goes back. Escape returns
    ;; to the document. Return opens the selected row (a folder opens or closes). ⌘-shortcuts
    ;; (⌘N, ⇧⌘O, ⌥⌘S...) go through the document's keymap as they would from the editor, since
    ;; key events otherwise only dispatch through the focused editor canvas.
    (define/public (focus-order)
      (append (list filter-row)
              (if (collapsed? 'recent) '() (list recent-list))
              (if (collapsed? 'folders) '() (list folders-list))))
    (define/public (next-focus from shift?)
      (define order (focus-order))
      (define idx (index-of order from))
      (cond
        [(not idx) (if shift? 'document (car order))]
        [shift? (if (zero? idx) 'document (list-ref order (sub1 idx)))]
        [(= idx (sub1 (length order))) 'document]
        [else (list-ref order (add1 idx))]))
    (define (move-focus! target)
      (if (eq? target 'document) (run-hook 'focus-editor) (send target focus)))
    (define/public (focus-filter!) (send filter-row focus))

    (define/override (on-subwindow-char receiver e)
      (define code (send e get-key-code))
      (define mod? (if (mac?) (send e get-meta-down) (send e get-control-down)))
      (cond
        [(and (eqv? code #\tab) (not mod?) (not (send e get-alt-down)))
         (move-focus! (next-focus receiver (send e get-shift-down)))
         #t]
        [(eq? code 'escape) (move-focus! 'document) #t]
        [(and (is-a? receiver bench-list%) (memq code '(#\return #\newline numpad-enter)))
         (send receiver activate-selected!)
         #t]
        [(and mod? (not (memq code '(up down left right home end release))))
         (or (dispatch-key-event (current-buffer) e) (super on-subwindow-char receiver e))]
        [else (super on-subwindow-char receiver e)]))

    (layout-sections!)
    (refresh-all!)))

;; ---- Show Library -------------------------------------------------------------------------

(define-command (toggle-library)
  #:icon "book"
  #:aliases ("show library" "hide library" "show sidebar" "hide sidebar" "show folders" "library")
  #:help "Show or hide the Library beside your documents."
  #:title "Show Library" #:menu "View" #:menu-order 24 #:keys/mac ("Mod-Alt-s")
  #:checked sidebar-shown?
  (define on? (not (sidebar-shown?)))
  (setting-set! 'show-library on?)
  (set-sidebar-shown! on?)
  ;; Showing it puts the keyboard in it (the filter row), so the Library is reachable without
  ;; a mouse; hiding it gives the keyboard back to the document.
  (if on?
      (let ([s (main-sidebar)]) (when s (send s focus-filter!)))
      (run-hook 'focus-editor)))

;; ---- wiring -------------------------------------------------------------------------------

(register-sidebar!
 (lambda (parent)
   (define panel (new sidebar-panel% [parent parent]))
   (add-hook! 'window-activated (lambda () (send panel refresh-all!)))
   (add-hook! 'library-changed (lambda () (send panel refresh-all!)))
   ;; below recents.rkt's own after-save (priority 0), so Recent already has the save
   (add-hook! 'after-save (lambda (b) (send panel refresh-all!)) #:priority -5)
   (add-hook! 'buffers-changed (lambda () (send panel refresh-modified!)))
   (add-hook! 'buffer-modified-changed (lambda (b) (send panel refresh-modified!)))
   (add-hook! 'current-buffer-changed (lambda (b) (send panel follow-current!)))
   (add-hook! 'setting-changed (lambda (name)
                                 (when (memq name '(library-folders library-show-all-files))
                                   (send panel refresh-all!))))
   (add-hook! 'theme-changed (lambda () (send panel refresh-colors!)))
   (values panel (setting-ref 'show-library))))
