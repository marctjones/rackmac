#lang racket/base
;; Public API (design §6.2). This is the mdlib-pkg/mdlib-blocks slice of the eventual surface:
;; block parsing, the block-level HTML renderer, and line/column conversion. `block-inlines`,
;; `style-runs`, `markup-tokens`, the parser/memo object, and the edit operations arrive with
;; mdlib-inlines, mdlib-runs, mdlib-parser, and mdlib-edits.
(require racket/contract/base
         "ast.rkt" "blocks.rkt" "html.rkt"
         (rename-in "lines.rkt"
                    [offset->line+col offset->line+col/index]
                    [line+col->offset line+col->offset/index]))

(provide (all-from-out "ast.rkt")
         (contract-out
          [parse-document (->* (string?) (#:extensions extension-set?) document?)]
          [document-blocks (-> document? (listof block?))]
          [document->html (->* (document?) (#:unsafe? boolean?) string?)]
          [offset->line+col (-> document? exact-nonnegative-integer?
                                 (values exact-nonnegative-integer? exact-nonnegative-integer?))]
          [line+col->offset (-> document? exact-nonnegative-integer? exact-nonnegative-integer?
                                exact-nonnegative-integer?)]))

(define (parse-document text #:extensions [extensions no-extensions])
  (parse-blocks text #:extensions extensions))

(define (document-blocks doc) (document-children doc))

(define (offset->line+col doc offset)
  (offset->line+col/index (document-line-index doc) offset))

(define (line+col->offset doc line col)
  (line+col->offset/index (document-line-index doc) line col))
