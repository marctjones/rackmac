#lang racket/base
;; The start screen (#277 start-view): what shows in the document area when nothing is open --
;; native controls (message%, button%, list-box%), not a document, so there is never a
;; Scratch Pad to greet a new person (that fallback moved out of rackmac/editor.rkt; #288
;; makes sure ⌘Return in a note still does nothing). Registers itself with rackmac/frame.rkt,
;; which decides *when* to show it; this module only builds it and supplies its commands.
(require racket/class racket/gui/base racket/draw racket/list racket/file racket/path
         "folders.rkt" "recents.rkt" "../command.rkt" "../editor.rkt" "../frame.rkt"
         "../hook.rkt" "../settings.rkt" "../platform.rkt" "../input.rkt")

(provide maybe-skip-start-screen!)

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

;; The Recent list here matches the sidebar's own Recent section (docs/UI-DESIGN.md S2.1/S2.8):
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

;; ---- the panel --------------------------------------------------------------------------

(define (open-recent-row! items i)
  (when (< i (length items))
    (set-current-buffer! (open-file! (recent-entry-path (list-ref items i))))))

(define start-screen-panel%
  (class vertical-panel%
    (super-new [alignment '(center top)])
    (define title-font (make-font #:size 22 #:weight 'bold))
    (new message% [parent this] [label "Rackmac"] [font title-font])
    (new message% [parent this] [label "Notes and documents you can trust to plain files"])
    (new pane% [parent this] [min-height 16] [stretchable-height #f])   ; breathing room
    (define buttons (new horizontal-panel% [parent this] [alignment '(center center)] [stretchable-height #f]))
    (define new-note-button
      (new button% [parent buttons] [label "New Note"]
           [callback (lambda (b e) (run-command/safe 'new-note))]))
    (new button% [parent buttons] [label "Add Folder…"]
         [callback (lambda (b e) (run-command/safe 'add-library-folder))])
    (new button% [parent buttons] [label "Open…"]
         [callback (lambda (b e) (run-command/safe 'open-file))])
    (new pane% [parent this] [min-height 16] [stretchable-height #f])
    (new message% [parent this] [label "Recent"])
    (define recent-items '())
    (define recent-list
      (new list-box% [parent this] [label #f] [choices '()] [style '(single)]
           [min-width 460] [min-height 140]
           [callback (lambda (lb e)
                       (when (eq? (send e get-event-type) 'list-box-dclick)
                         (open-recent-row! recent-items (send lb get-selection))))]))
    (new pane% [parent this] [min-height 16] [stretchable-height #f])
    (new button% [parent this] [label "Get Started"]
         [callback (lambda (b e) (run-command/safe 'open-getting-started))])

    ;; list-box% has no Return callback of its own (RM-039's `pick` hits the same thing) --
    ;; caught here at the panel so Enter on a highlighted Recent row opens it, same as a
    ;; double-click (docs/UI-DESIGN.md S2.8: "keyboard reachable").
    ;;
    ;; Every other shortcut (⌘N, ⌘O, ⇧⌘O, ⌘,...) normally dispatches through the focused editor
    ;; canvas (frame.rkt's header comment); with the canvas detached while this screen shows,
    ;; a Mod-combination reaching any control here is sent through the same dispatcher instead,
    ;; against the placeholder document's (global) keymap, so shortcuts keep working with
    ;; nothing open rather than needing a click first.
    (define/override (on-subwindow-char receiver ev)
      (cond
        [(and (eq? receiver recent-list) (memq (send ev get-key-code) '(#\return #\newline numpad-enter)))
         (open-recent-row! recent-items (send recent-list get-selection))
         #t]
        [(if (mac?) (send ev get-meta-down) (send ev get-control-down))
         (or (dispatch-key-event (current-buffer) ev) (super on-subwindow-char receiver ev))]
        [else (super on-subwindow-char receiver ev)]))

    (define/public (refresh-recent!)
      (set! recent-items (existing-recents))
      (send recent-list clear)
      (cond
        [(null? recent-items)
         (send recent-list append "Notes you open appear here.")
         (send recent-list enable #f)]
        [else
         (send recent-list enable #t)
         (for ([e (in-list recent-items)]) (send recent-list append (recent-entry-name e)))]))

    (define/public (focus-default!) (send new-note-button focus))))

(register-start-screen!
 (lambda (parent)
   (define panel (new start-screen-panel% [parent parent]))
   (send panel refresh-recent!)
   (add-hook! 'buffers-changed (lambda () (send panel refresh-recent!)))
   panel))
