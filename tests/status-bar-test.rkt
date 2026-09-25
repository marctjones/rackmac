#lang racket/base
;; The clickable status bar: pure layout and drawing (segments right-aligned, no overlap,
;; message truncation, narrow widths, colors at 1x/2x light/dark), then the real (hidden)
;; window: segment text, hover hints, click hit-testing, the Line Endings command, the word-
;; count cache, and an extension's own segment.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/list racket/draw racket/file racket/string
         "../rackmac/ui/status-bar.rkt" "../rackmac/ui/tokens.rkt" "../rackmac/ui/layout.rkt"
         "../rackmac/theme.rkt" "../rackmac/status.rkt" "../rackmac/status-defaults.rkt"
         "../rackmac/owner.rkt" "../rackmac/hook.rkt" "../rackmac/command.rkt"
         "../rackmac/commands.rkt" "../rackmac/editor.rkt" "../rackmac/frame.rkt")

;; ---- pure layout ------------------------------------------------------------------------

(define (test-dc [w 20] [h 20]) (new bitmap-dc% [bitmap (make-bitmap w h)]))
(define (measured [w 600]) (define dc (test-dc)) (send dc set-font (font-for-width w)) dc)
(define (text-w dc s) (define-values (w h d a) (send dc get-text-extent s)) w)

(define (no-overlap? rects)
  (define present (sort (filter values rects) < #:key car))
  (for/and ([a present] [b (cdr present)]) (<= (+ (first a) (third a)) (first b))))

(test-case "right-hand segments are placed right to left, in their own order, no overlap"
  (define dc (measured))
  (define segs (list (seg-view 'message "" #f #f 0)
                      (seg-view 'a "Ln 12, Col 8" 'goto-line #f 100)
                      (seg-view 'b "UTF-8" 'show-encoding #f 20)
                      (seg-view 'c "100%" 'zoom-reset #f 50)))
  (define rects (layout-segments segs 600 dc))
  (check-equal? (length rects) 4)
  (check-not-false (andmap values (cdr rects)) "all three fit at 600px")
  (check-true (no-overlap? rects))
  (define-values (msg ra rb rc) (apply values rects))
  (check-true (< (+ (first ra) (third ra)) (first rb)) "a is left of b")
  (check-true (< (+ (first rb) (third rb)) (first rc)) "b is left of c")
  (check-= (+ (first rc) (third rc)) 600 0.01 "the last segment ends flush with the right edge")
  (check-true (<= (+ (first msg) (third msg)) (first ra)) "the message stops before the segments"))

(test-case "a narrow bar drops the lowest-priority segments first"
  (define dc (measured))
  (define a (seg-view 'a "AAAAAAAAAA" 'x #f 100))
  (define b (seg-view 'b "BBBBBBBBBB" 'y #f 20))
  (define segs (list (seg-view 'message "" #f #f 0) a b))
  (define wa (+ 16 (text-w dc "AAAAAAAAAA")))
  (define wb (+ 16 (text-w dc "BBBBBBBBBB")))
  (define sep (text-w dc " · "))
  (define wide (+ wa wb sep 24 8 50))
  (define narrow (+ wa 24 8 2))
  (define tiny 10)
  (check-not-false (andmap values (cdr (layout-segments segs wide dc))) "both fit when there's room")
  (define at-narrow (layout-segments segs narrow dc))
  (check-not-false (second at-narrow) "a (priority 100) survives")
  (check-false (third at-narrow) "b (priority 20, lower) drops first")
  (check-not-false (first at-narrow) "the message always gets a rect")
  (check-false (second (layout-segments segs tiny dc)) "even a survives only down to some width"))

(test-case "the message segment truncates with an ellipsis when it doesn't fit"
  (define dc (measured))
  (define long "This is a very long status message that will not fit in a narrow window")
  (check-equal? (truncate-to-width dc long 10000) long "no truncation when there's room")
  (define shown (truncate-to-width dc long 60))
  (check-true (< (string-length shown) (string-length long)))
  (check-true (string-suffix? shown "…"))
  (check-true (<= (text-w dc shown) 60))
  (check-equal? (truncate-to-width dc long 0) ""))

;; ---- pure rendering: colors at 1x/2x, light/dark -----------------------------------------

(define (pixel-hex dc x y)
  (define c (make-object color% 0 0 0))
  (send dc get-pixel x y c)
  (color->hex c))

(test-case "renders the status-bg background and the top stroke line, at 1x/2x, light/dark"
  (for* ([scale '(1.0 2.0)] [appearance '(light dark)])
    (set-theme! appearance)
    (define w 400) (define h status-bar-height)
    (define dc (new bitmap-dc% [bitmap (make-bitmap w h #t #:backing-scale scale)]))
    (render-status dc w h (list (seg-view 'message "Saved x.txt" #f #f 0)) #f)
    (check-equal? (pixel-hex dc 350 (sub1 h)) (token-hex 'status-bg appearance)
                  (format "~a ~ax background" appearance scale))
    (check-equal? (pixel-hex dc 10 0) (token-hex 'stroke appearance)
                  (format "~a ~ax stroke line" appearance scale)))
  (set-theme! 'light))

(test-case "a hovered clickable segment gets an accent underline; others don't, at 1x/2x"
  (for* ([scale '(1.0 2.0)] [appearance '(light dark)])
    (set-theme! appearance)
    (define w 400) (define h status-bar-height)
    (define dc (new bitmap-dc% [bitmap (make-bitmap w h #t #:backing-scale scale)]))
    (define model (list (seg-view 'message "" #f #f 0) (seg-view 'lang "Markdown" 'set-major-mode #f 10)))
    (send dc set-font (font-for-width w))
    (define r (second (layout-segments model w dc h)))
    (define-values (tw th td ta) (send dc get-text-extent "Markdown"))
    (define tx (+ (first r) (/ (- (third r) tw) 2)))
    (define ty (+ (second r) (/ (- (fourth r) th) 2)))
    (define ux (inexact->exact (round (+ tx (/ tw 2)))))
    ;; the underline sits just under the text; scan a small contiguous window instead of one
    ;; exact row, since the renderer's own sub-pixel rounding needn't match ours.
    (define ys (range (inexact->exact (floor (+ ty th -1))) (inexact->exact (ceiling (+ ty th 3)))))
    (define (accent-in-column? hover)
      (render-status dc w h model hover)
      (for/or ([y ys]) (equal? (pixel-hex dc ux y) (token-hex 'accent appearance))))
    (check-true (accent-in-column? 'lang) (format "~a ~ax hover underline" appearance scale))
    (check-false (accent-in-column? #f) (format "~a ~ax no underline unhovered" appearance scale)))
  (set-theme! 'light))

;; ---- the real (hidden) window -------------------------------------------------------------

(define f (make-main-frame))
(send f reflow-container)      ; geometry only; the frame is never shown
(define sb (main-status-bar))

(define (model) (send sb current-model))
(define (seg-text name) (define s (findf (lambda (s) (eq? (seg-view-name s) name)) (model))) (and s (seg-view-text s)))
(define (doc text [mode 'text-mode])
  (define b (new-buffer! "sb"))
  (set-current-buffer! b)
  (send b set-mode! mode)
  (send b insert text)
  (send b set-position 0)
  b)

(test-case "Ln/Col follows the cursor"
  (define b (doc "abc\ndefgh"))
  (send b set-position 6)
  (check-equal? (seg-text 'line-col) "Ln 2, Col 3"))

(test-case "word count is shown for prose Languages, not for code, and selection wins"
  (define b (doc "one two three four"))
  (check-equal? (seg-text 'words) "4 words")
  (send b set-mode! 'racket-mode)
  (check-false (seg-text 'words) "no word count for Racket")
  (send b set-mode! 'markdown-mode)
  (check-equal? (seg-text 'words) "4 words" "Markdown's chain includes text-mode")
  (send b set-position 0 3)
  (check-equal? (seg-text 'words) "3 selected" "a selection overrides the word count"))

(test-case "the encoding segment for a file that isn't valid UTF-8"
  (define p (make-temporary-file "sb-latin1~a.txt"))
  (call-with-output-file p #:exists 'truncate (lambda (o) (write-bytes (bytes 99 97 102 233) o)))  ; "caf\xE9"
  (set-current-buffer! (open-file! p))
  (check-equal? (seg-text 'encoding) "Latin-1")
  (delete-file p))

(test-case "the line-ending segment: LF vs CRLF"
  (define lf (make-temporary-file "sb-lf~a.txt"))
  (define crlf (make-temporary-file "sb-crlf~a.txt"))
  (display-to-file #"a\nb" lf #:exists 'truncate)
  (call-with-output-file crlf #:exists 'truncate (lambda (o) (write-bytes #"a\r\nb" o)))
  (set-current-buffer! (open-file! lf))
  (check-equal? (seg-text 'eol) "LF")
  (set-current-buffer! (open-file! crlf))
  (check-equal? (seg-text 'eol) "CRLF")
  (delete-file lf) (delete-file crlf))

(test-case "zoom is a percentage of the default size, and follows Zoom In"
  (doc "")
  (check-equal? (seg-text 'zoom) "100%")
  (run-command 'zoom-in)
  (check-equal? (seg-text 'zoom)
                (format "~a%" (inexact->exact (round (* 100 (/ font-size (default-font-size)))))))
  (run-command 'zoom-reset)
  (check-equal? (seg-text 'zoom) "100%"))

;; ---- clicking: real geometry, real commands ------------------------------------------------

(define (dialog-window) (for/first ([w (get-top-level-windows)] #:when (is-a? w dialog%)) w))

;; Drives whatever modal dialog `thunk` pops (get-text-from-user or the `pick` picker) with
;; `script`, the same way tests/picker-test.rkt drives `pick` directly; a watchdog closes it
;; so a regression fails this test instead of hanging the suite.
(define (with-dialog script thunk)
  (define done? #f)
  (define step
    (new timer% [interval 15]
         [notify-callback (lambda ()
                            (define d (dialog-window))
                            (when (and d (not done?) (send d is-shown?))
                              (set! done? #t) (send step stop) (script d)))]))
  (define watchdog (new timer% [notify-callback (lambda () (define d (dialog-window)) (when d (send d show #f)))]))
  (send watchdog start 5000 #t)
  (begin0 (thunk) (send step stop) (send watchdog stop)))

(define (escape! d) (send d on-subwindow-char d (new key-event% [key-code 'escape])))

(define (segment-rect name)
  (define w (send sb get-width)) (define h (send sb get-height))
  (define m (model))
  (define dc (send sb get-dc))
  (send dc set-font (font-for-width w))
  (define i (index-of (map seg-view-name m) name))
  (and i (list-ref (layout-segments m w dc h) i)))

(define (segment-point name)
  (define r (segment-rect name))
  (and r (list (inexact->exact (round (+ (first r) (/ (third r) 2))))
               (inexact->exact (round (+ (second r) (/ (fourth r) 2)))))))

(define (mouse-at type x y) (new mouse-event% [event-type type] [x x] [y y]))

(define (click-segment! name)
  (define pt (segment-point name))
  (send sb on-event (mouse-at 'left-down (car pt) (cadr pt))))

(define (before-command-of thunk)
  (define ran #f)
  (define (spy n) (set! ran n))
  (add-hook! 'before-command spy)
  (thunk)
  (remove-hook! 'before-command spy)
  ran)

(test-case "clicking Ln/Col opens Go to Line"
  (doc "hello")
  (check-eq? (with-dialog escape! (lambda () (before-command-of (lambda () (click-segment! 'line-col)))))
             'goto-line))

(test-case "clicking Language opens the Language picker"
  (doc "hello")
  (check-eq? (with-dialog escape! (lambda () (before-command-of (lambda () (click-segment! 'language)))))
             'set-major-mode))

(test-case "clicking the line-ending segment opens Line Endings"
  (doc "hello")
  (check-eq? (with-dialog escape! (lambda () (before-command-of (lambda () (click-segment! 'eol)))))
             'set-line-endings))

(test-case "clicking the encoding segment shows the encoding"
  (define b (doc "hello"))
  (check-eq? (before-command-of (lambda () (click-segment! 'encoding))) 'show-encoding))

(test-case "clicking the zoom segment resets the zoom"
  (doc "")
  (run-command 'zoom-in)
  (check-eq? (before-command-of (lambda () (click-segment! 'zoom))) 'zoom-reset)
  (check-equal? (seg-text 'zoom) "100%"))

(test-case "hovering a clickable segment shows a hint in the message area; leaving clears it"
  (doc "hello")
  (define echoed #f)
  (define (spy s) (set! echoed s))
  (add-hook! 'echo spy)
  (define pt (segment-point 'language))
  (send sb on-event (mouse-at 'enter (car pt) (cadr pt)))
  (check-equal? echoed "Click to change the Language")
  (send sb on-event (mouse-at 'leave (car pt) (cadr pt)))
  (check-equal? echoed "")
  (remove-hook! 'echo spy))

;; ---- Line Endings: an undoable, saved conversion -------------------------------------------

(define (pick-next-then-enter! d)
  (define tf (first (send d get-children)))
  (send d on-subwindow-char tf (new key-event% [key-code 'down]))
  (send d on-subwindow-char tf (new key-event% [key-code #\return])))

(test-case "Line Endings converts LF to CRLF, and the file is rewritten on Save"
  (define b (doc "a\nb"))
  (send b local-set! 'eol "\n")
  (define p (make-temporary-file "sb-conv~a.txt"))
  (send b save-to! p)
  (check-equal? (file->bytes p) #"a\nb")
  (with-dialog pick-next-then-enter! (lambda () (run-command 'set-line-endings)))
  (check-equal? (seg-text 'eol) "CRLF")
  (check-true (send b is-modified?) "changing it marks the document modified, so Save writes it")
  (send b save-to! p)
  (check-equal? (file->bytes p) #"a\r\nb")
  (delete-file p))

;; ---- word count: cached, invalidated on edits ----------------------------------------------

(test-case "the word count is cached per buffer and only rescans after an edit"
  (define b (new-buffer! "wc-cache"))
  (send b insert "one two three")
  (reset-word-count-scans!)
  (check-equal? (word-count b) 3)
  (word-count b) (word-count b)
  (check-equal? (word-count-scans) 1 "later calls hit the cache")
  (send b insert " four")
  (check-equal? (word-count b) 4)
  (check-equal? (word-count-scans) 2 "an edit invalidates the cache"))

;; ---- extensions: their own segment appears, and leaves on unload ---------------------------

(test-case "an extension's status segment appears and leaves when it unloads"
  (doc "hello")
  (define ext (make-extension "sb-ext"))
  (parameterize ([current-extension ext])
    (add-status-segment! 'sb-ext-seg (lambda () "Hi there") #:command 'zoom-reset))
  (check-equal? (seg-text 'sb-ext-seg) "Hi there")
  (unload-extension! ext)
  (check-false (seg-text 'sb-ext-seg)))

;; ---- keyboard: Left/Right move, Enter activates --------------------------------------------

(test-case "Tab-then-arrow keyboard access: Right moves to the first segment, Enter activates it"
  (doc "hello")
  (send sb on-char (new key-event% [key-code 'right]))       ; the first clickable segment: Ln/Col
  (check-eq? (before-command-of
              (lambda () (with-dialog escape! (lambda () (send sb on-char (new key-event% [key-code #\return]))))))
             'goto-line))
