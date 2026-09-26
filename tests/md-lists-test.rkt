#lang racket/base
;; Enter, Tab and Shift+Tab in Markdown lists (#337, docs/UI-DESIGN.md §2.2 and §2.4): Enter
;; continues a bullet, a renumbering ordered item and a task item; Enter on an empty item ends
;; the list; Tab/Shift+Tab indent and outdent a list item; all three fall through to the plain
;; editor commands outside a list item (and outside Markdown), and work inside a block quote.
;; Driven through the real (hidden) window and the real keymaps.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/frame.rkt"
         "../rackmac/editor.rkt" "../rackmac/buffer.rkt" "../rackmac/platform.rkt"
         "../rackmac/md-lists.rkt")

(define f (make-main-frame))

(define (note text)
  (define b (new-buffer! "lists.md" #:mode 'markdown-mode))
  (send b insert text)
  (send b clear-undos)
  (send b set-modified #f)
  (set-current-buffer! b)
  b)
(define (text b) (send b get-text))

;; ---- Enter --------------------------------------------------------------------------------

(test-case "Enter continues a bulleted item"
  (define b (note "- one\n- two"))
  (send b set-position 5)                  ; end of "- one"
  (run-command 'markdown-enter)
  (check-equal? (text b) "- one\n- \n- two")
  (check-equal? (send b get-start-position) 8))

(test-case "Enter renumbers a continued ordered item, and the ones after it"
  (define b (note "1. one\n2. two"))
  (send b set-position 6)                  ; end of "1. one"
  (run-command 'markdown-enter)
  (check-equal? (text b) "1. one\n2. \n3. two"))

(test-case "Enter carries over an open task marker"
  (define b (note "- [ ] one"))
  (send b set-position (send b last-position))
  (run-command 'markdown-enter)
  (check-equal? (text b) "- [ ] one\n- [ ] "))

(test-case "Enter on an empty item ends the list"
  (define b (note "- one\n- "))
  (send b set-position (send b last-position))
  (run-command 'markdown-enter)
  (check-equal? (text b) "- one\n" "the marker is removed, leaving a plain blank line"))

(test-case "Enter works inside a block quote"
  (define b (note "> - one"))
  (send b set-position (send b last-position))
  (run-command 'markdown-enter)
  (check-equal? (text b) "> - one\n> - "))

(test-case "Enter with a selection falls through to plain Newline and Indent"
  (define b (note "- one"))
  (send b set-position 2 5)                ; "one" selected
  (run-command 'markdown-enter)
  (check-equal? (text b) "- \n"))

(test-case "Enter outside a list item falls through to plain Newline and Indent"
  (define b (note "  plain text"))
  (send b set-position 2)
  (run-command 'markdown-enter)
  (check-equal? (text b) "  \n  plain text" "keeps the line's indentation, like newline-and-indent"))

;; ---- Tab / Shift+Tab ------------------------------------------------------------------------

(test-case "Tab indents a list item; Shift+Tab outdents it"
  (define b (note "- one\n- two"))
  (send b set-position 8)                  ; inside "two"
  (run-command 'markdown-indent)
  (check-equal? (text b) "- one\n  - two")
  (send b set-position 10)                 ; still inside "two", now indented
  (run-command 'markdown-outdent)
  (check-equal? (text b) "- one\n- two"))

(test-case "Tab on a list's first item is a no-op (nothing to indent under)"
  (define b (note "- one"))
  (send b set-position 2)
  (run-command 'markdown-indent)
  (check-equal? (text b) "- one"))

(test-case "Tab outside a list keeps the normal Insert Indent behavior"
  (define b (note "plain"))
  (send b set-position 0)
  (run-command 'markdown-indent)
  (check-equal? (text b) "  plain"))

(test-case "Shift+Tab outside a list keeps the normal Outdent Lines behavior"
  (define b (note "  plain"))
  (send b set-position 2 2)
  (run-command 'markdown-outdent)
  (check-equal? (text b) "plain"))

(test-case "Enter and Tab behave the same in the Markdown Source view"
  (define b (note "- one\n- two"))
  (run-command 'toggle-markdown-view)      ; -> Source
  (send b set-position 5)
  (run-command 'markdown-enter)
  (check-equal? (text b) "- one\n- \n- two")
  (send b set-position 13)                 ; inside "two", now on its own line
  (run-command 'markdown-indent)
  (check-equal? (text b) "- one\n- \n  - two"))

;; ---- scoping: prose only ----------------------------------------------------------------------

(test-case "outside Markdown, all three fall through unchanged"
  (define b (new-buffer! "lists.rkt" #:mode 'racket-mode))
  (send b insert "(+ 1 2)")
  (set-current-buffer! b)
  (send b set-position 0)
  (run-command 'markdown-indent)
  (check-equal? (text b) "  (+ 1 2)" "plain Tab behavior"))

;; ---- key dispatch through the real keymaps ---------------------------------------------------

(define (kev code #:shift [shift #f])
  (new key-event% [key-code code] [shift-down shift]))

(test-case "Enter and Tab dispatch through markdown-mode's own keymap, ahead of the global one"
  (parameterize ([current-platform 'mac])
    (define b (note "- one"))
    (send b set-position (send b last-position))
    (send b on-char (kev #\return))
    (check-equal? (text b) "- one\n- ")
    (send b set-position (send b last-position))
    (send b on-char (kev #\tab))
    (check-equal? (text b) "- one\n  - " "indents under the previous item")
    (define b2 (note "plain"))
    (send b2 set-position 0)
    (send b2 on-char (kev #\tab))
    (check-equal? (text b2) "  plain" "outside a list, Tab still inserts an indent")))
