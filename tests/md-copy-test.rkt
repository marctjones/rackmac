#lang racket/base
;; Copy and Cut carry the Markdown source in both views (#334, docs/UI-DESIGN.md §2.2.1): a real
;; round trip through the system clipboard from the Edit commands, on a hidden window. The
;; clipboard holds plain text only (no styled editor data), so pasting into a code document gets
;; no heading sizes, and pasting into a note formats it there. The user's clipboard text is put
;; back afterwards.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/frame.rkt"
         "../rackmac/editor.rkt" "../rackmac/theme.rkt" "../rackmac/md-view.rkt")

(define f (make-main-frame))                ; hidden: show is never called
(define saved (send the-clipboard get-clipboard-string 0))

(define (size-at b pos) (send (send (send (send b find-snip pos 'after) get-style) get-font) get-point-size))
(define (face-at b pos) (send (send (send (send b find-snip pos 'after) get-style) get-font) get-face))

(define source "# Minutes\n\nThe **board** met on `Tuesday`.\n")
(define (note #:view [view 'formatted])
  (define b (new-buffer! "copy.md" #:mode 'markdown-mode))
  (send b insert source)
  (set-markdown-view! b view)
  (set-current-buffer! b)
  b)
(define (clip) (send the-clipboard get-clipboard-string 0))

(test-case "copy across a heading and a bold run yields the Markdown source, in both views"
  (for ([view '(formatted source)])
    (define b (note #:view view))
    (define end (+ 5 (caar (regexp-match-positions #rx"board" source))))
    (send b set-position 2 end)
    (run-command 'copy)
    (check-equal? (clip) (substring source 2 end) (format "~a view" view))
    (check-equal? (send b get-text) source "copy changes nothing")))

(test-case "the clipboard carries no styled editor data, only text"
  (note)
  (send (current-buffer) set-position 0 9)
  (run-command 'copy)
  (check-equal? (clip) "# Minutes")
  (check-false (send the-clipboard get-clipboard-data "WXME" 0) "no text% snips to paste back"))

(test-case "cut takes the source out and puts it on the clipboard, as one undoable step"
  (define b (note #:view 'formatted))
  (send b set-position 11 (sub1 (string-length source)))
  (run-command 'cut)
  (check-equal? (clip) "The **board** met on `Tuesday`.")
  (check-equal? (send b get-text) "# Minutes\n\n\n")
  (send b undo)
  (check-equal? (send b get-text) source))

(test-case "pasting into code carries no formatting; pasting into a note formats it there"
  (define b (note))
  (send b set-position 0 9)
  (run-command 'copy)
  (define code (new-buffer! "copy.rkt" #:mode 'racket-mode))
  (set-current-buffer! code)
  (run-command 'paste)
  (check-equal? (send code get-text) "# Minutes")
  (check-equal? (face-at code 3) mono-face)
  (check-equal? (size-at code 3) (size-at code 0) "no heading size came along")
  (define other (new-buffer! "paste.md" #:mode 'markdown-mode))
  (set-current-buffer! other)
  (send other insert "Body text\n\n")
  (run-command 'paste)
  (check-equal? (send other get-text) "Body text\n\n# Minutes")
  (check-true (> (size-at other 14) (size-at other 1)) "re-rendered as a heading"))

(test-case "copy with extend appends to what the clipboard holds"
  (define b (note))
  (send b copy #f 0 0 1)
  (send b copy #t 0 2 9)
  (check-equal? (clip) "#Minutes"))

(send the-clipboard set-clipboard-string (or saved "") 0)
