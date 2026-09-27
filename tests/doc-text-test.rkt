#lang racket/base
;; Snip-aware document text (#292, docs/UI-DESIGN.md §5.3): `document-text` reads each
;; decoration snip's source and drops foreign snips, so a note with decorations saves, copies,
;; counts and searches as its Markdown. A stand-in source snip (count = its source length) is
;; used here; the real checkbox snip has its own round trip in checkbox-test.rkt.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file racket/string
         "../rackmac/editor.rkt" "../rackmac/doc-text.rkt" "../rackmac/status-defaults.rkt"
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/frame.rkt")

(define f (make-main-frame))                ; hidden: show is never called

;; Draws nothing in particular; its text is the source it stands for.
(define marker-snip%
  (class* snip% (source-snip<%>)
    (init-field source)
    (super-new)
    (send this set-count (string-length source))
    (define/override (get-text offset num [flattened? #f])
      (substring source (min offset (string-length source)) (min (+ offset num) (string-length source))))
    (define/override (copy) (new marker-snip% [source source]))))

(define source "# Tasks\n\n- [ ] Call the vendor\n- [x] Send the draft\n")

;; The note with "[ ]" and "[x]" swapped for marker snips and an image snip after the heading.
(define (decorated)
  (define b (new-buffer! "tasks.md" #:mode 'text-mode))
  (send b insert source)
  (for ([m (in-list (reverse (regexp-match-positions* #rx"\\[.\\]" source)))])
    (send b insert (new marker-snip% [source (substring source (car m) (cdr m))]) (car m) (cdr m)))
  (send b insert (make-object image-snip%) 7)
  b)

(test-case "positions stay source offsets; get-text shows the image's placeholder"
  (define b (decorated))
  (check-equal? (send b last-position) (add1 (string-length source)))
  (check-true (string-contains? (send b get-text) "Tasks.\n") "text%'s own get-text leaks the '.'"))

(test-case "document-text is the file: markers give their source, the image nothing"
  (define b (decorated))
  (check-equal? (send b document-text) source)
  (check-equal? (send b document-text 0 8) "# Tasks")
  (check-equal? (send b document-text 12 15) "[ ]" "editor positions (the image is at 7)")
  (check-equal? (send b document-text 13 14) " " "a part of a marker is that part of its source"))

(test-case "keep-positions: aligned with editor positions, the image a U+FFFC"
  (define b (decorated))
  (define t (send b document-text #:keep-positions? #t))
  (check-equal? (string-length t) (send b last-position))
  (check-equal? (string-ref t 7) object-replacement)
  (check-equal? (remove-object-replacements t) source)
  (check-equal? (buffer-string b) t "find searches the aligned text"))

(test-case "round trip: saving a decorated note writes the Markdown byte for byte"
  (define b (decorated))
  (define p (make-temporary-file "rackmac-doc-text-~a.md"))
  (send b save-to! p)
  (check-equal? (file->bytes p) (string->bytes/utf-8 source))
  (check-false (regexp-match? #rx"\\." (file->string p)) "no image placeholder in the file")
  (delete-file p))

(test-case "copy yields the source; word count ignores the image"
  (define saved (send the-clipboard get-clipboard-string 0))
  (define b (decorated))
  (set-current-buffer! b)
  (send b set-position 9 (send b last-position))
  (run-command 'copy)
  (check-equal? (send the-clipboard get-clipboard-string 0) (substring source 8))
  (check-equal? (word-count b) 13)
  (send the-clipboard set-clipboard-string saved 0))
