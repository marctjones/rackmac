#lang racket/base
;; Spell checking in notes (#351): misspellings are found per paragraph after an edit, never
;; while typing; code, links, tags and front matter are never flagged, and code Languages are
;; not checked; suggestions, Learn and Ignore from the context menu; the setting and Edit >
;; Spelling; the underline is painted, never an edit. Every test but the last runs a fake
;; checker; the last uses macOS's NSSpellChecker and is skipped elsewhere.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/list racket/string racket/file
         "../rackmac/spell.rkt" "../rackmac/spell-mac.rkt"
         "../rackmac/editor.rkt" "../rackmac/command.rkt" "../rackmac/commands.rkt"
         "../rackmac/hook.rkt" "../rackmac/settings.rkt" "../rackmac/platform.rkt"
         "../rackmac/frame.rkt" "../rackmac/md-view.rkt" "../rackmac/context-defaults.rkt" "../rackmac/ui/context-menu.rkt"
         "../rackmac/ui/tokens.rkt" "../rackmac/theme.rkt"
         "ui-harness.rkt" "../rackmac-markdown/tests/notes-gen.rkt")

(define home (make-temporary-file "rackmac-spell~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string home)))   ; the setting persists here, not in the real file

;; ---- a fake checker: flags the words in `bad`, counts what it is asked to check ------------

(define bad (make-hash '(("wrng" . #t) ("speling" . #t) ("meetting" . #t))))
(define guesses (hash "wrng" '("wrong" "wing") "speling" '("spelling")))
(define learned '())
(define calls 0)
(define checked-chars 0)
(define fake
  (spell-checker
   (lambda (s)
     (set! calls (add1 calls))
     (set! checked-chars (+ checked-chars (string-length s)))
     (for/list ([m (in-list (regexp-match-positions* #px"[[:alpha:]']+" s))]
                #:when (hash-ref bad (substring s (car m) (cdr m)) #f))
       m))
   (lambda (w) (hash-ref guesses w '()))
   (lambda (w) (set! learned (cons w learned)) (hash-remove! bad w))))
(current-spell-checker fake)

(define (doc text [mode 'text-mode] [name "spell"])
  (define b (new-buffer! name #:mode mode))
  (send b insert text)
  (send b clear-undos)
  (send b set-modified #f)
  (spell-flush! b)
  b)

(define (flagged b) (for/list ([r (spell-misspellings b)]) (send b get-text (car r) (cdr r))))

;; ---- finding misspellings -------------------------------------------------------------------

(test-case "misspelled words in prose are found once the edit's paragraphs are checked"
  (define b (doc "This is wrng.\nAnd a speling here.\n"))
  (check-equal? (spell-misspellings b) '((8 . 12) (20 . 27)))
  (check-equal? (flagged b) '("wrng" "speling")))

(test-case "a keystroke never checks: it moves the underlines, drops the touched one, marks its paragraph"
  (define b (doc "One wrng.\nTwo wrng.\n"))
  (set! calls 0)
  (send b insert "Big " 10)                      ; start of the second paragraph
  (check-equal? calls 0 "nothing is checked during the edit")
  (check-equal? (spell-misspellings b) '((4 . 8) (18 . 22)) "the later one moved with its word")
  (check-true (spell-pending? b))
  (send b insert "x" 8)                          ; typing onto the first word
  (check-equal? (spell-misspellings b) '((19 . 23)) "the word being typed is not flagged until rechecked")
  (spell-flush! b)
  (check-false (spell-pending? b))
  (check-equal? (flagged b) '("wrng") "wrngx is not a word the fake knows; the second is still flagged"))

(test-case "Replace All and Undo (an edit sequence) leave the underlines on the right words"
  (define b (doc "a wrng b wrng c\nwrng\n"))
  (send b begin-edit-sequence)
  (send b insert "longer " 0)
  (send b delete 14 16)                          ; "b " removed inside the sequence
  (send b end-edit-sequence)
  (spell-flush! b)
  (check-equal? (flagged b) '("wrng" "wrng" "wrng"))
  (send b undo)
  (spell-flush! b)
  (check-equal? (send b get-text) "a wrng b wrng c\nwrng\n")
  (check-equal? (spell-misspellings b) '((2 . 6) (9 . 13) (16 . 20))))

(define big (generate-notes 5000 1))
(define big-note (doc (string-replace big "meeting" "meetting") 'markdown-mode "big"))

(define (middle-position b)
  (define p (quotient (send b last-paragraph) 2))
  (let loop ([p p])
    (define s (send b paragraph-start-position p))
    (if (and (> (- (send b paragraph-end-position p) s) 20)
             (char-alphabetic? (string-ref (send b get-text s (add1 s)) 0)))
        (+ 3 s)
        (loop (add1 p)))))

(test-case "after a keystroke only that paragraph is checked again"
  (check-true (> (length (spell-misspellings big-note)) 100) "the generated note has misspellings")
  (define before (length (spell-misspellings big-note)))
  (define pos (middle-position big-note))
  (define para-len (let ([p (send big-note position-paragraph pos)])
                     (- (send big-note paragraph-end-position p) (send big-note paragraph-start-position p))))
  (set! calls 0) (set! checked-chars 0)
  (send big-note insert "x" pos)
  (spell-flush! big-note)
  (check-equal? calls 1 "one check")
  (check-equal? checked-chars (add1 para-len) "of one paragraph")
  (send big-note delete pos (add1 pos))
  (spell-flush! big-note)
  (check-equal? (length (spell-misspellings big-note)) before))

(test-case "typing in a 5,000-line note with spell checking on stays under 10 ms a keystroke (3x margin)"
  (define keystrokes 100)
  (define pos (middle-position big-note))
  (set! calls 0)
  (collect-garbage)
  (define t0 (current-process-milliseconds))
  (for ([i (in-range keystrokes)]) (send big-note insert "x" (+ pos i)))
  (define typing (/ (- (current-process-milliseconds) t0) keystrokes 1.0))
  (check-equal? calls 0 "keystrokes never call the checker")
  (define t1 (current-process-milliseconds))
  (spell-flush! big-note)
  (define recheck (- (current-process-milliseconds) t1))
  (printf "spell: keystroke in a ~a KB note ~a ms CPU (mean of ~a); the idle recheck after: ~a ms, ~a call(s)\n"
          (quotient (string-length big) 1000) typing keystrokes recheck calls)
  (check-true (< typing 30) (format "~a ms per typed character" typing))
  (send big-note delete pos (+ pos keystrokes))
  (spell-flush! big-note))

;; ---- what is never checked ------------------------------------------------------------------

(define skipped-note
  (string-append
   "---\ntitle: wrng\n---\n"
   "Prose wrng with `wrng` and [wrng](https://wrng.example/wrng) and <https://wrng.org/wrng>.\n\n"
   "See [[wrng]] and #wrng and https://www.wrng.net/wrng or wrng@wrng.com today.\n\n"
   "```wrng\nwrng in code\n```\n\n"
   "    indented wrng code\n\n"
   "<div>\nwrng\n</div>\n"))

(test-case "code, link targets, URLs, wiki links, tags, HTML and front matter are never flagged"
  (define b (doc skipped-note 'markdown-mode))
  ;; the prose word and the link's text, nothing else
  (define prose (caar (regexp-match-positions #rx"Prose wrng" skipped-note)))
  (define link-text (caar (regexp-match-positions #rx"\\[wrng\\]\\(" skipped-note)))
  (check-equal? (spell-misspellings b) (list (cons (+ prose 6) (+ prose 10)) (cons (+ link-text 1) (+ link-text 5)))))

(test-case "the Markdown Source view skips the same things (its parser is not kept per edit)"
  (define b (doc skipped-note 'markdown-mode "source"))
  (define formatted (spell-misspellings b))
  (set-markdown-view! b 'source)
  (send b insert "\nAlso `wrng` wrng.\n" (send b last-position))
  (spell-check-document! b)
  (check-equal? (flagged b) '("wrng" "wrng" "wrng"))
  (check-equal? (take (spell-misspellings b) 2) formatted "the same words as the Formatted view"))

(test-case "URLs and email addresses are skipped in Plain Text too; the mask keeps every offset"
  (define b (doc "wrng https://wrng.com/x wrng@wrng.org wrng\n"))
  (check-equal? (flagged b) '("wrng" "wrng"))
  (define masked (check-text-mask "a 😀 b https://x.y c" 0 #f))
  (check-equal? (string-length masked) (string-length "a 😀 b https://x.y c"))
  (check-equal? masked "a   b             c" "emoji (UTF-16 surrogates to the system checker) and URLs blanked"))

(test-case "code Languages are not checked"
  (define b (doc "(define wrng 1) ; wrng\n" 'racket-mode "code.rkt"))
  (check-false (spell-checkable? b))
  (check-equal? (spell-misspellings b) '())
  (send b set-mode! 'text-mode)
  (spell-flush! b)
  (check-equal? (flagged b) '("wrng" "wrng") "the same text as Plain Text is")
  (send b set-mode! 'racket-mode)
  (check-equal? (spell-misspellings b) '() "and the underlines go when it becomes code again"))

;; ---- context menu: suggestions, Learn, Ignore -----------------------------------------------

(define (labels groups)
  (for/list ([g groups]) (for/list ([e g]) (if (pair? e) (car e) e))))

(test-case "right-clicking a flagged word offers its guesses first, then Learn and Ignore"
  (define b (doc "This is wrng today.\n"))
  (send b context-click-at! 9)                 ; selects the word under the pointer
  (check-equal? (misspelling-at-selection b) '(8 . 12))
  (define groups (editor-menu-groups 'text-mode b))
  (check-equal? (take (labels groups) 2) '(("wrong" "wing") (learn-spelling ignore-spelling)))
  (check-equal? (third (labels groups)) '(cut copy paste) "then the usual items")
  (define menu (build-popup-menu groups))
  (check-equal? (send (car (send menu get-items)) get-label) "wrong")
  (send b set-position 1)
  (check-equal? (spell-context-groups b) '() "nothing extra on a correct word"))

(test-case "a word with no guesses says so, disabled"
  (define b (doc "A meetting.\n"))
  (send b set-position 5)
  (define menu (build-popup-menu (spell-context-groups b)))
  (define first-item (car (send menu get-items)))
  (check-equal? (send first-item get-label) "No Guesses Found")
  (check-false (send first-item is-enabled?)))

(test-case "choosing a guess replaces the word as one undo step"
  (define b (doc "This is wrng today.\n"))
  (send b set-position 10)
  (define choose (cdr (car (car (spell-context-groups b)))))
  (choose)
  (check-equal? (send b get-text) "This is wrong today.\n")
  (check-equal? (send b get-start-position) 13 "the caret after the replacement")
  (spell-flush! b)
  (check-equal? (spell-misspellings b) '())
  (send b undo)
  (check-equal? (send b get-text) "This is wrng today.\n" "one Undo restores it")
  (check-false (send b can-do-edit-operation? 'undo) "and there was only one step"))

(test-case "Learn Spelling: the word is correct from then on, in every open document"
  (hash-set! bad "zqword" #t)
  (define a (doc "An zqword here.\n" 'text-mode "a"))
  (define c (doc "Another zqword.\n" 'markdown-mode "c"))
  (set-current-buffer! a)
  (send a set-position 4)
  (check-true (command-enabled? (find-command 'learn-spelling)))
  (run-command 'learn-spelling)
  (check-equal? learned '("zqword") "the checker was told")
  (check-equal? (spell-misspellings a) '())
  (check-equal? (spell-misspellings c) '() "gone in the other document too")
  (spell-check-document! c)
  (check-equal? (spell-misspellings c) '() "and not found again")
  (send a set-position 0)
  (check-false (command-enabled? (find-command 'learn-spelling)) "nothing to learn off a flagged word"))

(test-case "Ignore Spelling: only in this document, and it stays ignored there"
  (define a (doc "Our wrng plan, wrng again.\n" 'text-mode "a"))
  (define c (doc "Their wrng.\n" 'text-mode "c"))
  (set-current-buffer! a)
  (send a set-position 5)
  (run-command 'ignore-spelling)
  (check-equal? (spell-misspellings a) '() "every copy in this document")
  (spell-check-document! a)
  (check-equal? (spell-misspellings a) '() "still ignored after a full check")
  (check-equal? (flagged c) '("wrng") "the other document still flags it")
  (check-true (hash-ref bad "wrng" #f) "and nothing was learned"))

;; ---- the setting, the commands and Edit > Spelling ------------------------------------------

(test-case "Check Spelling While Typing is a checkable command backed by a persisted setting"
  (define c (find-command 'check-spelling-while-typing))
  (check-true (command-checked? c))
  (define b (doc "A wrng word.\n"))
  (send b set-position 3)
  (run-command 'check-spelling-while-typing)
  (check-false (setting-ref 'check-spelling-while-typing))
  (check-false (command-checked? c))
  (check-true (file-exists? (settings-file-path)) "written to settings.rktd")
  (check-regexp-match #rx"check-spelling-while-typing" (file->string (settings-file-path)))
  (check-false (misspelling-at-selection b) "off: nothing is offered")
  (check-equal? (spell-context-groups b) '())
  (run-command 'check-spelling-while-typing)
  (check-true (setting-ref 'check-spelling-while-typing)))

(test-case "Check Document Now checks everything and selects the next misspelled word"
  (define b (doc "First wrng.\nSecond speling.\n"))
  (set-current-buffer! b)
  (define said #f)
  (define (spy s) (set! said s))
  (add-hook! 'echo spy)
  (send b set-position 12)
  (run-command 'check-document-now)
  (remove-hook! 'echo spy)
  (check-equal? (list (send b get-start-position) (send b get-end-position)) '(19 26))
  (check-equal? said "2 possible spelling mistakes.")
  (set-current-buffer! (doc "(wrng)\n" 'racket-mode "c.rkt"))
  (check-false (command-enabled? (find-command 'check-document-now)) "not for code"))

(test-case "Edit > Spelling holds the checkable toggle and Check Document Now"
  (make-main-frame)                            ; hidden: show is never called
  (set-current-buffer! (doc "Text.\n"))
  (define m (menu-for-title "Spelling"))
  (check-not-false m)
  (send m on-demand)
  (define items (send m get-items))
  (check-equal? (map (lambda (i) (regexp-replace #px"(\t.*|  .*)$" (send i get-label) "")) items)
                '("Check Spelling While Typing" "Check Document Now"))
  (check-true (is-a? (car items) checkable-menu-item%))
  (check-true (send (car items) is-checked?))
  (check-true (send (cadr items) is-enabled?)))

;; ---- painting -------------------------------------------------------------------------------

;; A document drawn by the editor itself, as ui-harness's render-document does, after checking.
(define (render text #:scale [scale 1.0])
  (define b (doc text 'text-mode "paint"))
  (new editor-canvas% [parent (new frame% [label "spell"])] [editor b])   ; never shown
  (send b set-max-width 400)
  (values b (render-bitmap 440 80 (lambda (dc) (send b print-to-dc dc 1)) #:scale scale
                           #:background (token 'surface))))

(test-case "a misspelling is underlined in the error color, drawn, never styled or edited"
  (for* ([app (in-list appearances)] [scale (in-list scales)])
    (with-appearance app
      (lambda ()
        (define-values (b bm) (render "A wrng word.\n" #:scale scale))
        (write-tour-png! (format "spell-~a-~a" app scale) bm)
        (check-true (hash-has-key? (bitmap-colors bm) (token-hex 'error))
                    (format "~a ~ax: the error color is drawn" app scale))
        (check-false (send b is-modified?))
        (check-false (send b can-do-edit-operation? 'undo) "painting added no undo step")
        (check-equal? (send (send b find-snip 3 'after) get-style)
                      (send (send b find-snip 0 'after) get-style) "the word keeps the paragraph's style")
        (define-values (b2 bm2) (render "A right word.\n" #:scale scale))
        (check-false (hash-has-key? (bitmap-colors bm2) (token-hex 'error)) "no misspelling, no underline")))))

(test-case "the wavy line is a pure drawing on any dc"
  (define bm (render-bitmap 40 10 (lambda (dc) (paint-wavy-line! dc 2 30 6 (token 'error)))
                            #:background (token 'surface)))
  (check-equal? (bitmap-pixel-hex bm 2 6) (token-hex 'error))
  (check-equal? (bitmap-pixel-hex bm 20 1) (token-hex 'surface) "and stays near its line"))

;; ---- the real system checker (macOS only) ---------------------------------------------------

(test-case "macOS's NSSpellChecker: flags, guesses and learns (skipped on other systems)"
  (cond
    [(not (and (mac?) (mac-spell-available?))) (printf "spell: NSSpellChecker test skipped (not macOS)\n")]
    [else
     (check-equal? (mac-misspellings "This is wrng.") '((8 . 12)))
     (check-not-false (member "wrong" (mac-guesses "wrng")))
     (check-equal? (mac-misspellings "") '())
     ;; learn and unlearn a word no one has taught this Mac (never unlearn a word the user taught)
     (define w "Zqxrackmacspelltest")
     (unless (mac-has-learned-word? w)
       (dynamic-wind
        (lambda () (mac-learn-word! w))
        (lambda ()
          (check-true (mac-has-learned-word? w))
          (check-equal? (mac-misspellings w) '()))
        (lambda () (mac-unlearn-word! w)))
       (check-false (mac-has-learned-word? w)))
     ;; through the editor, with the real checker as the parameter
     (parameterize ([current-spell-checker
                     (spell-checker mac-misspellings mac-guesses mac-learn-word!)])
       (define b (doc "Notes on the meetting with `wrng` code.\n" 'markdown-mode "real"))
       (check-equal? (flagged b) '("meetting")))]))
