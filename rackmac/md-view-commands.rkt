#lang racket/base
;; Show Markdown Source / Show Formatted (#269, docs/UI-DESIGN.md §2.2.1): the one command every
;; entry point runs (View menu, ⌥⌘U, the status segment in status-defaults.rkt, and the Format
;; group's last button once it exists), so they never disagree. The views themselves are in
;; md-view.rkt; this module adds the command and the hooks that need the open documents.
(require racket/class "command.rkt" "editor.rkt" "hook.rkt" "md-view.rkt")
(provide markdown-document?)

(define (markdown-document? [b (current-buffer)]) (eq? (send b get-mode) 'markdown-mode))

(define-command (toggle-markdown-view)
  #:title "Show Markdown Source" #:menu "View" #:menu-order 24
  #:icon "keyboard" #:checked-title "Show Formatted" #:checked-icon "book"
  #:aliases ("view source" "markdown source" "raw markdown" "formatted view" "show formatted")
  #:help "Switch this note between its formatted view and its Markdown source."
  #:keys/mac ("Mod-Alt-u")
  #:when markdown-document?
  #:checked (lambda () (and (markdown-document?) (eq? (markdown-view (current-buffer)) 'source)))
  (define b (current-buffer))
  (when (markdown-document? b)
    (set-markdown-view! b (if (eq? (markdown-view b) 'source) 'formatted 'source))))

;; A long note opened in Source (md-view.rkt) says why, after open-file!'s own large-file note.
(define (explain-long-note b)
  (when (and (markdown-document? b) (send b large?) (eq? (markdown-view b) 'source))
    (message "~a is a long note, so it opens as Markdown source. View > Show Markdown Source switches it to the formatted view."
             (send b get-name))))
(add-hook! 'after-open-file explain-long-note)

;; Saving a note records its view with its recents entry; a note first saved while untitled
;; keeps the view it was written in. Runs after recents.rkt's own save hook made the entry.
(define (remember-on-save b) (when (markdown-document? b) (remember-markdown-view! b)))
(add-hook! 'after-save remember-on-save #:priority -1)
