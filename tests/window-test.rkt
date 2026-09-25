#lang racket/base
;; The real main window, built but never shown: keys delivered to its editor canvas reach
;; the buffer's key dispatch, and find/replace behave. (The OS -> window step still needs a
;; person or CI with a display; see issue "Verify real keystrokes".)
(require rackunit racket/class racket/gui/base
         "../rackmac/commands.rkt" "../rackmac/editor.rkt" "../rackmac/frame.rkt"
         "../rackmac/command.rkt" "../rackmac/platform.rkt")

(define f (make-main-frame))                ; hidden: show is never called
(define canvas (main-canvas))

(define (doc text [pos 0])
  (define b (new-buffer! "w"))
  (set-current-buffer! b)
  (send b insert text)
  (send b set-position pos)
  b)

(define (press code #:mod [mod? #f] #:shift [shift? #f] #:other-shift [os #f])
  (define e (new key-event% [key-code code] [shift-down shift?]
                 [meta-down (and mod? (mac?))] [control-down (and mod? (not (mac?)))]))
  (when os (send e set-other-shift-key-code os))
  (send canvas on-char e))

(test-case "the window shows the current buffer in its canvas"
  (define b (doc "hello"))
  (check-eq? (send canvas get-editor) b))

(test-case "typing through the canvas inserts text"
  (define b (doc ""))
  (press #\h) (press #\i)
  (check-equal? (send b get-text) "hi"))

(test-case "a shortcut through the canvas runs its command (Mod+Shift+D duplicates the line)"
  (define b (doc "line"))
  (define ran #f)
  (define (spy n) (set! ran n))
  (local-require "../rackmac/hook.rkt")
  (add-hook! 'before-command spy)
  (press #\D #:mod #t #:shift #t #:other-shift #\d)
  (remove-hook! 'before-command spy)
  (check-eq? ran 'duplicate-line)
  (check-equal? (send b get-text) "line\nline"))

(test-case "Mod+Z through the canvas undoes"
  (define b (doc ""))
  (press #\a) (press #\b)
  (press #\z #:mod #t)
  (check-true (< (string-length (send b get-text)) 2)))

;; ---- find and replace ------------------------------------------------------------

(define (sel b) (cons (send b get-start-position) (send b get-end-position)))

(test-case "find: next, wrap around, previous"
  (define b (doc "cat dog cat dog"))
  (set-find-options! "dog")
  (check-true (find! 'forward))
  (check-equal? (sel b) '(4 . 7))
  (find! 'forward)
  (check-equal? (sel b) '(12 . 15))
  (find! 'forward)
  (check-equal? (sel b) '(4 . 7) "wraps to the first match")
  (find! 'backward)
  (check-equal? (sel b) '(12 . 15) "backward wraps to the last"))

(test-case "find: match case"
  (define b (doc "Dog dog"))
  (set-find-options! "dog" #:match-case? #t)
  (find! 'forward)
  (check-equal? (sel b) '(4 . 7))
  (set-find-options! "dog")
  (send b set-position 0)
  (find! 'forward #:from-start? #t)
  (check-equal? (sel b) '(0 . 3) "case-insensitive by default"))

(test-case "find: not found leaves the selection alone"
  (define b (doc "abc" 1))
  (set-find-options! "zzz")
  (check-false (find! 'forward))
  (check-equal? (sel b) '(1 . 1)))

(test-case "replace all: counts, one undo step, replacement containing the query"
  (define b (doc "a-a-a"))
  (set-find-options! "a" #:replace "aa")
  (replace-all!)
  (check-equal? (send b get-text) "aa-aa-aa" "no infinite loop when the replacement contains the query")
  (send b undo)
  (check-equal? (send b get-text) "a-a-a" "one undo step"))

(test-case "replace current: only when the selection is a match"
  (define b (doc "one two one"))
  (set-find-options! "one" #:replace "1")
  (send b set-position 4 7)                  ; "two" selected: not a match, just moves to the next
  (replace-current!)
  (check-equal? (send b get-text) "one two one")
  (replace-current!)                         ; now "one" at 8 is selected: replaced
  (check-equal? (send b get-text) "one two 1"))
