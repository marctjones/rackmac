#lang racket/base
;; The Format toolbar group for notes (#336, docs/UI-DESIGN.md §2.3): Bold, Italic, Link, a
;; Heading popup (Heading 1-3, Body Text), Bulleted, Numbered, Checklist and the Formatted/Source
;; toggle, shown only for Markdown (the same #:mode scoping that already shows Run only for
;; Racket) and dimming from #:when. Driven through the real (hidden) window.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/list
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/frame.rkt"
         "../rackmac/editor.rkt" "../rackmac/toolbar.rkt" "../rackmac/ui/context-menu.rkt"
         "../rackmac/md-format.rkt" "../rackmac/md-toolbar.rkt")

(define (names groups) (map (lambda (g) (map toolbar-item-command g)) groups))
(define expected-format
  '(toggle-bold toggle-italic insert-link heading-menu
    toggle-bulleted-list toggle-numbered-list toggle-checklist toggle-markdown-view))

;; ---- registry ----------------------------------------------------------------------

(test-case "the Format group is registered for markdown-mode only, in the design's order"
  (check-not-false (member expected-format (names (toolbar-items-for 'markdown-mode))))
  (check-false (member expected-format (names (toolbar-items-for 'racket-mode)))))

(test-case "Bold, Italic, Bulleted and Numbered show a letter tile, not an icon"
  (define (tile name) (toolbar-item-label (findf (lambda (it) (eq? (toolbar-item-command it) name)) (toolbar-items))))
  (check-equal? (tile 'toggle-bold) "B")
  (check-equal? (tile 'toggle-italic) "I")
  (check-equal? (tile 'toggle-bulleted-list) "•")
  (check-equal? (tile 'toggle-numbered-list) "1.")
  (check-equal? (tile 'heading-menu) "H▾"))

(test-case "the Heading button pops up Heading 1-3 and Body Text"
  (define it (findf (lambda (it) (eq? (toolbar-item-command it) 'heading-menu)) (toolbar-items)))
  (check-equal? (toolbar-item-items it) '(heading-1 heading-2 heading-3 body-text))
  (define menu (build-popup-menu (list (toolbar-item-items it))))
  ;; labels carry their shortcut, like any other menu (command-menu-label, frame.rkt)
  (check-equal? (for/list ([i (send menu get-items)]) (send i get-label))
                '("Heading 1    ⌥⌘1" "Heading 2    ⌥⌘2" "Heading 3    ⌥⌘3" "Body Text    ⌥⌘0")))

;; ---- the button row in the window ------------------------------------------------------

(define f (make-main-frame))
(define tb (main-toolbar))
(define (doc text mode)
  (define b (new-buffer! "tb-format" #:mode mode))
  (set-current-buffer! b)
  (send b insert text)
  (send b set-position 0)
  b)
(define (click name) (send (send tb button-for name) command (new control-event% [event-type 'button])))
(define (enabled? name) (send (send tb button-for name) is-enabled?))

(test-case "the Format group shows for a Markdown document, not for Racket"
  (doc "hello" 'markdown-mode)
  (check-equal? (filter (lambda (n) (memq n expected-format)) (send tb button-commands)) expected-format)
  (doc "" 'racket-mode)
  (check-false (memq 'toggle-bold (send tb button-commands))))

(test-case "Format buttons are enabled for a Markdown document (dim from #:when otherwise)"
  (doc "hello" 'markdown-mode)
  (for ([n expected-format]) (check-true (enabled? n) (format "~a enabled" n))))

(test-case "clicking Bold runs the command, like a plain toolbar button"
  (define b (doc "hello" 'markdown-mode))
  (send b set-position 0 5)
  (click 'toggle-bold)
  (check-equal? (send b get-text) "**hello**"))

(test-case "clicking the Formatted/Source toggle button flips the view"
  (doc "hello" 'markdown-mode)
  (check-true (is-a? (send tb button-for 'toggle-markdown-view) button%))
  (click 'toggle-markdown-view)
  (check-equal? (command-checked? (find-command 'toggle-markdown-view)) #t)
  (click 'toggle-markdown-view))
