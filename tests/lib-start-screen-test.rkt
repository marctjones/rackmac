#lang racket/base
;; The start screen (#277 start-view): shown with no document open, painted on the paper ground
;; (the first live look put native controls on the grey panel color), leaves once a document
;; opens, a command reopens it, and it is keyboard reachable (Tab and arrows move, Return opens).
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file racket/list racket/path
         "../rackmac/library/folders.rkt" "../rackmac/library/new-note.rkt"
         "../rackmac/library/start-screen.rkt" "../rackmac/library/recents.rkt"
         "../rackmac/settings.rkt" "../rackmac/editor.rkt" "../rackmac/frame.rkt"
         "../rackmac/command.rkt" "../rackmac/platform.rkt" "../rackmac/hook.rkt"
         "../rackmac/ui/start-screen.rkt" "../rackmac/ui/tokens.rkt" "ui-harness.rkt")

(define dir (make-temporary-file "rackmac-startview~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))
(setting-set! 'library-folders '())
(setting-set! 'skip-start-screen #f)
(define lib (build-path dir "Notes"))
(make-directory* lib)
(add-library-folder-path! lib)
(enable-recent-tracking!)

(define f (make-main-frame))     ; hidden: show is never called
(send f reflow-container)        ; geometry only

(define (panel) (main-start-panel))
(define (items) (send (panel) current-items 800 600))
(define (kinds) (map sv-item-kind (items)))
(define (item-labels kind) (for/list ([it (items)] #:when (eq? (sv-item-kind it) kind)) (sv-item-label it)))
(define (key code #:shift? [shift? #f]) (new key-event% [key-code code] [shift-down shift?]))

(test-case "with no document open, the start screen (not the tabs/canvas) is shown"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (check-true (start-screen-shown?))
  (check-true (no-document-open?))
  ;; the document area is the window's middle row, `main-body` (beside the sidebar, #273)
  (check-not-false (memq (panel) (send (main-body) get-children)))
  (check-false (memq (main-tabs) (send (main-body) get-children))))

(test-case "it is one painted surface: title, subtitle, the four actions, Recent, Get Started"
  (check-true (is-a? (panel) canvas%) "painted, so it can sit on paper (a panel takes the OS color)")
  (check-equal? (item-labels 'title) '("Rackmac"))
  (check-equal? (item-labels 'subtitle) (list start-screen-subtitle))
  (check-equal? (item-labels 'action) '("New Note" "Add Folder…" "Open…" "From Template…"))  ; #353
  (check-equal? (item-labels 'link) '("Get Started"))
  (check-not-false (memq 'heading (kinds)) "Recent shows: this window has no sidebar"))

(test-case "opening a document dismisses the start screen"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (check-true (start-screen-shown?))
  (run-command 'new-note)
  (check-false (start-screen-shown?))
  (check-not-false (memq (main-tabs) (send (main-body) get-children))))

(test-case "closing the last document brings it back"
  (kill-buffer! (current-buffer))
  (check-true (start-screen-shown?)))

(test-case "the Start Screen command reopens it even with a document open"
  (run-command 'new-note)
  (check-false (start-screen-shown?))
  (run-command 'show-start-screen)
  (check-true (start-screen-shown?))
  ;; and it leaves again once a document is actually opened, as usual
  (run-command 'new-note)
  (check-false (start-screen-shown?)))

;; ---- Recent: real files, keyboard reachable -----------------------------------------------

(test-case "Recent lists real files and Enter on a row opens it, same as a double-click"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (clear-recent-files!)
  (define p (build-path lib "recent-me.md"))
  (display-to-file "# Hi" p #:exists 'truncate)
  (record-recent-open! (path->string p))
  (send (panel) refresh-recent!)
  (check-equal? (item-labels 'recent) '("recent-me.md"))
  (check-equal? (for/list ([it (items)] #:when (eq? (sv-item-kind it) 'recent)) (sv-item-detail it)) '("Notes")
                "the row names its folder")
  (send (panel) set-focus-id! '(recent . 0))
  (send (panel) on-char (key #\return))
  (check-equal? (send (current-buffer) get-name) "recent-me.md"))

(test-case "keyboard: New Note has the focus first; Tab and arrows move through every item, wrapping"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (clear-recent-files!)
  (send (panel) focus-default!)
  (check-equal? (send (panel) focused-id) 'new-note)
  (send (panel) on-char (key #\tab))
  (check-equal? (send (panel) focused-id) 'add-library-folder)
  (send (panel) on-char (key 'right))
  (check-equal? (send (panel) focused-id) 'open-file)
  (send (panel) on-char (key #\tab))
  (check-equal? (send (panel) focused-id) 'new-from-template)   ; #353, the fourth action
  (send (panel) on-char (key #\tab))
  (check-equal? (send (panel) focused-id) 'open-getting-started "the empty Recent line is not a stop")
  (send (panel) on-char (key #\tab))
  (check-equal? (send (panel) focused-id) 'new-note "wraps")
  (send (panel) on-char (key #\tab #:shift? #t))
  (check-equal? (send (panel) focused-id) 'open-getting-started "Shift+Tab goes back")
  (send (panel) set-focus-id! 'new-note)
  (send (panel) on-char (key #\space))
  (check-false (start-screen-shown?) "Space on New Note made a note"))

(test-case "a click on an action runs it"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (define it (findf (lambda (it) (eq? (sv-item-id it) 'new-note)) (send (panel) current-items)))
  (define-values (x y w h) (apply values (sv-item-rect it)))
  (for ([type '(left-down left-up)])
    (send (panel) on-event (new mouse-event% [event-type type] [x (inexact->exact (round (+ x 4)))]
                                [y (inexact->exact (round (+ y 4)))] [left-down (eq? type 'left-down)])))
  (check-false (start-screen-shown?)))

(test-case "a moved or deleted recent file is not offered"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (clear-recent-files!)
  (define gone (build-path lib "gone.md"))
  (display-to-file "x" gone)
  (record-recent-open! (path->string gone))
  (delete-file gone)
  (send (panel) refresh-recent!)
  (check-equal? (item-labels 'recent) '())
  (check-equal? (item-labels 'empty) (list empty-recent-text)))

;; ---- Get Started ---------------------------------------------------------------------------

(test-case "Get Started opens a bundled note with checkboxes, creating it once"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (run-command 'open-getting-started)
  (define b (current-buffer))
  (check-regexp-match #rx"Getting started" (send b get-name))
  (check-regexp-match #rx"- \\[ \\]" (send b get-text))
  (define p (send b get-path))
  (check-true (file-exists? p))
  ;; opening it again reuses the same file rather than overwriting it
  (send b insert "edited")
  (send b save-to! p)
  (kill-buffer! b)
  (run-command 'open-getting-started)
  (check-regexp-match #rx"edited" (send (current-buffer) get-text)))

;; ---- setting: skip the screen -------------------------------------------------------------

(test-case "skip-start-screen opens the most recent existing note instead"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (clear-recent-files!)
  (define p (build-path lib "skip-me.md"))
  (display-to-file "hi" p #:exists 'truncate)
  (record-recent-open! (path->string p))
  (setting-set! 'skip-start-screen #t)
  (maybe-skip-start-screen!)
  (check-equal? (send (current-buffer) get-name) "skip-me.md")
  (setting-set! 'skip-start-screen #f))

(test-case "skip-start-screen with nothing to open still leaves the screen showing"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (clear-recent-files!)
  (setting-set! 'skip-start-screen #t)
  (maybe-skip-start-screen!)
  (check-true (no-document-open?))
  (setting-set! 'skip-start-screen #f))

;; ---- keyboard: shortcuts still work with the canvas detached -------------------------------
;; Every shortcut normally dispatches through the focused editor canvas; with the start screen
;; showing that canvas is not even a child of the window, so a Mod-key reaching one of this
;; screen's own controls (any control can have focus) is routed the same way instead.

(define (cmd-key code)
  (new key-event% [key-code code] [meta-down (mac?)] [control-down (not (mac?))]))

(test-case "Mod-N from the start screen creates a new note, just like the button"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (check-true (start-screen-shown?))
  (send (panel) on-char (cmd-key #\n))
  (check-regexp-match #rx"^Untitled" (send (current-buffer) get-name))
  (check-false (start-screen-shown?)))

(test-case "an unmodified key on the panel is not swallowed as a shortcut"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (send (panel) on-char (new key-event% [key-code #\n]))
  (check-true (start-screen-shown?) "plain 'n' did not run New Note"))

;; A never-shown window (docs/DEVELOPMENT.md: tests never call `show`) does not track real OS
;; focus, so this only proves 'focus-editor routes to the right *widget's* focus method without
;; raising in either state -- not that the OS actually moves focus there (README's own caveat
;; about real keystrokes applies equally here).
(test-case "'focus-editor does not raise while the start screen is shown or while a document is open"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (check-true (start-screen-shown?))
  (run-hook 'focus-editor)
  (run-command 'new-note)
  (check-false (start-screen-shown?))
  (run-hook 'focus-editor))

;; ---- copy ----------------------------------------------------------------------------------

(test-case "the subtitle is plain, README-like copy with no exclamation marks"
  (check-equal? start-screen-subtitle "Notes in plain Markdown files, in folders you choose.")
  (check-false (regexp-match? #rx"!" start-screen-subtitle)))

;; ---- the look: paper, not the OS panel -----------------------------------------------------

(define (sample-model recent)
  (start-model "Rackmac" start-screen-subtitle
               (list (cons 'new-note "New Note") (cons 'add-library-folder "Add Folder…") (cons 'open-file "Open…"))
               recent (cons 'open-getting-started "Get Started") "a short note that shows what Rackmac does"))

(test-case "the ground is the paper (`surface`), with readable text and ruled boxes, light and dark"
  (define recent (list (list "Weekly notes.md" "Notes" #f) (list "Acme SPA - turn 4.md" "Acme" #f)))
  (for* ([a appearances] [s scales] [r (list #f recent)])
    (with-appearance a
      (lambda ()
        (define bm (render-bitmap 800 560 (lambda (dc) (draw-start-view dc 800 560 (sample-model r) #:focus 'new-note))
                                  #:scale s))
        (write-tour-png! (format "start-screen-~a-~a~a" a s (if r "-recent" "")) bm)
        (check-equal? (dominant-color bm) (token-hex 'surface a) "paper, not the OS panel grey")
        (for ([x '(1 400 798)]) (check-equal? (bitmap-pixel-hex bm x 550) (token-hex 'surface a)))
        (check-false (and (not (equal? (token-hex 'surface a) "#FFFFFF")) (hash-ref (bitmap-colors bm) "#FFFFFF" #f))
                     "no white list box")
        (check-true (>= (ink-contrast bm (token-hex 'surface a)) 4.5))
        (define colors (bitmap-colors bm))
        (check-not-false (hash-ref colors (token-hex 'stroke a) #f) "the actions are 1 px stroke boxes")
        (check-not-false (hash-ref colors (token-hex 'accent a) #f) "the focused box is outlined in accent")))))

(test-case "Recent is left off the layout when the model says so (the sidebar has it)"
  (define dc (new bitmap-dc% [bitmap (make-bitmap 10 10)]))
  (check-false (memq 'heading (map sv-item-kind (layout-start-view (sample-model #f) 800 560 dc))))
  (check-not-false (memq 'heading (map sv-item-kind (layout-start-view (sample-model '()) 800 560 dc)))))
