#lang racket/base
;; Major and minor modes. A mode bundles a keymap, buffer-local defaults, file
;; patterns, enable/disable hooks and a highlighter. Modes inherit through `parent`.
;; Pure (no GUI).
(require racket/list racket/string "keymap.rkt" "hook.rkt" "owner.rkt")
(provide (struct-out mode) define-mode register-mode! find-mode all-modes mode-display-name
         mode-chain mode-keymaps mode-local find-highlighter mode-for-path mode-user-keymap)

(struct mode (name kind parent keymap files locals on-enable on-disable highlighter doc label))

(define modes (make-hasheq))

(define (register-mode! name
                        #:kind [kind 'major]
                        #:parent [parent #f]
                        #:keymap [keymap #f]
                        #:files [files '()]
                        #:locals [locals '()]     ; alist: variable -> default value
                        #:on-enable [on-enable #f]
                        #:on-disable [on-disable #f]
                        #:highlighter [highlighter #f]   ; (buffer) -> void
                        #:doc [doc ""]
                        #:label [label #f])            ; what users see, e.g. "Plain Text"
  (define old (hash-ref modes name #f))
  (hash-set! modes name (mode name kind parent keymap files locals on-enable on-disable highlighter doc label))
  (register-undo! 'mode (lambda () (if old (hash-set! modes name old) (hash-remove! modes name))))
  (run-hook 'mode-registered name))

(define-syntax-rule (define-mode name arg ...) (register-mode! 'name arg ...))

(define (find-mode name) (hash-ref modes name #f))

;; The label users see: the mode's #:label, else its name without "-mode", title-cased.
(define (mode-display-name name)
  (define m (find-mode name))
  (or (and m (mode-label m))
      (string-titlecase (string-replace (regexp-replace #rx"-mode$" (symbol->string name) "") "-" " "))))
(define (all-modes [kind #f])
  (sort (for/list ([m (in-hash-values modes)] #:when (or (not kind) (eq? kind (mode-kind m)))) m)
        symbol<? #:key mode-name))

;; The mode followed by its ancestors, most specific first.
(define (mode-chain name)
  (let loop ([n name])
    (define m (and n (find-mode n)))
    (if m (cons m (loop (mode-parent m))) '())))

;; Keymaps that init files add to (bind-key! ... #:mode 'x); created on first use and
;; consulted before the mode's own keymap.
(define user-keymaps (make-hasheq))
(define (mode-user-keymap name)
  (hash-ref! user-keymaps name (lambda () (make-keymap name))))

(define (mode-keymaps name)
  (append*
   (for/list ([m (in-list (mode-chain name))])
     (filter values (list (hash-ref user-keymaps (mode-name m) #f) (mode-keymap m))))))

;; The value from the most specific mode that sets `var`, even when that value is #f
;; (a child of text-mode can turn wrapping off).
(define (mode-local name var [default #f])
  (define p (for/or ([m (in-list (mode-chain name))]) (assq var (mode-locals m))))
  (if p (cdr p) default))

(define (find-highlighter name)
  (for/or ([m (in-list (mode-chain name))]) (mode-highlighter m)))

(define (glob->regexp g)
  (regexp (string-append
           "^"
           (apply string-append
                  (for/list ([c (in-string g)])
                    (case c [(#\*) ".*"] [(#\?) "."] [(#\.) "[.]"] [else (regexp-quote (string c))])))
           "$")))

(define (mode-for-path path)
  (define file (let-values ([(base name dir?) (split-path path)]) (path->string name)))
  (for/or ([m (in-list (all-modes 'major))])
    (and (for/or ([g (in-list (mode-files m))]) (regexp-match? (glob->regexp g) file))
         (mode-name m))))
