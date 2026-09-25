#lang racket/base
;; Position and coverage properties (design §5): for every fixture and every spec example --
;; children lie inside their parent's span, siblings are ordered and disjoint, and every
;; non-blank source character belongs to exactly one leaf block. Tokens are not yet populated
;; (mdlib-blocks doesn't emit them), so the token-containment/disjointness half of this property
;; is vacuous for now and will start exercising real data once mdlib-inlines lands.
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

(define (check-document! source)
  (define doc (parse-document source))
  (check-node! doc "doc")
  (check-coverage! doc source))

(test-case "positions: every spec example"
  (for ([e (in-list examples)])
    (check-document! (hash-ref e 'markdown))))

(test-case "positions: hand fixtures"
  (for ([s (in-list
            (list "" "\n" "no trailing newline"
                  "# H1\n\nplain *text* paragraph\n\n> quoted\n> more\n\n- a\n- b\n  - nested\n\n1. one\n2. two\n\n```lang\ncode here\n```\n\n    indented code\n\n---\n\nFoo\n===\n\nBar\n---\n\n<div>\nraw html\n</div>\n\n[ref]: /url \"title\"\n"
                  "a\tb\n>\t\tfoo\n-\t\tfoo\n"
                  "> a\n>> b\n>>> c\n"))])
    (check-document! s)))
