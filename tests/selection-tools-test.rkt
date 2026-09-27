#lang racket/base
;; Selection actions (#125-#129, rackmac/selection-tools.rkt): Change Case, Sort Lines, Swap
;; Words/Lines, Wrap to Width and Trim Trailing Whitespace, each one undo step, reachable from
;; the Edit menu (or, for Change Case, its own submenu) and the palette.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/string racket/file
         "../rackmac/selection-tools.rkt" "../rackmac/command.rkt" "../rackmac/editor.rkt"
         "../rackmac/settings.rkt")

;; setting-set! persists to settings.rktd (settings.rkt); redirect it to a scratch dir first,
;; the same idiom appearance-test.rkt and settings-test.rkt use, so this never touches a real
;; ~/.config/rackmac on whoever runs the suite.
(void (putenv "RACKMAC_HOME" (path->string (make-temporary-file "rackmac-selection-tools~a" 'directory))))

(define (doc text [start 0] [end start])
  (define b (new-buffer! "sel-tools" #:mode 'markdown-mode))
  (send b insert text) (send b clear-undos) (send b set-position start end)
  (set-current-buffer! b)
  b)
(define (txt b) (send b get-text))
(define (sel b) (cons (send b get-start-position) (send b get-end-position)))

;; ---- Change Case (#125) -------------------------------------------------------------------

(test-case "UPPERCASE changes the selection and leaves it selected; one undo step"
  (define b (doc "Hello World" 0 11))
  (run-command 'change-case-upper)
  (check-equal? (txt b) "HELLO WORLD")
  (check-equal? (sel b) '(0 . 11))
  (send b undo)
  (check-equal? (txt b) "Hello World" "one undo step"))

(test-case "lowercase"
  (define b (doc "Hello World" 0 11))
  (run-command 'change-case-lower)
  (check-equal? (txt b) "hello world"))

(test-case "Title Case"
  (define b (doc "hello world" 0 11))
  (run-command 'change-case-title)
  (check-equal? (txt b) "Hello World"))

(test-case "no selection: the word at the cursor, like Bold/Italic's own fallback"
  (define b (doc "hello world" 8 8))   ; a bare caret inside "world"
  (run-command 'change-case-upper)
  (check-equal? (txt b) "hello WORLD"))

(test-case "empty selection with no word under it (an empty document) is a no-op"
  (define b (doc "" 0 0))
  (run-command 'change-case-upper)
  (check-equal? (txt b) ""))

(test-case "unicode: accented characters case-convert correctly"
  (define b (doc "café" 0 4))
  (run-command 'change-case-upper)
  (check-equal? (txt b) "CAFÉ")
  (define b2 (doc "CAFÉ" 0 4))
  (run-command 'change-case-lower)
  (check-equal? (txt b2) "café"))

(test-case "unicode: a case conversion that changes length (ß -> SS) still selects the result"
  (define b (doc "straße" 0 6))
  (run-command 'change-case-upper)
  (check-equal? (txt b) "STRASSE")
  (check-equal? (sel b) '(0 . 7) "the selection grew with the text"))

(test-case "Change Case items live in their own submenu, not directly on Edit, and have no Emacs terms"
  (for ([n '(change-case-upper change-case-lower change-case-title)])
    (define c (find-command n))
    (check-false (command-menu c))
    (check-false (string=? (command-help c) ""))
    (check-true (pair? (command-aliases c)))))

;; ---- Sort Lines (#126) --------------------------------------------------------------------

(test-case "Sort Lines sorts the selected lines alphabetically; one undo step"
  (define b (doc "banana\napple\ncherry"))
  (send b set-position 0 (send b last-position))
  (run-command 'sort-lines)
  (check-equal? (txt b) "apple\nbanana\ncherry")
  (send b undo)
  (check-equal? (txt b) "banana\napple\ncherry" "one undo step"))

(test-case "an already-sorted selection is left alone (no spurious undo step)"
  (define b (doc "apple\nbanana\ncherry"))
  (send b set-position 0 (send b last-position))
  (send b set-modified #f)
  (run-command 'sort-lines)
  (check-equal? (txt b) "apple\nbanana\ncherry")
  (check-false (send b is-modified?) "no edit when the selection is already sorted"))

(test-case "a single line, or no selection, has nothing to sort"
  (define b (doc "only one line"))
  (send b set-position 3 3)
  (run-command 'sort-lines)
  (check-equal? (txt b) "only one line"))

(test-case "sorting is case-insensitive, like Word's Sort"
  (define b (doc "Zebra\napple\nMango"))
  (send b set-position 0 (send b last-position))
  (run-command 'sort-lines)
  (check-equal? (txt b) "apple\nMango\nZebra"))

;; ---- Swap Words and Swap Lines (#127) -------------------------------------------------------

(test-case "Swap Words swaps the word before and after the caret; aliased transpose-*"
  (define b (doc "hello world" 5 5))
  (run-command 'swap-words)
  (check-equal? (txt b) "world hello")
  (check-not-false (member "transpose words" (command-aliases (find-command 'swap-words)))))

(test-case "Swap Words: a caret inside a word swaps that word with the next one"
  (define b (doc "hello world" 2 2))
  (run-command 'swap-words)
  (check-equal? (txt b) "world hello"))

(test-case "Swap Words: no word before the caret (document start) is a no-op"
  (define b (doc "hello world" 0 0))
  (run-command 'swap-words)
  (check-equal? (txt b) "hello world"))

(test-case "Swap Words: no word after the caret (document end) is a no-op"
  (define b (doc "hello world" 11 11))
  (run-command 'swap-words)
  (check-equal? (txt b) "hello world"))

(test-case "Swap Lines swaps the current line with the next; aliased transpose-*; one undo step"
  (define b (doc "one\ntwo\nthree"))
  (send b set-position 0 0)
  (run-command 'swap-lines)
  (check-equal? (txt b) "two\none\nthree")
  (check-not-false (member "transpose lines" (command-aliases (find-command 'swap-lines))))
  (send b undo)
  (check-equal? (txt b) "one\ntwo\nthree" "one undo step"))

(test-case "Swap Lines at the last line swaps with the line above instead"
  (define b (doc "one\ntwo\nthree"))
  (send b set-position (send b last-position) (send b last-position))
  (run-command 'swap-lines)
  (check-equal? (txt b) "one\nthree\ntwo"))

(test-case "Swap Lines on a single-line document is a no-op"
  (define b (doc "only"))
  (run-command 'swap-lines)
  (check-equal? (txt b) "only"))

;; ---- Wrap to Width (#128) -------------------------------------------------------------------

(test-case "Wrap to Width hard-wraps a long paragraph at the configured width, keeping it selected"
  (define w1 (make-string 30 #\a)) (define w2 (make-string 30 #\b)) (define w3 (make-string 30 #\c))
  (define para (string-append w1 " " w2 " " w3))
  (define b (doc para))
  (send b set-position 0 (send b last-position))
  (run-command 'wrap-to-width)
  (check-equal? (txt b) (string-append w1 " " w2 "\n" w3))
  (check-equal? (sel b) (cons 0 (string-length para)) "the wrapped paragraph stays selected")
  (check-equal? (setting-ref 'wrap-width) 80 "the default column width"))

(test-case "Wrap to Width does not merge a heading or list item into an adjacent paragraph"
  (setting-set! 'wrap-width 8)
  (define b (doc "# Heading\nAlpha Beta Gamma\n- one\n- two"))
  (send b set-position 0 (send b last-position))
  (run-command 'wrap-to-width)
  (check-equal? (txt b) "# Heading\nAlpha\nBeta\nGamma\n- one\n- two"
                "the heading and the list items are left exactly as they were")
  (setting-set! 'wrap-width 80))

(test-case "Wrap to Width does not merge a setext heading underline into the paragraph below"
  (setting-set! 'wrap-width 8)
  (define b (doc "Title\n-----\nAlpha Beta Gamma"))
  (send b set-position 0 (send b last-position))
  (run-command 'wrap-to-width)
  (check-equal? (txt b) "Title\n-----\nAlpha\nBeta\nGamma"
                "\"-----\" is a structural line, not a short word to join with \"Title\"")
  (setting-set! 'wrap-width 80))

(test-case "Wrap to Width: no selection does not reach across a list item into the paragraph above"
  (define w1 (make-string 30 #\a)) (define w2 (make-string 30 #\b)) (define w3 (make-string 30 #\c))
  (define upper (string-append w1 " " w2 " " w3))
  (define w4 (make-string 30 #\x)) (define w5 (make-string 30 #\y)) (define w6 (make-string 30 #\z))
  (define lower (string-append w4 " " w5 " " w6))
  (define text (string-append upper "\n- item\n" lower))
  (define caret (+ (string-length upper) (string-length "\n- item\n")))   ; start of the lower paragraph
  (define b (doc text caret caret))
  (run-command 'wrap-to-width)
  (check-equal? (txt b) (string-append upper "\n- item\n" w4 " " w5 "\n" w6)
                "the paragraph above the list item is untouched"))

(test-case "Wrap to Width wraps multiple selected paragraphs in one undo step"
  (define w1 (make-string 30 #\a)) (define w2 (make-string 30 #\b)) (define w3 (make-string 30 #\c))
  (define para1 (string-append w1 " " w2 " " w3))
  (define w4 (make-string 30 #\x)) (define w5 (make-string 30 #\y)) (define w6 (make-string 30 #\z))
  (define para2 (string-append w4 " " w5 " " w6))
  (define original (string-append para1 "\n\n" para2))
  (define expected (string-append w1 " " w2 "\n" w3 "\n\n" w4 " " w5 "\n" w6))
  (define b (doc original))
  (send b set-position 0 (send b last-position))
  (run-command 'wrap-to-width)
  (check-equal? (txt b) expected)
  (check-equal? (sel b) (cons 0 (string-length expected)) "both wrapped paragraphs stay selected")
  (send b undo)
  (check-equal? (txt b) original "one undo step restores both paragraphs"))

(test-case "Wrap to Width: no selection wraps only the paragraph under the caret"
  (define w1 (make-string 30 #\a)) (define w2 (make-string 30 #\b)) (define w3 (make-string 30 #\c))
  (define para (string-append w1 " " w2 " " w3))
  (define prefix "Title\n\n")
  (define b (doc (string-append prefix para) (string-length prefix) (string-length prefix)))
  (run-command 'wrap-to-width)
  (check-equal? (txt b) (string-append prefix w1 " " w2 "\n" w3)))

(test-case "Wrap to Width: a blank line at the caret is a no-op"
  (define b (doc "one\n\ntwo" 4 4))
  (run-command 'wrap-to-width)
  (check-equal? (txt b) "one\n\ntwo"))

(test-case "Wrap to Width: a paragraph already within the width is left alone (no spurious undo step)"
  (define b (doc "short line"))
  (send b set-position 0 (send b last-position))
  (send b set-modified #f)
  (run-command 'wrap-to-width)
  (check-equal? (txt b) "short line")
  (check-false (send b is-modified?)))

(test-case "the width comes from the wrap-width setting"
  (setting-set! 'wrap-width 5)
  (define b (doc "aa bb cc"))
  (send b set-position 0 (send b last-position))
  (run-command 'wrap-to-width)
  (check-equal? (txt b) "aa bb\ncc")
  (check-equal? (sel b) '(0 . 8))
  (setting-set! 'wrap-width 80))

;; ---- Trim Trailing Whitespace (#129) ---------------------------------------------------------

(test-case "Trim Trailing Whitespace removes trailing whitespace from each selected line; one undo step"
  (define b (doc "one  \ntwo\t\nthree "))
  (send b set-position 0 (send b last-position))
  (run-command 'trim-trailing-whitespace)
  (check-equal? (txt b) "one\ntwo\nthree")
  (send b undo)
  (check-equal? (txt b) "one  \ntwo\t\nthree " "one undo step"))

(test-case "nothing selected trims the whole document"
  (define b (doc "one  \ntwo  " 0 0))
  (run-command 'trim-trailing-whitespace)
  (check-equal? (txt b) "one\ntwo"))

(test-case "lines with no trailing whitespace are a no-op"
  (define b (doc "clean\nlines"))
  (send b set-position 0 (send b last-position))
  (send b set-modified #f)
  (run-command 'trim-trailing-whitespace)
  (check-equal? (txt b) "clean\nlines")
  (check-false (send b is-modified?)))

;; ---- reachable from the Edit menu, real help text, real aliases -----------------------------

(test-case "the direct Edit-menu commands have menu placement, help and aliases"
  (for ([n '(sort-lines wrap-to-width trim-trailing-whitespace swap-words swap-lines)])
    (define c (find-command n))
    (check-equal? (command-menu c) "Edit" (format "~a" n))
    (check-false (string=? (command-help c) "") (format "~a help" n))
    (check-true (pair? (command-aliases c)) (format "~a aliases" n))))
