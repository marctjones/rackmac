#lang racket/base
;; The incremental property (design §5, mdlib-parser #321): random edits (insertions, deletions,
;; replacements at random positions, with Markdown-significant text so they land inside fences,
;; list markers, block quotes, headings and reference definitions) applied to the fixtures;
;; after every edit `parser-reparse!` must equal `parse-document` on the new text (`equal?` on
;; the transparent structs: absolute positions and every inline tree included), and the change
;; report must be sound: every leaf block it does not name has the inline tree of the old leaf
;; it came from, shifted by the edit; every character outside the report's ranges, the spans of
;; the leaves it names and the inserted text has the role stack (`style-runs`) its old character
;; had; and every leaf outside the report's blocks keeps its layout (kind, depth, list level).
;;
;; 10,000 edits by default, from a fixed seed. To run more, or another seed:
;;   RACKMAC_MD_EDITS=200000 RACKMAC_MD_SEED=7 raco test rackmac-markdown/tests/incremental-test.rkt
;; A failure prints the seed, the text before the edit and the edit, which reproduce it.
(require json racket/list racket/string racket/runtime-path rackunit
         "../main.rkt" (only-in "../parser.rkt" leaf-blocks) (only-in "../inlines.rkt" cell-relative-inlines)
         "notes-gen.rkt" "ext-corpus.rkt")

(define-runtime-path spec-path "spec/spec-0.31.2.json")

(define edit-count (or (let ([v (getenv "RACKMAC_MD_EDITS")]) (and v (string->number v))) 10000))
(define seed (or (let ([v (getenv "RACKMAC_MD_SEED")]) (and v (string->number v))) 321))
(define edits-per-session 25)
(define max-length 4000)

(define spec-vector
  (for/vector ([e (in-list (call-with-input-file spec-path read-json))]) (hash-ref e 'markdown)))
(define notes-vector
  (list->vector
   (append
   (for/list ([s (in-range 12)]) (generate-notes 40 s))
   (list "# H1\n\nplain *text* paragraph\n\n> quoted\n> more\n\n- a\n- b\n  - nested\n\n1. one\n2. two\n\n```lang\ncode here\n```\n\n    indented code\n\n---\n\nFoo\n===\n\nBar\n---\n\n<div>\nraw html\n</div>\n\n[ref]: /url \"title\"\n"
         "[foo] and [bar][] and [baz][foo]\n\n[foo]: /f\n\n> [bar]: /b 'title'\n"
         "> a *b\n> c* d <span\n> class=\"x\">e</span> [l](/u\n> \"t\n> t\") `x\n> y`\n"
         "- a **b\n  c** \\\n  d  \n  e &amp; \\* <http://x.y> ![i *j*](/k)\n"))))

;; Text an edit inserts: Markdown syntax more often than prose.
(define snippets
  '("\n" "\n\n" " " "  " "\t" "a" "word" "> " ">" "- " "* " "+ " "1. " "2) " "# " "## " "###"
    "```" "~~~" "```x\n" "    " "===" "---" "***" "*" "**" "_" "__" "`" "``" "[" "]" "[x]" "](" ")"
    "(" "<" ">" "<div>" "</div>" "<!--" "-->" "\\" "&amp;" "&" "!" "[foo]: /url\n" "[bar]: /b \"t\"\n"
    "[foo]" "[bar][]" "<http://a.b>" "  \n" "\n- x\n" "\n> y\n" "\n    z\n" "\n\n# h\n\n"
    ;; extension syntax (design §2.3), for the sessions with extensions on
    "|" " | " "| a | b |\n" "|---|---|\n" "\n| - |\n" ":-:" "\\|" "~" "~~" "[[" "]]" "[[a|b]]" "#" "#tag"
    "2026-09-30" "due " "[ ] " "[x] " "[-]" "- [ ] " "---\n" "...\n" "a: 1\n" "TODO " "DONE "
    "www." "www.a.b" "http://x.y/(z)" "@" "a@b.c" "."))

;; --- the soundness check for the change report ------------------------------------------------

;; An inline tree as nested lists with positions relative to `base`, so trees can be compared
;; across a shift.
(define (relative x base)
  (cond
    [(token? x) (list (token-role x) (- (token-start x) base) (- (token-end x) base))]
    [(inline? x)
     (define v (struct->vector x))
     (for/list ([f (in-vector v)] [i (in-naturals)])
       (cond [(memv i '(1 2)) (- f base)]
             [(list? f) (for/list ([y (in-list f)]) (relative y base))]
             [else f]))]
    [else x]))

(define (check-report-sound! old new e rep)
  (define es (edit-start e)) (define ee (edit-end e))
  (define delta (- (string-length (edit-text e)) (- ee es)))
  (define len (string-length (document-text new)))
  ;; ranges: sorted, disjoint, inside the document
  (for/fold ([prev -1]) ([r (in-list (change-report-ranges rep))])
    (check-true (and (< prev (car r)) (< (car r) (cdr r)) (<= (cdr r) len)) (format "bad range ~a" r))
    (cdr r))
  (define new-leaves (leaf-blocks new))
  (define reported (make-hasheq))
  (for ([b (in-list (change-report-inline-changed rep))])
    (check-not-false (memq b new-leaves) "inline-changed names a leaf of the new document")
    (hash-set! reported b #t))
  (define old-by-new-start
    (for/hash ([b (in-list (leaf-blocks old))]
               #:when (or (<= (block-end b) es) (>= (block-start b) ee)))
      (values (if (>= (block-start b) ee) (+ (block-start b) delta) (block-start b)) b)))
  (for ([b (in-list new-leaves)] #:unless (hash-ref reported b #f))
    (define o (hash-ref old-by-new-start (block-start b) #f))
    (check-not-false o (format "unreported leaf at ~a has no old counterpart" (block-start b)))
    (when o
      (check-equal? (map (lambda (x) (relative x (block-start b))) (block-inlines b))
                    (map (lambda (x) (relative x (block-start o))) (block-inlines o))
                    (format "unreported leaf at ~a changed its inlines" (block-start b)))))
  ;; role stacks, character by character
  (define (roles-vector doc)
    (define v (make-vector (string-length (document-text doc)) #f))
    (for* ([r (in-list (style-runs doc))] [i (in-range (run-start r) (run-end r))]) (vector-set! v i (run-roles r)))
    v)
  (define old-roles (roles-vector old))
  (define new-roles (roles-vector new))
  (define restyled (make-vector len #f))
  (define (mark! s e) (for ([i (in-range s (min e len))]) (vector-set! restyled i #t)))
  (for ([r (in-list (change-report-ranges rep))]) (mark! (car r) (cdr r)))
  (for ([b (in-list (change-report-inline-changed rep))]) (mark! (block-start b) (block-end b)))
  (define ins-end (+ es (string-length (edit-text e))))
  (mark! es ins-end)
  (for ([p (in-range len)] #:unless (vector-ref restyled p))
    (define q (if (< p es) p (- p delta)))
    (unless (equal? (vector-ref new-roles p) (vector-ref old-roles q))
      (fail-check (format "unreported restyle at ~a: ~a, was ~a at ~a" p (vector-ref new-roles p) (vector-ref old-roles q) q))))
  ;; layouts of leaves outside the report's blocks
  (define (inside-reported? l)
    (for/or ([b (in-list (change-report-blocks rep))]) (<= (block-start b) (layout-start l) (block-end b))))
  (define old-layouts
    (for/hash ([l (in-list (block-layouts old))]
               #:when (or (< (layout-start l) es) (>= (layout-start l) ee)))
      (values (if (>= (layout-start l) ee) (+ (layout-start l) delta) (layout-start l)) l)))
  (for ([l (in-list (block-layouts new))] #:unless (inside-reported? l))
    (define o (hash-ref old-layouts (layout-start l) #f))
    (check-not-false o (format "unreported layout at ~a has no old counterpart" (layout-start l)))
    (when o
      (check-equal? (list (layout-kind l) (layout-depth l) (layout-list-level l) (layout-ordered? l))
                    (list (layout-kind o) (layout-depth o) (layout-list-level o) (layout-ordered? o))
                    (format "unreported layout change at ~a" (layout-start l))))))

;; --- the property -------------------------------------------------------------------------------

(define (random-edit text rng)
  (define len (string-length text))
  (define (rnd n) (random n rng))
  (define pos (rnd (add1 len)))
  (define (snippet) (list-ref snippets (rnd (length snippets))))
  (define kind (if (> len max-length) 'delete (case (rnd 10) [(0 1 2) 'delete] [(3 4) 'replace] [else 'insert])))
  (case kind
    [(insert) (edit pos pos (snippet))]
    [(delete) (edit pos (min len (+ pos 1 (rnd (if (= 0 (rnd 5)) 60 6)))) "")]
    [(replace) (edit pos (min len (+ pos 1 (rnd 8))) (snippet))]))

(define (apply-edit text e)
  (string-append (substring text 0 (edit-start e)) (edit-text e) (substring text (edit-end e))))

(define (run-sessions! exts count seed starts)
  (define rng (make-pseudo-random-generator))
  (parameterize ([current-pseudo-random-generator rng]) (random-seed seed))
  (let session ([done 0])
    (when (< done count)
      (define p (make-parser #:extensions exts))
      (define start-text (starts rng))
      (parser-parse! p start-text)
      (define n (min edits-per-session (- count done)))
      (for/fold ([text start-text]) ([i (in-range n)])
        (define e (random-edit text rng))
        (define new-text (apply-edit text e))
        (define old (parser-document p))
        (define-values (doc rep) (parser-reparse! p new-text e))
        (define expected (parse-document new-text #:extensions exts))
        (unless (equal? doc expected)
          (fail-check (format "reparse != parse (seed ~a)\ntext: ~s\nedit: ~s" seed text e)))
        (with-check-info (['seed seed] ['text text] ['edit e])
          (check-report-sound! old doc e rep))
        new-text)
      (session (+ done n)))))

(test-case (format "incremental: ~a random edits, reparse == parse (seed ~a)" edit-count seed)
  ;; half the sessions on a spec example, half on generated notes and the hand fixtures
  (run-sessions! no-extensions edit-count seed
                 (lambda (rng)
                   (if (= 0 (random 2 rng))
                       (vector-ref spec-vector (random (vector-length spec-vector) rng))
                       (vector-ref notes-vector (random (vector-length notes-vector) rng))))))

;; mdlib-ext (#320): the same property with every extension on, starting from the extension
;; corpus half the time.
(define ext-vector (list->vector ext-corpus))
(test-case (format "incremental with all extensions: ~a random edits (seed ~a)" edit-count (add1 seed))
  (run-sessions! all-extensions edit-count (add1 seed)
                 (lambda (rng)
                   (case (random 4 rng)
                     [(0) (vector-ref spec-vector (random (vector-length spec-vector) rng))]
                     [(1) (vector-ref notes-vector (random (vector-length notes-vector) rng))]
                     [else (vector-ref ext-vector (random (vector-length ext-vector) rng))]))))

;; --- targeted cases ------------------------------------------------------------------------------

(define (reparse p text e) (parser-reparse! p (apply-edit text e) e))

(test-case "first reparse without a previous parse reports everything"
  (define p (make-parser))
  (define-values (doc rep) (parser-reparse! p "# a\n\nb\n" (edit 0 0 "")))
  (check-equal? (change-report-ranges rep) '((0 . 7)))
  (check-equal? (length (change-report-inline-changed rep)) 2)
  (check-true (change-report-structure-changed? rep)))

(test-case "an edit that does not match the last parse is rejected"
  (define p (make-parser))
  (parser-parse! p "abc\n")
  (check-exn exn:fail:contract? (lambda () (parser-reparse! p "abcd\n" (edit 0 1 "")))))

(test-case "typing in one paragraph re-parses and reports only that paragraph"
  (define text (generate-notes 400 3))
  (define p (make-parser))
  (define old (parser-parse! p text))
  (for-each block-inlines (leaf-blocks old)) ; what md-render does; only forced trees are memoized
  (define target (list-ref (filter paragraph? (document-children old)) 10))
  (define pos (sub1 (block-end target)))
  (define-values (doc rep) (reparse p text (edit pos pos "x")))
  (check-equal? (length (change-report-inline-changed rep)) 1)
  (check-false (change-report-structure-changed? rep))
  (check-false (change-report-refmap-changed? rep))
  (check-equal? (change-report-ranges rep) (list (cons (block-start target) (add1 (block-end target)))))
  ;; every other leaf's inline tree is the memo's object, not a fresh parse
  (define (cell b) (if (heading? b) (heading-inlines b) (paragraph-inlines b)))
  (for ([o (in-list (leaf-blocks old))] [n (in-list (leaf-blocks doc))]
        #:unless (memq n (change-report-inline-changed rep)))
    (check-eq? (cell-relative-inlines (cell o)) (cell-relative-inlines (cell n)))))

(test-case "a paragraph edited to equal another one is still reported (a memo hit, new styling)"
  (define text "*a*\n\nb\n")
  (define p (make-parser))
  (parser-parse! p text)
  (define-values (doc rep) (reparse p text (edit 5 6 "*a*")))
  (check-equal? (map block-start (change-report-inline-changed rep)) '(5))
  (check-equal? (change-report-ranges rep) '((5 . 8))))

(test-case "a definition added after its use re-parses the earlier block"
  (define text "[foo]\n\nx\n")
  (define p (make-parser))
  (parser-parse! p text)
  (define-values (doc rep) (reparse p text (edit 9 9 "\n[foo]: /u\n")))
  (check-true (change-report-refmap-changed? rep))
  (check-true (link? (car (block-inlines (car (document-children doc))))))
  (check-equal? (length (change-report-inline-changed rep)) 2))

(test-case "opening a fence restyles everything after it"
  (define text "a\n\nb\n\n- c\n")
  (define p (make-parser))
  (parser-parse! p text)
  (define-values (doc rep) (reparse p text (edit 0 0 "```\n")))
  (check-true (change-report-structure-changed? rep))
  (check-equal? (change-report-ranges rep) (list (cons 0 (block-end (car (document-children doc)))))))

(test-case "typing inside a long list reports the item's paragraph, not the list"
  (define text (string-append* (for/list ([i 200]) (format "- item ~a\n" i))))
  (define p (make-parser))
  (parser-parse! p text)
  (define pos (+ (caar (regexp-match-positions #rx"- item 100\n" text)) 4))
  (define-values (doc rep) (reparse p text (edit pos pos "z")))
  (check-false (change-report-structure-changed? rep))
  (check-equal? (length (change-report-inline-changed rep)) 1)
  (check-true (< (- (cdr (car (change-report-ranges rep))) (car (car (change-report-ranges rep)))) 20)))

(test-case "typing in a note with front matter and a table reports only the edited paragraph"
  (define text (string-append ext-note "\n" (generate-notes 200 5)))
  (define p (make-parser #:extensions all-extensions))
  (define old (parser-parse! p text))
  (for-each block-inlines (leaf-blocks old))
  (define target (list-ref (filter paragraph? (document-children old)) 8))
  (define pos (sub1 (block-end target)))
  (define-values (doc rep) (reparse p text (edit pos pos "x")))
  (check-equal? (length (change-report-inline-changed rep)) 1)
  (check-false (change-report-structure-changed? rep))
  (check-equal? (change-report-ranges rep) (list (cons (block-start target) (add1 (block-end target)))))
  ;; the front matter and the table matched their old selves: only the paragraph is reported
  (check-true (for/and ([b (in-list (change-report-blocks rep))]) (paragraph? b))))
