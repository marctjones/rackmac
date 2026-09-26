#lang racket/base
;; Tools menu (#289, menu-tools): a Scratch Pad command that is reachable without being the
;; document shown when nothing is open (that fallback is `run-code-only`, #101, separate future
;; work -- this only adds a way to reopen or refocus it), and the Extensions submenu that
;; gathers Customize with Code, Reload Extensions and List Extensions out of File and Help
;; (docs/REPLAN.md §8), rebuilt from the command registry every time it opens like every other
;; submenu here (rackmac/library/open-recent.rkt is the existing example).
(require racket/class racket/gui/base
         "command.rkt" "editor.rkt" "frame.rkt")

(define (find-scratch-pad)
  (for/first ([b (in-list (all-buffers))] #:when (equal? (send b get-name) "Scratch Pad")) b))

(define-command (open-scratch-pad)
  #:icon "code"
  #:aliases ("scratch pad" "scratch buffer" "try racket" "racket playground")
  #:help "Open the Scratch Pad, a place to try Racket code."
  #:title "Scratch Pad" #:menu "Tools" #:menu-order 20 #:category "Tools"
  #:doc "Switch to the Scratch Pad, creating it (with its usual starter comment) if it is not open."
  (define b (or (find-scratch-pad)
                (let ([nb (new-buffer! "Scratch Pad" #:mode 'racket-mode)])
                  (send nb insert ";; Scratch Pad: a place to try Racket code.\n;; Select some code and press Mod-Enter to run it.\n\n")
                  (send nb set-modified #f)
                  nb)))
  (send b set-shown! #t)
  (set-current-buffer! b))

;; Extensions submenu items run the moved commands by name (rackmac/commands.rkt), so this
;; module never has to require commands.rkt itself; each item's enabled state is set once, when
;; the menu opens (these three commands have no #:when, so this always matches command-enabled?).
(define extension-command-names '(customize-with-code reload-init list-extensions))

(define (populate-extensions! m)
  (for ([name (in-list extension-command-names)])
    (define c (find-command name))
    (when c
      (define item (new menu-item% [label (command-menu-label name)] [parent m]
                        [callback (lambda (i e) (run-command/safe name))]))
      (send item enable (command-enabled? c)))))

(register-submenu! "Extensions" #:menu "Tools" #:menu-order 30 populate-extensions!)
