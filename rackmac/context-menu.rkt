#lang racket/base
;; The context-menu item registry (no GUI). Items name commands; the editor's right-click
;; menu draws them for the current Language. Mirrors rackmac/toolbar.rkt: grouped (a
;; separator between groups), can be limited to a Language (and its children, via
;; mode-chain), and unloaded with the extension that added them.
(require racket/list "owner.rkt" "hook.rkt" "mode.rkt")
(provide (struct-out context-item) add-context-item! remove-context-item!
         context-items context-items-for context-groups
         add-context-provider! context-provider-groups)

;; group: a symbol; groups appear in the order they were first used, and a separator sits
;; between non-empty groups in the popup. mode: limits the item to that Language and its
;; children (mode-chain), or #f for every Language.
(struct context-item (command group mode) #:transparent)

(define items '())          ; in insertion order
(define groups '())         ; group symbols, first-use order

(define (context-items) items)
(define (context-groups) groups)

(define (changed!) (run-hook 'context-menu-changed))

;; Adding the same command again (for the same mode) replaces it rather than duplicating.
(define (add-context-item! command #:group [group 'main] #:mode [mode #f])
  (unless (symbol? command) (raise-argument-error 'add-context-item! "symbol?" command))
  (define old items)
  (define old-groups groups)
  (define it (context-item command group mode))
  (set! items (append (filter (lambda (x) (not (and (eq? (context-item-command x) command)
                                                    (eq? (context-item-mode x) mode))))
                              items)
                      (list it)))
  (unless (memq group groups) (set! groups (append groups (list group))))
  (register-undo! 'context-item (lambda () (set! items old) (set! groups old-groups) (changed!)))
  (changed!))

(define (remove-context-item! command #:mode [mode #f])
  (define old items)
  (set! items (filter (lambda (x) (not (and (eq? (context-item-command x) command)
                                            (eq? (context-item-mode x) mode))))
                      items))
  (register-undo! 'context-item (lambda () (set! items old) (changed!)))
  (changed!))

;; The items to show for a document in `mode-name`: global ones plus those for the mode or
;; any of its parents, ordered by group. Returns a list of groups, each a list of items
;; (empty groups dropped), the same shape as toolbar-items-for.
(define (context-items-for mode-name)
  (define chain (map mode-name* (mode-chain mode-name)))
  (define visible (filter (lambda (x) (or (not (context-item-mode x)) (memq (context-item-mode x) chain))) items))
  (define (in-group g) (filter (lambda (x) (eq? (context-item-group x) g)) visible))
  (filter pair? (for/list ([g groups]) (in-group g))))

(define (mode-name* m) (mode-name m))

;; Providers (#351): items that depend on what was clicked, such as spelling suggestions for a
;; flagged word, which a fixed list of commands cannot express. A provider is a procedure from
;; the document to a list of groups shown before the registry's own; each entry is a command
;; name or (label . thunk), with a #f thunk for a disabled row ("No Guesses Found"). A failing
;; provider is reported and contributes nothing.
(define providers '())

(define (add-context-provider! proc)
  (define old providers)
  (set! providers (append providers (list proc)))
  (register-undo! 'context-provider (lambda () (set! providers old) (changed!)))
  (changed!))

(define (context-provider-groups doc)
  (filter pair?
          (append* (for/list ([p (in-list providers)])
                     (with-handlers ([exn:fail? (lambda (e) (report-error! 'context-menu e) '())])
                       (p doc))))))
