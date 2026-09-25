#lang racket/base
;; Named HTML entities, vendored from the WHATWG entities.json table (entities.rktd).
;; CommonMark only recognizes the semicolon-terminated form (spec, "Entities and numeric
;; character references"), so `entity-lookup` requires the trailing `;` in `name`.
(require racket/runtime-path)
(provide entity-lookup entity-table)

(define-runtime-path entities-data-path "entities.rktd")

;; Loaded once, lazily, so requiring this module has no I/O cost until an entity is looked up.
(define entity-table
  (let ([cache #f])
    (lambda ()
      (unless cache
        (set! cache (call-with-input-file entities-data-path read)))
      cache)))

;; name includes the trailing `;` (and excludes the leading `&`), e.g. "amp;", "frac34;".
;; Returns the decoded character string, or #f if `name` is not a known entity.
(define (entity-lookup name)
  (hash-ref (entity-table) name #f))
