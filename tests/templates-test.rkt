#lang racket/base
;; New from Template (#353 note-templates): a Templates folder of plain .md files, File > New
;; from Template listing them as a submenu rebuilt every time it opens, Tools > Edit Templates
;; revealing the folder, and {{date}}/{{time}}/{{title}}/{{cursor}} substitution with a fixed
;; clock (the same current-clock parameter tests/insert-date-test.rkt uses).
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/file racket/class racket/gui/base racket/path racket/list racket/date
         "../rackmac/templates.rkt" "../rackmac/library/folders.rkt" "../rackmac/library/new-note.rkt"
         "../rackmac/settings.rkt" "../rackmac/editor.rkt" "../rackmac/command.rkt" "../rackmac/commands.rkt"
         "../rackmac/frame.rkt" "../rackmac/platform.rkt" "../rackmac/insert-date.rkt" "../rackmac/md-view.rkt")

(define home (make-temporary-file "rackmac-templates~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string home)))
(setting-set! 'library-folders '())
(setting-set! 'templates-folder "")

;; 2026-09-30 14:05 local time, the same fixture insert-date-test.rkt uses.
(define fixed (find-seconds 0 5 14 30 9 2026))

;; The default location (rackmac/templates.rkt: empty templates-folder => config-dir/Templates)
;; -- one fixed path for this whole process (RACKMAC_HOME is set once, above), so tests that
;; want it fresh delete it first rather than getting a brand new one each time.
(define default-dir (build-path (config-dir) "Templates"))
(define (reset-default-templates!)
  (setting-set! 'templates-folder "")
  (when (directory-exists? default-dir) (delete-directory/files default-dir))
  default-dir)

;; Each test gets its own fresh Library folder, and the default templates folder reset (deleted,
;; then re-seeded if asked), so file names and template lists never collide across test cases.
(define counter 0)
(define (fresh! #:seed-templates? [seed? #f])
  (set! counter (add1 counter))
  (define lib (build-path home (format "Notes~a" counter)))
  (make-directory* lib)
  (setting-set! 'library-folders '())
  (add-library-folder-path! lib)
  (reset-default-templates!)
  (when seed? (scan-templates))     ; touching it seeds the three examples into the fresh folder
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (values lib default-dir))

(define (memo-path) (car (filter (lambda (p) (equal? (template-title-for p) "Memo")) (scan-templates))))

;; ---- render-template: pure placeholder substitution ---------------------------------------

(test-case "known placeholders are replaced; an unknown one is left exactly as typed"
  (define-values (body cursor)
    (render-template "# {{title}}\n\n{{date}} {{time}}\n\nClient: {{client}}\n\n{{cursor}}" "My Title" fixed))
  (check-equal? body "# My Title\n\n2026-09-30 14:05\n\nClient: {{client}}\n\n")
  (check-equal? cursor (string-length body)))

(test-case "with no {{cursor}}, the caret goes at the very end"
  (define-values (body cursor) (render-template "{{title}}, no cursor here" "T" fixed))
  (check-equal? cursor (string-length body)))

(test-case "{{cursor}} in the middle: the offset points right after what came before it"
  (define-values (body cursor) (render-template "Before\n{{cursor}}\nAfter" "T" fixed))
  (check-equal? body "Before\n\nAfter")
  (check-equal? cursor (string-length "Before\n")))

(test-case "a template with a checklist BEFORE {{cursor}} still lands the caret at the right offset"
  ;; checkbox-snip% keeps a 3-character width even once rendered as a snip (md-checkbox.rkt),
  ;; so the plain-text offset computed here should still be correct after Formatted rendering.
  (define-values (body cursor) (render-template "- [ ] a task\n\n{{cursor}}here" "T" fixed))
  (check-equal? cursor (string-length "- [ ] a task\n\n")))

;; ---- scan-templates: seeding the default folder, listing, the custom-folder setting --------

(test-case "scan-templates seeds the three examples into a fresh default folder, sorted by name"
  (reset-default-templates!)
  (check-false (directory-exists? default-dir))
  (define paths (scan-templates))
  (check-equal? (map template-title-for paths) '("Call note" "Meeting note" "Memo"))
  (check-true (directory-exists? default-dir))
  (for ([p paths]) (check-true (file-exists? p))))

(test-case "seeding never happens twice: a deleted example stays deleted"
  (reset-default-templates!)
  (scan-templates)
  (delete-file (build-path default-dir "Memo.md"))
  (check-equal? (map template-title-for (scan-templates)) '("Call note" "Meeting note")))

(test-case "the templates-folder setting points scan-templates at a folder of your own"
  (reset-default-templates!)
  (define custom (build-path home "MyOwnTemplates"))
  (make-directory* custom)
  (display-to-file "hi" (build-path custom "Custom.md"))
  (setting-set! 'templates-folder (path->string custom))
  (check-equal? (map template-title-for (scan-templates)) '("Custom"))
  ;; a custom folder is never seeded with the three examples -- only the default location is
  (check-equal? (directory-list custom) (list (string->path "Custom.md"))))

(test-case "a missing custom folder is never fatal, and is never silently created either"
  (reset-default-templates!)
  (define missing (build-path home "does-not-exist-at-all"))
  (setting-set! 'templates-folder (path->string missing))
  (check-equal? (scan-templates) '())
  (check-false (directory-exists? missing) "pointing the setting at a path never creates it"))

;; ---- create-note-from-template!: the acceptance criteria ----------------------------------

(test-case "the note is created in the selected Library folder, named from the title, in Formatted"
  (define-values (lib tdir) (fresh! #:seed-templates? #t))
  (setting-set! 'markdown-default-view 'source)   ; prove Formatted is forced, not just the default
  (parameterize ([ask-template-title (lambda (name) "Acme Kickoff")]
                 [current-clock (lambda () fixed)])
    (create-note-from-template! (memo-path)))
  (define b (current-buffer))
  (check-equal? (send b get-name) "Acme Kickoff.md")
  (check-true (file-exists? (build-path lib "Acme Kickoff.md")))
  (check-eq? (markdown-view b) 'formatted)
  (setting-set! 'markdown-default-view 'formatted))

(test-case "placeholders are filled from the title and the (fixed) clock"
  (define-values (lib tdir) (fresh! #:seed-templates? #t))
  (parameterize ([ask-template-title (lambda (name) "Roe v. Doe")]
                 [current-clock (lambda () fixed)])
    (create-note-from-template! (memo-path)))
  (define b (current-buffer))
  (check-equal? (send b get-text) "# Memo: Roe v. Doe\n\n2026-09-30\n\n")
  ;; the sanitized title, not the raw one, becomes the file name (new-note.rkt's own rule)
  (check-equal? (send b get-name) "Roe v. Doe.md"))

(test-case "the caret lands where {{cursor}} was"
  (define-values (lib tdir) (fresh! #:seed-templates? #t))
  (parameterize ([ask-template-title (lambda (name) "T")] [current-clock (lambda () fixed)])
    (create-note-from-template! (memo-path)))
  (define b (current-buffer))
  (check-equal? (send b get-start-position) (string-length "# Memo: T\n\n2026-09-30\n\n")))

(test-case "an unknown {{...}} placeholder is left as typed in the created note"
  (define-values (lib tdir) (fresh!))
  (make-directory* tdir)
  (display-to-file "# {{title}}\n\nMatter: {{matter}}\n{{cursor}}" (build-path tdir "Custom.md"))
  (define custom (car (scan-templates)))
  (parameterize ([ask-template-title (lambda (name) "New Case")] [current-clock (lambda () fixed)])
    (create-note-from-template! custom))
  (check-equal? (send (current-buffer) get-text) "# New Case\n\nMatter: {{matter}}\n"))

(test-case "a canceled title dialog creates nothing"
  (define-values (lib tdir) (fresh! #:seed-templates? #t))
  (define before (directory-list lib))
  (parameterize ([ask-template-title (lambda (name) #f)])
    (create-note-from-template! (memo-path)))
  (check-equal? (directory-list lib) before))

(test-case "with no Library folder, it offers to add one; declining cancels it"
  (define-values (lib tdir) (fresh! #:seed-templates? #t))
  (setting-set! 'library-folders '())
  (parameterize ([ask-template-title (lambda (name) "T")]
                 [confirm-add-folder-first? (lambda () #f)])
    (create-note-from-template! (memo-path)))
  (check-equal? (directory-list lib) '()))

(test-case "a second note from the same title gets a unique file name"
  (define-values (lib tdir) (fresh! #:seed-templates? #t))
  (parameterize ([ask-template-title (lambda (name) "Dup")] [current-clock (lambda () fixed)])
    (create-note-from-template! (memo-path))
    (create-note-from-template! (memo-path)))
  (check-true (file-exists? (build-path lib "Dup.md")))
  (check-true (file-exists? (build-path lib "Dup 1.md"))))

;; ---- File > New from Template: the submenu -------------------------------------------------

(define f (make-main-frame))          ; hidden: show is never called
(define (labels m) (for/list ([i (send m get-items)]) (send i get-label)))

(test-case "the submenu exists under File, right after New Note"
  (check-not-false (menu-for-title "New from Template")))

(test-case "an unseeded, empty folder shows a disabled placeholder"
  (define-values (lib tdir) (fresh!))
  (make-directory* tdir)     ; exists, but empty -- scan-templates must not reseed an existing folder
  (define m (menu-for-title "New from Template"))
  (send m on-demand)
  (check-equal? (labels m) '("No templates yet."))
  (check-false (send (car (send m get-items)) is-enabled?)))

(test-case "it lists the templates, and clicking one asks for a title and creates the note"
  (define-values (lib tdir) (fresh! #:seed-templates? #t))
  (define m (menu-for-title "New from Template"))
  (send m on-demand)
  (check-equal? (labels m) '("Call note" "Meeting note" "Memo"))
  (define memo-item (findf (lambda (i) (equal? (send i get-label) "Memo")) (send m get-items)))
  (parameterize ([ask-template-title (lambda (name) "Clicked")] [current-clock (lambda () fixed)])
    (send memo-item command (new control-event% [event-type 'menu])))
  (check-equal? (send (current-buffer) get-name) "Clicked.md"))

(test-case "the menu updates when a template is added or removed: rescanned on open, not cached"
  (define-values (lib tdir) (fresh! #:seed-templates? #t))
  (define m (menu-for-title "New from Template"))
  (send m on-demand)
  (check-equal? (labels m) '("Call note" "Meeting note" "Memo"))
  (display-to-file "{{cursor}}" (build-path tdir "Motion.md"))
  (delete-file (build-path tdir "Memo.md"))
  (send m on-demand)
  (check-equal? (labels m) '("Call note" "Meeting note" "Motion")))

;; ---- the new-from-template command: palette / start screen ---------------------------------

(test-case "reachable by name, off the top menus (the submenu is the File-menu entry point)"
  (define c (find-command 'new-from-template))
  (check-not-false c)
  (check-false (command-menu c))
  (check-not-false (member "new from template" (command-aliases c))))

(test-case "the command lists templates via the pick-template parameter, then creates the note"
  (define-values (lib tdir) (fresh! #:seed-templates? #t))
  (parameterize ([pick-template (lambda () (memo-path))]
                 [ask-template-title (lambda (name) "Via Command")]
                 [current-clock (lambda () fixed)])
    (run-command 'new-from-template))
  (check-equal? (send (current-buffer) get-name) "Via Command.md"))

(test-case "with no templates at all, it says so instead of opening an empty picker"
  (define-values (lib tdir) (fresh!))
  (make-directory* tdir)
  (define asked? #f)
  (parameterize ([pick-template (lambda () (set! asked? #t) #f)])
    (run-command 'new-from-template))
  (check-false asked?))

;; ---- Tools > Edit Templates -----------------------------------------------------------------

(test-case "Edit Templates creates the default folder, seeds it, and opens it"
  (define-values (lib tdir) (fresh!))
  (check-false (directory-exists? tdir))
  (define opened #f)
  (parameterize ([edit-templates-folder! (lambda (d) (set! opened d) #t)])
    (run-command 'edit-templates))
  (check-equal? opened tdir)
  (check-true (directory-exists? tdir))
  (check-equal? (length (directory-list tdir)) 3))

(test-case "Edit Templates on a custom folder creates it empty -- no seeding someone else's folder"
  (fresh!)
  (define custom (build-path home "EditCustom"))
  (setting-set! 'templates-folder (path->string custom))
  (parameterize ([edit-templates-folder! (lambda (d) #t)])
    (run-command 'edit-templates))
  (check-true (directory-exists? custom))
  (check-equal? (directory-list custom) '()))

(test-case "reachable, in Tools, with help and an alias"
  (define c (find-command 'edit-templates))
  (check-equal? (command-menu c) "Tools")
  (check-not-false (member "edit templates" (command-aliases c)))
  (check-false (string=? (command-help c) "")))

(test-case "when the launcher fails, the folder still exists (no silent no-op, no crash)"
  (define-values (lib tdir) (fresh!))
  (parameterize ([edit-templates-folder! (lambda (d) #f)])
    (run-command 'edit-templates))
  (check-true (directory-exists? tdir)))
