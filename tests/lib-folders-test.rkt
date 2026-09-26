#lang racket/base
;; The Library folder list (#272 lib-folders): an ordered setting, Add/Remove Folder commands
;; (dialogs as parameters, per docs/DEVELOPMENT.md), OneDrive/SharePoint/iCloud Drive
;; suggestions from a fake home tree, and a missing folder that is reported, never fatal.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/file racket/list racket/path
         "../rackmac/library/folders.rkt" "../rackmac/settings.rkt" "../rackmac/command.rkt"
         "../rackmac/platform.rkt" "../rackmac/hook.rkt")

(define dir (make-temporary-file "rackmac-libfolders~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))
(setting-set! 'library-folders '())    ; the setting may have seeded from an unrelated config dir

(define (folder n) (build-path dir (format "folder-~a" n)))
(define (mk! p) (make-directory* p) (path->string (simplify-path (path->complete-path p))))

(test-case "adding a folder appends it, in order, and paths are normalized"
  (setting-set! 'library-folders '())
  (define a (mk! (folder 1)))
  (define b (mk! (folder 2)))
  (add-library-folder-path! (folder 1))
  (add-library-folder-path! (folder 2))
  (check-equal? (library-folder-paths) (list a b)))

(test-case "adding the same folder twice does not duplicate it"
  (setting-set! 'library-folders '())
  (add-library-folder-path! (folder 1))
  (add-library-folder-path! (folder 1))
  (check-equal? (length (library-folder-paths)) 1))

(test-case "removing a folder leaves the rest, in order"
  (setting-set! 'library-folders '())
  (add-library-folder-path! (folder 1))
  (add-library-folder-path! (folder 2))
  (add-library-folder-path! (folder 3))
  (remove-library-folder-path! (folder 2))
  (check-equal? (library-folder-paths) (list (mk! (folder 1)) (mk! (folder 3)))))

(test-case "the setting survives a simulated restart"
  (setting-set! 'library-folders '())
  (add-library-folder-path! (folder 1))
  (check-true (file-exists? (settings-file-path)))
  ;; A fresh registration (as Reload Extensions or a real restart would do) reads it back.
  (define-setting library-folders #:contract (lambda (v) (and (list? v) (andmap string? v)))
    #:default '() #:doc "d" #:category "Library")
  (check-equal? (library-folder-paths) (list (mk! (folder 1)))))

(test-case "a synced folder is added and read back exactly like any other folder"
  (setting-set! 'library-folders '())
  (define synced (mk! (build-path dir "Library" "CloudStorage" "OneDrive-Acme")))
  (add-library-folder-path! synced)
  (check-equal? (library-folder-paths) (list synced))
  (check-eq? (library-folder-status synced) 'ok))

(test-case "the Add Folder dialog is a parameter tests can answer without a native picker"
  (setting-set! 'library-folders '())
  (define chosen (mk! (folder 9)))
  (parameterize ([pick-folder-directory (lambda () (string->path chosen))])
    (run-command 'add-library-folder))
  (check-equal? (library-folder-paths) (list chosen)))

(test-case "cancelling the Add Folder dialog changes nothing"
  (setting-set! 'library-folders '())
  (parameterize ([pick-folder-directory (lambda () #f)])
    (run-command 'add-library-folder))
  (check-equal? (library-folder-paths) '()))

(test-case "Remove Folder is only enabled when the Library has a folder"
  (setting-set! 'library-folders '())
  (check-false (command-enabled? (find-command 'remove-library-folder)))
  (add-library-folder-path! (folder 1))
  (check-true (command-enabled? (find-command 'remove-library-folder))))

;; ---- missing folders: dimmed with a hint, never fatal ------------------------------------

(test-case "a missing folder is reported as missing, with a hint, and never raises"
  (setting-set! 'library-folders '())
  (define gone (path->string (build-path dir "was-here")))
  (add-library-folder-path! gone)     ; add-library-folder-path! itself must not require it exist
  (check-equal? (library-folder-status gone) 'missing)
  (check-regexp-match #rx"not found" (library-folder-hint gone))
  (check-equal? (library-folder-status (mk! (folder 1))) 'ok)
  (check-equal? (library-folder-hint (mk! (folder 1))) ""))

(test-case "Remove Folder's dialog is a parameter, and can remove a folder that is gone"
  (setting-set! 'library-folders '())
  (define gone (path->string (build-path dir "gone-folder")))
  (add-library-folder-path! gone)
  (parameterize ([pick-folder-to-remove (lambda () gone)])
    (run-command 'remove-library-folder))
  (check-equal? (library-folder-paths) '()))

(test-case "cancelling Remove Folder changes nothing"
  (setting-set! 'library-folders '())
  (add-library-folder-path! (folder 1))
  (parameterize ([pick-folder-to-remove (lambda () #f)])
    (run-command 'remove-library-folder))
  (check-equal? (length (library-folder-paths)) 1))

;; ---- suggestions: only existing, not-yet-added folders ------------------------------------

(test-case "suggestions list Documents, iCloud Drive and OneDrive folders that exist"
  (setting-set! 'library-folders '())
  (define home (mk! (build-path dir "home")))
  (mk! (build-path home "Documents"))
  (mk! (build-path home "Library" "CloudStorage" "OneDrive-Acme"))
  (mk! (build-path home "Library" "CloudStorage" "OneDrive-SharedLibraries-Acme"))
  (mk! (build-path home "Library" "CloudStorage" "NotOneDrive-Ignored"))
  (mk! (build-path home "Library" "Mobile Documents" "com~apple~CloudDocs"))
  (define cs (map path->string (candidate-library-folders home)))
  (check-true (ormap (lambda (p) (regexp-match? #rx"Documents$" p)) cs))
  (check-true (ormap (lambda (p) (regexp-match? #rx"CloudDocs$" p)) cs))
  (check-true (ormap (lambda (p) (regexp-match? #rx"OneDrive-Acme$" p)) cs))
  (check-true (ormap (lambda (p) (regexp-match? #rx"OneDrive-SharedLibraries-Acme$" p)) cs))
  (check-false (ormap (lambda (p) (regexp-match? #rx"NotOneDrive" p)) cs)))

(test-case "a folder already in the Library is not suggested again"
  (setting-set! 'library-folders '())
  (define home (mk! (build-path dir "home2")))
  (define docs (mk! (build-path home "Documents")))
  (add-library-folder-path! docs)
  (check-false (member docs (map path->string (candidate-library-folders home)))))

(test-case "a home with nothing set up yet suggests nothing that does not exist"
  (setting-set! 'library-folders '())
  (define home (mk! (build-path dir "home-empty")))
  (check-equal? (candidate-library-folders home) '()))
