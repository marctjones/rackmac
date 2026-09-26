#lang racket/base
;; The Library sidebar (#273 lib-sidebar; docs/UI-DESIGN.md S2.1, #331 option (a)): Recent and
;; Folders on the bench beside the tabs, the painted filter row, View > Show Library (⌥⌘S) with
;; its state persisted, keyboard reachability, right-click actions, the empty state, refresh
;; on activate and after saves, and bench colors checked headless in both appearances.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file racket/list racket/path racket/string
         mrlib/hierlist
         "ui-harness.rkt"
         "../rackmac/library/folders.rkt" "../rackmac/library/new-note.rkt"
         "../rackmac/library/start-screen.rkt" "../rackmac/library/recents.rkt"
         "../rackmac/library/sidebar.rkt"
         "../rackmac/ui/sidebar.rkt" "../rackmac/ui/tokens.rkt" "../rackmac/ui/context-menu.rkt"
         "../rackmac/settings.rkt" "../rackmac/store.rkt" "../rackmac/editor.rkt" "../rackmac/frame.rkt"
         "../rackmac/command.rkt" "../rackmac/keymap.rkt" "../rackmac/hook.rkt")

(define dir (make-temporary-file "rackmac-sidebar~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))
(setting-set! 'library-folders '())
(setting-set! 'show-library #t)
(setting-set! 'library-collapsed-sections '())
(define lib (build-path dir "Notes"))
(make-directory* (build-path lib "Clients" "Acme"))
(make-directory* (build-path lib "node_modules"))
(for ([f '("Agenda.md" "b.txt" "c.py" "d.pdf" ".hidden.md" "data.csv")])
  (display-to-file (format "# ~a\n" f) (build-path lib f)))
(display-to-file "# Engagement\n" (build-path lib "Clients" "Engagement.md"))
(display-to-file "x" (build-path lib "node_modules" "skip.md"))
;; a OneDrive-synced folder, where the sync client puts it
(define synced (build-path dir "Library" "CloudStorage" "OneDrive-Acme" "Shared Notes"))
(make-directory* synced)
(display-to-file "# Memo\n" (build-path synced "Memo.md"))
(add-library-folder-path! lib)
(enable-recent-tracking!)
(clear-recent-files!)

(define f (make-main-frame))     ; hidden: show is never called
(define (panel) (main-sidebar))
(define (folders) (send (panel) get-folders-list))
(define (recent) (send (panel) get-recent-list))
(define (labels lst) (map bench-row-label (send lst all-rows)))
(define (row-for lst label)
  (findf (lambda (i) (equal? (bench-row-label i) label)) (send lst all-rows)))
(define (close-all!) (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b)))

;; ---- the tree, as data ----------------------------------------------------------------------

(test-case "a folder shows subfolders, then notes/text/code files, sorted; other files and hidden ones do not"
  (define-values (ds fs) (folder-children lib #:all? #f))
  (check-equal? (map (lambda (p) (path->string (file-name-from-path p))) ds) '("Clients"))
  (check-equal? (map (lambda (p) (path->string (file-name-from-path p))) fs)
                '("Agenda.md" "b.txt" "c.py" "data.csv"))
  (define-values (ds2 fs2) (folder-children lib #:all? #t))
  (check-not-false (member "d.pdf" (map (lambda (p) (path->string (file-name-from-path p))) fs2))
                   "the show-all setting shows every file")
  (check-false (member ".hidden.md" (map (lambda (p) (path->string (file-name-from-path p))) fs2))))

;; ---- in the window ------------------------------------------------------------------------

(test-case "the sidebar sits left of the document area, shown by default"
  (check-true (sidebar-shown?))
  (check-eq? (car (send (main-body) get-children)) (panel))
  (check-true (is-a? (folders) hierarchical-list%) "Folders is an editor-based hierlist (#331 a)")
  (check-true (is-a? (recent) hierarchical-list%) "and so is Recent"))

(test-case "Show Library toggles it, and the hidden state persists"
  (run-command 'toggle-library)
  (check-false (sidebar-shown?))
  (check-false (memq (panel) (send (main-body) get-children)))
  (check-equal? (store-ref (settings-file-path) 'show-library 'none) #f "written to settings.rktd")
  (check-false (command-checked? (find-command 'toggle-library)))
  (run-command 'toggle-library)
  (check-true (sidebar-shown?))
  (check-equal? (store-ref (settings-file-path) 'show-library 'none) #t)
  (check-true (command-checked? (find-command 'toggle-library))))

(test-case "View > Show Library, a checkable item beside Show Toolbar"
  (define view (menu-for-title "View"))
  (send view on-demand)
  (define labels (for/list ([i (send view get-items)] #:when (is-a? i labelled-menu-item<%>))
                   (regexp-replace #px"(\t.*|  .*)$" (send i get-label) "")))
  (check-not-false (member "Show Library" labels))
  (check-equal? (cadr (member "Show Toolbar" labels)) "Show Library")
  (check-true (is-a? (menu-item-for 'toggle-library) checkable-menu-item%))
  (check-true (send (menu-item-for 'toggle-library) is-checked?)))

(test-case "a click opens after the list has finished with the click (queued), not inside it"
  (close-all!)
  (define fl (folders))
  (define row (row-for fl "Agenda.md"))
  (send fl select-quietly! #f)
  (send fl click-row! row)
  (check-true (no-document-open?) "nothing yet: still inside the click")
  (let drain () (when (yield) (drain)))
  (check-equal? (send (current-buffer) get-name) "Agenda.md"))

(test-case "⌥⌘S is Show Library on macOS; Save All keeps its menu item without a key"
  (check-equal? (default-key-strings 'toggle-library 'mac) '("Mod-Alt-s"))
  (check-equal? (default-key-strings 'save-all 'mac) '())
  (check-equal? (command-menu (find-command 'save-all)) "File"))

(test-case "Folders: one open row per Library folder, its folders and files inside"
  (send (panel) refresh-all!)
  (define ls (labels (folders)))
  (check-equal? (take ls 6) '("Notes" "Clients" "Agenda.md" "b.txt" "c.py" "data.csv"))
  (check-false (member "d.pdf" ls))
  (check-false (member "node_modules" ls))
  (check-false (member "Engagement.md" ls) "a subfolder stays closed until opened"))

(test-case "a synced (OneDrive) folder appears like any folder"
  (add-library-folder-path! synced)
  (check-not-false (member "Shared Notes" (labels (folders))))
  (check-not-false (member "Memo.md" (labels (folders))))
  (remove-library-folder-path! synced)
  (check-false (member "Shared Notes" (labels (folders)))))

(test-case "keyboard: arrows move without opening, Right/Left open and close a folder, Return opens a file"
  (close-all!)
  (define fl (folders))
  (send fl select-quietly! (row-for fl "Clients"))
  (send fl on-char (new key-event% [key-code 'right]))      ; select-in: opens, selects its first row
  (check-not-false (member "Engagement.md" (labels fl)))
  (check-equal? (bench-row-label (send fl get-selected)) "Acme")
  (send fl on-char (new key-event% [key-code 'down]))
  (check-equal? (bench-row-label (send fl get-selected)) "Engagement.md")
  (check-true (no-document-open?) "moving the selection opens nothing")
  (send (panel) on-subwindow-char fl (new key-event% [key-code #\return]))
  (check-equal? (send (current-buffer) get-name) "Engagement.md")
  (send fl on-char (new key-event% [key-code 'left]))       ; select-out: back to the folder row
  (check-equal? (bench-row-label (send fl get-selected)) "Clients")
  (send (panel) on-subwindow-char fl (new key-event% [key-code #\return]))   ; Return on a folder closes it
  (check-false (member "Engagement.md" (labels fl))))

(test-case "Tab goes filter row -> Recent -> Folders -> document; Shift+Tab goes back"
  (define p (panel))
  (define fr (send p get-filter-row))
  (check-eq? (send p next-focus fr #f) (recent))
  (check-eq? (send p next-focus (recent) #f) (folders))
  (check-eq? (send p next-focus (folders) #f) 'document)
  (check-eq? (send p next-focus (folders) #t) (recent))
  (check-eq? (send p next-focus fr #t) 'document)
  (check-true (send p on-subwindow-char fr (new key-event% [key-code #\tab])) "the panel handles Tab itself")
  ;; a collapsed section drops out of the order, and its header persists that
  (send p toggle-section! 'recent)
  (check-eq? (send p next-focus fr #f) (folders))
  (check-equal? (setting-ref 'library-collapsed-sections) '(recent))
  (send p toggle-section! 'recent)
  (check-eq? (send p next-focus fr #f) (recent)))

(test-case "the filter row is a painted row that opens Quick Open on Return, Space or a click"
  (check-true (is-a? (send (panel) get-filter-row) filter-row%))
  (check-false (is-a? (send (panel) get-filter-row) text-field%) "no native field on the bench")
  (define ran 0)
  (define fr (new filter-row% [parent (new frame% [label "t"])] [on-activate (lambda () (set! ran (add1 ran)))]))
  (send fr on-char (new key-event% [key-code #\return]))
  (send fr on-char (new key-event% [key-code #\space]))
  (send fr on-event (new mouse-event% [event-type 'left-up]))
  (check-equal? ran 3))

(test-case "click (Return) opens a file in a single tab, however often"
  (close-all!)
  (define fl (folders))
  (send fl select-quietly! (row-for fl "Agenda.md"))
  (send fl activate-selected!)
  (send fl activate-selected!)
  (check-equal? (length (filter (lambda (b) (equal? (send b get-name) "Agenda.md")) (all-buffers))) 1)
  (check-equal? (send (current-buffer) get-name) "Agenda.md"))

(test-case "Recent lists opened files; the selection follows the current document"
  (send (panel) refresh-recent!)
  (check-not-false (member "Agenda.md" (labels (recent))))
  (check-equal? (bench-row-label (send (recent) get-selected)) "Agenda.md")
  (check-equal? (bench-row-label (send (folders) get-selected)) "Agenda.md"))

(test-case "an open document with unsaved changes gets \"•\" in both sections"
  (define b (current-buffer))
  (send b insert "more\n")
  (check-not-false (member "• Agenda.md" (labels (folders))))
  (check-not-false (member "• Agenda.md" (labels (recent))))
  (run-command 'save)
  (check-not-false (member "Agenda.md" (labels (folders))))
  (check-false (member "• Agenda.md" (labels (folders)))))

(test-case "refresh: after our own saves, and when the window is activated"
  (display-to-file "x" (build-path lib "Added outside.md"))
  (check-false (member "Added outside.md" (labels (folders))))
  (run-hook 'window-activated)
  (check-not-false (member "Added outside.md" (labels (folders))))
  (display-to-file "x" (build-path lib "Another.md"))
  (send (current-buffer) insert "x")
  (run-command 'save)
  (check-not-false (member "Another.md" (labels (folders))) "rescanned after a save"))

;; ---- right-click actions ------------------------------------------------------------------

(test-case "the right-click menu is the registry's `library` group, and stays out of documents' menus"
  (define names (apply append (library-context-groups)))
  (check-equal? (sort names symbol<?)
                (sort '(new-note-here new-library-folder rename-library-item trash-library-item
                        reveal-library-item copy-library-path) symbol<?))
  (for ([m '(markdown-mode text-mode racket-mode)])
    (check-false (ormap (lambda (n) (memq n names)) (apply append (editor-menu-groups m)))
                 (format "not in the ~a document menu" m)))
  (define menu (build-popup-menu (library-context-groups)))
  (check-equal? (length (filter (lambda (i) (is-a? i separator-menu-item%)) (send menu get-items))) 2))

(test-case "New Note Here makes the note in the chosen folder"
  (set-library-target! (list 'folder (path->string (build-path lib "Clients"))))
  (run-command 'new-note-here)
  (check-true (file-exists? (build-path lib "Clients" "Untitled 1.md")))
  (check-equal? (send (current-buffer) get-name) "Untitled 1.md"))

(test-case "New Folder… and Rename…"
  (set-library-target! (list 'root (path->string lib)))
  (parameterize ([ask-library-name (lambda (t p init) "Matters")])
    (run-command 'new-library-folder))
  (check-true (directory-exists? (build-path lib "Matters")))
  (check-not-false (member "Matters" (labels (folders))))
  ;; rename a file that is open: the document follows it
  (define old (build-path lib "b.txt"))
  (define b (open-file! old))
  (set-library-target! (list 'file (path->string old)))
  (parameterize ([ask-library-name (lambda (t p init) (check-equal? init "b.txt") "Brief.txt")])
    (run-command 'rename-library-item))
  (check-true (file-exists? (build-path lib "Brief.txt")))
  (check-false (file-exists? old))
  (check-equal? (send b get-name) "Brief.txt")
  (check-not-false (member "Brief.txt" (labels (folders))))
  ;; a Library folder itself is not renamed or trashed from here
  (set-library-target! (list 'root (path->string lib)))
  (check-false (command-enabled? (find-command 'rename-library-item)))
  (check-false (command-enabled? (find-command 'trash-library-item))))

(test-case "Move to Trash uses the Finder; if that fails, it asks before deleting"
  (define p (build-path lib "c.py"))
  (define asked #f)
  (define runner-got #f)
  (set-library-target! (list 'file (path->string p)))
  (parameterize ([move-to-trash-runner (lambda (q) (set! runner-got q) #t)]
                 [confirm-delete-permanently? (lambda (n) (set! asked n) #t)])
    (run-command 'trash-library-item))
  (check-equal? runner-got p)
  (check-false asked "the Finder took it: no question")
  (check-true (file-exists? p) "(the fake Finder did not really move it)")
  (set-library-target! (list 'file (path->string p)))
  (parameterize ([move-to-trash-runner (lambda (q) #f)]
                 [confirm-delete-permanently? (lambda (n) (set! asked n) #f)])
    (run-command 'trash-library-item))
  (check-equal? asked "c.py")
  (check-true (file-exists? p) "declined: nothing deleted")
  (set-library-target! (list 'file (path->string p)))
  (parameterize ([move-to-trash-runner (lambda (q) #f)]
                 [confirm-delete-permanently? (lambda (n) #t)])
    (run-command 'trash-library-item))
  (check-false (file-exists? p))
  (check-false (member "c.py" (labels (folders)))))

(test-case "the Finder script gets the path as an argument, never inside its text"
  (define argv (trash-argv (build-path lib "it's \"odd\".md")))
  (check-equal? (car argv) "osascript")
  (check-equal? (last argv) (path->string (build-path lib "it's \"odd\".md")))
  (check-false (ormap (lambda (a) (string-contains? a "odd")) (drop-right argv 1))))

(test-case "Copy Path"
  (set-library-target! (list 'file (path->string (build-path lib "Agenda.md"))))
  (run-command 'copy-library-path)
  (check-equal? (send the-clipboard get-clipboard-string 0) (path->string (build-path lib "Agenda.md"))))

;; ---- empty state --------------------------------------------------------------------------

(test-case "with no Library folders: the explanation and an Add Folder… row that adds one"
  (define saved (library-folder-paths))
  (setting-set! 'library-folders '())
  (define rows (send (folders) all-rows))
  (check-equal? (map bench-row-label rows) (list empty-library-text "Add Folder…"))
  (check-false (send (car rows) get-allow-selection?) "the explanation is not a row you can select")
  (send (folders) select-quietly! (cadr rows))
  (parameterize ([pick-folder-directory (lambda () lib)])
    (send (panel) on-subwindow-char (folders) (new key-event% [key-code #\return])))
  (check-equal? (library-folder-paths) (list (path->string lib)))
  (check-equal? (car (labels (folders))) "Notes")
  (setting-set! 'library-folders saved))

;; ---- the bench, headless, in both appearances ---------------------------------------------

(test-case "bench tokens: text on the bench is readable, the same bench in both appearances"
  (for ([a appearances])
    (check-true (>= (contrast-ratio (token-hex 'bench-text a) (token-hex 'bench a)) 4.5) (format "~a bench-text" a))
    (check-true (>= (contrast-ratio (token-hex 'bench-heading a) (token-hex 'bench a)) 4.5) (format "~a bench-heading" a))
    (check-true (>= (contrast-ratio (token-hex 'accent a) (token-hex 'bench a)) 3.0) (format "~a accent marker" a)))
  (check-true (>= (contrast-ratio (color->hex (selected-row-text-color #t)) highlight-hex) 4.5)
              "a focused selection's text reads on the OS highlight hierlist fills it with"))

(test-case "the filter row and section headers paint the bench with readable text"
  (for* ([a appearances] [s scales] [focused? '(#f #t)])
    (with-appearance a
      (lambda ()
        (define bm (render-bitmap 240 36 (lambda (dc) (draw-filter-row dc 240 36 #:focused? focused? #:shortcut "⇧⌘O"))
                                  #:scale s))
        (write-tour-png! (format "sidebar-filter-~a-~a~a" a s (if focused? "-focused" "")) bm)
        (check-equal? (dominant-color bm) (token-hex 'bench a))
        (check-true (>= (ink-contrast bm (token-hex 'bench a)) 4.5))
        (check-equal? (bitmap-pixel-hex bm 0.5 18) (if focused? (token-hex 'accent a) (token-hex 'bench a))
                      "the 2 px accent marker only when focused")
        (define hb (render-bitmap 240 26 (lambda (dc) (draw-section-header dc 240 26 "Folders")) #:scale s))
        (check-equal? (dominant-color hb) (token-hex 'bench a))
        (check-equal? (bitmap-pixel-hex hb 100 0) (token-hex 'bench-rule a) "the rule above the section")
        (check-true (>= (ink-contrast hb (token-hex 'bench a)) 4.5))))))

(test-case "the Folders list itself draws on the bench: no white boxes, readable rows, a marker on the selection"
  (for ([a appearances])
    (with-appearance a
      (lambda ()
        (send (panel) refresh-colors!)
        (define fl (folders))
        (send fl select-quietly! (row-for fl "Agenda.md"))
        (define ed (send fl get-editor))
        (define bm (render-bitmap 240 200 (lambda (dc) (send ed print-to-dc dc 1)) #:background (token 'bench)))
        (write-tour-png! (format "sidebar-folders-~a" a) bm)
        (define colors (bitmap-colors bm))
        (check-false (hash-ref colors "#FFFFFF" #f) "nested rows are transparent, not white")
        (check-equal? (dominant-color bm) (token-hex 'bench a))
        (check-true (>= (ink-contrast bm (token-hex 'bench a)) 4.5))
        (check-true (get-field on? (bench-row-marker (send fl get-selected))) "the selected row's marker is on")
        (check-not-false (hash-ref colors (token-hex 'accent a) #f) "and it is painted in the accent")))))
