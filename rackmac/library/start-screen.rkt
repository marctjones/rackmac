#lang racket/base
;; The start screen (#277 start-view): what shows in the document area when nothing is open --
;; a painted surface (rackmac/ui/start-screen.rkt), not a document, so there is never a
;; Scratch Pad to greet a new person (that fallback moved out of rackmac/editor.rkt; #288
;; makes sure ⌘Return in a note still does nothing). Registers itself with rackmac/frame.rkt,
;; which decides *when* to show it; this module only builds it and supplies its commands.
(require racket/class racket/gui/base racket/list racket/file racket/path
         "folders.rkt" "recents.rkt" "open-recent.rkt" "../command.rkt" "../editor.rkt" "../frame.rkt"
         "../hook.rkt" "../settings.rkt" "../platform.rkt" "../input.rkt" "../ui/start-screen.rkt")

(provide maybe-skip-start-screen! start-screen-subtitle)

;; README-like, not a landing page (the brand): what it is, in plain words, no exclamation.
(define start-screen-subtitle "Notes in plain Markdown files, in folders you choose.")

(define-setting skip-start-screen
  #:contract boolean? #:default #f
  #:doc "Skip the start screen and open your most recent note instead."
  #:category "Startup")

;; Called once from app.rkt's `main`, after any command-line files are already open: with the
;; setting on and nothing open yet, the most recent existing note is opened instead of showing
;; the screen (UI-DESIGN S2.8); with nothing to open, the screen shows anyway.
(define (maybe-skip-start-screen!)
  (when (and (setting-ref 'skip-start-screen) (no-document-open?))
    (define hit (findf (lambda (e) (file-exists? (recent-entry-path e))) (recent-entries)))
    (when hit (set-current-buffer! (open-file! (recent-entry-path hit))))))

;; The Recent list here matches the sidebar's own Recent section (docs/UI-DESIGN.md S2.1/S2.8)
;; and shows only while the sidebar is hidden (see "the screen" below):
;; the last 10, and only ones still on disk (a moved or deleted file would otherwise open to an
;; error the moment someone double-clicks it).
(define recent-shown-count 10)
(define (existing-recents)
  (filter (lambda (e) (file-exists? (recent-entry-path e))) (recent-entries recent-shown-count)))

;; ---- Get Started note ------------------------------------------------------------------
;; Bundled with the app (this string), materialized into a real file on first use -- the same
;; pattern rackmac/commands.rkt's `customize-with-code` uses for its init template -- so it is
;; an ordinary note a person can edit, not a read-only resource inside the app.
(define getting-started-text #<<TEXT
# Getting Started with Rackmac

Welcome. This is a real note in your Library -- try editing it, then save your changes.

- [ ] Type `#` at the start of a line to make a heading, like the one above
- [ ] Write a plain paragraph here
- [ ] Add a folder to your Library from File > Add Folder...
- [ ] Create another note with New Note
- [ ] Save this note once you have made a change

This file is plain Markdown. Open it in any other editor, or a colleague's, and it reads
exactly the same.
TEXT
  )

(define (getting-started-path)
  (define folder (or (selected-library-folder) (path->string (config-dir))))
  (build-path folder "Getting started.md"))

(define-command (open-getting-started)
  #:icon "book"
  #:aliases ("get started" "getting started" "tutorial" "show me around")
  #:help "Open a short note that teaches the basics of Rackmac."
  #:title "Get Started"
  (define p (getting-started-path))
  (unless (file-exists? p)
    (make-directory* (let-values ([(base n d?) (split-path p)]) base))
    (display-to-file getting-started-text p))
  (set-current-buffer! (open-file! p)))

(define-command (show-start-screen)
  #:icon "book"
  #:aliases ("start screen" "show start screen" "welcome screen")
  #:help "Show the start screen again."
  #:title "Start Screen" #:menu "Help" #:menu-order 13
  (show-start-screen!))

;; ---- the screen -------------------------------------------------------------------------
;; A painted canvas on the paper ground (rackmac/ui/start-screen.rkt): native controls would sit
;; on the OS panel color and read as a dialog (the first live look, 2026-09-26).
;;
;; Recent shows here only while the Library sidebar is hidden. With the sidebar showing, its
;; own Recent section is the one list of recent notes, beside this screen; two copies of the
;; same list side by side read as a mistake. With the sidebar hidden, this screen is the only
;; way back to a recent note without a menu, so the list comes back.

(define (start-actions)
  (list (cons 'new-note "New Note") (cons 'add-library-folder "Add Folder…") (cons 'open-file "Open…")))

(define (current-start-model)
  (define items (existing-recents))
  (start-model "Rackmac" start-screen-subtitle (start-actions)
               (and (not (sidebar-shown?))
                    (for/list ([e (in-list items)])
                      (list (entry-label e items) (folder-label (recent-entry-path e)) (recent-entry-path e))))
               (cons 'open-getting-started "Get Started")
               "a short note that shows what Rackmac does"))

;; The folder a recent note is in, by name ("Notes", "Acme"): enough to tell two apart.
(define (folder-label p)
  (define-values (dir file must-dir?) (split-path (simplify-path (path->complete-path p))))
  (define-values (up name d?) (if (path? dir) (split-path dir) (values #f #f #f)))
  (if (path? name) (path->string name) ""))

(define (activate-item! it)
  (case (sv-item-kind it)
    [(recent)
     (define p (sv-item-data it))
     (if (file-exists? p)
         (set-current-buffer! (open-file! p))
         (message "~a is no longer there." (sv-item-label it)))]
    [else (run-command/safe (sv-item-id it))]))

;; Every shortcut (⌘N, ⌘O, ⇧⌘O, ⌘,...) normally dispatches through the focused editor canvas
;; (frame.rkt's header comment); with that canvas detached while this screen shows, a ⌘
;; combination here goes through the same dispatcher, against the placeholder document's
;; (global) keymap, so shortcuts work with nothing open rather than needing a click first.
(define (shortcut! ev) (dispatch-key-event (current-buffer) ev))

(define start-screen%
  (class start-view%
    (super-new [model-getter current-start-model] [on-activate activate-item!] [on-shortcut shortcut!])
    (inherit refresh focus-first!)
    ;; frame.rkt's contract: where the keyboard goes while this screen shows (New Note)
    (define/public (focus-default!) (focus-first!))
    (define/public (refresh-recent!) (refresh))))

(register-start-screen!
 (lambda (parent)
   (define view (new start-screen% [parent parent]))
   (add-hook! 'buffers-changed (lambda () (send view refresh-recent!)))
   (add-hook! 'theme-changed (lambda () (send view refresh-colors!)))
   view))
