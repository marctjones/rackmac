#lang racket/base
;; The document's text as the file holds it (#292 doc-text, docs/UI-DESIGN.md §5.3). A note's
;; Formatted view puts decoration snips in the editor (checkboxes, later rules, folds, image
;; previews); every snip that stands for source markup implements `source-snip<%>`: its
;; `get-text` is that source and its count is the source's length, so positions stay source
;; offsets. Any other non-text snip (an `image-snip%`, whose `get-text` is ".") is not part of
;; the file. `text-source` walks the snips: text and source snips give their characters, other
;; snips none. buffer% exposes it as its `document-text` method; every path that means "the
;; file's text" (saving, recovery, export, copy, word count) reads it, and readers that work
;; in positions (find, the parser, highlighting, spell check) read it with `#:keep-positions?`,
;; where each position of a foreign snip becomes U+FFFC (OBJECT REPLACEMENT CHARACTER), so
;; offsets match the editor's and no "." is ever matched, spelled or parsed.
(require racket/class racket/snip racket/string)
(provide source-snip<%> source-snip? text-source object-replacement remove-object-replacements)

;; A snip whose get-text is the source markup it draws in place of.
(define source-snip<%> (interface ()))
(define (source-snip? s) (is-a? s source-snip<%>))

(define object-replacement (integer->char #xFFFC))

(define (text-source t [start 0] [end 'eof] #:keep-positions? [keep? #f])
  (define last (send t last-position))
  (define s (min (max 0 start) last))
  (define e (if (eq? end 'eof) last (min (max s end) last)))
  (define out (open-output-string))
  (define first (and (< s e) (let ([b (box 0)]) (cons (send t find-snip s 'after-or-none b) (unbox b)))))
  (let loop ([snip (and first (car first))] [pos (if first (cdr first) 0)])
    (when (and snip (< pos e))
      (define count (send snip get-count))
      (define from (max 0 (- s pos)))
      (define num (- (min e (+ pos count)) (+ pos from)))
      (cond
        [(or (is-a? snip string-snip%) (source-snip? snip))
         (write-string (send snip get-text from num #t) out)]
        [keep? (write-string (make-string num object-replacement) out)]
        [else (void)])
      (loop (send snip next) (+ pos count))))
  (get-output-string out))

;; Text read with #:keep-positions? and about to be inserted again: without the placeholders.
(define (remove-object-replacements str)
  (string-replace str (string object-replacement) ""))
