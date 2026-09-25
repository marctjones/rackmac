#lang racket/base
;; Named hooks. A failing hook function is reported and skipped, never propagated,
;; so one broken extension cannot take the editor down.
(require racket/list "owner.rkt")
(provide add-hook! remove-hook! run-hook error-reporter report-error!)

(define hooks (make-hasheq))   ; name -> list of (priority . proc), highest priority first

(define error-reporter
  (make-parameter
   (lambda (who e)
     (eprintf "~a: ~a\n" who (if (exn? e) (exn-message e) e)))))

(define (report-error! who e) ((error-reporter) who e))

(define (add-hook! name proc #:priority [priority 0])
  (define others (filter (lambda (p) (not (eq? (cdr p) proc))) (hash-ref hooks name '())))
  (hash-set! hooks name (sort (cons (cons priority proc) others) > #:key car))
  (register-undo! 'hook (lambda () (remove-hook! name proc))))

(define (remove-hook! name proc)
  (hash-set! hooks name (filter (lambda (p) (not (eq? (cdr p) proc))) (hash-ref hooks name '()))))

(define (run-hook name . args)
  (for ([p (in-list (hash-ref hooks name '()))])
    (with-handlers ([exn:fail? (lambda (e) (report-error! name e))])
      (apply (cdr p) args))))
