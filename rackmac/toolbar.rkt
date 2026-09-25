#lang racket/base
;; The toolbar registry (no GUI). Items name commands; the window draws them as buttons.
;; Items are grouped (a gap between groups), can be limited to a Language (and its
;; children, like keymaps), and are unloaded with the extension that added them.
(require racket/list "owner.rkt" "hook.rkt" "mode.rkt")
(provide (struct-out toolbar-item) add-toolbar-item! remove-toolbar-item!
         toolbar-items toolbar-items-for toolbar-groups)

;; group: a symbol; groups appear in the order they were first used. end?: pushed to the
;; right-hand end of the bar (e.g. "Search commands").
(struct toolbar-item (command group mode end?) #:transparent)

(define items '())          ; in insertion order
(define groups '())         ; group symbols, first-use order

(define (toolbar-items) items)
(define (toolbar-groups) groups)

(define (changed!) (run-hook 'toolbar-changed))

;; Adding the same command again (for the same mode) replaces it rather than duplicating.
(define (add-toolbar-item! command #:group [group 'main] #:mode [mode #f] #:end? [end? #f])
  (unless (symbol? command) (raise-argument-error 'add-toolbar-item! "symbol?" command))
  (define old items)
  (define old-groups groups)
  (define it (toolbar-item command group mode end?))
  (set! items (append (filter (lambda (x) (not (and (eq? (toolbar-item-command x) command)
                                                    (eq? (toolbar-item-mode x) mode))))
                              items)
                      (list it)))
  (unless (memq group groups) (set! groups (append groups (list group))))
  (register-undo! 'toolbar (lambda () (set! items old) (set! groups old-groups) (changed!)))
  (changed!))

(define (remove-toolbar-item! command #:mode [mode #f])
  (define old items)
  (set! items (filter (lambda (x) (not (and (eq? (toolbar-item-command x) command)
                                            (eq? (toolbar-item-mode x) mode))))
                      items))
  (register-undo! 'toolbar (lambda () (set! items old) (changed!)))
  (changed!))

;; The items to show for a document in `mode-name`: global ones plus those for the mode or
;; any of its parents, ordered by group, with end? items last. Returns a list of groups,
;; each a list of items (empty groups dropped).
(define (toolbar-items-for mode-name)
  (define chain (map mode-name* (mode-chain mode-name)))
  (define visible (filter (lambda (x) (or (not (toolbar-item-mode x)) (memq (toolbar-item-mode x) chain))) items))
  (define (in-group g end?) (filter (lambda (x) (and (eq? (toolbar-item-group x) g) (eq? (toolbar-item-end? x) end?))) visible))
  (filter pair? (append (for/list ([g groups]) (in-group g #f))
                        (for/list ([g groups]) (in-group g #t)))))

(define (mode-name* m) (mode-name m))
