#lang racket/base
;; Commands with an on/off state (#333): #:checked makes a checkable menu item whose check is
;; refreshed when the menu opens, and a toolbar button swaps to #:checked-title/#:checked-icon
;; while on. Driven through the real (hidden) window and registry.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/frame.rkt"
         "../rackmac/editor.rkt" "../rackmac/toolbar.rkt" "../rackmac/hook.rkt")

(define f (make-main-frame))
(define state #f)
(define-command (checked-probe)
  #:title "Probe Setting" #:menu "View" #:menu-order 29 #:icon "wrap"
  #:checked (lambda () state)
  #:checked-title "Probe Off" #:checked-icon "check"
  (set! state (not state)))

(define (item name) (menu-item-for name))
(define (open-view!) (send (menu-for-title "View") on-demand))

(test-case "a #:checked command is a checkable menu item that follows its state"
  (check-true (is-a? (item 'checked-probe) checkable-menu-item%))
  (open-view!)
  (check-false (send (item 'checked-probe) is-checked?))
  (run-command 'checked-probe)
  (open-view!)
  (check-true (send (item 'checked-probe) is-checked?))
  (check-true (command-checked? (find-command 'checked-probe))))

(test-case "commands without #:checked stay plain items"
  (check-false (is-a? (item 'zoom-in) checkable-menu-item%))
  (check-false (command-checked? (find-command 'zoom-in))))

(test-case "a failing #:checked thunk reads as off, never breaks the menu"
  (define-command (checked-broken) #:title "Broken Probe" #:menu "View" #:menu-order 29 #:icon "wrap"
    #:checked (lambda () (error "boom")) (void))
  (check-false (command-checked? (find-command 'checked-broken)))
  (open-view!))

(test-case "Show Toolbar and Toggle Word Wrap show their state"
  (define tb (menu-item-for 'toggle-toolbar))
  (open-view!)
  (check-true (send tb is-checked?))
  (run-command 'toggle-toolbar) (open-view!)
  (check-false (send tb is-checked?))
  (run-command 'toggle-toolbar)
  (define b (new-buffer! "wrap" #:mode 'text-mode))
  (set-current-buffer! b)
  (open-view!)
  (check-true (send (menu-item-for 'toggle-word-wrap) is-checked?) "notes wrap")
  (run-command 'toggle-word-wrap) (open-view!)
  (check-false (send (menu-item-for 'toggle-word-wrap) is-checked?)))

(test-case "a toolbar button swaps to its checked title while on"
  (set! state #f)
  (add-toolbar-item! 'checked-probe #:group 'probe #:end? #t)
  (define tb (main-toolbar))
  (send tb rebuild!)
  (check-false (send tb button-shows-checked? 'checked-probe))
  (run-command 'checked-probe)
  (send tb refresh-enabled!)
  (check-true (send tb button-shows-checked? 'checked-probe))
  (remove-toolbar-item! 'checked-probe))
