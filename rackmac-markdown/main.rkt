#lang racket/base
;; Public API (design §6.2), the slice built so far: parsing, the parser object with its inline
;; memo and change report (mdlib-parser), `block-inlines`, what the editor consumes --
;; `style-runs`, `markup-tokens`, `block-layouts`, `block-at` (mdlib-runs) -- the HTML renderer,
;; and line/column conversion. The edit operations arrive with mdlib-edits.
(require racket/contract/base
         "ast.rkt" "blocks.rkt" "html.rkt" "inlines.rkt" "parser.rkt" "runs.rkt"
         (rename-in "lines.rkt"
                    [offset->line+col offset->line+col/index]
                    [line+col->offset line+col->offset/index]))

(provide (all-from-out "ast.rkt")
         leaf-block?
         parser? (struct-out change-report)
         (struct-out run) (struct-out layout) style-roles
         (contract-out
          [parse-document (->* (string?) (#:extensions extension-set?) document?)]
          [make-parser (->* () (#:extensions extension-set?) parser?)]
          [parser-parse! (-> parser? string? document?)]
          [parser-reparse! (-> parser? string? edit? (values document? change-report?))]
          [parser-document (-> parser? (or/c document? #f))]
          [document-blocks (-> document? (listof block?))]
          [block-inlines (-> leaf-block? (listof inline?))]
          [block-at (-> document? exact-nonnegative-integer? (or/c block? #f))]
          [style-runs (->* (document?) (#:start exact-nonnegative-integer? #:end exact-nonnegative-integer?)
                           (listof run?))]
          [markup-tokens (->* (document?) (#:start exact-nonnegative-integer? #:end exact-nonnegative-integer?)
                              (listof token?))]
          [block-layouts (-> document? (listof layout?))]
          [document->html (->* (document?) (#:unsafe? boolean?) string?)]
          [offset->line+col (-> document? exact-nonnegative-integer?
                                 (values exact-nonnegative-integer? exact-nonnegative-integer?))]
          [line+col->offset (-> document? exact-nonnegative-integer? exact-nonnegative-integer?
                                exact-nonnegative-integer?)]))

(define (parse-document text #:extensions [extensions no-extensions])
  (parse-blocks text #:extensions extensions))

(define (document-blocks doc) (document-children doc))

;; A block with inline content (tables' cells join this with mdlib-ext).
(define (leaf-block? b) (or (paragraph? b) (heading? b)))

;; The block's inline nodes with absolute (document) offsets, parsed and relocated on first
;; request and cached on the block (design §1.3).
(define (block-inlines b)
  (cell-inlines (if (paragraph? b) (paragraph-inlines b) (heading-inlines b))))

(define (offset->line+col doc offset)
  (offset->line+col/index (document-line-index doc) offset))

(define (line+col->offset doc line col)
  (line+col->offset/index (document-line-index doc) line col))
