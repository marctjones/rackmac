#lang racket/base
;; Spelling checked as you type in notes (#351): misspelled words get a wavy underline in the
;; `error` color, drawn over the text by the editor (buffer.rkt's 'paint-document hook), so no
;; style, character or undo step is ever added. Prose Languages only (Plain Text, Markdown and
;; other children of text-mode); code Languages are never checked. In a note, code spans and
;; blocks, link targets, bare URLs, [[wiki links]], #tags, raw HTML and front matter are skipped
;; (the parser's style runs say where they are); in any document, URLs and email addresses are.
;;
;; A keystroke never checks anything: it shifts the stored misspellings, drops the ones it
;; touched and marks its paragraph. After typing pauses, an idle timer checks the marked
;; paragraphs in slices of a few milliseconds (spell-mac.rkt's timings: the system checker
;; takes about 1 ms a paragraph and 1-2 s for a 5,000-line note), then repaints those lines.
;;
;; The checker is a parameter (`current-spell-checker`), so tests run with a fake one and no OS
;; service. It finds nothing until the app turns on the system checker (`enable-spell-checking!`,
;; from app.rkt; macOS's NSSpellChecker, spell-mac.rkt).
(require racket/class racket/gui/base racket/list racket/string racket/lazy-require
         "command.rkt" "editor.rkt" "hook.rkt" "mode.rkt" "settings.rkt" "platform.rkt"
         "context-menu.rkt" "frame.rkt" "md-style.rkt" (only-in "ui/tokens.rkt" token)
         (only-in "../rackmac-markdown/main.rkt"
                  parse-document document-text all-extensions style-runs run-start run-end run-roles
                  run-node link? link-kind))
(provide (struct-out spell-checker) null-spell-checker current-spell-checker
         enable-spell-checking! spell-checkable? spell-misspellings spell-flush! spell-pending?
         spell-check-document! misspelling-at-selection replace-misspelling! learn-spelling!
         ignore-spelling! spell-context-groups check-text-mask paint-wavy-line! spelling-menu-items)

(lazy-require ["spell-mac.rkt" (mac-spell-available? mac-misspellings mac-guesses mac-learn-word!)])

;; ---- the checker ----------------------------------------------------------------------------

;; misspellings: string -> list of (start . end), in order, offsets into the string;
;; guesses: word -> list of replacement strings, best first; learn!: word -> void (the word is
;; correct from now on, in every document and, for the system checker, every app).
(struct spell-checker (misspellings guesses learn!))
(define null-spell-checker (spell-checker (lambda (s) '()) (lambda (w) '()) void))
(define current-spell-checker (make-parameter null-spell-checker))

(define (enable-spell-checking!)
  (when (and (mac?) (mac-spell-available?))
    (current-spell-checker (spell-checker mac-misspellings mac-guesses mac-learn-word!))
    (for ([b (in-list (all-buffers))]) (mark-all! b))))

(define-setting check-spelling-while-typing
  #:contract boolean?
  #:default #t
  #:category "Notes"
  #:doc "Underline misspelled words in notes as you type.")

(define (typing-check?) (setting-ref 'check-spelling-while-typing))

;; ---- per-document state ---------------------------------------------------------------------

;; ranges: the misspellings found so far, sorted disjoint (start . end); dirty: position ranges
;; still to check, merged and sorted; ignored: words Ignore Spelling set aside in this document;
;; parsed: (text . document) when the note's own parser is not current (Markdown Source view).
(struct sp ([checkable? #:mutable] [ranges #:mutable] [dirty #:mutable] [ignored #:mutable]
            [parsed #:mutable]))
(define states (make-weak-hasheq))

(define (prose-mode? name) (and (memq 'text-mode (map mode-name (mode-chain name))) #t))
(define (spell-checkable? b) (and (prose-mode? (send b get-mode)) (not (send b large?))))

(define (state-of b)
  (hash-ref! states b (lambda () (sp (prose-mode? (send b get-mode)) '() '() (hash) #f))))

(define (spell-misspellings b)
  (define st (hash-ref states b #f))
  (if st (sp-ranges st) '()))
(define (spell-pending? b)
  (define st (hash-ref states b #f))
  (and st (pair? (sp-dirty st))))

;; Sorted, merged union of position ranges (touching ones join).
(define (merge-ranges rs)
  (let loop ([xs (sort rs < #:key car)] [acc '()])
    (cond
      [(null? xs) (reverse acc)]
      [(and (pair? acc) (<= (car (car xs)) (cdr (car acc))))
       (loop (cdr xs) (cons (cons (car (car acc)) (max (cdr (car acc)) (cdr (car xs)))) (cdr acc)))]
      [else (loop (cdr xs) (cons (car xs) acc))])))

(define (mark-all! b)
  (define st (state-of b))
  (set-sp-ranges! st '())
  (set-sp-parsed! st #f)
  (set-sp-checkable?! st (prose-mode? (send b get-mode)))
  (set-sp-dirty! st (if (sp-checkable? st) (list (cons 0 (send b last-position))) '()))
  (invalidate-all! b)
  (schedule!))

;; [s, old-end) became new-len characters. Misspellings before the edit stay, the ones after
;; it move, and the ones it touched (including a word typed onto) are dropped until rechecked.
(define (on-edit! b s old-end new-len)
  (define st (state-of b))
  (when (sp-checkable? st)
    (define delta (- new-len (- old-end s)))
    (define (shift r) (cons (+ (car r) delta) (+ (cdr r) delta)))
    (set-sp-ranges! st (for/list ([r (in-list (sp-ranges st))]
                                  #:unless (and (>= (cdr r) s) (<= (car r) old-end)))
                         (if (> (car r) old-end) (shift r) r)))
    (set-sp-dirty! st
      (merge-ranges
       (cons (cons s (+ s new-len))
             (for/list ([d (in-list (sp-dirty st))])
               (cond [(< (cdr d) s) d]
                     [(> (car d) old-end) (shift d)]
                     [else (cons (min (car d) s) (max (+ s new-len) (+ (cdr d) delta)))])))))
    (schedule!)))

(add-hook! 'text-edited on-edit!)
(add-hook! 'mode-changed (lambda (b) (mark-all! b)))
(add-hook! 'setting-changed
           (lambda (name . _)
             (when (eq? name 'check-spelling-while-typing)
               (for ([b (in-list (all-buffers))]) (invalidate-all! b))
               (schedule!))))

;; ---- checking -------------------------------------------------------------------------------

;; Roles whose text is not prose: code, link targets, wiki links, tags, HTML, front matter, and
;; markup characters (fence info strings, list markers).
(define skip-roles '(code code-block link-dest wiki-link tag html front-matter markup))
(define (skip-run? r)
  (or (for/or ([role (in-list (run-roles r))]) (memq role skip-roles))
      (let ([n (run-node r)]) (and (link? n) (memq (link-kind n) '(literal autolink)) #t))))

(define url-rx #px"(?i:(?:https?|ftp|file|mailto):[^\\s<>()\\[\\]]*|www\\.[^\\s<>()\\[\\]]+|[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)+)")

;; `text` is the document's [start, end); `doc` its Markdown document or #f. Returns the text
;; with everything that must not be checked replaced by spaces (so offsets are unchanged), and
;; characters above U+FFFF replaced too, since the system checker counts in UTF-16.
(define (check-text-mask text start doc)
  (define out (string-copy text))
  (define n (string-length text))
  (define (blank! a b) (for ([i (in-range (max 0 a) (min n b))]) (string-set! out i #\space)))
  (for ([i (in-range n)] #:when (> (char->integer (string-ref text i)) #xFFFF))
    (string-set! out i #\space))
  (for ([m (in-list (regexp-match-positions* url-rx text))]) (blank! (car m) (cdr m)))
  (when doc
    (for ([r (in-list (style-runs doc #:start start #:end (+ start n)))] #:when (skip-run? r))
      (blank! (- (run-start r) start) (- (run-end r) start))))
  out)

;; The note's Markdown document, current with the text: its own parser's in the Formatted view,
;; else (Markdown Source view, where edits do not reparse) a parse kept until the text changes.
(define (markdown-doc b st)
  ;; In the Formatted view every edit reparses (md-style.rkt's `restyle-edit`), so its document
  ;; is current whenever its length is; comparing 300 KB of text each time would cost more
  ;; than the check.
  (define d (markdown-parser-document b))
  (cond
    [(not (eq? (send b get-mode) 'markdown-mode)) #f]
    [(and d (send b local-ref 'restyle-edit #f)
          (= (string-length (document-text d)) (send b last-position)))
     d]
    [else
     (define text (send b get-text))
     (cond
       [(and (sp-parsed st) (string=? (car (sp-parsed st)) text)) (cdr (sp-parsed st))]
       [else (define d2 (parse-document text #:extensions all-extensions))
             (set-sp-parsed! st (cons text d2))
             d2])]))

;; Check [s, e) (whole paragraphs) and replace the misspellings stored for it.
(define (check-region! b st s e doc)
  (define text (send b get-text s e))
  (define found ((spell-checker-misspellings (current-spell-checker)) (check-text-mask text s doc)))
  (define ignored (sp-ignored st))
  (define new
    (for/list ([r (in-list found)]
               #:unless (hash-ref ignored (substring text (car r) (cdr r)) #f))
      (cons (+ s (car r)) (+ s (cdr r)))))
  (define-values (before rest) (splitf-at (sp-ranges st) (lambda (r) (< (cdr r) s))))
  (define after (dropf rest (lambda (r) (<= (car r) e))))
  (set-sp-ranges! st (append before new after))
  (invalidate-lines! b s e))

;; Check the marked paragraphs, a chunk of about `chunk` characters at a time, until `budget`
;; milliseconds have passed (#f: until done). Returns #t when nothing is left to check.
(define chunk 2000)
(define (work! b st budget)
  (define t0 (current-inexact-milliseconds))
  (define doc (and (pair? (sp-dirty st)) (markdown-doc b st)))
  (let loop ()
    (define dirty (sp-dirty st))
    (cond
      [(null? dirty) #t]
      [(and budget (> (- (current-inexact-milliseconds) t0) budget)) #f]
      [else
       (define last (send b last-position))
       (define d (car dirty))
       (define s (send b paragraph-start-position (send b position-paragraph (min last (car d)))))
       ;; whole paragraphs, up to about `chunk` characters past s (always at least one paragraph)
       (define limit-para (send b position-paragraph (min last (max (cdr d) s))))
       (define e (let grow ([p (send b position-paragraph s)])
                   (define pe (send b paragraph-end-position p))
                   (if (and (< p limit-para) (< (- pe s) chunk)) (grow (add1 p)) pe)))
       (check-region! b st s e doc)
       ;; what is left: the marks past e (the next paragraph starts at e + 1)
       (set-sp-dirty! st (for*/list ([d (in-list dirty)]
                                     [d2 (in-value (if (<= (car d) e) (cons (add1 e) (cdr d)) d))]
                                     #:when (or (eq? d2 d) (< (car d2) (cdr d2))))
                           d2))
       (loop)])))

;; Check everything still marked in `b` now (tests, Check Document Now).
(define (spell-flush! b)
  (define st (state-of b))
  (if (and (sp-checkable? st) (not (send b large?)))
      (void (work! b st #f))
      (set-sp-dirty! st '())))

(define (spell-check-document! b)
  (define st (state-of b))
  (set-sp-checkable?! st (prose-mode? (send b get-mode)))
  (set-sp-dirty! st (if (sp-checkable? st) (list (cons 0 (send b last-position))) '()))
  (set-sp-ranges! st '())
  (spell-flush! b))

;; One timer for every document: first after typing pauses, then back to back in slices.
(define idle-delay 300)
(define slice-ms 12)
(define timer #f)
(define (schedule! [delay idle-delay])
  (when (typing-check?)
    (unless timer (set! timer (new timer% [notify-callback tick!])))
    (send timer start delay #t)))
(define (tick!)
  (when (typing-check?)
    (define more?
      (for/or ([b (in-list (all-buffers))])
        (define st (hash-ref states b #f))
        (and st (pair? (sp-dirty st))
             (cond [(or (not (sp-checkable? st)) (send b large?)) (set-sp-dirty! st '()) #f]
                   [else (not (work! b st slice-ms))]))))
    (when more? (schedule! 1))))

;; ---- drawing --------------------------------------------------------------------------------

(define (invalidate-lines! b s e)
  (define y0 (box 0.0)) (define y1 (box 0.0))
  (send b position-location s #f y0 #t)
  (send b position-location e #f y1 #f)
  (send b invalidate-bitmap-cache 0.0 (unbox y0) 'end (max 1.0 (- (unbox y1) (unbox y0)))))
(define (invalidate-all! b) (send b invalidate-bitmap-cache 0.0 0.0 'end 'end))

;; A wavy line from x0 to x1 whose troughs sit on y, two pixels high, in `color`; unsmoothed,
;; so it is the token's exact color.
(define (paint-wavy-line! dc x0 x1 y color)
  (define old-pen (send dc get-pen))
  (define old-smoothing (send dc get-smoothing))
  (send dc set-pen color 1 'solid)
  (send dc set-smoothing 'unsmoothed)
  (define pts (for/list ([x (in-range x0 (+ x1 0.01) 2)] [i (in-naturals)])
                (cons (min x x1) (if (even? i) y (- y 2)))))
  (when (>= (length pts) 2) (send dc draw-lines pts))
  (send dc set-smoothing old-smoothing)
  (send dc set-pen old-pen))

(define (paint! b dc left top right bottom dx dy)
  (define st (hash-ref states b #f))
  (when (and st (typing-check?) (pair? (sp-ranges st)))
    (define from (send b line-start-position (send b find-line top)))
    (define to (send b line-end-position (send b find-line bottom)))
    (define color (token 'error))
    (define spacing (send b get-line-spacing))
    (define x0 (box 0.0)) (define y0 (box 0.0)) (define x1 (box 0.0)) (define y1 (box 0.0))
    (for ([r (in-list (sp-ranges st))]
          #:when (and (<= (car r) to) (>= (cdr r) from)))
      (send b position-location (car r) x0 y0 #f)
      (send b position-location (cdr r) x1 y1 #f)
      (when (= (unbox y0) (unbox y1))                ; a word wrapped across lines is left alone
        ;; y0 is the line's bottom, below the line spacing; the wave sits just under the
        ;; baseline, through the descenders, as in other Mac apps
        (paint-wavy-line! dc (+ dx (unbox x0)) (+ dx (unbox x1)) (+ dy (- (unbox y0) spacing) 1) color)))))

(add-hook! 'paint-document paint!)

;; ---- suggestions, Learn, Ignore -------------------------------------------------------------

;; The flagged range the selection is on (the caret inside or at the end of a flagged word, or
;; the word selected), or #f.
(define (misspelling-at-selection b)
  (define st (hash-ref states b #f))
  (define s (send b get-start-position))
  (define e (send b get-end-position))
  (and st (typing-check?)
       (for/first ([r (in-list (sp-ranges st))] #:when (and (<= (car r) s) (<= e (cdr r)))) r)))

(define (range-text b r) (send b get-text (car r) (cdr r)))

;; Replace a misspelling with `word`: one undo step, the replacement selected like a typed word.
(define (replace-misspelling! b r word)
  (send b begin-edit-sequence)
  (send b insert word (car r) (cdr r))
  (send b end-edit-sequence)
  (send b set-position (+ (car r) (string-length word))))

(define (drop-word! b word)
  (define st (hash-ref states b #f))
  (when st
    (set-sp-ranges! st (filter (lambda (r) (not (string=? (range-text b r) word))) (sp-ranges st)))
    (invalidate-all! b)))

;; Learn: correct from now on everywhere (the system checker keeps it in the user's dictionary).
(define (learn-spelling! b r)
  (define word (range-text b r))
  ((spell-checker-learn! (current-spell-checker)) word)
  (for ([d (in-list (all-buffers))]) (drop-word! d word)))

;; Ignore: correct in this document, for as long as it is open.
(define (ignore-spelling! b r)
  (define word (range-text b r))
  (define st (state-of b))
  (set-sp-ignored! st (hash-set (sp-ignored st) word #t))
  (drop-word! b word))

(define max-guesses 6)

;; The context menu's first groups on a flagged word: the guesses (each replaces the word), then
;; Learn Spelling and Ignore Spelling.
(define (spell-context-groups b)
  (define r (misspelling-at-selection b))
  (cond
    [(not r) '()]
    [else
     (define guesses ((spell-checker-guesses (current-spell-checker)) (range-text b r)))
     (list (if (null? guesses)
               (list (cons "No Guesses Found" #f))
               (for/list ([g (in-list (take guesses (min max-guesses (length guesses))))])
                 (cons g (lambda () (replace-misspelling! b r g)))))
           (list 'learn-spelling 'ignore-spelling))]))

(add-context-provider! spell-context-groups)

;; ---- commands and Edit > Spelling -----------------------------------------------------------

(define (flagged-now) (misspelling-at-selection (current-buffer)))

(define-command (check-spelling-while-typing)
  #:title "Check Spelling While Typing"
  #:aliases ("spelling" "spell check" "spellcheck" "underline misspelled words" "typos")
  #:help "Turn underlining of misspelled words in notes on or off."
  #:checked (lambda () (typing-check?))
  (setting-set! 'check-spelling-while-typing (not (typing-check?))))

(define-command (check-document-now)
  #:title "Check Document Now"
  #:aliases ("spelling" "spell check" "check spelling" "find misspelled words" "typos")
  #:help "Check the spelling of the whole document and select the next misspelled word."
  #:when (lambda () (spell-checkable? (current-buffer)))
  (define b (current-buffer))
  (spell-check-document! b)
  (define ranges (spell-misspellings b))
  (define caret (send b get-end-position))
  (define next (or (for/first ([r (in-list ranges)] #:when (>= (car r) caret)) r)
                   (and (pair? ranges) (car ranges))))
  (when next (send b set-position (car next) (cdr next)))
  (invalidate-all! b)
  (run-hook 'echo (case (length ranges)
                    [(0) "No spelling mistakes found."]
                    [(1) "1 possible spelling mistake."]
                    [else (format "~a possible spelling mistakes." (length ranges))])))

(define-command (learn-spelling)
  #:title "Learn Spelling"
  #:aliases ("add to dictionary" "learn word" "spelling")
  #:help "Add the underlined word to your dictionary, so it is never flagged again."
  #:when flagged-now
  (define r (flagged-now))
  (when r (learn-spelling! (current-buffer) r)))

(define-command (ignore-spelling)
  #:title "Ignore Spelling"
  #:aliases ("ignore word" "ignore all" "spelling")
  #:help "Stop flagging the underlined word in this document."
  #:when flagged-now
  (define r (flagged-now))
  (when r (ignore-spelling! (current-buffer) r)))

;; Edit > Spelling ▸ Check Spelling While Typing (checked while on), Check Document Now.
(define (spelling-menu-items) '(check-spelling-while-typing check-document-now))
(define (populate! m)
  (for ([name (in-list (spelling-menu-items))])
    (define c (find-command name))
    (define item
      (if (command-checked c)
          (new checkable-menu-item% [label (command-menu-label name)] [parent m]
               [checked (command-checked? c)] [callback (lambda (i e) (run-command/safe name))])
          (new menu-item% [label (command-menu-label name)] [parent m]
               [callback (lambda (i e) (run-command/safe name))])))
    (send item enable (command-enabled? c))))

(register-submenu! "Spelling" #:menu "Edit" #:menu-order 60 populate!)
