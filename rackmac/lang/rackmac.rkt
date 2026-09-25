#lang racket/base
;; The `rackmac` module language: racket/base plus the whole public extension API, so an
;; extension file is just
;;
;;     #lang rackmac
;;     (extension-info #:requires-api 1)
;;     (define-command (hello) (message "hi"))
;;
;; Differences from `#lang racket/base`:
;;   * no (require rackmac/api) needed;
;;   * module-level values are not printed (racket/base would print them to stdout);
;;   * `extension-info` declares metadata and is checked against the API version at COMPILE time.
(require (for-syntax racket/base syntax/parse "../version.rkt")
         "../api.rkt" "../owner.rkt")
(provide (except-out (all-from-out racket/base) #%module-begin)
         (all-from-out "../api.rkt")
         (rename-out [module-begin #%module-begin])
         extension-info)

(define-syntax-rule (module-begin form ...)
  (#%plain-module-begin form ...))

(define-syntax (extension-info stx)
  (syntax-parse stx
    [(_ (~or (~optional (~seq #:name n:str))
             (~optional (~seq #:version v:str))
             (~optional (~seq #:doc d:str))
             (~optional (~seq #:requires-api r:exact-positive-integer)))
        ...)
     #:fail-when (and (attribute r) (> (syntax-e (attribute r)) api-version) (attribute r))
     (format "this extension needs Rackmac API ~a, but this is API ~a"
             (syntax-e (attribute r)) api-version)
     #'(declare-extension! #:name (~? n #f) #:version (~? v #f)
                           #:requires-api (~? r #f) #:doc (~? d ""))]))
