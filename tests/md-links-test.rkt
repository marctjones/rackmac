#lang racket/base
;; Links in notes (#338, docs/UI-DESIGN.md §2.2): ⌘-click (Ctrl+click on Windows) follows a link,
;; a plain click only places the caret, hover names the target in the status message. Web links
;; go to the browser, Markdown files open in Rackmac, other files in their default app; relative
;; paths resolve against the note's folder. Opening is a parameter, so nothing is launched.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file racket/string
         "../rackmac/commands.rkt" "../rackmac/frame.rkt" "../rackmac/editor.rkt" "../rackmac/hook.rkt"
         "../rackmac/platform.rkt" "../rackmac/md-view.rkt" "../rackmac/md-links.rkt"
         "../rackmac/md-links-open.rkt" "../rackmac-markdown/main.rkt")

(define f (make-main-frame))
(send f reflow-container)                             ; geometry only; the frame is never shown

(define dir (make-temporary-file "rackmac-links~a" 'directory))
(make-directory (build-path dir "docs"))
(define brief (build-path dir "docs" "the brief.md"))
(display-to-file "# The brief\n" brief)
(define pdf (build-path dir "docs" "exhibit.pdf"))
(display-to-file "%PDF" pdf)
(display-to-file "# Other\n" (build-path dir "Other Note.md"))

;; ---- where a link points --------------------------------------------------------------------

(define note-path (build-path dir "minutes.md"))
(define (url-of p) (string-append "file://" (string-replace (path->string p) " " "%20")))
(define (resolve t [p note-path]) (call-with-values (lambda () (resolve-link t p)) list))

(test-case "web and mail links go to the system"
  (check-equal? (resolve "https://example.com/a?b=1") '(url "https://example.com/a?b=1"))
  (check-equal? (resolve "HTTP://example.com") '(url "HTTP://example.com"))
  (check-equal? (resolve "mailto:clerk@example.com") '(url "mailto:clerk@example.com")))

(test-case "relative paths resolve against the note's folder"
  (check-equal? (resolve "docs/the%20brief.md") (list 'note (simplify-path brief)) "percent-escapes decoded")
  (check-equal? (resolve "docs/the%20brief.md#facts") (list 'note (simplify-path brief)) "fragment dropped")
  (check-equal? (resolve "./docs/../docs/exhibit.pdf") (list 'file (simplify-path pdf)))
  (check-equal? (resolve "docs") (list 'file (simplify-path (build-path dir "docs"))) "a folder opens in Finder")
  (check-equal? (resolve (path->string pdf) #f) (list 'file (simplify-path pdf)) "absolute paths need no folder")
  (check-equal? (resolve (url-of pdf)) (list 'file (simplify-path pdf)) "file: URLs"))

(test-case "missing files, untitled notes, other schemes and same-note anchors are not opened"
  (check-equal? (car (resolve "docs/nothing.md")) 'missing)
  (check-equal? (resolve "docs/the%20brief.md" #f) '(missing "docs/the%20brief.md"))
  (check-equal? (car (resolve "javascript:alert(1)")) 'unsupported)
  (check-equal? (car (resolve "#top")) 'unsupported))

(test-case "a wiki link names a note in the same folder"
  (check-equal? (resolve "[[Other Note]]") (list 'note (simplify-path (build-path dir "Other Note.md"))))
  (check-equal? (resolve "[[Other Note|the other one]]") (list 'note (simplify-path (build-path dir "Other Note.md"))))
  (check-equal? (car (resolve "[[Nobody]]")) 'missing))

(test-case "the link under a position: inline, autolink, inside bold, reference; not outside"
  (define text "See [the brief](docs/a.md) and <https://x.org>, **[b](c.pdf)**, [ref].\n\n[ref]: https://r.example\n")
  (define doc (parse-document text #:extensions all-extensions))
  (define (at s) (link-target-at doc (caar (regexp-match-positions (regexp-quote s) text))))
  (check-equal? (at "brief") "docs/a.md" "the link text")
  (check-equal? (at "(docs") "docs/a.md" "the markup is part of the link")
  (check-equal? (at "x.org") "https://x.org")
  (check-equal? (at "b](") "c.pdf")
  (check-equal? (at "ref]") "https://r.example")
  (check-false (at "See"))
  (check-false (at "and")))

;; ---- through the note, the mouse and the hook -----------------------------------------------

(define opened '())
(define (record! t) (set! opened (cons t opened)))

(define text "Read [the brief](docs/the%20brief.md) and <https://example.com> today.\n")
(define (pos-of s) (+ 1 (caar (regexp-match-positions (regexp-quote s) text))))
(define (note #:view [view 'formatted])
  (define b (new-buffer! "minutes.md" #:mode 'markdown-mode))
  (send b insert text)
  (send b set-path! note-path)
  (set-markdown-view! b view)
  (send b set-position 0)
  (set-current-buffer! b)
  (send f reflow-container)
  b)

;; A mouse event over position `pos`, in the canvas's coordinates.
(define (mouse type pos #:command? [command? #f])
  (define b (current-buffer))
  (define x (box 0)) (define y (box 0))
  (send b position-location pos x y #f)
  (define-values (dx dy) (send b editor-location-to-dc-location (+ 1 (unbox x)) (+ 2 (unbox y))))
  (new mouse-event% [event-type type] [x (inexact->exact (round dx))] [y (inexact->exact (round dy))]
       [left-down (eq? type 'left-down)]
       [meta-down (and command? (mac?))] [control-down (and command? (not (mac?)))]))

(test-case "⌘-click on a web link opens it in the browser; the caret stays put"
  (set! opened '())
  (define b (note))
  (parameterize ([open-externally record!])
    (send b on-event (mouse 'left-down (pos-of "example.com") #:command? #t)))
  (check-equal? opened '("https://example.com"))
  (check-equal? (send b get-start-position) 0 "the click followed the link instead of moving the caret"))

(test-case "a plain click places the caret and opens nothing"
  (set! opened '())
  (define b (note))
  (define p (pos-of "example.com"))
  (parameterize ([open-externally record!])
    (send b on-event (mouse 'left-down p))
    (send b on-event (mouse 'left-up p)))
  (check-equal? opened '())
  (check-true (<= (abs (- (send b get-start-position) p)) 1) "the caret is at the click"))

(test-case "⌘-click on a relative .md link opens that note in Rackmac"
  (define b (note))
  (check-true (send b link-click-at! (pos-of "the brief")))
  (check-equal? (send (current-buffer) get-path) (simplify-path brief))
  (check-equal? (send (current-buffer) get-mode) 'markdown-mode))

(test-case "⌘-click away from a link does nothing special"
  (define b (note))
  (check-false (send b link-click-at! (pos-of "Read")))
  (check-false (send b link-click-at! (pos-of "today"))))

(test-case "links follow in the Markdown Source view too"
  (set! opened '())
  (define b (note #:view 'source))
  (parameterize ([open-externally record!])
    (check-true (send b link-click-at! (pos-of "example.com"))))
  (check-equal? opened '("https://example.com")))

(test-case "another file opens in its default app; a missing one says so"
  (set! opened '())
  (define b (new-buffer! "files.md" #:mode 'markdown-mode))
  (send b insert "[exhibit](docs/exhibit.pdf) and [gone](docs/gone.pdf)\n")
  (send b set-path! note-path)
  (define said '())
  (define (spy s) (set! said (cons s said)))
  (add-hook! 'echo spy)
  (parameterize ([open-externally record!])
    (send b link-click-at! 2)
    (send b link-click-at! 32))
  (remove-hook! 'echo spy)
  (check-equal? opened (list (simplify-path pdf)))
  (check-true (for/or ([s said]) (regexp-match? #rx"^Can't find .*gone[.]pdf" s))))

(test-case "hovering a link names its target in the status message; leaving clears it"
  (define b (note))
  (define said '())
  (define (spy s) (set! said (cons s said)))
  (add-hook! 'echo spy)
  (send b on-event (mouse 'motion (pos-of "example.com")))
  (send b on-event (mouse 'motion (pos-of "example.com")))   ; same link: said once
  (send b on-event (mouse 'motion (pos-of "Read")))
  (remove-hook! 'echo spy)
  (check-equal? (length said) 2)
  (check-regexp-match #rx"^https://example[.]com  \\((⌘-click|Ctrl\\+click) to open\\)$" (cadr said))
  (check-equal? (car said) ""))

(test-case "documents without links ignore ⌘-click"
  (define b (new-buffer! "code.rkt" #:mode 'racket-mode))
  (send b insert "\"https://example.com\"")
  (check-false (send b link-click-at! 3)))
