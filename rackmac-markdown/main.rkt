#lang racket/base
;; Public API (design §6.2), the slice built so far: parsing, the parser object with its inline
;; memo and change report (mdlib-parser), `block-inlines`, what the editor consumes --
;; `style-runs`, `markup-tokens`, `block-layouts`, `block-at` (mdlib-runs) -- the HTML renderer,
;; line/column conversion, and the token-based edit operations (mdlib-edits, edits.rkt).
(require racket/contract/base
         "ast.rkt" "blocks.rkt" "edits.rkt" "html.rkt" "inlines.rkt" "parser.rkt" "runs.rkt"
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
                                exact-nonnegative-integer?)]
          ;; edit operations (edits.rkt): edits sorted, non-overlapping, offsets into the old text
          [apply-edits (-> string? (listof edit?) string?)]
          [map-position (->* ((listof edit?) exact-nonnegative-integer?) ((or/c 'after 'before))
                             exact-nonnegative-integer?)]
          [toggle-emphasis-edits (-> document? exact-nonnegative-integer? exact-nonnegative-integer?
                                     (or/c 'emph 'strong 'strike 'code)
                                     (values (listof edit?) exact-nonnegative-integer? exact-nonnegative-integer?))]
          [set-heading-level-edits (-> document? exact-nonnegative-integer? exact-nonnegative-integer?
                                       (integer-in 0 6) (listof edit?))]
          [toggle-list-edits (-> document? exact-nonnegative-integer? exact-nonnegative-integer?
                                 (or/c 'bullet 'ordered 'task) (listof edit?))]
          [toggle-quote-edits (-> document? exact-nonnegative-integer? exact-nonnegative-integer? (listof edit?))]
          [list-enter-edits (-> document? exact-nonnegative-integer?
                                (values (or/c #f (listof edit?)) (or/c #f exact-nonnegative-integer?)))]
          [indent-list-edits (-> document? exact-nonnegative-integer? exact-nonnegative-integer? (listof edit?))]
          [outdent-list-edits (-> document? exact-nonnegative-integer? exact-nonnegative-integer? (listof edit?))]
          [toggle-task-edits (-> document? exact-nonnegative-integer? (listof edit?))]
          [set-task-edits (-> document? exact-nonnegative-integer? (or/c 'open 'done 'cancelled) (listof edit?))]))

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
