#lang racket/base
;; What the editor consumes (design §4.1): style runs, markup tokens, block layouts, and the
;; block at a position. `md-render` (#268) styles a document from `style-runs`; after an edit,
;; `md-restyle-region` (#266) calls it again over the change report's ranges only.
;;
;; `style-runs` partitions the requested range into maximal runs of characters that share a
;; role stack: the roles of the nodes enclosing the character, outermost first, with `markup`
;; innermost on a token's characters (`(heading-2 strong markup)` for the `**` of bold text in a
;; heading). Every character of the range is in exactly one run; a character no styled node
;; encloses (plain paragraph text, blank lines at top level) is in a run with roles '(), so a
;; consumer can set each run's complete style instead of first resetting the range.
;;
;; The stacks come from painting the range in tree order: each node that has a role paints its
;; span with its stack, its children paint over it, and its tokens paint last. A container's
;; tokens (the `>` of a block quote's later lines, which fall inside its paragraph's span) are
;; painted after the container's children, so they carry the container's stack plus `markup`,
;; never the paragraph's or heading's role.
(require racket/list
         "ast.rkt" "inlines.rkt")
(provide style-runs markup-tokens block-layouts block-at
         (struct-out run) (struct-out layout)
         style-roles)

;; roles: the role stack, outermost first; node: the innermost node that gave the run a role
;; (the token's owner for markup; #f for a run with no roles). A `keyword` run's node is the
;; state-keyword whose value it shows; a `link` run's node is the link.
(struct run (start end roles node) #:transparent)

;; One per leaf block (a text% paragraph run) and per empty list item: kind is 'paragraph,
;; 'heading-1 .. 'heading-6, 'code-block, 'html, 'thematic-break, 'link-ref-def, 'table,
;; 'front-matter or 'list-item (an item with no content); depth counts the enclosing block
;; quotes and list items, list-level the enclosing lists; ordered? is the innermost list's (#f
;; outside lists); number is the item's number on the first block of an ordered list item, else
;; #f.
(struct layout (start end kind depth list-level ordered? number) #:transparent)

;; The closed set of roles runs carry (design §4.1), exported so tests can check them.
(define style-roles
  '(heading-1 heading-2 heading-3 heading-4 heading-5 heading-6
    emph strong strike code code-block quote link link-dest image wiki-link tag date keyword
    task-done task-cancelled markup html front-matter))

(define heading-roles #(#f heading-1 heading-2 heading-3 heading-4 heading-5 heading-6))

(define (block-role b)
  (cond
    [(heading? b) (vector-ref heading-roles (heading-level b))]
    [(code-block? b) 'code-block]
    [(html-block? b) 'html]
    [(block-quote? b) 'quote]
    [(thematic-break? b) 'markup]
    [(front-matter? b) 'front-matter]
    [else #f]))

(define (inline-role x)
  (cond
    [(emph? x) 'emph] [(strong? x) 'strong] [(strike? x) 'strike] [(code-span? x) 'code]
    [(link? x) 'link] [(image? x) 'image] [(raw-html? x) 'html]
    [(wiki-link? x) 'wiki-link] [(tag? x) 'tag] [(date-ref? x) 'date]
    [(state-keyword? x) 'keyword]
    [else #f]))

(define (block-children b)
  (cond
    [(document? b) (document-children b)]
    [(block-quote? b) (block-quote-children b)]
    [(list-block? b) (list-block-children b)]
    [(list-item? b) (list-item-children b)]
    [(table? b) (append (table-head b) (apply append (table-rows b)))]
    [else '()]))

(define (inline-children x)
  (cond
    [(emph? x) (emph-children x)] [(strong? x) (strong-children x)] [(strike? x) (strike-children x)]
    [(link? x) (link-children x)] [(image? x) (image-children x)]
    [else '()]))

(define (leaf-inlines b)
  (cond
    [(paragraph? b) (cell-inlines (paragraph-inlines b))]
    [(heading? b) (cell-inlines (heading-inlines b))]
    [(table-cell? b) (cell-inlines (table-cell-inlines b))]
    [else '()]))

(define (document-length doc) (string-length (document-text doc)))

;; --- style-runs --------------------------------------------------------------------------------

(define (style-runs doc #:start [start 0] #:end [end (document-length doc)])
  (define s (min start (document-length doc)))
  (define e (max s (min end (document-length doc))))
  (define n (- e s))
  ;; Stacks are kept innermost first while painting (sharing tails); runs reverse them.
  (define stacks (make-vector n '()))
  (define owners (make-vector n #f))
  (define (paint! a b stack node)
    (for ([i (in-range (max 0 (- a s)) (min n (- b s)))])
      (vector-set! stacks i stack)
      (vector-set! owners i node)))
  (define (touches? a b) (and (< a e) (> b s)))
  (define (paint-tokens! tokens stack node)
    (for ([t (in-list tokens)] #:when (touches? (token-start t) (token-end t)))
      (paint! (token-start t) (token-end t)
              (case (token-role t)
                [(link-dest refdef-dest) (list* 'markup 'link-dest stack)]
                [else (cons 'markup stack)])
              node)))
  (define (walk-inline x stack node)
    (when (touches? (inline-start x) (inline-end x))
      (define role (inline-role x))
      (define stack2 (if role (cons role stack) stack))
      (define node2 (if role x node))
      (when role (paint! (inline-start x) (inline-end x) stack2 node2))
      (for ([c (in-list (inline-children x))]) (walk-inline c stack2 node2))
      (paint-tokens! (inline-tokens x) stack2 x)))
  (define (walk-block b stack node [extra #f])
    (when (or (document? b) (touches? (block-start b) (block-end b)))
      (define role (block-role b))
      (define stack1 (if extra (cons extra stack) stack))
      (define stack2 (if role (cons role stack1) stack1))
      (define node2 (if (or role extra) b node))
      (when (or role extra) (paint! (block-start b) (block-end b) stack2 node2))
      (cond
        [(or (paragraph? b) (heading? b) (table-cell? b))
         (for ([x (in-list (leaf-inlines b))]) (walk-inline x stack2 node2))]
        [(list-item? b)
         (define task-role (case (list-item-task b) [(done) 'task-done] [(cancelled) 'task-cancelled] [else #f]))
         (for ([c (in-list (list-item-children b))] [i (in-naturals)])
           (walk-block c stack2 node2 (and (= i 0) task-role)))]
        [else (for ([c (in-list (block-children b))]) (walk-block c stack2 node2))])
      (paint-tokens! (block-tokens b) stack2 b)))
  (walk-block doc '() #f)
  ;; Maximal runs of equal (stack, owner).
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i n) (reverse acc)]
      [else
       (define stack (vector-ref stacks i))
       (define node (vector-ref owners i))
       (define j (let scan ([j (add1 i)])
                   (if (and (< j n) (eq? (vector-ref owners j) node)
                            (let ([t (vector-ref stacks j)]) (or (eq? t stack) (equal? t stack))))
                       (scan (add1 j))
                       j)))
       (loop j (cons (run (+ s i) (+ s j) (reverse stack) node) acc))])))

;; --- markup-tokens -----------------------------------------------------------------------------

;; Every token (block and inline) that touches [start, end), whole, in position order. Tokens are
;; pairwise disjoint (tests/positions-test.rkt), so each can become one snip.
(define (markup-tokens doc #:start [start 0] #:end [end (document-length doc)])
  (define (touches? a b) (and (< a end) (> b start)))
  (define acc '())
  (define (take-tokens! ts)
    (for ([t (in-list ts)] #:when (touches? (token-start t) (token-end t))) (set! acc (cons t acc))))
  (define (walk-inline x)
    (when (touches? (inline-start x) (inline-end x))
      (take-tokens! (inline-tokens x))
      (for-each walk-inline (inline-children x))))
  (define (walk-block b)
    (when (or (document? b) (touches? (block-start b) (block-end b)))
      (take-tokens! (block-tokens b))
      (for-each walk-inline (leaf-inlines b))
      (for-each walk-block (block-children b))))
  (walk-block doc)
  (sort acc < #:key token-start))

;; --- block-layouts -----------------------------------------------------------------------------

(define (leaf-kind b)
  (cond
    [(paragraph? b) 'paragraph]
    [(heading? b) (vector-ref heading-roles (heading-level b))]
    [(code-block? b) 'code-block]
    [(html-block? b) 'html]
    [(thematic-break? b) 'thematic-break]
    [(link-ref-def? b) 'link-ref-def]
    [(table? b) 'table]
    [(front-matter? b) 'front-matter]
    [else #f]))

(define (block-layouts doc)
  (define acc '())
  ;; number: the item number still to hand to the first leaf of the current item, or #f.
  ;; Returns #f once a leaf has taken it.
  (define (walk b depth list-level ordered? number)
    (cond
      [(block-quote? b)
       (for/fold ([number number]) ([c (in-list (block-quote-children b))])
         (walk c (add1 depth) list-level ordered? number))]
      [(list-block? b)
       (for ([item (in-list (list-block-children b))] [k (in-naturals)])
         (define num (and (list-block-ordered? b) (+ (or (list-block-start-number b) 1) k)))
         (cond
           [(null? (list-item-children item))
            (set! acc (cons (layout (block-start item) (block-end item) 'list-item (add1 depth)
                                    (add1 list-level) (list-block-ordered? b) num)
                            acc))]
           [else
            (for/fold ([number num]) ([c (in-list (list-item-children item))])
              (walk c (add1 depth) (add1 list-level) (list-block-ordered? b) number))]))
       #f] ; a nested list's items number their own first blocks
      [else
       (set! acc (cons (layout (block-start b) (block-end b) (leaf-kind b) depth list-level ordered? number) acc))
       #f]))
  (for ([b (in-list (document-children doc))]) (walk b 0 0 #f #f))
  (reverse acc))

;; --- block-at ----------------------------------------------------------------------------------

;; The innermost block whose span contains `pos`, its end included (a caret after a paragraph's
;; last character is in that paragraph); #f between top-level blocks. Sibling blocks never touch
;; (each starts on a later line than the previous one ends), so the end-inclusive test is
;; unambiguous.
(define (block-at doc pos)
  (let loop ([kids (document-children doc)] [found #f])
    (define hit (for/first ([k (in-list kids)] #:when (<= (block-start k) pos (block-end k))) k))
    (if hit (loop (block-children hit) hit) found)))
