#lang racket/base
;; Heading keyword states (#294 task-heading-states, docs/REPLAN.md E17.M1): a heading line
;; starting with a configured keyword and a space is colored by its state (bold in error/warning/
;; success by the word's position in the list) and cycled by Mark Done (⇧⌘U), the heading-level
;; sibling of the task checkbox (#293, tests/checkbox-test.rkt). Covers keyword recognition and
;; coloring, cycling through states (including an unknown/stale word and an empty configured
;; list), the per-Library keyword-list setting, and that save/export round-trips the word intact.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file
         "ui-harness.rkt"
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/frame.rkt"
         "../rackmac/editor.rkt" "../rackmac/settings.rkt" "../rackmac/md-view.rkt" "../rackmac/md-format.rkt"
         "../rackmac/md-heading-state.rkt"
         "../rackmac/ui/tokens.rkt")

;; Isolated config dir (like settings-test.rkt/settings-dialog-test.rkt): setting-set! below
;; never touches the real settings.rktd.
(void (putenv "RACKMAC_HOME" (path->string (make-temporary-file "rackmac-task-heading~a" 'directory))))

(define f (make-main-frame))                ; hidden: show is never called

(define (note text)
  (define b (new-buffer! "headings.md" #:mode 'markdown-mode))
  (send b insert text)
  (set-markdown-view! b 'formatted)
  (send b clear-undos)
  (send b set-modified #f)
  (send b set-position 0)
  (set-current-buffer! b)
  (new editor-canvas% [parent (new frame% [label "task-heading"] [width 700] [height 500])] [editor b]) ; never shown
  b)

;; Paints `b`'s current styling (whatever the last rehighlight left in place -- this never
;; rehighlights itself), the same way ui-harness.rkt's render-document does for a fresh buffer.
(define (render-buffer b #:width [w 520] #:height [h 260])
  (send b set-max-width (- w 32))
  (render-bitmap w h (lambda (dc) (send b print-to-dc dc 1)) #:background (token 'surface)))

;; Reset the setting (and the shared rackmac-markdown parameter it drives) around a test that
;; changes it, so later tests -- in this file or, since settings are process-global, a file run
;; after it -- always see the default list.
(define (with-keywords str thunk)
  (dynamic-wind
   (lambda () (setting-set! 'heading-state-keywords str))
   thunk
   (lambda () (setting-set! 'heading-state-keywords "TODO WAITING DONE"))))

;; ---- recognition and coloring (pure: no buffer, no setting change) ------------------------------

(test-case "the default list is TODO WAITING DONE, first = open, last = done"
  (check-equal? (heading-state-keyword-list) '("TODO" "WAITING" "DONE")))

(define (color-count bm hex) (hash-ref (bitmap-colors bm) hex 0))

(test-case "keyword coloring renders in the state's color (bold error/warning/success)"
  (for ([app '(light dark)])
    (with-appearance app
      (lambda ()
        (define bm (render-document
                    (string-append "# TODO Buy milk\n\n# WAITING Call back\n\n# DONE Ship it\n\n# Plain heading\n")
                    'markdown-mode #:width 520 #:height 260))
        (write-tour-png! (format "heading-state-~a" app) bm)
        (check-true (> (color-count bm (token-hex 'error)) 0) (format "~a: TODO in error" app))
        (check-true (> (color-count bm (token-hex 'warning)) 0) (format "~a: WAITING in warning" app))
        (check-true (> (color-count bm (token-hex 'success)) 0) (format "~a: DONE in success" app))))))

;; ---- cycling: TODO -> WAITING -> DONE -> none -> TODO, via Mark Done ----------------------------

(test-case "Mark Done cycles a heading's keyword forward, then removes it, one undo step each"
  (define b (note "# Buy milk\n\nBody text.\n"))
  (send b set-position 5)                                    ; inside "Buy milk"
  (run-command 'mark-done)
  (check-equal? (send b get-text) "# TODO Buy milk\n\nBody text.\n")
  (run-command 'mark-done)
  (check-equal? (send b get-text) "# WAITING Buy milk\n\nBody text.\n")
  (run-command 'mark-done)
  (check-equal? (send b get-text) "# DONE Buy milk\n\nBody text.\n")
  (run-command 'mark-done)
  (check-equal? (send b get-text) "# Buy milk\n\nBody text.\n" "DONE -> no keyword, wrapping around")
  (run-command 'mark-done)
  (check-equal? (send b get-text) "# TODO Buy milk\n\nBody text.\n" "and back to the first word")
  (for ([i (in-range 5)]) (send b undo))
  (check-equal? (send b get-text) "# Buy milk\n\nBody text.\n" "five undos, five toggles"))

(test-case "Mark Done never touches a non-heading line's Mark Done meaning (the checkbox)"
  (define b (note "- [ ] Call the vendor\n"))
  (send b set-position 3)
  (run-command 'mark-done)
  (check-equal? (send b get-text) "- [x] Call the vendor\n" "still a checkbox toggle, not a heading cycle"))

(test-case "cycling adds the keyword before the heading's own text, not before other markup"
  (define b (note "## **Renewal**\n"))
  (send b set-position 4)
  (run-command 'mark-done)
  (check-equal? (send b get-text) "## TODO **Renewal**\n"))

;; ---- the per-Library keyword-list setting --------------------------------------------------

(test-case "changing the setting changes which words are recognized and how they cycle"
  (with-keywords "NEXT DONE"
    (lambda ()
      (check-equal? (heading-state-keyword-list) '("NEXT" "DONE"))
      (define b (note "# Ship it\n"))
      (send b set-position 3)
      (run-command 'mark-done)
      (check-equal? (send b get-text) "# NEXT Ship it\n" "the old word TODO is no longer offered")
      (run-command 'mark-done)
      (check-equal? (send b get-text) "# DONE Ship it\n")
      (run-command 'mark-done)
      (check-equal? (send b get-text) "# Ship it\n"))))

(test-case "a word the current list no longer recognizes reads as plain heading text"
  (with-keywords "TODO WAITING DONE"
    (lambda ()
      (define b (note "# TODO Ship it\n"))
      (setting-set! 'heading-state-keywords "NEXT LATER")     ; rehighlights; TODO is no longer a keyword
      (check-equal? (send b get-text) "# TODO Ship it\n" "the word itself is untouched by the setting change")
      (send b set-position 3)
      (run-command 'mark-done)
      (check-equal? (send b get-text) "# NEXT TODO Ship it\n"
                    "TODO is ordinary text now; cycling adds the new first word before it, like any other heading")
      (setting-set! 'heading-state-keywords "TODO WAITING DONE"))))

(test-case "an empty keyword list makes cycling a no-op on a heading"
  (with-keywords ""
    (lambda ()
      (check-equal? (heading-state-keyword-list) '())
      (define b (note "# Ship it\n"))
      (send b set-position 3)
      (run-command 'mark-done)
      (check-equal? (send b get-text) "# Ship it\n" "nothing to cycle to"))))

(test-case "cycling an empty heading inserts the keyword with a separating space"
  (define b (note "#\nBody\n"))
  (send b set-position 1)
  (run-command 'mark-done)
  (check-equal? (send b get-text) "# TODO\nBody\n"))

;; This is the regression that motivates rehighlighting on the setting-changed hook at all: a
;; note stays open and colored while the setting changes underneath it (no edit, no reopen).
;; hook.rkt runs same-priority 'setting-changed hooks most-recently-added first, so this only
;; passes if md-format.rkt's rehighlight hook resyncs the rackmac-markdown parameter itself
;; before rehighlighting, rather than trusting md-heading-state.rkt's own hook to have gone first.
(test-case "an already-open note recolors immediately when the setting changes, no edit or reopen"
  (define b (note "# TODO Ship it\n"))
  (check-true (> (color-count (render-buffer b) (token-hex 'error)) 0) "TODO is the first word: error")
  (with-keywords "STARTED TODO"
    (lambda ()
      (check-true (> (color-count (render-buffer b) (token-hex 'success)) 0)
                  "TODO is now the last word: success, purely from the setting change")))
  (check-true (> (color-count (render-buffer b) (token-hex 'error)) 0) "back to error once the list is restored"))

;; ---- export/save: the word round-trips unchanged -------------------------------------------

(define source "# TODO Renew the lease\n\nCall the landlord.\n")

(test-case "round trip: a note with a heading keyword saves byte for byte"
  (define b (note source))
  (define p (make-temporary-file "rackmac-task-heading-~a.md"))
  (send b save-to! p)
  (check-equal? (file->bytes p) (string->bytes/utf-8 source))
  (check-equal? (send b document-text) source "the snip-aware document text every export path reads")
  (delete-file p))

(test-case "cycling the keyword away and undoing it restores the exact source bytes"
  (define b (note source))
  (send b set-position 10)
  (run-command 'mark-done)          ; TODO -> WAITING
  (run-command 'mark-done)          ; WAITING -> DONE
  (run-command 'mark-done)          ; DONE -> none
  (check-equal? (send b document-text) "# Renew the lease\n\nCall the landlord.\n")
  (for ([i (in-range 3)]) (send b undo))
  (check-equal? (send b document-text) source "back to the original word, unchanged"))

(test-case "the keyword is never a snip: it is plain colored text, so copy yields the word too"
  (define saved (send the-clipboard get-clipboard-string 0))
  (define b (note source))
  (send b set-position 0 (string-length "# TODO Renew the lease"))
  (run-command 'copy)
  (check-equal? (send the-clipboard get-clipboard-string 0) "# TODO Renew the lease")
  (send the-clipboard set-clipboard-string saved 0))
