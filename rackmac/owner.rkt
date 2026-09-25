#lang racket/base
;; Extension bookkeeping. While an extension file loads, everything it registers
;; (commands, hooks, key bindings, modes) records an "undo" here, so the extension can
;; be unloaded and a reload replaces it instead of piling up duplicates. Pure (no GUI).
(require "version.rkt")
(provide (struct-out extension) current-extension make-extension
         register-undo! unload-extension! declare-extension!)

(struct extension (name path [meta #:mutable] [undos #:mutable] [counts #:mutable]))

(define current-extension (make-parameter #f))

(define (make-extension name [path #f]) (extension name path (hasheq) '() (hasheq)))

;; Called by the registries. A no-op outside extension loading (e.g. for built-ins).
(define (register-undo! kind thunk)
  (define e (current-extension))
  (when e
    (set-extension-undos! e (cons thunk (extension-undos e)))      ; newest first
    (set-extension-counts! e (hash-update (extension-counts e) kind add1 0))))

(define (unload-extension! e)
  (for ([undo (in-list (extension-undos e))])
    (with-handlers ([exn:fail? void]) (undo)))
  (set-extension-undos! e '())
  (set-extension-counts! e (hasheq)))

;; Runtime half of (extension-info ...): records metadata and re-checks the API version.
(define (declare-extension! #:name [name #f] #:version [version #f]
                            #:requires-api [requires #f] #:doc [doc ""])
  (when (and requires (> requires api-version))
    (error 'extension-info "this extension needs Rackmac API ~a, but this is API ~a" requires api-version))
  (define e (current-extension))
  (when e
    (set-extension-meta! e (hasheq 'name name 'version version 'requires-api requires 'doc doc))))
