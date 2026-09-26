#lang racket/base
;; mdlib-edits (#323, design §4.4): the token-based edit operations. For each operation, the
;; expected text on hand-written cases, including nested markup (emphasis inside links, lists
;; inside quotes, items with children); toggling twice is the identity (the second toggle at the
;; selection the first returned); and each diff touches only the tokens it names: every edit that
;; removes or replaces text removes only markup-token characters or whitespace (checked on
;; every case), and inline toggles leave the document's plain text unchanged. Every case runs
;; with extensions off and on.
(require racket/list racket/string rackunit "../main.rkt")

(define current-exts (make-parameter no-extensions))
(define (parse s) (parse-document s #:extensions (current-exts)))

;; Every replaced or deleted character is markup (a token of the old document), whitespace, or
;; a task marker's bracketed character.
(define (check-touches-only-markup! text edits)
  (define doc (parse text))
  (define toks (markup-tokens doc))
  (define (markup? p) (for/or ([t (in-list toks)]) (and (<= (token-start t) p) (< p (token-end t)))))
  (define (empty-pair? e) ; `****` put down at a caret parses as text; toggling there removes it
    (member (substring text (edit-start e) (edit-end e)) '("**" "****" "~~~~" "``")))
  (for* ([e (in-list edits)] #:unless (empty-pair? e) [p (in-range (edit-start e) (edit-end e))])
    (define c (string-ref text p))
    (unless (or (markup? p) (char-whitespace? c) (memv c '(#\[ #\] #\x #\X #\- #\>)))
      (fail-check (format "edit ~s removes content character ~s at ~a of ~s" e c p text)))))

(define (plain-text doc)
  (define (inl x)
    (cond [(text? x) (text-value x)] [(code-span? x) (code-span-value x)]
          [(or (soft-break? x) (hard-break? x)) "\n"]
          [(emph? x) (string-append* (map inl (emph-children x)))]
          [(strong? x) (string-append* (map inl (strong-children x)))]
          [(strike? x) (string-append* (map inl (strike-children x)))]
          [(link? x) (string-append* (map inl (link-children x)))]
          [else ""]))
  (define (blk b)
    (cond [(leaf-block? b) (string-append* (map inl (block-inlines b)))]
          [(block-quote? b) (string-join (map blk (block-quote-children b)) "|")]
          [(list-block? b) (string-join (map blk (list-block-children b)) "|")]
          [(list-item? b) (string-join (map blk (list-item-children b)) "|")]
          [else ""]))
  (string-join (map blk (document-children doc)) "|"))

;; --- inline toggles ---

(define (toggle text start end kind)
  (define-values (edits s e) (toggle-emphasis-edits (parse text) start end kind))
  (check-touches-only-markup! text edits)
  (values (apply-edits text edits) s e))

(define (sel-of text sub [nth 0]) ; the [start, end) of the nth occurrence of sub
  (define ps (regexp-match-positions* (regexp (regexp-quote sub)) text))
  (values (car (list-ref ps nth)) (cdr (list-ref ps nth))))

;; toggles `sub` (by position), checks the result, toggles again, checks the identity
(define (check-toggle text sub kind expected #:twice? [twice? #t] #:caret [caret #f])
  (define-values (s e) (if caret (values caret caret) (sel-of text sub)))
  (define-values (t1 s1 e1) (toggle text s e kind))
  (check-equal? t1 expected (format "toggle ~a on ~s in ~s" kind sub text))
  (unless (or (memq kind '(code)) (regexp-match? #rx"[*][*][*][*]" t1))
    (check-equal? (plain-text (parse t1)) (plain-text (parse text)) (format "plain text kept: ~s" t1)))
  (when twice?
    (define-values (t2 s2 e2) (toggle t1 s1 e1 kind))
    (check-equal? t2 text (format "toggling twice is the identity: ~s -> ~s -> ~s" text t1 t2))
    (check-equal? (list s2 e2) (list s e) "and restores the selection")))

(define (inline-cases)
  (check-toggle "hello world" "hello" 'strong "**hello** world")
  (check-toggle "hello world" "world" 'emph "hello *world*")
  (check-toggle "a b c" "b" 'strong "a **b** c")
  (check-toggle "abc" "b" 'strong "a**b**c")
  (check-toggle "use foo here" "foo" 'code "use `foo` here")
  (check-toggle "a`b" "a`b" 'code "``a`b``")
  ;; the word at the caret; the caret keeps its place in the word
  (check-toggle "hello world" #f 'strong "hello **world**" #:caret 8)
  (check-toggle "hello world" #f 'emph "hello *world*" #:caret 11)
  (check-toggle "hello world" #f 'strong "**hello** world" #:caret 0)
  ;; a caret outside any word inserts a pair; toggling at its middle removes it
  (check-toggle "a  b" #f 'strong "a **** b" #:caret 2)
  ;; selecting blanks around a word, or the delimiters with it, means the word
  (check-toggle "x  abc  y" "  abc  " 'strong "x  **abc**  y")
  (let-values ([(t s e) (toggle "x **abc** y" 2 9 'strong)])
    (check-equal? t "x abc y"))
  ;; removing from part of a node splits it around the selection, and back
  (check-toggle "**abc**" "b" 'strong "**a**b**c**")
  (check-toggle "**a b c**" "b" 'strong "**a** b **c**")
  (check-toggle "**abc**" "a" 'strong "a**bc**")
  (check-toggle "_abc_" "b" 'emph "*a*b*c*" #:twice? #f)
  ;; adding over or next to existing nodes of the kind merges them
  (let-values ([(t s e) (toggle "**ab** cd" 3 9 'strong)])
    (check-equal? t "**ab cd**"))
  (let-values ([(t s e) (toggle "**a**b**c**" 5 6 'strong)])
    (check-equal? t "**abc**"))
  (let-values ([(t s e) (toggle "a **b** c **d** e" 0 17 'strong)])
    (check-equal? t "**a b c d e**"))
  ;; nested markup: inside link text, across a link, inside strong, inside code
  (check-toggle "[a b](/u) c" "b" 'strong "[a **b**](/u) c")
  (check-toggle "[a b](/u) c" "b](/u) c" 'strong "**[a b](/u) c**")
  (check-toggle "x [a b](/u)" "x [a" 'emph "*x [a b](/u)*")
  (check-toggle "**a b**" "b" 'emph "**a *b***")
  (check-toggle "*a b*" "a b" 'strong "***a b***")
  ;; emphasis and strong together (#323, #335): `***x***` is emphasis around strong, and the
  ;; kind goes around other emphasis it covers whole; toggling back is the identity
  (check-toggle "**two**" "two" 'emph "***two***")
  (check-toggle "***two***" "two" 'emph "**two**")
  (check-toggle "***two***" "two" 'strong "*two*")
  (check-toggle "__two__" "two" 'emph "*__two__*")
  (check-toggle "_two_" "two" 'strong "**_two_**")
  (check-toggle "x**ab**y" "ab" 'emph "x***ab***y")
  (check-toggle "**a b**" "a" 'emph "***a* b**")
  ;; removing from inside: pieces on either side, placed within the nesting, never across it
  (check-toggle "*a **b** c*" "b" 'emph "*a* **b** *c*")
  (check-toggle "*a **b c** d*" "c" 'emph "*a* ***b* c** *d*")
  (check-toggle "**abc**" "b" 'emph "**a*b*c**")
  ;; a neighbor written with `_` merges as `_`, so it comes back
  (check-toggle "_a_ b" "b" 'emph "_a b_")
  ;; where `*` would run into a neighboring `*`, a pair is written with `_`
  (check-toggle "**x*x file*** memo" "file" 'strong "__x__***x** file* memo" #:twice? #f)
  ;; a selection partly of the kind gets it throughout (as in word processors), so toggling
  ;; back removes it from all of it
  (check-toggle "*a **b** c*" "a **b** c" 'strong "***a b c***" #:twice? #f)
  (check-toggle "**ab** *cd*" "ab** *cd" 'emph "***ab** cd*" #:twice? #f)
  (check-toggle "a `code` b" "de` b" 'strong "a **`code` b**")
  (check-toggle "a &amp; b" "mp; b" 'strong "a **&amp; b**")
  (check-toggle "a \\* b" "* b" 'strong "a **\\* b**")
  (check-toggle "a <http://x.y> b" "x.y> b" 'strong "a **<http://x.y> b**")
  ;; lines, containers and blocks
  (check-toggle "> - one two\n>   three" "two\n>   three" 'strong "> - one **two\n>   three**")
  (check-toggle "a\n\nb" "a\n\nb" 'strong "**a**\n\n**b**")
  (check-toggle "# Title here" "Title" 'emph "# *Title* here")
  (check-toggle "# Title" "# Title" 'strong "# **Title**")
  (check-toggle "- one\n- two" "one\n- two" 'strong "- **one**\n- **two**"))

;; strikethrough parses only with its extension (GFM); tasks, tables and wiki links nearby
(define (strike-cases)
  (check-toggle "a b c" "b" 'strike "a ~~b~~ c")
  (check-toggle "~~abc~~" "b" 'strike "~~a~~b~~c~~")
  (check-toggle "~a b~" "b" 'strike "~~a~~ b" #:twice? #f)
  (check-toggle "**a b**" "b" 'strike "**a ~~b~~**")
  (check-toggle "- [ ] buy milk" "buy milk" 'strike "- [ ] ~~buy milk~~")
  (check-toggle "- [ ] buy milk" "buy milk" 'strong "- [ ] **buy milk**")
  (check-toggle "see [[Page|the page]] now" "the page]] now" 'strong "see **[[Page|the page]] now**")
  (check-toggle "a #tag b" "tag b" 'emph "a *#tag b*")
  (check-toggle "due 2026-09-30 x" "09-30 x" 'strong "**due 2026-09-30 x**")
  (check-toggle "| a b | c |\n| - | - |" "b" 'strong "| a **b** | c |\n| - | - |")
  (check-toggle "# TODO fix it" "fix" 'emph "# TODO *fix* it"))

(test-case "toggle-emphasis-edits: strike and extension syntax (extensions on)"
  (parameterize ([current-exts all-extensions]) (strike-cases)))

(test-case "toggle-emphasis-edits (extensions off)" (inline-cases))
(test-case "toggle-emphasis-edits (extensions on)" (parameterize ([current-exts all-extensions]) (inline-cases)))

;; --- block operations ---

;; Runs a block operation, checks the result and that it touches only markup when removing.
(define (check-op op text expected [what ""])
  (define edits (op (parse text)))
  (check-touches-only-markup! text edits)
  (check-equal? (apply-edits text edits) expected (format "~a on ~s" what text)))

(define (heading-cases)
  (define (lvl n [s 0] [e #f]) (lambda (doc) (set-heading-level-edits doc s (or e s) n)))
  (check-op (lvl 2) "Title" "## Title")
  (check-op (lvl 0) "## Title" "Title")
  (check-op (lvl 0) "## Title ##" "Title")
  (check-op (lvl 3) "# T" "### T")
  (check-op (lvl 1) "## T ##" "# T ##")
  (check-op (lvl 2) "T\n===" "T\n---")
  (check-op (lvl 3) "T\n===" "### T")
  (check-op (lvl 4) "a\nb\n---" "#### a b")
  (check-op (lvl 0) "T\n===\n\nx" "T\n\nx")
  (check-op (lvl 1 2) "a\nb\nc" "a\n# b\nc")
  (check-op (lvl 1 0 5) "a\nb\nc" "# a\n# b\n# c")
  (check-op (lvl 2 3) "- item" "- ## item")
  (check-op (lvl 2 3) "> quote" "> ## quote")
  (check-op (lvl 0) "plain" "plain")
  ;; twice: body -> heading -> body
  (define t1 (apply-edits "note" (set-heading-level-edits (parse "note") 0 0 2)))
  (check-equal? (apply-edits t1 (set-heading-level-edits (parse t1) 3 3 0)) "note"))

(test-case "set-heading-level-edits (extensions off)" (heading-cases))
(test-case "set-heading-level-edits (extensions on)" (parameterize ([current-exts all-extensions]) (heading-cases)))

(define (check-toggle-lines op text expected [start 0] [end (string-length text)])
  (check-op (lambda (doc) (op doc start end)) text expected)
  (define t1 (apply-edits text (op (parse text) start end)))
  (check-op (lambda (doc) (op doc start (min (string-length t1) (+ end (- (string-length t1) (string-length text))))))
            t1 text "toggling twice"))

(define (list-cases)
  (define (tl kind) (lambda (doc s e) (toggle-list-edits doc s e kind)))
  (check-toggle-lines (tl 'bullet) "a\nb\nc" "- a\n- b\n- c")
  (check-toggle-lines (tl 'ordered) "a\nb" "1. a\n2. b")
  (check-toggle-lines (tl 'task) "a\nb" "- [ ] a\n- [ ] b")
  (check-toggle-lines (tl 'bullet) "> a\n> b" "> - a\n> - b")
  (check-toggle-lines (tl 'bullet) "# H\nx" "- # H\n- x")
  (check-toggle-lines (tl 'bullet) "a\n\nb" "- a\n\n- b")
  ;; converting between kinds rewrites only the markers
  (check-op (lambda (d) (toggle-list-edits d 0 7 'ordered)) "- a\n- b" "1. a\n2. b")
  (check-op (lambda (d) (toggle-list-edits d 0 9 'bullet)) "1. a\n2. b" "- a\n- b")
  (check-op (lambda (d) (toggle-list-edits d 0 3 'task)) "- a" "- [ ] a")
  (check-op (lambda (d) (toggle-list-edits d 0 7 'bullet)) "- [x] a" "- a")
  (check-op (lambda (d) (toggle-list-edits d 0 7 'ordered)) "- [x] a" "1. a")
  (check-op (lambda (d) (toggle-list-edits d 0 1 'task)) "-" "- [ ] ")
  (check-op (lambda (d) (toggle-list-edits d 0 6 'ordered)) "1. a\nb" "a\nb") ; b is a's lazy line
  (check-op (lambda (d) (toggle-list-edits d 0 11 'ordered)) "3. a\n\n- b" "3. a\n\n1. b")
  (check-op (lambda (d) (toggle-list-edits d 0 12 'bullet)) "- a\n  - b\nc" "a\n  b\nc") ; c is lazy
  (check-op (lambda (d) (toggle-list-edits d 0 13 'bullet)) "- a\n  - b\n\nc" "- a\n  - b\n\n- c")
  ;; nested items keep their indentation when unbulleted
  (check-op (lambda (d) (toggle-list-edits d 0 9 'bullet)) "- a\n  - b" "a\n  b"))

(test-case "toggle-list-edits (extensions off)" (list-cases))
(test-case "toggle-list-edits (extensions on)" (parameterize ([current-exts all-extensions]) (list-cases)))

(define (quote-cases)
  (check-toggle-lines toggle-quote-edits "a\nb" "> a\n> b")
  (check-toggle-lines toggle-quote-edits "a\n\nb" "> a\n>\n> b")
  (check-toggle-lines toggle-quote-edits "- a\n- b" "> - a\n> - b")
  (check-op (lambda (d) (toggle-quote-edits d 0 5)) "> a\nb" "> a\n> b")
  (check-op (lambda (d) (toggle-quote-edits d 2 2)) "x\n\ny" "x\n\ny")
  (check-op (lambda (d) (toggle-quote-edits d 0 7)) "> > a\nb" "> > a\n> b")
  (check-op (lambda (d) (toggle-quote-edits d 0 9)) ">> a\n> b" "> a\nb"))

(test-case "toggle-quote-edits (extensions off)" (quote-cases))
(test-case "toggle-quote-edits (extensions on)" (parameterize ([current-exts all-extensions]) (quote-cases)))

;; --- Enter ---

(define (check-enter text pos expected expected-caret)
  (define-values (edits caret) (list-enter-edits (parse text) pos))
  (cond
    [(not expected) (check-false edits (format "not a list: ~s" text))]
    [else
     (check-touches-only-markup! text edits)
     (check-equal? (apply-edits text edits) expected (format "Enter at ~a in ~s" pos text))
     (check-equal? caret expected-caret (format "caret after Enter at ~a in ~s" pos text))]))

(define (enter-cases)
  (check-enter "- a" 3 "- a\n- " 6)
  (check-enter "- ab" 3 "- a\n- b" 6)
  (check-enter "- a b" 3 "- a\n- b" 6)
  (check-enter "- ab" 2 "- \n- ab" 5)
  (check-enter "- ab" 0 "- \n- ab" 5)
  (check-enter "* a" 3 "* a\n* " 6)
  (check-enter "-   a" 5 "-   a\n-   " 10)
  (check-enter "1. a\n2. b" 4 "1. a\n2. \n3. b" 8)
  (check-enter "1. a\n2. b\n3. c\n7. d" 4 "1. a\n2. \n3. b\n4. c\n7. d" 8)
  (check-enter "1) a" 4 "1) a\n2) " 8)
  (check-enter "9. a" 4 "9. a\n10. " 9)
  (check-enter "1. a\n1. b" 4 "1. a\n1. \n1. b" 8)
  (check-enter "- [x] a" 7 "- [x] a\n- [ ] " 14)
  (check-enter "> - a" 5 "> - a\n> - " 10)
  (check-enter "- a\n  - b" 9 "- a\n  - b\n  - " 14)
  (check-enter "- a\n\n- b" 3 "- a\n\n- \n\n- b" 7)
  (check-enter "> - a\n>\n> - b" 5 "> - a\n>\n> - \n>\n> - b" 12)
  (check-enter "- # h" 5 "- # h\n- " 8)
  ;; an empty item ends the list; a nested one moves out a level
  (check-enter "- a\n- " 6 "- a\n" 4)
  (check-enter "- a\n-" 5 "- a\n" 4)
  (check-enter "- a\n- [ ] " 10 "- a\n" 4)
  (check-enter "- a\n  - b\n  - " 14 "- a\n  - b\n- " 12)
  (check-enter "> - a\n> - " 10 "> - a\n> " 8)
  ;; not in a list item's text
  (check-enter "abc" 1 #f #f)
  (check-enter "- a\n\n```\nx\n```" 12 #f #f))

(test-case "list-enter-edits (extensions off)" (enter-cases))
(test-case "list-enter-edits (extensions on)" (parameterize ([current-exts all-extensions]) (enter-cases)))

;; --- indent / outdent ---

(define (check-indent text start end expected)
  (define e1 (indent-list-edits (parse text) start end))
  (define t1 (apply-edits text e1))
  (check-equal? t1 expected (format "indent ~s" text))
  (unless (equal? t1 text)
    (define e2 (outdent-list-edits (parse t1) (map-position e1 start) (map-position e1 end 'before)))
    (check-touches-only-markup! t1 e2)
    (check-equal? (apply-edits t1 e2) text (format "outdent after indent ~s" t1))))

(define (indent-cases)
  (check-indent "- a\n- b" 5 5 "- a\n  - b")
  (check-indent "1. a\n2. b" 6 6 "1. a\n   1. b")          ; a new sublist starts at 1
  (check-indent "- a\n- b" 1 1 "- a\n- b")                      ; a first item stays
  (check-indent "- a\n- b\n  - c" 5 5 "- a\n  - b\n    - c")      ; children move along
  (check-indent "- a\n- b\n  more\n- c" 5 5 "- a\n  - b\n    more\n- c")
  (check-indent "> - a\n> - b" 8 8 "> - a\n>   - b")
  (check-indent "- a\n- b\n- c" 5 11 "- a\n  - b\n  - c")
  (check-equal? (outdent-list-edits (parse "- a") 0 0) '()) ; top level stays
  (check-equal? (apply-edits "- a\n  - b\n  - c" (outdent-list-edits (parse "- a\n  - b\n  - c") 6 6))
                "- a\n- b\n  - c"))

(test-case "indent/outdent-list-edits (extensions off)" (indent-cases))
(test-case "indent/outdent-list-edits (extensions on)" (parameterize ([current-exts all-extensions]) (indent-cases)))

;; --- tasks ---

(define (task-cases)
  (define (tt text pos) (apply-edits text (toggle-task-edits (parse text) pos)))
  (check-equal? (tt "- [ ] a" 6) "- [x] a")
  (check-equal? (tt "- [x] a" 0) "- [ ] a")
  (check-equal? (tt "- [X] a" 3) "- [ ] a")
  (check-equal? (tt "- [-] a" 6) "- [ ] a")
  (check-equal? (tt (tt "- [ ] a" 6) 6) "- [ ] a")
  (check-equal? (tt "- a" 2) "- [ ] a")
  (check-equal? (tt "1. a" 3) "1. [ ] a")
  (check-equal? (tt "- [ ] a\n  - [x] b" 16) "- [ ] a\n  - [ ] b")
  (check-equal? (tt "- [ ] a\n  - [x] b" 3) "- [x] a\n  - [x] b")
  (check-equal? (tt "> - [ ] q" 9) "> - [x] q")
  (check-equal? (tt "text" 2) "text")
  (check-equal? (toggle-task-edits (parse "- [ ] a") 6) (list (edit 3 4 "x")) "one character, inside the marker")
  (check-equal? (apply-edits "- [ ] a" (set-task-edits (parse "- [ ] a") 0 'cancelled)) "- [-] a")
  (check-equal? (apply-edits "- a" (set-task-edits (parse "- a") 0 'done)) "- [x] a"))

(test-case "toggle-task-edits (extensions off)" (task-cases))
(test-case "toggle-task-edits (extensions on)" (parameterize ([current-exts all-extensions]) (task-cases)))

;; --- helpers ---

(test-case "apply-edits and map-position"
  (define es (list (edit 1 1 "**") (edit 3 5 "x")))
  (check-equal? (apply-edits "abcdef" es) "a**bcxf")
  (check-equal? (map-position es 0) 0)
  (check-equal? (map-position es 1) 3)
  (check-equal? (map-position es 1 'before) 1)
  (check-equal? (map-position es 2) 4)
  (check-equal? (map-position es 4) 6)
  (check-equal? (map-position es 4 'before) 5)
  (check-equal? (map-position es 5) 6)
  (check-equal? (map-position es 6) 7))

;; --- property: random words of generated notes ---
;; A random word of a random paragraph's top-level text, toggled to each kind: the result has a
;; node of that kind covering the word (it may merge with a neighbor of the kind), the plain text is unchanged (except for code,
;; whose value is the word too), and toggling at the returned selection gives back the text.
(require "notes-gen.rkt")
(test-case "toggle-emphasis-edits: random words of generated notes, twice is the identity"
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng]) (random-seed 323))
  (define (find-kind xs kind s e)
    (for/or ([x (in-list xs)])
      (or (and (case kind [(strong) (strong? x)] [(emph) (emph? x)] [(code) (code-span? x)] [(strike) (strike? x)])
               (<= (inline-start x) s) (>= (inline-end x) e))
          (find-kind (cond [(emph? x) (emph-children x)] [(strong? x) (strong-children x)]
                           [(strike? x) (strike-children x)] [(link? x) (link-children x)] [else '()])
                     kind s e))))
  (for ([exts (in-list (list no-extensions all-extensions))])
    (parameterize ([current-exts exts])
      (define text (generate-notes 300 7))
      (define doc (parse text))
      (define paras (let loop ([bs (document-children doc)])
                      (append* (for/list ([b (in-list bs)])
                                 (cond [(paragraph? b) (list b)]
                                       [(block-quote? b) (loop (block-quote-children b))]
                                       [(list-block? b) (loop (list-block-children b))]
                                       [(list-item? b) (loop (list-item-children b))]
                                       [else '()])))))
      (for ([i (in-range 150)])
        (define p (list-ref paras (random (length paras) rng)))
        (define texts (filter (lambda (x) (and (text? x) (null? (inline-tokens x)))) (block-inlines p)))
        (unless (null? texts)
          (define t (list-ref texts (random (length texts) rng)))
          (define words (regexp-match-positions* #px"[A-Za-z]+" text (inline-start t) (inline-end t)))
          (unless (null? words)
            (define w (list-ref words (random (length words) rng)))
            (define kind (list-ref '(strong emph code strike) (random 4 rng)))
            (unless (and (eq? kind 'strike) (not (extension-set-strike exts)))
              (define-values (t1 s1 e1) (toggle text (car w) (cdr w) kind))
              (define d1 (parse t1))
              (define leaf (block-at d1 s1))
              (with-check-info (['word (substring text (car w) (cdr w))] ['kind kind] ['at (car w)])
                (check-not-false (and (leaf-block? leaf)
                                      (find-kind (block-inlines leaf) kind
                                                 (- s1 (string-length (if (eq? kind 'code) "`" (if (eq? kind 'emph) "*" "**"))))
                                                 (+ e1 (string-length (if (eq? kind 'code) "`" (if (eq? kind 'emph) "*" "**"))))))
                                 "the word is now a node of the kind")
                (unless (eq? kind 'code) (check-equal? (plain-text d1) (plain-text doc)))
                (define-values (t2 s2 e2) (toggle t1 s1 e1 kind))
                (check-equal? t2 text "twice is the identity")))))))))

;; --- property: generated nested inline markup (#323, #335) ---
;; Paragraphs of words nested in strong, emphasis, strikethrough, code spans and links, with `*`
;; and `_` delimiters and emphasis glued inside words; a selection of whole words (a code span
;; or a link counts as one); each kind toggled on it. Afterwards, per content character of the
;; paragraph (in order; the plain text is unchanged): the selected characters have gained the
;; kind (or, when all had it, lost it) and every other character keeps exactly the formatting
;; it had, in every kind. When the selection was all of the kind or none of it, toggling again
;; at the returned selection gives back the text. Inputs are in normal form: no kind nested in
;; itself; two nodes of one kind always have a plain word between them (a toggle merges nodes
;; that only blanks separate, which toggling back cannot tell apart); and the toggled kind over
;; all of another node's content is written outside it (`**_x_**`, not `_**x**_`: toggling
;; strong off either gives `_x_`, and toggling it on again gives the first).
(define (content-kinds text doc)
  ;; (char . kinds) for each content character of the first paragraph, in order
  (define para (car (document-children doc)))
  (define out '())
  (define (add! p kinds)
    (unless (char-whitespace? (string-ref text p))
      (set! out (cons (cons (string-ref text p) (sort kinds symbol<?)) out))))
  (let walk ([xs (block-inlines para)] [kinds '()])
    (for ([x (in-list xs)])
      (cond
        [(text? x) (for ([p (in-range (inline-start x) (inline-end x))]) (add! p kinds))]
        [(code-span? x)
         (define ts (inline-tokens x))
         (for ([p (in-range (token-end (first ts)) (token-start (last ts)))]) (add! p (cons 'code kinds)))]
        [(emph? x) (walk (emph-children x) (cons 'emph kinds))]
        [(strong? x) (walk (strong-children x) (cons 'strong kinds))]
        [(strike? x) (walk (strike-children x) (cons 'strike kinds))]
        [(link? x) (walk (link-children x) kinds)])))
  (reverse out))

;; A random paragraph for toggling `kind`: its text, its intended (char . kinds) list and its
;; units (start end) in order: words, code spans and links.
(define (gen-nested rng kind strike?)
  (define (rnd n) (random n rng))
  (define (word) (list-ref '("ab" "cd" "note" "file" "x" "memo" "due" "brief") (rnd 8)))
  (define out (open-output-string))
  (define seq '()) (define units '())
  (define (emit-word! w kinds)
    (define s (file-position out))
    (write-string w out)
    (set! units (cons (list s (file-position out)) units))
    (for ([c (in-string w)]) (set! seq (cons (cons c (sort kinds symbol<?)) seq))))
  (define (delim k)
    (case k
      [(emph) (if (or (eq? kind 'emph) (zero? (rnd 2))) "*" "_")]
      [(strong) (if (or (eq? kind 'strong) (zero? (rnd 2))) "**" "__")]
      [(strike) "~~"]))
  ;; items: 'word, 'code, 'link or (k items); siblings of a node never nest its kind
  (define (gen-items depth used)
    (define n (add1 (rnd 3)))
    (define kinds (filter (lambda (k) (and (not (memq k used)) (or strike? (not (eq? k 'strike)))))
                          '(emph strong strike)))
    (define raw
      (for/list ([i (in-range n)])
        (case (if (or (>= depth 3) (null? kinds)) (rnd 3) (rnd 6))
          [(0) 'word] [(1) (if (zero? (rnd 3)) 'code 'word)] [(2) (if (zero? (rnd 3)) 'link 'word)]
          [else
           (define k (list-ref kinds (rnd (length kinds))))
           (define kids (gen-items (add1 depth) (cons k used)))
           ;; the toggled kind over all of another node's content is written outside it
           (cons k (if (and (not (eq? k kind)) (= (length kids) 1) (pair? (car kids)) (eq? (caar kids) kind))
                       (append kids '(word))
                       kids))])))
    ;; a plain word between two nodes
    (let loop ([xs raw] [acc '()])
      (cond [(null? xs) (reverse acc)]
            [(and (pair? (car xs)) (pair? acc) (pair? (car acc))) (loop xs (cons 'word acc))]
            [else (loop (cdr xs) (cons (car xs) acc))])))
  (define (render items kinds)
    (for ([x (in-list items)] [i (in-naturals)])
      (define prev (and (> i 0) (list-ref items (sub1 i))))
      ;; emphasis written with `*` whose content is words may be glued to a word before it
      (define d (and (pair? x) (delim (car x))))
      (define glue? (and prev (eq? prev 'word) d (not (regexp-match? #rx"_" d))
                         (eq? (cadr x) 'word) (eq? (last x) 'word) (zero? (rnd 4))))
      (when (and (> i 0) (not glue?)) (write-string " " out))
      (cond
        [(eq? x 'word) (emit-word! (word) kinds)]
        [(eq? x 'code)
         (define s (file-position out))
         (write-string "`" out) (define w (word))
         (for ([c (in-string w)]) (set! seq (cons (cons c (sort (cons 'code kinds) symbol<?)) seq)))
         (write-string w out) (write-string "`" out)
         (set! units (cons (list s (file-position out)) units))]
        [(eq? x 'link)
         (define s (file-position out))
         (write-string "[" out) (define w (word))
         (for ([c (in-string w)]) (set! seq (cons (cons c (sort kinds symbol<?)) seq)))
         (write-string w out) (write-string "](/u)" out)
         (set! units (cons (list s (file-position out)) units))]
        [else
         (write-string d out)
         (render (cdr x) (cons (car x) kinds))
         (write-string d out)])))
  (render (gen-items 0 '()) '())
  (values (get-output-string out) (reverse seq) (reverse units)))

(test-case "toggle-emphasis-edits: generated nested markup, exact formatting, twice is the identity"
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng]) (random-seed 335))
  (define tried 0) (define well-formed 0) (define identities 0) (define refused 0)
  (for* ([exts (in-list (list no-extensions all-extensions))] [n (in-range 1500)])
    (parameterize ([current-exts exts])
      (define strike? (extension-set-strike exts))
      (define kind (list-ref (if strike? '(strong emph strike code) '(strong emph code)) (random (if strike? 4 3) rng)))
      (define-values (text seq units) (gen-nested rng kind strike?))
      (define doc (parse text))
      (set! tried (add1 tried))
      ;; skip the rare generated text that does not parse as written
      (when (equal? (content-kinds text doc) seq)
        (set! well-formed (add1 well-formed))
        (define i (random (length units) rng))
        ;; code only on one plain word: code makes markup inside it literal
        (define j (if (eq? kind 'code) i (+ i (random (min 4 (- (length units) i)) rng))))
        (define s (car (list-ref units i))) (define e (cadr (list-ref units j)))
        ;; (and not inside emphasis glued to a word: `x**`y`**` cannot be strong in CommonMark)
        (define lone-word? (and (regexp-match? #px"^[a-z]+$" (substring text s e))
                                (not (regexp-match? #px"[a-z][*~]+$" (substring text 0 s)))
                                (not (regexp-match? #px"^[*~]+[a-z]" (substring text e)))))
        (unless (and (eq? kind 'code) (not lone-word?))
          ;; the content characters selected, by index
          (define idx (for/list ([u (in-list units)] [c (in-naturals)] #:when (<= s (car u) (cadr u) e)) u))
          (define sel-idx
            (let loop ([us units] [k 0] [acc '()])
              (cond [(null? us) (reverse acc)]
                    [else
                     (define u (car us))
                     (define len (let ([w (substring text (car u) (cadr u))])
                                   (string-length (regexp-replace* #px"[`\\[\\]]|\\(/u\\)" w ""))))
                     (loop (cdr us) (+ k len)
                           (if (member u idx) (append (reverse (range k (+ k len))) acc) acc))])))
          (define had (for/list ([k (in-list sel-idx)]) (and (memq kind (cdr (list-ref seq k))) #t)))
          (define removing? (andmap values had))
          (define expected
            (for/list ([c (in-list seq)] [k (in-naturals)])
              (if (memv k sel-idx)
                  (cons (car c) (sort (if removing? (remq kind (cdr c)) (remove-duplicates (cons kind (cdr c)))) symbol<?))
                  c)))
          (define-values (t1 s1 e1) (toggle text s e kind))
          (with-check-info (['text text] ['selection (substring text s e)] ['kind kind] ['result t1])
            ;; (a toggle the markup cannot express, emphasis glued inside a word cut where it is
            ;; glued, leaves the text alone; rare)
            (if (and (equal? t1 text) (not (eq? kind 'code)))
                (set! refused (add1 refused))
                (check-equal? (content-kinds t1 (parse t1)) expected "exactly the selection changes"))
            ;; (where `*` would have joined a neighboring `*` run, a pair is written with `_`,
            ;; which toggling back keeps)
            (define (count-_ s) (length (regexp-match* #rx"_" s)))
            (when (and (or removing? (not (ormap values had))) (= (count-_ t1) (count-_ text)) (not (equal? t1 text)))
              (set! identities (add1 identities))
              (define-values (t2 s2 e2) (toggle t1 s1 e1 kind))
              (check-equal? t2 text "twice is the identity")))))))
  (check-true (> well-formed (* 0.9 tried)) (format "~a of ~a generated texts parse as written" well-formed tried))
  (check-true (> identities 1500) (format "~a identities checked" identities))
  (check-true (< (* 50 refused) well-formed) (format "~a of ~a toggles left alone" refused well-formed)))
