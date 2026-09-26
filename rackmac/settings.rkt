#lang racket/base
;; The one settings system (docs/REPLAN.md S6, "settings-core" #270): `define-setting`
;; registers a name with a contract, default, doc, category and scope; `setting-ref` resolves
;; document -> Language -> global, matching the office pattern of "this document" overriding
;; "this file type" overriding "everywhere". Pure (no GUI): it knows nothing about buffer% or
;; current-buffer, only about a `#:document` value it treats as an opaque eq?-comparable key
;; (a buffer instance in practice) and a `#:language` symbol (a mode name) -- callers supply
;; both explicitly, which keeps this module beneath buffer.rkt/editor.rkt so v0.4 can migrate
;; #:locals onto it later without a require cycle.
;;
;; Persistence of the global value to settings.rktd is "settings-store" (#271, a later commit).
(require racket/list "owner.rkt" "hook.rkt")
(provide define-setting setting-ref setting-set! find-setting all-settings
         setting-name setting-doc setting-category setting-scope setting-default setting-contract)

;; contract: a plain predicate (any/c -> boolean?), not a racket/contract value -- consistent
;; with #:when elsewhere in this codebase (command.rkt), and simple enough that a bad value can
;; always be reported instead of raised (below).
(struct setting (name contract default doc category scope) #:transparent)

(define registry (make-hasheq))            ; name -> setting
(define global-values (make-hasheq))       ; name -> current global value
(define language-overrides (make-hash))    ; (cons name language) -> value
;; A document is any value the caller treats as one (a buffer% instance in practice); a weak
;; hash means a closed document's overrides do not keep it alive or leak.
(define document-overrides (make-weak-hasheq))   ; document -> hasheq(name -> value)

;; Distinguishes "no override recorded" from "recorded, value is #f".
(define no-value (gensym 'no-value))
(define (hash-ref/found h k)
  (define v (hash-ref h k no-value))
  (values (not (eq? v no-value)) v))

(define (register-setting! name #:contract pred #:default default #:doc [doc ""]
                           #:category [category "General"] #:scope [scope 'global])
  (unless (and (procedure? pred) (procedure-arity-includes? pred 1))
    (raise-argument-error 'define-setting "(-> any/c boolean?)" pred))
  (unless (memq scope '(global document))
    (raise-argument-error 'define-setting "(or/c 'global 'document)" scope))
  (unless (pred default)
    (raise-argument-error 'define-setting "a #:default satisfying #:contract" default))
  (define old (hash-ref registry name #f))
  (hash-set! registry name (setting name pred default doc category scope))
  (unless (hash-has-key? global-values name) (hash-set! global-values name default))
  (register-undo! 'setting
                  (lambda ()
                    (if old (hash-set! registry name old) (hash-remove! registry name))
                    (hash-remove! global-values name)))
  (run-hook 'setting-registered name))

(define-syntax-rule (define-setting name kw ...) (register-setting! 'name kw ...))

(define (find-setting name) (hash-ref registry name #f))
(define (all-settings) (sort (hash-values registry) symbol<? #:key setting-name))

;; The value an override table has recorded for `name`, or #f/#f if none (never confused with
;; a stored value that happens to be #f, via hash-ref/found above).
(define (document-override doc name)
  (define h (and doc (hash-ref document-overrides doc #f)))
  (if h (hash-ref/found h name) (values #f #f)))
(define (language-override lang name)
  (if lang (hash-ref/found language-overrides (cons name lang)) (values #f #f)))

;; Resolution order: document -> Language -> global -> #:default. An unknown name is reported
;; (never raised, so a typo in a hook or a stale extension cannot crash a caller) and reads as #f.
(define (setting-ref name #:document [doc #f] #:language [lang #f])
  (define s (hash-ref registry name #f))
  (cond
    [(not s) (report-error! 'setting-ref (format "unknown setting ~a" name)) #f]
    [(not (eq? (setting-scope s) 'document)) (hash-ref global-values name (lambda () (setting-default s)))]
    [else
     (define-values (dfound? dval) (document-override doc name))
     (define-values (lfound? lval) (language-override lang name))
     (cond [dfound? dval]
           [lfound? lval]
           [else (hash-ref global-values name (lambda () (setting-default s)))])]))

;; Sets the value at the most specific level given (document, else Language, else global).
;; A #:document or #:language on a #:scope 'global setting, an unknown name, or a value that
;; fails the contract is reported to the Activity log and leaves the setting unchanged --
;; never raised, so a bad value from a script or a hand-edited init file cannot crash the
;; editor (docs/REPLAN.md: "contract violations report to Activity").
(define (setting-set! name val #:document [doc #f] #:language [lang #f])
  (define s (hash-ref registry name #f))
  (cond
    [(not s) (report-error! 'setting-set! (format "unknown setting ~a" name))]
    [(and (or doc lang) (not (eq? (setting-scope s) 'document)))
     (report-error! 'setting-set!
                    (format "~a is a global setting; it cannot be set per-document or per-Language" name))]
    [(not ((setting-contract s) val))
     (report-error! 'setting-set! (format "~a: ~v does not satisfy its contract" name val))]
    [doc
     (hash-update! document-overrides doc (lambda (h) (hash-set h name val)) hasheq)
     (run-hook 'setting-changed name)]
    [lang
     (hash-set! language-overrides (cons name lang) val)
     (run-hook 'setting-changed name)]
    [else
     (hash-set! global-values name val)
     (run-hook 'setting-changed name)]))
