#lang racket/base
;; Typography (docs/UI-DESIGN.md 1.3, 1.4): notes are set in the prose face, code in the mono
;; face, both from the Skeptical Engineering type system with installed fallbacks; restyling
;; never counts as an edit; zoom scales both; prose sits centered at its measure.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base
         "../rackmac/editor.rkt" "../rackmac/theme.rkt" "../rackmac/commands.rkt" "../rackmac/ui/layout.rkt")

(define (style-at b pos) (send (send b find-snip pos 'after) get-style))
(define (face-at b pos) (send (send (style-at b pos) get-font) get-face))
(define (size-at b pos) (send (send (style-at b pos) get-font) get-point-size))
(define (fresh mode text)
  (define b (new-buffer! "typo" #:mode mode))
  (send b insert text)
  (send b clear-undos)
  (send b set-modified #f)
  b)

(test-case "faces resolve to the first installed candidate, Plex first"
  (check-equal? (resolve-face '("IBM Plex Serif" "Georgia") '("Georgia" "IBM Plex Serif")) "IBM Plex Serif")
  (check-equal? (resolve-face '("IBM Plex Serif" "Charter" "Georgia") '("Georgia" "Charter")) "Charter")
  (check-false (resolve-face '("IBM Plex Sans") '("Helvetica")))
  (check-equal? (car prose-faces) "IBM Plex Serif")
  (check-equal? (car mono-faces) "IBM Plex Mono")
  (check-not-false (member prose-face prose-faces))
  (check-not-false (member mono-face mono-faces)))

(test-case "chrome text uses the ui face at the control font's size, or the control font itself"
  (check-eq? (ui-font normal-control-font #f) normal-control-font "no Plex Sans: the control font")
  (define installed (car (get-face-list)))      ; stands in for IBM Plex Sans
  (define f (ui-font small-control-font installed))
  (check-equal? (send f get-face) installed)
  (check-equal? (send f get-size) (send small-control-font get-size))
  (check-equal? (send f get-size-in-pixels) (send small-control-font get-size-in-pixels)))

(test-case "a note is set in the prose face; code in the mono face"
  (define note (fresh 'markdown-mode "Plain words.\n"))
  (check-equal? (send note default-style-name) "Prose")
  (check-equal? (face-at note 2) prose-face)
  (define code (fresh 'racket-mode "(define x 1)\n"))
  (check-equal? (send code default-style-name) "Standard")
  (check-equal? (face-at code 2) mono-face))

(test-case "typing into an empty note uses the prose face"
  (define b (new-buffer! "typo-empty" #:mode 'text-mode))
  (send b insert "hello")
  (check-equal? (face-at b 1) prose-face))

(test-case "changing the Language restyles the document without making it an edit"
  (define b (fresh 'text-mode "(define x 1)\n"))
  (send b set-mode! 'racket-mode)
  (check-equal? (face-at b 3) mono-face)
  (send b set-mode! 'text-mode)
  (check-equal? (face-at b 3) prose-face)
  (check-false (send b is-modified?) "restyling is not an edit")
  (check-false (send b can-do-edit-operation? 'undo) "and leaves nothing to undo"))

(test-case "inline code in a note switches to the mono face"
  (define b (fresh 'markdown-mode "Run `raco test` now.\n"))
  (send b rehighlight!)
  (check-equal? (face-at b 7) mono-face "inside the code span")
  (check-equal? (face-at b 1) prose-face "outside it"))

(test-case "prose is one point larger than code, and zoom scales both"
  (define note (fresh 'text-mode "words\n"))
  (define code (fresh 'racket-mode "(x)\n"))
  (check-equal? (size-at note 1) (add1 (size-at code 1)))
  (define before font-size)
  (set-font-size! (+ before 4))
  (check-equal? (size-at code 1) (+ before 4))
  (check-equal? (size-at note 1) (+ before 5))
  (set-font-size! before))

(test-case "prose uses extra line spacing; code does not"
  (check-= (send (fresh 'text-mode "a\n") get-line-spacing) 4 0)
  (check-= (send (fresh 'racket-mode "a\n") get-line-spacing) 1 0))

(test-case "the measure is centered in wide windows and never squeezes narrow ones"
  (check-equal? (centered-inset 1000 600) 200)
  (check-equal? (centered-inset 1001 600.4) 200 "rounds the measure up, the inset down")
  (check-equal? (centered-inset 500 600) editor-inset-x "narrower than the measure: normal inset")
  (check-equal? (centered-inset 1000 #f) editor-inset-x "code: normal inset"))
