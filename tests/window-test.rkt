#lang racket/base
;; The real main window, built but never shown: keys delivered to its editor canvas reach
;; the buffer's key dispatch, and find/replace behave. (The OS -> window step still needs a
;; person or CI with a display; see issue "Verify real keystrokes".)
(require rackunit racket/class racket/gui/base racket/string racket/list
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

;; ---- find row: count, Advanced, whole word, regex, in-selection, Esc (docs/UI-DESIGN.md 7.4) --

(define (fb) (main-find-bar))
(define (fire ctl type) (send ctl command (new control-event% [event-type type])))

(test-case "find bar: typing updates the count live, colored, never 'K of N' until a step"
  (doc "cat dog cat")
  (set-find-options! "")                     ; clears query and every option from earlier tests
  (send (send (fb) get-find-field) set-value "cat")
  (fire (send (fb) get-find-field) 'text-field)
  (check-equal? (send (fb) count-text) "2 matches"))

(test-case "find bar: No matches, and an empty query shows nothing"
  (doc "abc")
  (set-find-options! "zzz")
  (check-equal? (send (fb) count-text) "No matches")
  (set-find-options! "")
  (check-equal? (send (fb) count-text) ""))

(test-case "find bar: stepping shows 'K of N', wrapping back to 1"
  (doc (string-join (make-list 12 "x") " "))  ; 12 single-character matches
  (set-find-options! "x")
  (for ([_ 3]) (find! 'forward))
  (check-equal? (send (fb) count-text) "3 of 12")
  (for ([_ 9]) (find! 'forward))              ; now at the 12th (last) match
  (check-equal? (send (fb) count-text) "12 of 12")
  (find! 'forward)
  (check-equal? (send (fb) count-text) "Wrapped · 1 of 12"))

(test-case "find bar: Whole word narrows the results"
  (doc "cat catalog cat")
  (set-find-options! "cat")
  (check-equal? (send (fb) count-text) "3 matches")
  (send (send (fb) get-word-box) set-value #t)
  (fire (send (fb) get-word-box) 'check-box)
  (check-equal? (send (fb) count-text) "2 matches"))

(test-case "find bar: Advanced discloses and hides the regex/in-selection row"
  (check-false (send (fb) advanced-shown?))
  (fire (send (fb) get-advanced-button) 'button)
  (check-true (send (fb) advanced-shown?))
  (fire (send (fb) get-advanced-button) 'button)
  (check-false (send (fb) advanced-shown?)))

(test-case "find bar: an invalid regular expression is reported, not thrown"
  (doc "abc")
  (set-find-options! "(unclosed" #:regex? #t)
  (check-equal? (send (fb) count-text) "Invalid pattern"))

(test-case "find bar: regex replace-all with a \\1 \\2 group reference, one undo step"
  (define b (doc "John Smith, Jane Doe"))
  (set-find-options! "(\\w+) (\\w+)" #:replace "\\2 \\1" #:regex? #t)
  (replace-all!)
  (check-equal? (send b get-text) "Smith John, Doe Jane")
  (send b undo)
  (check-equal? (send b get-text) "John Smith, Jane Doe"))

(test-case "find bar: In selection restricts matches to the selection at open time"
  (define b (doc "cat cat cat cat"))
  (send b set-position 4 7)                  ; the second "cat" only
  (show-find-bar!)
  (set-find-options! "cat" #:in-selection? #t)
  (check-equal? (send (fb) count-text) "1 match")
  (hide-find-bar!))

(test-case "find bar: Esc hides the bar and refocuses the editor"
  (doc "hello")
  (show-find-bar!)
  (define refocused #f)
  (define (spy) (set! refocused #t))
  (local-require "../rackmac/hook.rkt")
  (add-hook! 'focus-editor spy)
  (define field (send (fb) get-find-field))
  (send field on-subwindow-char field (new key-event% [key-code 'escape]))
  (remove-hook! 'focus-editor spy)
  (check-true refocused)
  (check-false (memq (fb) (send f get-children))))

(test-case "find bar: In selection survives Replace All shrinking the buffer past the old bounds"
  (define b (doc "aaa"))
  (send b set-position 0 3)                  ; the whole (and only) buffer is selected
  (show-find-bar!)
  (set-find-options! "a" #:replace "" #:in-selection? #t)
  (replace-all!)                             ; used to crash: substring past the now-empty buffer
  (check-equal? (send b get-text) "")
  (check-equal? (send (fb) count-text) "No matches")
  (hide-find-bar!))

;; ---- tabs and layout (UI foundation) ------------------------------------------------

(define tabs (main-tabs))
(define (fresh-tabs names)
  (define bs (for/list ([n names]) (new-buffer! n)))
  (for ([b (all-buffers)] #:unless (or (memq b bs) (messages-buffer? b))) (kill-buffer! b))
  (set-current-buffer! (car bs))
  bs)

(test-case "the tab strip has close boxes, reordering and a + button, the same on both OSes"
  (for ([st '(can-close can-reorder new-button flat-portable)])
    (check-not-false (memq st tab-strip-style) (format "~a" st))))

(test-case "a tab's close box closes that document"
  (define bs (fresh-tabs '("one" "two" "three")))
  (send tabs on-close-request 1)
  (check-equal? (map (lambda (b) (send b get-name)) (visible-buffers)) '("one" "three")))

(test-case "the + button makes a new document"
  (define bs (fresh-tabs '("only")))
  (send tabs on-new-request)
  (check-equal? (length (visible-buffers)) 2)
  (check-equal? (send (current-buffer) get-name) "untitled"))

(test-case "dragging tabs reorders the documents (and Go to Tab N follows)"
  (define bs (fresh-tabs '("a" "b" "c")))
  (send tabs on-reorder '(2 0 1))             ; c moved to the front
  (check-equal? (map (lambda (b) (send b get-name)) (visible-buffers)) '("c" "a" "b"))
  (check-equal? (send tabs get-item-label 0) "c" "the strip shows the new order")
  (run-command 'go-to-tab-1)
  (check-equal? (send (current-buffer) get-name) "c"))

(test-case "closing a modified document from its tab asks first"
  (define bs (fresh-tabs '("keep" "other")))
  (send (car bs) insert "unsaved")
  (parameterize ([confirm-save-changes (lambda (b) 'cancel)])
    (send tabs on-close-request 0))
  (check-equal? (length (visible-buffers)) 2 "Cancel keeps it open")
  (parameterize ([confirm-save-changes (lambda (b) 'discard)])
    (send tabs on-close-request 0))
  (check-equal? (map (lambda (b) (send b get-name)) (visible-buffers)) '("other") "Don't Save closes it"))

(test-case "the editor has comfortable margins"
  (check-equal? (send canvas horizontal-inset) 16)
  (check-equal? (send canvas vertical-inset) 12))

(test-case "prose wraps at a readable measure, code does not wrap"
  (define b (doc "some prose"))
  (send b set-mode! 'text-mode)
  (define w (send b measure-width))
  (check-true (and (real? w) (> w 200)) "80 columns of the editor font")
  (send b set-max-width 100000)             ; as if the window were very wide
  (send b on-display-size)
  (check-true (<= (send b get-max-width) w) "clamped to the measure")
  (send b set-mode! 'racket-mode)
  (check-false (send b auto-wrap))
  (check-false (send b measure-width) "no measure for code"))
