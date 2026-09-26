#lang racket/base
;; The version of the public extension API. Bump when `rackmac/api` changes incompatibly;
;; extensions declare the version they need with (extension-info #:requires-api N).
;; app-version is the app's own release number (numbers and dots only: it becomes the app
;; bundle's CFBundleShortVersionString, #286). Rackmac stays below 1.0.
(provide api-version app-version)
(define api-version 1)
(define app-version "0.3.0")
