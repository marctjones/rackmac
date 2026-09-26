#lang racket/base
;; The Library (#272 lib-folders): an ordered list of folders the person chose, persisted as
;; the `library-folders` setting (rackmac/settings.rkt). A folder is a folder: a plain one, or
;; one a sync client keeps up to date (OneDrive, SharePoint under OneDrive, iCloud Drive) --
;; Rackmac reads and writes files, the sync client does the syncing (docs/UI-DESIGN.md S2.1).
;;
;; Paths are stored as strings, not `path?` values: put-preferences writes under
;; `with-pref-params`, which turns off `print-struct`, and a `path?` (like a struct) prints
;; unreadable that way (rackmac/library/recents.rkt hit the same thing first).
;;
;; Pure data plus the Add/Remove Folder commands; no sidebar here (that is #273, later).
(require racket/list racket/string racket/path racket/file
         racket/class racket/gui/base
         "../settings.rkt" "../command.rkt" "../frame.rkt" "../editor.rkt" "../picker.rkt")
(provide library-folder-paths add-library-folder-path! remove-library-folder-path!
         selected-library-folder candidate-library-folders
         library-folder-status library-folder-hint
         pick-folder-directory pick-folder-to-remove)

(define-setting library-folders
  #:contract (lambda (v) (and (list? v) (andmap string? v)))
  #:default '()
  #:doc "The folders that make up your Library, in order."
  #:category "Library")

(define (library-folder-paths) (setting-ref 'library-folders))
(define (set-library-folder-paths! ps) (setting-set! 'library-folders ps))

(define (normalize-dir p) (path->string (simplify-path (path->complete-path p))))

(define (add-library-folder-path! p)
  (define n (normalize-dir p))
  (unless (member n (library-folder-paths))
    (set-library-folder-paths! (append (library-folder-paths) (list n)))))

(define (remove-library-folder-path! p)
  (define n (normalize-dir p))
  (set-library-folder-paths! (remove n (library-folder-paths))))

;; The folder New Note (and Quick Open) use when nothing more specific has been chosen --
;; there is no sidebar selection yet (#273), so this is simply the first one, existing or not
;; (a missing first folder is still reported, never silently skipped).
(define (selected-library-folder)
  (define fs (library-folder-paths))
  (and (pair? fs) (car fs)))

;; ---- Add Folder… suggestions ------------------------------------------------------------
;; `home` is a parameter so a test can point this at a fake tree instead of the real
;; ~/Library/CloudStorage. Only folders that exist and are not already in the Library are
;; offered (docs/UI-DESIGN.md S2.1: Documents, OneDrive-*, OneDrive-SharedLibraries-* under
;; CloudStorage, and iCloud Drive).
(define (onedrive-candidates cloud-storage)
  (if (directory-exists? cloud-storage)
      (sort (for/list ([d (in-list (directory-list cloud-storage))]
                       #:when (regexp-match? #rx"^OneDrive-" (path->string d)))
              (build-path cloud-storage d))
            string<? #:key path->string)
      '()))

(define (candidate-library-folders [home (find-system-path 'home-dir)])
  (define cloud-storage (build-path home "Library" "CloudStorage"))
  (define icloud (build-path home "Library" "Mobile Documents" "com~apple~CloudDocs"))
  (define documents (build-path home "Documents"))
  (define already (map normalize-dir (filter directory-exists? (library-folder-paths))))
  (filter (lambda (p) (and (directory-exists? p) (not (member (normalize-dir p) already))))
          (list* documents icloud (onedrive-candidates cloud-storage))))

;; The dialog itself: a parameter (docs/DEVELOPMENT.md: "dialogs that ask the user something
;; are parameters") so tests can answer without a native folder picker. The default starts
;; the OS dialog at the first suggestion that exists, if any.
(define pick-folder-directory
  (make-parameter
   (lambda ()
     (define cands (candidate-library-folders))
     (get-directory "Add Folder" (ui-parent) (and (pair? cands) (car cands))))))

(define-command (add-library-folder)
  #:icon "book"
  #:aliases ("add folder" "add library folder" "new library folder" "add notes folder")
  #:help "Add a folder to your Library."
  #:title "Add Folder…" #:menu "File" #:menu-order 14
  #:doc "Choose a folder -- a plain folder, or one a OneDrive/SharePoint/iCloud Drive sync client already keeps up to date -- and add it to your Library."
  (define p ((pick-folder-directory)))
  (when p
    (add-library-folder-path! (path->string p))
    (message "Added ~a to your Library." (path->string p))))

;; ---- Remove Folder ------------------------------------------------------------------------
;; No sidebar yet to click a folder in (#273), so Remove Folder picks from the list; a folder
;; that no longer exists (unmounted drive, renamed share) is never fatal -- it shows a hint
;; here instead of being silently dropped or crashing anything that reads the Library.
(define (library-folder-status p) (if (directory-exists? p) 'ok 'missing))
(define (library-folder-hint p)
  (case (library-folder-status p) [(missing) "not found -- check that it is connected"] [else ""]))

;; A parameter, like pick-folder-directory above, so tests never have to drive the real modal
;; `pick` dialog (rackmac/picker.rkt) just to prove Remove Folder works.
(define pick-folder-to-remove
  (make-parameter
   (lambda ()
     (define items (for/list ([p (library-folder-paths)]) (list p (library-folder-hint p) p)))
     (pick "Remove Folder" items #:detail-heading "Status"))))

(define-command (remove-library-folder)
  #:when (lambda () (pair? (library-folder-paths)))
  #:icon "book"
  #:aliases ("remove folder" "remove library folder" "delete library folder")
  #:help "Remove a folder from your Library (its files are not touched)."
  #:title "Remove Folder…" #:menu "File" #:menu-order 15
  #:doc "Choose one of your Library folders to remove. The folder and its files are left alone on disk."
  (define choice ((pick-folder-to-remove)))
  (when choice
    (remove-library-folder-path! choice)
    (message "Removed ~a from your Library." choice)))
