#lang racket/base
;; The version of the public extension API. Bump when `rackmac/api` changes incompatibly;
;; extensions declare the version they need with (extension-info #:requires-api N).
(provide api-version)
(define api-version 1)
