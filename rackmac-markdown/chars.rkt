#lang racket/base
;; Character classification from the CommonMark spec ("Characters and lines"), plus tab-column
;; helpers used by the block parser to track indentation exactly as cmark does.
(require racket/string)
(provide space-or-tab? unicode-whitespace? unicode-punctuation? ascii-punctuation?
         line-ending-char? blank-string?
         tab-stop advance-columns)

;; Space or tab (U+0020, U+0009): the two characters that make up "horizontal whitespace"
;; in most of the spec's line-structure rules.
(define (space-or-tab? ch)
  (or (eqv? ch #\space) (eqv? ch #\tab)))

;; A line-ending character as the spec defines it (line endings are normalized to \n by the
;; caller per the design's position model, but \r is tolerated for other callers/spec text).
(define (line-ending-char? ch)
  (or (eqv? ch #\newline) (eqv? ch #\return)))

;; Unicode whitespace character (spec): a Unicode Zs, or tab, LF, CR, FF, or space.
(define (unicode-whitespace? ch)
  (or (eqv? ch #\space) (eqv? ch #\tab) (eqv? ch #\newline)
      (eqv? ch #\return) (eqv? ch #\page)
      (eq? (char-general-category ch) 'zs)))

;; ASCII punctuation character (spec, exact set):
;; !"#$%&'()*+,-./:;<=>?@[\]^_`{|}~
(define ascii-punctuation-chars
  (string->list "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"))

(define (ascii-punctuation? ch)
  (and (memv ch ascii-punctuation-chars) #t))

;; Unicode punctuation character (spec): ASCII punctuation, or anything in the Unicode P
;; (punctuation) or S (symbol) general category classes.
(define (unicode-punctuation? ch)
  (or (ascii-punctuation? ch)
      (memq (char-general-category ch)
            '(pc pd pe pf pi po ps sc sk sm so))))

;; A string of only spaces and tabs (used for blank-line detection).
(define (blank-string? s)
  (for/and ([ch (in-string s)]) (space-or-tab? ch)))

;; Tab stops are every 4 columns (spec, "Tabs").
(define tab-width 4)
(define (tab-stop column) (- tab-width (modulo column tab-width)))

;; Advances (offset, column) across `n` columns of the line's whitespace prefix, starting the
;; scan at `offset` (must be spaces/tabs only up to where it stops), following cmark's rule for
;; partially-consumed tabs: a tab that straddles the target column is not consumed (the offset
;; does not move past it), but the column does advance by the requested amount, and the caller
;; is left knowing the tab was only partially used.
;; Returns (values new-offset new-column partially-consumed-tab?).
(define (advance-columns source offset column n line-end)
  (let loop ([offset offset] [column column] [remaining n])
    (cond
      [(<= remaining 0) (values offset column #f)]
      [(>= offset line-end) (values offset column #f)]
      [else
       (define ch (string-ref source offset))
       (cond
         [(eqv? ch #\tab)
          (define step (tab-stop column))
          (cond
            [(> step remaining)
             ;; Partial: column advances, offset stays on the tab.
             (values offset (+ column remaining) #t)]
            [else (loop (add1 offset) (+ column step) (- remaining step))])]
         [(eqv? ch #\space)
          (loop (add1 offset) (add1 column) (sub1 remaining))]
         [else (values offset column #f)])]))) ; non-space/tab: stop, as-is
