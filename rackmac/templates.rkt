#lang racket/base
;; New from Template (#353 note-templates): a Templates folder of ordinary .md files. File >
;; New from Template lists them as a submenu (rescanned every time it opens, the same
;; register-submenu! mechanism as Open Recent, rackmac/library/open-recent.rkt); Tools >
;; Edit Templates reveals the folder so a person edits the files in Rackmac itself; the start
;; screen's New from Template action opens the same picker as the palette. A sibling of
;; rackmac/library/new-note.rkt (#276): the folder-picking and file-naming pieces are reused
;; from there instead of duplicated.
;;
;; A template is plain Markdown with four placeholders: {{date}}, {{time}}, {{title}} (asked
;; in a small dialog before creating -- a parameter, like every other asking dialog here, so
;; tests answer it) and {{cursor}} (removed from the text; the caret lands where it was). Any
;; other {{...}} is left exactly as typed -- render-template only ever substitutes the four
;; known names.
(require racket/class racket/gui/base racket/string racket/path racket/file racket/format
         "command.rkt" "editor.rkt" "settings.rkt" "platform.rkt" "insert-date.rkt" "md-view.rkt"
         "picker.rkt" "commands.rkt" "hook.rkt" "frame.rkt"
         "library/folders.rkt" "library/new-note.rkt")
(provide ask-template-title pick-template edit-templates-folder!
         templates-dir scan-templates template-title-for render-template
         create-note-from-template!)

;; ---- where templates live ---------------------------------------------------------------
;; Empty (the default) means "Templates" inside the config dir; a person can point this at a
;; folder of their own instead (a Library folder, say, so a Templates folder syncs the same
;; way the rest of their notes do) -- an ordinary setting, so Settings… already has a row for
;; it (rackmac/ui/settings-dialog.rkt builds one for every registered setting).
;;
;; The default is the empty string, not a path built from config-dir here: config-dir reads an
;; environment variable (RACKMAC_HOME) that a test sets after this module is required, and a
;; #:default is computed once, at registration time -- baking the path in would freeze it to
;; whatever config-dir was before the test pointed it elsewhere. templates-dir resolves it
;; fresh on every call instead.
(define-setting templates-folder
  #:contract string? #:default ""
  #:doc "Folder your templates are kept in. Empty uses the Templates folder in your config folder."
  #:category "Templates")

(define (custom-templates-folder) (let ([v (setting-ref 'templates-folder)]) (and (non-empty-string? v) v)))
(define (default-templates-dir) (build-path (config-dir) "Templates"))
(define (templates-dir)
  (define custom (custom-templates-folder))
  (if custom (string->path custom) (default-templates-dir)))

;; ---- the three examples --------------------------------------------------------------------
;; Bundled as strings and written out to real, editable files the first time the folder is
;; looked at -- the same pattern rackmac/library/start-screen.rkt's Getting Started note and
;; rackmac/commands.rkt's init-file template use, so this is an ordinary note a person can
;; edit or delete, not a read-only resource inside the app. {{cursor}} sits above any
;; checklist in each one: a checkbox becomes a snip that keeps its own 3-character width
;; (md-checkbox.rkt), so this is not required for correctness, but it keeps the caret
;; landing in the obvious place regardless.
(define example-templates
  (list
   (cons "Call note.md" #<<TEXT
# Call with {{title}}

{{date}} {{time}}

## Notes

{{cursor}}

## Follow-up

- [ ]
TEXT
     )
   (cons "Meeting note.md" #<<TEXT
# {{title}}

{{date}} {{time}}

## Attendees

-

## Agenda

{{cursor}}

## Action Items

- [ ]
TEXT
     )
   (cons "Memo.md" #<<TEXT
# Memo: {{title}}

{{date}}

{{cursor}}
TEXT
     )))

;; Creates and seeds the DEFAULT folder the first time it does not exist -- never again after
;; that, so a template a person deleted on purpose stays deleted. Never called for a custom
;; #:templates-folder: pointing this setting at a folder of your own (a Library folder, say)
;; must never silently drop three example files into it, the same way library/folders.rkt
;; never creates a Library folder a person merely typed the path of.
(define (seed-default-if-new! dir)
  (unless (directory-exists? dir)
    (make-directory* dir)
    (for ([t (in-list example-templates)])
      (display-to-file (cdr t) (build-path dir (car t))))))

;; Every .md/.markdown file directly in the templates folder, sorted by name -- seeding the
;; default location first if this is the first time anything has looked at it. A missing
;; custom folder (an unmounted drive, a renamed share) is never fatal: it just has nothing in
;; it yet, same as library/folders.rkt treats a missing Library folder.
(define (scan-templates)
  (define dir (templates-dir))
  (unless (custom-templates-folder) (seed-default-if-new! dir))
  (if (directory-exists? dir)
      (sort (for/list ([p (in-list (directory-list dir #:build? #t))]
                       #:when (and (file-exists? p)
                                   (member (path-get-extension p) '(#".md" #".markdown"))))
              p)
            string-ci<? #:key (lambda (p) (path->string (file-name-from-path p))))
      '()))

;; A template's display name: its file name without the extension ("Call note.md" -> "Call note").
(define (template-title-for p)
  (path->string (path-replace-extension (file-name-from-path p) #"")))

;; ---- placeholders -----------------------------------------------------------------------

(define (two n) (~r n #:min-width 2 #:pad-string "0"))
(define (time-string [secs ((current-clock))])
  (define d (seconds->date secs))
  (format "~a:~a" (two (date-hour d)) (two (date-minute d))))

(define placeholder-rx #px"\\{\\{([A-Za-z0-9_]+)\\}\\}")

;; {{date}}, {{time}} and {{title}} are replaced; every other {{...}} -- including {{cursor}},
;; on purpose -- comes back exactly as it matched, so an unknown placeholder is left typed
;; rather than stripped.
(define (substitute-known text title secs)
  (regexp-replace* placeholder-rx text
                   (lambda (whole key)
                     (cond [(string=? key "date") (date-string secs)]
                           [(string=? key "time") (time-string secs)]
                           [(string=? key "title") title]
                           [else whole]))))

;; Removes the first {{cursor}} and returns the character offset it sat at; with none, the
;; caret goes at the very end of the note.
(define (extract-cursor text)
  (define m (regexp-match-positions #rx"\\{\\{cursor\\}\\}" text))
  (if m
      (let ([start (caar m)] [end (cdar m)])
        (values (string-append (substring text 0 start) (substring text end)) start))
      (values text (string-length text))))

;; The note's text and the caret offset within it, given a template's raw source, the title
;; typed in the dialog, and (for tests) a fixed clock reading.
(define (render-template raw title [secs ((current-clock))])
  (extract-cursor (substitute-known raw title secs)))

;; ---- creating the note --------------------------------------------------------------------

;; "Title for the new note:" -- a parameter (docs/DEVELOPMENT.md: dialogs that ask the user
;; something are parameters) so tests answer without the native dialog. #f (Cancel) aborts
;; the whole command; the template's own name is offered as a starting point.
(define ask-template-title
  (make-parameter
   (lambda (template-name)
     (get-text-from-user "New from Template" "Title for the new note:" (ui-parent) template-name))))

(define (unique-md-path dir base)
  (let loop ([n 0])
    (define name (if (= n 0) (format "~a.md" base) (format "~a ~a.md" base n)))
    (define p (build-path dir name))
    (if (or (file-exists? p) (directory-exists? p)) (loop (add1 n)) p)))

;; The folder New Note itself creates into (library/new-note.rkt): the sidebar's target if one
;; is set, else the first Library folder, offering to add one first if there is none.
(define (target-folder!)
  (or (selected-library-folder)
      (and ((confirm-add-folder-first?))
           (begin (run-command/safe 'add-library-folder) (selected-library-folder)))))

;; Asks for a title, then creates and opens a note from `template-path` -- in the selected
;; Library folder, named from the title, opened in the Formatted view (set explicitly: a long
;; document or the markdown-default-view setting could otherwise land it in Source, and the
;; acceptance criterion is unconditional), with the caret where {{cursor}} was.
(define (create-note-from-template! template-path)
  (define name (template-title-for template-path))
  (define title ((ask-template-title) name))
  (when title
    (define folder (target-folder!))
    (cond
      [(not folder) (message "New from Template needs a Library folder.")]
      [else
       (with-handlers ([exn:fail? (lambda (e) (report-error! 'new-from-template e)
                                    (message "Could not create the note: ~a" (exn-message e)))])
         (define raw (file->string template-path))
         (define-values (body cursor) (render-template raw title))
         (define base (or (sanitize-note-filename title) name))
         (define path (unique-md-path folder base))
         (display-to-file body path #:exists 'error)
         (define b (open-file! path))
         (set-markdown-view! b 'formatted)
         (send b set-position (min cursor (send b last-position)))
         (set-current-buffer! b))])))

;; ---- File > New from Template (a submenu, like Open Recent: rebuilt fresh every time it
;; opens, so adding or removing a .md file in the folder shows up the next time someone looks) --

(define (populate-templates-menu! m)
  (define paths (scan-templates))
  (cond
    [(null? paths)
     (define none (new menu-item% [label "No templates yet."] [parent m] [callback void]))
     (send none enable #f)]
    [else
     (for ([p (in-list paths)])
       (new menu-item% [label (template-title-for p)] [parent m]
            [callback (lambda (i e) (create-note-from-template! p))]))]))

;; Order 10, the same as New Note: rebuild-menus! (frame.rkt) sorts commands and submenus
;; together by menu-order with a stable sort, and always appends submenus after commands
;; within the append it sorts, so at equal order this submenu lands right after the New Note
;; command rather than needing an order number of its own.
(register-submenu! "New from Template" #:menu "File" #:menu-order 10 populate-templates-menu!)

;; ---- the palette/start-screen path: pick a template, then the same creation function -----

;; A parameter (docs/DEVELOPMENT.md), like library/folders.rkt's pick-folder-to-remove, so
;; tests never have to drive the real modal `pick` dialog just to prove this command works.
(define pick-template
  (make-parameter
   (lambda ()
     (define items (for/list ([p (in-list (scan-templates))]) (list (template-title-for p) "" p)))
     (pick "New from Template" items #:columns (list "Name")))))

(define-command (new-from-template)
  #:icon "new"
  #:aliases ("new from template" "new templated note" "note from template" "template note")
  #:help "Create a new note from one of your templates."
  #:title "New from Template…" #:menu #f
  #:doc "Choose one of your templates (File > New from Template also lists them) and create a note from it, asking for its title first."
  (if (null? (scan-templates))
      (message "No templates yet. Use Tools > Edit Templates to add one.")
      (let ([choice ((pick-template))]) (when choice (create-note-from-template! choice)))))

;; ---- Tools > Edit Templates ----------------------------------------------------------------
;; Reveals the folder itself (not a file inside it, so `open` rather than commands.rkt's
;; reveal-argv, which selects one file with `-R`): the acceptance criterion is that templates
;; are plain Markdown a person can edit in Rackmac, and a Finder/Explorer window on the folder
;; is how every "reveal a folder" affordance in this codebase gets there (commands.rkt's
;; reveal-in-file-manager, library/sidebar.rkt's reveal-library-item, both do the equivalent
;; for a single file).
(define (open-folder-argv dir)
  (cond [(windows?) (list "explorer" (path->string dir))]
        [(mac?) (list "open" (path->string dir))]
        [else (list "xdg-open" (path->string dir))]))

;; Factored out and made a parameter, like launch! itself is used elsewhere, so a test can
;; assert the argv without a real Finder/Explorer window popping up.
(define edit-templates-folder!
  (make-parameter (lambda (dir) (launch! (open-folder-argv dir)))))

(define-command (edit-templates)
  #:icon "open"
  #:aliases ("edit templates" "templates folder" "open templates folder" "manage templates")
  #:help "Open your Templates folder to add, edit or remove templates."
  #:title "Edit Templates" #:menu "Tools" #:menu-order 21
  #:doc "Open the folder your templates are kept in, creating it (seeding it with three examples if it is the default location) if it does not exist yet."
  (define dir (templates-dir))
  (if (custom-templates-folder) (make-directory* dir) (seed-default-if-new! dir))
  (unless ((edit-templates-folder!) dir)
    (message "Could not open the Templates folder.")))
