#lang racket/base
;; Native popup-menu%s built from command names: labeled and shortcut-suffixed like the
;; menu bar (command-menu-label), disabled per command-enabled?. `build-popup-menu` only
;; builds the menu% (so tests can inspect its items without ever showing anything);
;; `popup-menu-at!` pops it up in a window. Used both for the editor's right-click menu
;; (from the context-item registry) and the tab strip's fixed menu.
(require racket/class racket/gui/base
         "../command.rkt" "../context-menu.rkt" "../platform.rkt")
(provide build-popup-menu popup-menu-at! editor-menu-groups context-click-event?)

;; A right-click, or (macOS only) a Ctrl-click, per docs/UI-DESIGN.md section 4's "Context
;; menu" row. Factored out so the click detection itself is testable without ever calling
;; popup-menu (which would block/show something even on a hidden frame).
(define (context-click-event? e)
  (or (send e button-down? 'right) (and (mac?) (send e button-down? 'left) (send e get-control-down))))

;; groups: a list of (list command-name ...); a separator sits between non-empty groups.
(define (build-popup-menu groups)
  (define menu (new popup-menu%))
  (let loop ([gs (filter pair? groups)] [first? #t])
    (unless (null? gs)
      (unless first? (new separator-menu-item% [parent menu]))
      (for ([name (car gs)])
        (define c (find-command name))
        (define item (new menu-item% [label (command-menu-label name)] [parent menu]
                          [callback (lambda (i e) (run-command/safe name))]))
        (send item enable (and c (command-enabled? c))))
      (loop (cdr gs) #f)))
  menu)

;; The editor context menu's groups for `mode`, from the registry (RM-055, RM-057).
(define (editor-menu-groups mode)
  (map (lambda (g) (map context-item-command g)) (context-items-for mode)))

(define (popup-menu-at! window menu x y) (send window popup-menu menu x y))
