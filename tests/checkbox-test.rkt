#lang racket/base
;; Task checkboxes (#293, docs/UI-DESIGN.md §2.2 and §5.3): in the Formatted view `[ ]`, `[x]` and
;; `[-]` are checkbox snips whose text is the marker and whose count is 3; the file, positions,
;; copy and undo are unchanged by them; the caret never lands inside one and no key deletes part
;; of one; a click toggles like Mark Done, one undo step; the Source view has none. Keys and
;; clicks go through the editor itself on an unshown canvas.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file racket/list racket/string
         "ui-harness.rkt"
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/frame.rkt"
         "../rackmac/editor.rkt" "../rackmac/theme.rkt" "../rackmac/md-view.rkt" "../rackmac/md-format.rkt"
         "../rackmac/md-style.rkt" "../rackmac/md-checkbox.rkt"
         (only-in "../rackmac/markdown-lib.rkt" markup-tokens token-start token-end)
         "../rackmac/ui/tokens.rkt")

(define f (make-main-frame))                ; hidden: show is never called

(define source
  (string-append "# Tasks\n\n"
                 "- [ ] Call the vendor about the renewal\n"
                 "- [x] Send the draft\n"
                 "- [-] Book the old room\n"
                 "- [X] Upper-case done\n"
                 "\nNot a task: [ ] in a sentence.\n"))
(define (marker-positions text)
  (for/list ([m (in-list (regexp-match-positions* #rx"(?m:^- )\\[.\\]" text))]) (+ 2 (car m))))

;; A note in the Formatted view on an unshown canvas (key and mouse handling need an editor admin).
(define (note [text source] #:view [view 'formatted])
  (define b (new-buffer! "tasks.md" #:mode 'markdown-mode))
  (send b insert text)
  (set-markdown-view! b view)
  (send b clear-undos)
  (send b set-modified #f)
  (send b set-position 0)
  (set-current-buffer! b)                     ; first: the main window's canvas takes the document
  (define fr (new frame% [label "checkbox"] [width 700] [height 500]))   ; never shown
  (new editor-canvas% [parent fr] [editor b])
  (send fr reflow-container)                  ; a real size, so clicks map to stable positions
  b)

(define (checkboxes b)
  (let loop ([s (send b find-first-snip)] [p 0] [acc '()])
    (if s
        (loop (send s next) (+ p (send s get-count))
              (if (checkbox-snip? s) (cons (cons p (send s get-source)) acc) acc))
        (reverse acc))))
(define (inside-snip? b pos)
  (for/or ([c (in-list (checkboxes b))]) (< (car c) pos (+ (car c) 3))))

(define (key b code #:shift [shift #f] #:alt [alt #f])
  (send b on-char (new key-event% [key-code code] [shift-down shift] [alt-down alt])))

;; ---- rendering and text -------------------------------------------------------------------------

(test-case "task markers become checkbox snips; the text and positions are the source"
  (define b (note))
  (check-equal? (checkboxes b)
                (for/list ([p (in-list (marker-positions source))]) (cons p (substring source p (+ p 3)))))
  (check-equal? (length (checkboxes b)) 4 "the [ ] in a sentence stays text")
  (for ([c (in-list (checkboxes b))])
    (check-equal? (send (send b find-snip (car c) 'after) get-count) 3 "count = source length"))
  (check-equal? (send b last-position) (string-length source))
  (check-equal? (send b get-text) source)
  (check-equal? (send b document-text) source)
  (check-false (send b is-modified?) "rendering is not an edit")
  (check-false (send b can-do-edit-operation? 'undo) "and never enters undo"))

(test-case "positions equal source offsets: every parser token lines up with the text"
  (define b (note))
  (define doc (markdown-parser-document b))
  (for ([t (in-list (markup-tokens doc))])
    (check-equal? (send b get-text (token-start t) (token-end t))
                  (substring source (token-start t) (token-end t)) (format "~a" t))))

(test-case "round trip: a note with checkboxes saves byte for byte"
  (define b (note))
  (define p (make-temporary-file "rackmac-checkbox-~a.md"))
  (send b save-to! p)
  (check-equal? (file->bytes p) (string->bytes/utf-8 source))
  (delete-file p))

;; ---- the atomic caret ---------------------------------------------------------------------------

(define line-start (index-where (string->list source) (lambda (c) (eqv? c #\-))))   ; "- [ ] Call..."
(define box-pos (+ line-start 2))

(test-case "Right and Left step over the checkbox as one character"
  (define b (note))
  (send b set-position line-start)
  (define rights (for/list ([i 6]) (key b 'right) (send b get-start-position)))
  (check-equal? rights (list (+ line-start 1) box-pos (+ box-pos 3) (+ box-pos 4) (+ box-pos 5) (+ box-pos 6)))
  (define lefts (for/list ([i 5]) (key b 'left) (send b get-start-position)))
  (check-equal? lefts (list (+ box-pos 5) (+ box-pos 4) (+ box-pos 3) box-pos (+ line-start 1))))

(test-case "walking the task lines key by key: the caret and selection never end inside a snip"
  (define b (note))
  (send b set-position 0)
  (for ([i (in-range (string-length source))])
    (key b 'right)
    (check-false (inside-snip? b (send b get-start-position)) (format "Right #~a" i)))
  (for ([i (in-range (string-length source))])
    (key b 'left #:shift #t)
    (check-false (inside-snip? b (send b get-start-position)) (format "Shift-Left #~a" i))
    (check-false (inside-snip? b (send b get-end-position))))
  (for ([code '(right left)])
    (send b set-position (if (eq? code 'right) 0 (send b last-position)))
    (for ([i (in-range 60)])
      (key b code #:alt #t)                                      ; Option-arrow: word by word
      (check-false (inside-snip? b (send b get-start-position)) (format "Option-~a #~a" code i))))
  (for ([p (in-range (send b last-position))])                   ; any position a command sets
    (send b set-position p)
    (check-false (inside-snip? b (send b get-start-position)) (format "set-position ~a" p))
    (send b set-position line-start p)
    (check-false (inside-snip? b (send b get-end-position)) (format "selection to ~a" p))))

(test-case "no key deletes part of a marker: Backspace and Delete at every caret on the line"
  (define line-end (+ line-start (string-length "- [ ] Call the vendor about the renewal")))
  (for* ([p (in-range line-start (add1 line-end))] [code (list #\backspace #\rubout)])
    (define b (note))
    (send b set-position p)
    (define at (send b get-start-position))
    (key b code)
    (define text (send b get-text))
    (define line (car (regexp-match #rx"[^\n]*\n[^\n]*\n[^\n]*" text)))
    (check-true (or (regexp-match? #rx"\\[ \\]" line) (not (regexp-match? #rx"[][]" line)))
                (format "~s at ~a leaves ~s" code at line))
    (check-equal? (length (checkboxes b)) (length (regexp-match* #px"(?m:^- \\[.\\][ \t]+\\S)" text))
                  "a checkbox exactly where a task marker is")))

(test-case "Backspace after a checkbox and Delete before it remove the whole marker"
  (for ([code (list #\backspace #\rubout)] [at (list (+ box-pos 3) box-pos)])
    (define b (note))
    (send b set-position at)
    (key b code)
    (check-equal? (send b get-text) (string-replace source "- [ ] Call" "-  Call") (format "~s" code))
    (check-true (send b can-do-edit-operation? 'undo))
    (send b undo)
    (check-equal? (send b get-text) source "undo puts the marker back")
    (check-equal? (length (checkboxes b)) 4 "as a checkbox again")))

;; ---- toggling ----------------------------------------------------------------------------------

(define (snip-center b pos)
  (define l (box 0.0)) (define t (box 0.0)) (define r (box 0.0)) (define bt (box 0.0))
  (define snip (send b find-snip pos 'after))
  (send b get-snip-location snip l t #f)
  (send b get-snip-location snip r bt #t)
  (define-values (x y) (send b editor-location-to-dc-location (/ (+ (unbox l) (unbox r)) 2) (/ (+ (unbox t) (unbox bt)) 2)))
  (values x y))

(define (click! b pos)
  (define-values (x y) (snip-center b pos))
  (send b on-event (new mouse-event% [event-type 'left-down] [x (inexact->exact (round x))] [y (inexact->exact (round y))]))
  (send b on-event (new mouse-event% [event-type 'left-up] [x (inexact->exact (round x))] [y (inexact->exact (round y))])))

(test-case "a click on the box toggles it, as one undo step; the caret stays"
  (define b (note))
  (send b set-position 3)
  (click! b box-pos)
  (check-equal? (send b get-text box-pos (+ box-pos 3)) "[x]")
  (check-equal? (cdr (assv box-pos (checkboxes b))) "[x]" "a done checkbox now")
  (check-equal? (send b get-start-position) 3)
  (check-true (send b is-modified?) "a toggle is an edit")
  (click! b box-pos)
  (check-equal? (send b document-text) source "clicked twice: open again")
  (send b undo)
  (check-equal? (send b get-text box-pos (+ box-pos 3)) "[x]" "one undo step per toggle")
  (send b undo)
  (check-equal? (send b get-text) source)
  (check-false (send b can-do-edit-operation? 'undo))
  (send b redo) (send b redo)
  (check-equal? (send b get-text) source)
  (check-equal? (length (checkboxes b)) 4 "undo and redo keep the snips in step"))

(test-case "a click on the text beside the box places the caret and toggles nothing"
  (define b (note))
  (define-values (x y) (snip-center b (+ box-pos 8)))
  (send b on-event (new mouse-event% [event-type 'left-down] [x (inexact->exact (round x))] [y (inexact->exact (round y))]))
  (check-equal? (send b get-text) source))

(test-case "Mark Done toggles the same way in both views; undo works across toggles"
  (for ([view '(formatted source)])
    (define b (note #:view view))
    (send b set-position (+ box-pos 10))
    (run-command 'mark-done)
    (check-equal? (send b get-text box-pos (+ box-pos 3)) "[x]" (format "~a" view))
    (check-equal? (send b get-start-position) (+ box-pos 10))
    (run-command 'mark-done)
    (check-equal? (send b get-text) source)
    (send b undo)
    (check-equal? (send b get-text box-pos (+ box-pos 3)) "[x]")
    (send b undo)
    (check-equal? (send b get-text) source)
    (check-equal? (length (checkboxes b)) (if (eq? view 'formatted) 4 0))))

(test-case "the done and cancelled items open again with Mark Done"
  (define b (note))
  (for ([p (in-list (cdr (marker-positions source)))])
    (send b set-position (+ p 5))
    (run-command 'mark-done)
    (check-equal? (send b get-text p (+ p 3)) "[ ]")))

(test-case "copy across a checkbox yields the Markdown"
  (define saved (send the-clipboard get-clipboard-string 0))
  (define b (note))
  (click! b box-pos)
  (send b set-position line-start (+ line-start (string-length "- [x] Call the vendor")))
  (run-command 'copy)
  (check-equal? (send the-clipboard get-clipboard-string 0) "- [x] Call the vendor")
  (send the-clipboard set-clipboard-string saved 0))

;; ---- keeping in step ---------------------------------------------------------------------------

(test-case "typing a task makes a checkbox; breaking the item takes it away"
  (define b (note "Notes\n"))
  (send b set-position (send b last-position))
  (for ([c (in-string "- [ ] Ring the court")]) (key b c))
  (check-equal? (checkboxes b) (list (cons 8 "[ ]")))
  (check-equal? (send b get-text) "Notes\n- [ ] Ring the court")
  (send b set-position 6 8)
  (key b #\backspace)                                     ; "[ ] Ring..." is no longer a list item
  (check-equal? (checkboxes b) '())
  (check-equal? (send b get-text) "Notes\n[ ] Ring the court")
  (send b undo)
  (check-equal? (checkboxes b) (list (cons 8 "[ ]"))))

(test-case "the Source view and other Languages have no snips; Formatted brings them back"
  (define b (note))
  (set-markdown-view! b 'source)
  (check-equal? (checkboxes b) '())
  (check-equal? (send b get-text) source)
  (check-false (send b is-modified?))
  (check-false (send b can-do-edit-operation? 'undo))
  (set-markdown-view! b 'formatted)
  (check-equal? (length (checkboxes b)) 4)
  (send b set-mode! 'text-mode)
  (check-equal? (checkboxes b) '())
  (send b set-mode! 'markdown-mode)
  (check-equal? (length (checkboxes b)) 4))

;; ---- how they look ------------------------------------------------------------------------------

(define checklist
  (string-append "# Closing checklist\n\n"
                 "- [x] Send the engagement letter\n"
                 "- [ ] Call the vendor about the **renewal**\n"
                 "- [-] Book the old conference room\n"
                 "- [ ] File the motion by Friday\n"))

(define (color-count bm hex) (hash-ref (bitmap-colors bm) hex 0))

(test-case "the boxes render: a done box is filled with the accent, open ones outlined"
  (for ([app '(light dark)])
    (with-appearance app
      (lambda ()
        (define bm (render-document checklist 'markdown-mode #:width 520 #:height 170))
        (write-tour-png! (format "checklist-~a" app) bm)
        (check-true (> (color-count bm (token-hex 'accent)) 60) (format "~a: a box filled with the accent" app))
        (check-true (> (color-count bm (token-hex 'text-2)) 0) (format "~a: outlines and done text in text-2" app))))))
