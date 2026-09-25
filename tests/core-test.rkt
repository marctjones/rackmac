#lang racket/base
;; Pure-module tests: keys, keymaps, commands, modes, fuzzy matching. No GUI needed.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/list
         "../rackmac/keymap.rkt" "../rackmac/command.rkt" "../rackmac/mode.rkt"
         "../rackmac/fuzzy.rkt" "../rackmac/hook.rkt" "../rackmac/platform.rkt")

(define-syntax-rule (on plat body ...) (parameterize ([current-platform plat]) body ...))

(test-case "Mod resolves per platform"
  (check-equal? (on 'mac (parse-key "Mod-s")) (key #\s '(cmd)))
  (check-equal? (on 'windows (parse-key "Mod-s")) (key #\s '(ctrl)))
  (check-equal? (parse-key "Shift-Alt-Ctrl-Up") (key 'up '(ctrl alt shift))))

(test-case "parsing corner cases"
  (check-equal? (on 'windows (parse-key "Mod--")) (key #\- '(ctrl)) "hyphen as base key")
  (check-equal? (on 'mac (parse-key "Mod-Shift-P")) (key #\p '(shift cmd)) "case-insensitive base")
  (check-equal? (parse-key "F5") (key 'f5 '()))
  (check-equal? (parse-key "Enter") (key 'enter '()))
  (check-exn exn:fail:user? (lambda () (parse-key "Mod-Bogus"))))

(test-case "display strings"
  (check-equal? (on 'mac (key->string (parse-key "Mod-Shift-p"))) "⇧⌘P")
  (check-equal? (on 'windows (key->string (parse-key "Mod-Shift-p"))) "Ctrl+Shift+P")
  (check-equal? (on 'mac (key-sequence->string (parse-key-sequence "Mod-k Mod-c"))) "⌘K ⌘C"))

(test-case "lookup: commands, chords, layering"
  (define low (make-keymap 'low))
  (define high (make-keymap 'high))
  (keymap-bind! low "Ctrl-a" 'from-low)
  (keymap-bind! low "Ctrl-x Ctrl-s" 'chord)
  (keymap-bind! high "Ctrl-a" 'from-high)
  (define (look ks) (let-values ([(kind name) (lookup-key (list high low) (parse-key-sequence ks))]) (list kind name)))
  (check-equal? (look "Ctrl-a") '(command from-high) "higher layer wins")
  (check-equal? (look "Ctrl-x") '(prefix #f))
  (check-equal? (look "Ctrl-x Ctrl-s") '(command chord))
  (check-equal? (look "Ctrl-q") '(none #f))
  (keymap-unbind! low "Ctrl-x Ctrl-s")
  (check-equal? (look "Ctrl-x Ctrl-s") '(none #f)))

(test-case "rebinding a chord prefix replaces it"
  (define km (make-keymap))
  (keymap-bind! km "Ctrl-k Ctrl-c" 'a)
  (keymap-bind! km "Ctrl-k" 'b)
  (let-values ([(kind name) (lookup-key (list km) (parse-key-sequence "Ctrl-k"))])
    (check-equal? (list kind name) '(command b))))

(test-case "define-command registers, binds per platform and runs"
  (define ran '())
  (on 'mac
    (define-command (core-test-cmd)
      #:title "Core Test" #:doc "d" #:keys ("Mod-9") #:keys/mac ("Mod-8") #:keys/windows ("Ctrl-7")
      (set! ran (cons 'ran ran))))
  (check-equal? (command-title (find-command 'core-test-cmd)) "Core Test")
  (define (bound? seq)
    (let-values ([(kind name) (lookup-key (list global-keymap) (on 'mac (parse-key-sequence seq)))]) (eq? kind 'command)))
  (check-true (bound? "Mod-9"))
  (check-true (bound? "Mod-8") "mac layer applied")
  (check-false (bound? "Ctrl-7") "windows layer not applied on mac")
  (run-command 'core-test-cmd)
  (check-equal? ran '(ran))
  (check-exn #rx"unknown command" (lambda () (run-command 'nope))))

(test-case "run-command/safe reports instead of raising"
  (define seen #f)
  (define-command (core-test-boom) (error 'boom "bang"))
  (parameterize ([error-reporter (lambda (who e) (set! seen (list who (exn-message e))))])
    (run-command/safe 'core-test-boom))
  (check-equal? (car seen) 'core-test-boom))

(test-case "a failing hook does not stop later hooks"
  (define log '())
  (define (bad) (error "nope"))
  (define (good) (set! log (cons 'good log)))
  (add-hook! 'core-test-hook bad #:priority 10)
  (add-hook! 'core-test-hook good #:priority 0)
  (parameterize ([error-reporter void]) (run-hook 'core-test-hook))
  (check-equal? log '(good)))

(test-case "modes: chain, locals, globs"
  (register-mode! 'ct-parent #:locals '((a . 1) (b . 2)))
  (register-mode! 'ct-child #:parent 'ct-parent #:locals '((b . 20)) #:files '("*.ctx" "Makefile"))
  (check-equal? (map mode-name (mode-chain 'ct-child)) '(ct-child ct-parent))
  (check-equal? (mode-local 'ct-child 'a) 1 "inherited")
  (check-equal? (mode-local 'ct-child 'b) 20 "overridden")
  (check-equal? (mode-local 'ct-child 'zzz 'dflt) 'dflt)
  (check-equal? (mode-for-path "/tmp/x.ctx") 'ct-child)
  (check-equal? (mode-for-path "/tmp/Makefile") 'ct-child)
  (check-false (mode-for-path "/tmp/xctx"))
  (check-false (mode-for-path "/tmp/x.ctxt") "glob is anchored"))

(test-case "fuzzy matching"
  (check-equal? (fuzzy-filter "sv" '("Save" "Select All" "Save As" "Reverse") values) '("Save" "Save As"))
  (check-equal? (car (fuzzy-filter "sa" '("Select All" "Save") values)) "Save" "prefix beats scattered")
  (check-false (fuzzy-score "zz" "Save"))
  (check-equal? (fuzzy-score "" "anything") 0))
