#lang racket/base
;; Position and coverage properties (design §5): for every fixture and every spec example --
;; children lie inside their parent's span, siblings are ordered and disjoint, and every
;; non-blank source character belongs to exactly one leaf block. For inline content
;; (mdlib-inlines): every inline node of a leaf lies inside the leaf's span; siblings are ordered
;; and disjoint and lie inside their parent; every token lies inside its node; all tokens of a
;; leaf's subtree are pairwise disjoint; no token covers a container prefix or line ending; and a
;; token-free text node's source slice is its value (relocation through segments is exact).
(require json racket/list racket/string racket/runtime-path rackunit
         "../main.rkt" "../ast.rkt")

(define-runtime-path spec-path "spec/spec-0.31.2.json")
(define examples (call-with-input-file spec-path read-json))

(define (block-children b)
  (cond
    [(block-quote? b) (block-quote-children b)]
    [(list-block? b) (list-block-children b)]
    [(list-item? b) (list-item-children b)]
    [(document? b) (document-children b)]
    [else '()]))

(define (leaf? b)
  (or (paragraph? b) (heading? b) (thematic-break? b) (code-block? b) (html-block? b)
      (link-ref-def? b)))

;; Checks: b's span is [start, end), start <= end; every child's span lies within b's; children
;; are ordered and pairwise disjoint (next child's start >= previous child's end).
(define (check-node! b path)
  (define s (block-start b)) (define e (block-end b))
  (check-true (<= s e) (format "~a: start <= end (~a)" path b))
  (define kids (block-children b))
  (for/fold ([prev-end s]) ([k (in-list kids)] [i (in-naturals)])
    (define ks (block-start k)) (define ke (block-end k))
    (check-true (>= ks s) (format "~a child ~a: start >= parent start" path i))
    (check-true (<= ke e) (format "~a child ~a: end <= parent end" path i))
    (check-true (>= ks prev-end) (format "~a child ~a: starts before previous child ends" path i))
    (check-node! k (format "~a>~a" path i))
    ke)
  (void))

;; Every non-blank character of `source` belongs to some block's [start,end) span: a leaf's, if
;; it's content, or (until mdlib-inlines/mdlib-runs give bullets, quote markers, and heading
;; markers their own tokens) a container's or heading's own span, if it's markup. Document's own
;; span is excluded from this (it trivially covers everything and would make the check vacuous).
(define (all-non-document-nodes doc)
  (let loop ([b doc])
    (append (if (document? b) '() (list b)) (append-map loop (block-children b)))))

(define (check-coverage! doc source)
  (define len (string-length source))
  (define covered (make-vector len #f))
  (for ([b (in-list (all-non-document-nodes doc))])
    (for ([i (in-range (max 0 (block-start b)) (min len (block-end b)))])
      (vector-set! covered i #t)))
  (for ([i (in-range len)])
    (unless (or (vector-ref covered i) (char-whitespace? (string-ref source i)))
      (fail-check (format "uncovered non-blank char ~s at offset ~a" (string-ref source i) i)))))

(define (inline-children x)
  (cond
    [(emph? x) (emph-children x)] [(strong? x) (strong-children x)]
    [(link? x) (link-children x)] [(image? x) (image-children x)]
    [else '()]))

;; Checks one inline node against its parent's [lo, hi); returns the tokens of its subtree.
(define (check-inline! x lo hi source where)
  (define s (inline-start x)) (define e (inline-end x))
  (check-true (<= lo s e hi) (format "~a: inline ~a [~a,~a) not inside [~a,~a)" where x s e lo hi))
  (for ([t (in-list (inline-tokens x))])
    (check-true (<= s (token-start t) (token-end t) e)
                (format "~a: token ~a outside its node [~a,~a)" where t s e))
    (check-false (for/or ([c (in-string source (token-start t) (token-end t))]) (eqv? c #\newline))
                 (format "~a: token ~a covers a line ending" where t)))
  (when (and (text? x) (null? (inline-tokens x))
             (not (for/or ([c (in-string source s e)]) (eqv? c #\tab))))
    (check-equal? (text-value x) (substring source s e) (format "~a: text slice" where)))
  (append (inline-tokens x) (check-inline-list! (inline-children x) s e source where)))

(define (check-inline-list! xs lo hi source where)
  (let loop ([xs xs] [prev-end lo] [acc '()])
    (cond
      [(null? xs) acc]
      [else
       (define x (car xs))
       (check-true (>= (inline-start x) prev-end)
                   (format "~a: inline ~a starts before its previous sibling ends (~a)" where x prev-end))
       (loop (cdr xs) (inline-end x) (append (check-inline! x lo hi source where) acc))])))

(define (check-leaf-inlines! doc source)
  (for ([b (in-list (all-non-document-nodes doc))] #:when (leaf-block? b))
    (define where (format "~s block [~a,~a)" source (block-start b) (block-end b)))
    (define tokens (sort (check-inline-list! (block-inlines b) (block-start b) (block-end b) source where)
                         < #:key token-start))
    (for ([a (in-list tokens)] [c (in-list (if (null? tokens) '() (cdr tokens)))])
      (check-true (<= (token-end a) (token-start c))
                  (format "~a: tokens ~a and ~a overlap" where a c)))
    ;; Every token lies within one segment's source text, so it never covers a container
    ;; prefix (`> `, list indentation) or a line ending (design §1.3).
    (define segs (if (paragraph? b) (paragraph-segments b) (heading-segments b)))
    (for ([t (in-list tokens)])
      (check-true (for/or ([g (in-list segs)])
                    (<= (segment-source-start g) (token-start t) (token-end t)
                        (+ (segment-source-start g) (segment-source-length g))))
                  (format "~a: token ~a is not inside one segment" where t)))))

(define (check-document! source)
  (define doc (parse-document source))
  (check-node! doc "doc")
  (check-coverage! doc source)
  (check-leaf-inlines! doc source)
  (check-equal? doc (parse-document source) "parsing is deterministic and equal? is structural"))

(test-case "positions: every spec example"
  (for ([e (in-list examples)])
    (check-document! (hash-ref e 'markdown))))

(test-case "positions: hand fixtures"
  (for ([s (in-list
            (list "" "\n" "no trailing newline"
                  "# H1\n\nplain *text* paragraph\n\n> quoted\n> more\n\n- a\n- b\n  - nested\n\n1. one\n2. two\n\n```lang\ncode here\n```\n\n    indented code\n\n---\n\nFoo\n===\n\nBar\n---\n\n<div>\nraw html\n</div>\n\n[ref]: /url \"title\"\n"
                  "a\tb\n>\t\tfoo\n-\t\tfoo\n"
                  "> a\n>> b\n>>> c\n"
                  ;; inline content across container prefixes (design §1.3)
                  "> a *b\n> c* d <span\n> class=\"x\">e</span> [l](/u\n> \"t\n> t\") `x\n> y`\n"
                  "- a **b\n  c** \\\n  d  \n  e &amp; \\* <http://x.y> ![i *j*](/k)\n"
                  ">\tfoo *bar*\n"))])
    (check-document! s)))
