#lang racket/base
;; mdlib-runs (#322, design §4.1): for every spec example and the generated notes --
;; `style-runs` partitions the document (every character covered, runs non-overlapping and
;; maximal); each run's role stack equals an independent per-character oracle that walks the
;; tree down to the character (role-stacked: outermost first, `markup` innermost on tokens);
;; runs over a sub-range are the full runs clipped to it; `markup-tokens` returns every token,
;; disjoint and in order; `block-layouts` has one entry per leaf block and empty list item; and
;; `block-at` finds the innermost block. Plus hand-checked expectations on small documents.
(require json racket/list racket/runtime-path rackunit
         "../main.rkt" "notes-gen.rkt" "ext-corpus.rkt")

(define-runtime-path spec-path "spec/spec-0.31.2.json")
(define fixtures
  (append (map (lambda (e) (hash-ref e 'markdown)) (call-with-input-file spec-path read-json))
          (for/list ([s (in-range 6)]) (generate-notes 60 s))
          (list "> # H *e* `c`\n> ===\n>\n> - [l](/u \"t\") &amp; \\*\n\n[r]: <d> 't'\n\n---\n")))

(define (block-children b)
  (cond [(document? b) (document-children b)] [(block-quote? b) (block-quote-children b)]
        [(list-block? b) (list-block-children b)] [(list-item? b) (list-item-children b)]
        [(table? b) (append (table-head b) (apply append (table-rows b)))]
        [else '()]))
(define (inline-children x)
  (cond [(emph? x) (emph-children x)] [(strong? x) (strong-children x)] [(strike? x) (strike-children x)]
        [(link? x) (link-children x)] [(image? x) (image-children x)] [else '()]))
(define (span x) (if (block? x) (values (block-start x) (block-end x)) (values (inline-start x) (inline-end x))))
(define (tokens-of x) (if (block? x) (block-tokens x) (inline-tokens x)))
(define (children-of x)
  (cond [(block? x) (if (leaf-block? x) (block-inlines x) (block-children x))]
        [else (inline-children x)]))
(define (role-of x)
  (cond
    [(heading? x) (string->symbol (format "heading-~a" (heading-level x)))]
    [(code-block? x) 'code-block] [(html-block? x) 'html] [(block-quote? x) 'quote]
    [(thematic-break? x) 'markup] [(front-matter? x) 'front-matter]
    [(emph? x) 'emph] [(strong? x) 'strong] [(strike? x) 'strike] [(code-span? x) 'code]
    [(link? x) 'link] [(image? x) 'image] [(raw-html? x) 'html] [(wiki-link? x) 'wiki-link]
    [(tag? x) 'tag] [(date-ref? x) 'date] [(state-keyword? x) 'keyword]
    [else #f]))

;; The oracle: walk from the document to position p; a token of a node on the way ends the walk
;; (tokens are disjoint, and a container's token may sit inside its child's span); otherwise
;; descend into the child whose span holds p. Returns (values roles node).
(define (oracle doc p)
  (let loop ([x doc] [roles '()] [node #f])
    (define t (for/first ([t (in-list (tokens-of x))] #:when (<= (token-start t) p (sub1 (token-end t)))) t))
    (cond
      [t (values (append roles (if (memq (token-role t) '(link-dest refdef-dest)) '(link-dest markup) '(markup))) x)]
      [else
       (define c (for/first ([c (in-list (children-of x))]
                             #:when (let-values ([(s e) (span c)]) (<= s p (sub1 e))))
                   c))
       ;; a done or cancelled task item's first child carries the task role, outside its own
       (define task (and c (list-item? x) (eq? c (car (list-item-children x)))
                         (case (list-item-task x) [(done) 'task-done] [(cancelled) 'task-cancelled] [else #f])))
       (cond
         [c (define r (role-of c))
            (define added (append (if task (list task) '()) (if r (list r) '())))
            (loop c (append roles added) (if (pair? added) c node))]
         [else (values roles node)])])))

(define (check-runs! doc)
  (define text (document-text doc))
  (define len (string-length text))
  (define runs (style-runs doc))
  (when (> len 0)
    (check-equal? (run-start (first runs)) 0)
    (check-equal? (run-end (last runs)) len))
  (for ([r (in-list runs)])
    (check-true (< (run-start r) (run-end r)) (format "~s: empty run ~a" text r))
    (for ([role (in-list (run-roles r))])
      (check-not-false (memq role style-roles) (format "~s: unknown role ~a" text role))))
  (for ([a (in-list runs)] [b (in-list (if (null? runs) '() (cdr runs)))])
    (check-equal? (run-end a) (run-start b) (format "~s: runs ~a and ~a do not abut" text a b))
    (check-false (and (equal? (run-roles a) (run-roles b)) (eq? (run-node a) (run-node b)))
                 (format "~s: runs ~a and ~a are not maximal" text a b)))
  (for* ([r (in-list runs)] [p (in-range (run-start r) (run-end r))])
    (define-values (roles node) (oracle doc p))
    (unless (and (equal? roles (run-roles r)) (eq? node (run-node r)))
      (fail-check (format "~s at ~a: run ~a, oracle ~a ~a" text p r roles node))))
  ;; sub-ranges: the full runs clipped
  (for ([k (in-range 3)] #:when (> len 0))
    (define s (random len)) (define e (+ s (random (add1 (- len s)))))
    (define clipped (for/list ([r (in-list runs)] #:when (< (max s (run-start r)) (min e (run-end r))))
                      (run (max s (run-start r)) (min e (run-end r)) (run-roles r) (run-node r))))
    (check-equal? (style-runs doc #:start s #:end e) clipped (format "~s: runs over [~a,~a)" text s e))))

(define (all-tokens doc)
  (let loop ([x doc])
    (append (tokens-of x) (append-map loop (children-of x)))))

(define (check-tokens! doc)
  (define ts (markup-tokens doc))
  (check-equal? ts (sort (all-tokens doc) < #:key token-start))
  (for ([a (in-list ts)] [b (in-list (if (null? ts) '() (cdr ts)))])
    (check-true (<= (token-end a) (token-start b)) (format "tokens ~a and ~a overlap" a b))))

(define (leaves doc)
  (let loop ([b doc])
    (cond [(or (block-quote? b) (list-block? b) (document? b)) (append-map loop (block-children b))]
          [(list-item? b) (if (null? (list-item-children b)) (list b) (append-map loop (list-item-children b)))]
          [else (list b)])))

(define (check-layouts-and-block-at! doc)
  (define ls (block-layouts doc))
  (check-equal? (map (lambda (l) (cons (layout-start l) (layout-end l))) ls)
                (map (lambda (b) (cons (block-start b) (block-end b))) (leaves doc)))
  (define len (string-length (document-text doc)))
  (for ([p (in-range 0 (add1 len) 7)])
    (define expected
      (let loop ([kids (block-children doc)] [found #f])
        (define hit (for/first ([k (in-list kids)] #:when (<= (block-start k) p (block-end k))) k))
        (if hit (loop (block-children hit) hit) found)))
    (check-eq? (block-at doc p) expected)))

(test-case "runs, tokens, layouts over every spec example and the generated notes"
  (random-seed 322)
  (for ([f (in-list fixtures)])
    (define doc (parse-document f))
    (check-runs! doc)
    (check-tokens! doc)
    (check-layouts-and-block-at! doc)))

(define-runtime-path gfm-path "spec/gfm-0.29-extensions.json")
(test-case "runs, tokens, layouts with all extensions: spec and GFM examples, notes, the corpus"
  (random-seed 320)
  (for ([f (in-list (append fixtures ext-corpus
                            (map (lambda (e) (hash-ref e 'markdown)) (call-with-input-file gfm-path read-json))))])
    (define doc (parse-document f #:extensions all-extensions))
    (check-runs! doc)
    (check-tokens! doc)
    (check-layouts-and-block-at! doc)))

(define (roles-of doc) (map (lambda (r) (list (run-start r) (run-end r) (run-roles r))) (style-runs doc)))

(test-case "role stacks: heading, emphasis, markup innermost"
  (check-equal? (roles-of (parse-document "## a **b**\n"))
                '((0 2 (heading-2 markup)) (2 5 (heading-2)) (5 7 (heading-2 strong markup))
                  (7 8 (heading-2 strong)) (8 10 (heading-2 strong markup)) (10 11 ()))))

(test-case "a quote marker inside a heading's span keeps the quote's stack"
  (check-equal? (roles-of (parse-document "> Foo\n> ===\n"))
                '((0 1 (quote markup)) (1 2 (quote)) (2 6 (quote heading-1)) (6 7 (quote markup))
                  (7 8 (quote heading-1)) (8 11 (quote heading-1 markup)) (11 12 ()))))

(test-case "links: brackets and parentheses are markup, the destination is link-dest"
  (check-equal? (roles-of (parse-document "[a](/u)"))
                '((0 1 (link markup)) (1 2 (link)) (2 4 (link markup)) (4 6 (link link-dest markup))
                  (6 7 (link markup)))))

(test-case "block-layouts: depth, list level, numbering"
  (check-equal? (for/list ([l (block-layouts (parse-document "3. a\n\n   b\n4. > c\n\n-\n\n# h\n"))])
                  (list (layout-kind l) (layout-depth l) (layout-list-level l) (layout-ordered? l) (layout-number l)))
                '((paragraph 1 1 #t 3) (paragraph 1 1 #t #f) (paragraph 2 1 #t 4) (list-item 1 1 #f #f)
                  (heading-1 0 0 #f #f))))

(test-case "block-at: innermost block, end inclusive, #f between blocks"
  (define doc (parse-document "a\n\n> - b\n"))
  (check-true (paragraph? (block-at doc 1)))
  (check-false (block-at doc 2))
  (check-true (paragraph? (block-at doc 7)))
  (check-true (list-item? (block-at doc 6)))
  (check-true (block-quote? (block-at doc 4))))
