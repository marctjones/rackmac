#lang racket/base
;; Public API (design §6.2). This is the mdlib-pkg/mdlib-blocks/mdlib-inlines slice of the
;; eventual surface: parsing, `block-inlines`, the HTML renderer, and line/column conversion.
;; `style-runs`, `markup-tokens`, the parser/memo object, and the edit operations arrive with
;; mdlib-runs, mdlib-parser, and mdlib-edits.
(require racket/contract/base
         "ast.rkt" "blocks.rkt" "html.rkt" "inlines.rkt"
         (rename-in "lines.rkt"
                    [offset->line+col offset->line+col/index]
                    [line+col->offset line+col->offset/index]))

(provide (all-from-out "ast.rkt")
         leaf-block?
         (contract-out
          [parse-document (->* (string?) (#:extensions extension-set?) document?)]
          [document-blocks (-> document? (listof block?))]
          [block-inlines (-> leaf-block? (listof inline?))]
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
