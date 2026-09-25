#lang racket/base
;; Run with:  racket main.rkt [file ...]
;; Puts this directory on the collection path so init files can (require rackmac/api).
;; RACKMAC_NO_FRONT=1 opens the window without taking keyboard focus.
(require "rackmac/no-front.rkt")
(define here
  (let-values ([(base name dir?)
                (split-path (resolved-module-path-name
                             (variable-reference->resolved-module-path (#%variable-reference))))])
    base))

(current-library-collection-paths (cons here (current-library-collection-paths)))

((dynamic-require (build-path here "rackmac" "app.rkt") 'main)
 (vector->list (current-command-line-arguments)))
