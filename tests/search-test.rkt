#lang racket/base
;; The pure matcher (rackmac/search.rkt): no window, no buffer, just strings and options.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit "../rackmac/search.rkt")

;; ---- find-matches ----------------------------------------------------------------

(test-case "literal search is case-insensitive by default"
  (check-equal? (find-matches "Cat cat CAT" "cat") '((0 . 3) (4 . 7) (8 . 11))))

(test-case "match case narrows to the exact case"
  (check-equal? (find-matches "Cat cat CAT" "cat" #:case? #t) '((4 . 7))))

(test-case "whole word excludes matches inside a longer word"
  (check-equal? (find-matches "cat category catalog cat" "cat" #:word? #t) '((0 . 3) (21 . 24))))

(test-case "whole word respects punctuation boundaries"
  (check-equal? (find-matches "\"cat,\" cat." "cat" #:word? #t) '((1 . 4) (7 . 10))))

(test-case "whole word treats unicode letters as word characters"
  ;; "café" inside "cafés" is not a whole word (é is a letter, so is the trailing "s");
  ;; "café" next to punctuation is.
  (check-equal? (find-matches "café, cafés, café!" "café" #:word? #t) '((0 . 4) (13 . 17))))

(test-case "empty query has no matches, without error"
  (check-equal? (find-matches "anything" "") '()))

(test-case "regular expression mode"
  (check-equal? (find-matches "a1 b22 c333" "[a-z][0-9]+" #:regex? #t)
                '((0 . 2) (3 . 6) (7 . 11))))

(test-case "invalid regular expression is reported, not thrown"
  (define r (find-matches "text" "(unclosed" #:regex? #t))
  (check-true (find-error? r))
  (check-equal? (find-error-message r) "Invalid pattern"))

(test-case "overlapping patterns: matches are non-overlapping, leftmost first"
  (check-equal? (find-matches "aaaa" "aa") '((0 . 2) (2 . 4))))

(test-case "a pattern that can match empty never produces a zero-width match"
  (check-equal? (find-matches "abc" "x*" #:regex? #t) '()))

(test-case "the match count is capped"
  (define text (apply string-append (for/list ([i 20000]) "a")))
  (define matches (find-matches text "a" #:limit 10000))
  (check-equal? (length matches) 10000))

;; ---- step-match-index --------------------------------------------------------------

(test-case "stepping forward, backward and wrapping"
  (define ms '((4 . 7) (12 . 15)))
  (define-values (i0 w0) (step-match-index ms 0 'forward))
  (check-equal? (list i0 w0) (list 0 #f))
  (define-values (i1 w1) (step-match-index ms 7 'forward))
  (check-equal? (list i1 w1) (list 1 #f))
  (define-values (i2 w2) (step-match-index ms 15 'forward))
  (check-equal? (list i2 w2) (list 0 #t) "wraps to the first")
  (define-values (i3 w3) (step-match-index ms 4 'backward))
  (check-equal? (list i3 w3) (list 1 #t) "wraps to the last"))

(test-case "forward stepping lands on a match starting exactly at the anchor"
  (define-values (i w) (step-match-index '((2 . 4)) 2 'forward))
  (check-equal? (list i w) (list 0 #f)))

(test-case "no matches: no index, not wrapped"
  (define-values (i w) (step-match-index '() 0 'forward))
  (check-equal? (list i w) (list #f #f)))

;; ---- replace-all-string -------------------------------------------------------------

(test-case "replace all: replacement containing the query does not loop"
  (define r (replace-all-string "a-a-a" "a" "aa"))
  (check-equal? (replace-result-text r) "aa-aa-aa")
  (check-equal? (replace-result-count r) 3))

(test-case "replace all with a regex group reference"
  (define r (replace-all-string "John Smith, Jane Doe" "(\\w+) (\\w+)" "\\2 \\1" #:regex? #t))
  (check-equal? (replace-result-text r) "Smith John, Doe Jane")
  (check-equal? (replace-result-count r) 2))

(test-case "replace all respects whole word"
  (define r (replace-all-string "cat catalog" "cat" "dog" #:word? #t))
  (check-equal? (replace-result-text r) "dog catalog")
  (check-equal? (replace-result-count r) 1))

(test-case "replace all with a literal replacement is never treated as a pattern"
  ;; The replacement contains backslash-group and & syntax; in literal mode it is inserted as-is.
  (define r (replace-all-string "x" "x" "\\1 & done"))
  (check-equal? (replace-result-text r) "\\1 & done"))

(test-case "replace all with an invalid pattern is reported, not thrown"
  (check-true (find-error? (replace-all-string "text" "(unclosed" "y" #:regex? #t))))

(test-case "replace all with no matches changes nothing"
  (define r (replace-all-string "abc" "zzz" "y"))
  (check-equal? (replace-result-text r) "abc")
  (check-equal? (replace-result-count r) 0))

;; ---- format-count --------------------------------------------------------------------

(test-case "format-count adds thousands separators and a plus at the cap"
  (check-equal? (format-count 12) "12")
  (check-equal? (format-count 1234) "1,234")
  (check-equal? (format-count 10000) "10,000+"))
