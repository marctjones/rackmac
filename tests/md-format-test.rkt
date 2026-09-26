#lang racket/base
;; Formatting commands for notes (#335, docs/UI-DESIGN.md §2.3-2.4): each toggles/wraps
;; correctly, including across existing markup, in one undo step, identically in the Formatted
;; and Markdown Source views, only for prose documents (#:when, and the Format menu itself), and
;; dispatches through the real keymaps.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/frame.rkt"
         "../rackmac/editor.rkt" "../rackmac/buffer.rkt" "../rackmac/platform.rkt"
         "../rackmac/md-view.rkt" "../rackmac/md-view-commands.rkt" "../rackmac/md-format.rkt")

(define f (make-main-frame))

(define (note text #:name [name "format.md"])
  (define b (new-buffer! name #:mode 'markdown-mode))
  (send b insert text)
  (send b clear-undos)
  (send b set-modified #f)
  (set-current-buffer! b)
  b)
(define (text b) (send b get-text))
(define (sel! b s e) (send b set-position s e))
(define (sel b) (cons (send b get-start-position) (send b get-end-position)))

;; ---- inline formatting ------------------------------------------------------------------------

(test-case "Bold wraps the selection and leaves it selected; undo is one step"
  (define b (note "hello world"))
  (sel! b 6 11)
  (run-command 'toggle-bold)
  (check-equal? (text b) "hello **world**")
  (check-equal? (sel b) '(8 . 13))
  (send b undo)
  (check-equal? (text b) "hello world" "one undo step"))

(test-case "Bold at a bare caret takes the word under it"
  (define b (note "hello world"))
  (sel! b 8 8)                    ; inside "world"
  (run-command 'toggle-bold)
  (check-equal? (text b) "hello **world**"))

(test-case "Italic adds onto existing bold (nested markup)"
  (define b (note "one **two** three"))
  (sel! b 6 9)                    ; "two", already bold
  (run-command 'toggle-italic)
  (check-equal? (text b) "one ***two*** three" "bold and italic together"))

(test-case "Bold toggles off cleanly on plain text (round trip)"
  (define b (note "one two three"))
  (sel! b 4 7)                    ; "two"
  (run-command 'toggle-bold)
  (check-equal? (text b) "one **two** three")
  (run-command 'toggle-bold)             ; selection is already set to the new "two" by the first call
  (check-equal? (text b) "one two three" "toggling twice restores the original text"))

(test-case "Inline Code and Strikethrough"
  (define b (note "some code"))
  (sel! b 5 9)
  (run-command 'toggle-inline-code)
  (check-equal? (text b) "some `code`")
  (define b2 (note "oops"))
  (sel! b2 0 4)
  (run-command 'toggle-strikethrough)
  (check-equal? (text b2) "~~oops~~"))

;; ---- link ---------------------------------------------------------------------------------

(test-case "Insert Link wraps the selection with the cursor in the URL"
  (define b (note "see the docs"))
  (sel! b 8 12)                   ; "docs"
  (run-command 'insert-link)
  (check-equal? (text b) "see the [docs]()")
  (check-equal? (sel b) '(15 . 15) "caret is inside the empty URL"))

(test-case "Insert Link at a bare caret makes an empty link"
  (define b (note "x"))
  (sel! b 0 0)
  (run-command 'insert-link)
  (check-equal? (text b) "[]()x")
  (check-equal? (sel b) '(3 . 3)))

;; ---- headings and body text -----------------------------------------------------------------

(test-case "Heading 1/2/3 and Body Text"
  (define b (note "Title"))
  (sel! b 0 0)
  (run-command 'heading-1)
  (check-equal? (text b) "# Title")
  (run-command 'heading-2)
  (check-equal? (text b) "## Title")
  (run-command 'heading-3)
  (check-equal? (text b) "### Title")
  (run-command 'body-text)
  (check-equal? (text b) "Title" "Body Text removes the heading marker"))

;; ---- lists and quote -------------------------------------------------------------------------

(test-case "Bulleted List toggles on and off"
  (define b (note "milk\neggs"))
  (sel! b 0 (string-length (text b)))
  (run-command 'toggle-bulleted-list)
  (check-equal? (text b) "- milk\n- eggs")
  (run-command 'toggle-bulleted-list)
  (check-equal? (text b) "milk\neggs" "toggling again removes the markers"))

(test-case "Numbered List renumbers as it goes"
  (define b (note "milk\neggs"))
  (sel! b 0 (string-length (text b)))
  (run-command 'toggle-numbered-list)
  (check-equal? (text b) "1. milk\n2. eggs"))

(test-case "Checklist adds a task marker to a bulleted item"
  (define b (note "- one"))
  (sel! b 0 0)
  (run-command 'toggle-checklist)
  (check-equal? (text b) "- [ ] one")
  (run-command 'toggle-checklist)
  (check-equal? (text b) "one" "toggling again removes the item entirely, like Bulleted/Numbered"))

(test-case "Quote toggles on and off"
  (define b (note "important"))
  (sel! b 0 0)
  (run-command 'toggle-quote)
  (check-equal? (text b) "> important")
  (run-command 'toggle-quote)
  (check-equal? (text b) "important"))

(test-case "Mark Done toggles the checkbox of the item at the caret"
  (define b (note "- [ ] one"))
  (sel! b 3 3)
  (run-command 'mark-done)
  (check-equal? (text b) "- [x] one")
  (run-command 'mark-done)
  (check-equal? (text b) "- [ ] one"))

;; ---- both views -----------------------------------------------------------------------------

(test-case "formatting commands behave identically in the Markdown Source view"
  (define b (note "hello world"))
  (run-command 'toggle-markdown-view)          ; -> Source
  (check-eq? (markdown-view b) 'source)
  (sel! b 6 11)
  (run-command 'toggle-bold)
  (check-equal? (text b) "hello **world**")
  (check-equal? (sel b) '(8 . 13))
  (sel! b 0 0)
  (run-command 'heading-1)
  (check-equal? (text b) "# hello **world**"))

;; ---- scoping: prose only ----------------------------------------------------------------------

(test-case "formatting commands are no-ops outside prose documents"
  (define b (new-buffer! "format.rkt" #:mode 'racket-mode))
  (send b insert "(+ 1 2)")
  (set-current-buffer! b)
  (sel! b 0 (send b last-position))
  (check-false (command-enabled? (find-command 'toggle-bold)))
  (run-command 'toggle-bold)
  (check-equal? (text b) "(+ 1 2)" "the command guards itself and does nothing"))

(test-case "the Format menu appears only for prose documents"
  (define md (note "x" #:name "menu.md"))
  (check-not-false (menu-for-title "Format") "shown for Markdown")
  (define rkt (new-buffer! "menu.rkt" #:mode 'racket-mode))
  (set-current-buffer! rkt)
  (check-false (menu-for-title "Format") "hidden for Racket")
  (set-current-buffer! md)
  (check-not-false (menu-for-title "Format") "comes back for Markdown"))

;; ---- key dispatch through the real keymaps ---------------------------------------------------

(define (kev code #:cmd [cmd #f] #:shift [shift #f] #:alt [alt #f])
  (new key-event% [key-code code] [meta-down cmd] [alt-down alt] [shift-down shift]))

(test-case "default shortcuts dispatch through the real keymaps"
  (parameterize ([current-platform 'mac])
    (define b (note "hello world"))
    (sel! b 6 11)
    (send b on-char (kev #\b #:cmd #t))
    (check-equal? (text b) "hello **world**" "Cmd+B")
    (send b set-position 0 0)
    (send b on-char (kev #\1 #:cmd #t #:alt #t))
    (check-equal? (text b) "# hello **world**" "Cmd+Option+1")
    (define b2 (note "x"))
    (sel! b2 0 1)
    (send b2 on-char (kev #\l #:cmd #t #:shift #t))
    (check-equal? (text b2) "- [ ] x" "Shift+Cmd+L")))
