#lang racket/base
;; Settings dialog (#291, settings-dialog-min): a dialog% built (never shown) from every
;; registered setting (rackmac/settings.rkt), one row each, grouped by category; checkbox,
;; choice, number and text rows apply live through setting-set!, and a value that cannot be
;; parsed or fails the contract is reported (rackmac/hook.rkt) and left unapplied. "Edit as
;; Code" closes the dialog and runs the existing `customize-with-code` command.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/list racket/file
         "../rackmac/settings.rkt" "../rackmac/hook.rkt" "../rackmac/command.rkt"
         "../rackmac/editor.rkt" "../rackmac/commands.rkt" "../rackmac/appearance.rkt"
         "../rackmac/ui/settings-dialog.rkt")

;; Isolated config dir, like settings-test.rkt/appearance-test.rkt: writes from setting-set!
;; below never touch the real settings.rktd.
(void (putenv "RACKMAC_HOME" (path->string (make-temporary-file "rackmac-settings-dialog~a" 'directory))))

(define-setting st-dialog-bool #:contract boolean? #:default #f #:category "Dialog Test"
  #:doc "A checkbox row.")
(define-setting st-dialog-choice #:contract (lambda (v) (and (memq v '(a b c)) #t)) #:default 'a
  #:category "Dialog Test" #:choices '((a . "Alpha") (b . "Beta") (c . "Gamma"))
  #:doc "A choice row.")
(define-setting st-dialog-number #:contract exact-nonnegative-integer? #:default 3
  #:category "Dialog Test" #:doc "A number row.")
(define-setting st-dialog-string #:contract string? #:default "hi" #:category "Dialog Test"
  #:doc "A text row.")

;; Depth-first search of the dialog's widget tree (dialog%/panel%s implement area-container<%>;
;; leaf controls like button%/check-box% do not, so recursion stops there on its own).
(define (find-by-label root cls label)
  (for/or ([c (in-list (send root get-children))])
    (cond [(and (is-a? c cls) (equal? (send c get-label) label)) c]
          [(is-a? c area-container<%>) (find-by-label c cls label)]
          [else #f])))

(define (fire! control type)
  (send control command (new control-event% [event-type type])))

(test-case "the dialog is constructible unshown, for tests"
  (define-values (dlg control-for) (make-settings-dialog))
  (check-false (send dlg is-shown?)))

(test-case "every registered setting has a row, of the right control class"
  (define-values (dlg control-for) (make-settings-dialog))
  (for ([s (in-list (all-settings))])
    (check-not-false (control-for (setting-name s)) (format "~a has a row" (setting-name s))))
  (check-true (is-a? (control-for 'st-dialog-bool) check-box%))
  (check-true (is-a? (control-for 'st-dialog-choice) choice%))
  (check-true (is-a? (control-for 'st-dialog-number) text-field%))
  (check-true (is-a? (control-for 'st-dialog-string) text-field%))
  (check-true (is-a? (control-for 'editor-theme) choice%) "a #:choices setting is a choice%, not a text field"))

(test-case "rows are grouped by category (a group-box-panel% per category)"
  (define-values (dlg control-for) (make-settings-dialog))
  (check-not-false (find-by-label dlg group-box-panel% "Dialog Test"))
  (check-not-false (find-by-label dlg group-box-panel% "Appearance")))

(test-case "a checkbox applies its setting live"
  (define-values (dlg control-for) (make-settings-dialog))
  (define cb (control-for 'st-dialog-bool))
  (send cb set-value #t)
  (fire! cb 'check-box)
  (check-true (setting-ref 'st-dialog-bool)))

(test-case "a choice applies its setting live, by value not by label"
  (define-values (dlg control-for) (make-settings-dialog))
  (define ch (control-for 'st-dialog-choice))
  (check-equal? (send ch get-string-selection) "Alpha" "starts on the default's label")
  (send ch set-selection 1)
  (fire! ch 'choice)
  (check-eq? (setting-ref 'st-dialog-choice) 'b))

(test-case "a text field applies a valid value on Enter, live"
  (define-values (dlg control-for) (make-settings-dialog))
  (define tf (control-for 'st-dialog-string))
  (send tf set-value "bye")
  (fire! tf 'text-field-enter)
  (check-equal? (setting-ref 'st-dialog-string) "bye"))

(test-case "a text field does not apply on every keystroke, only on Enter"
  (define-values (dlg control-for) (make-settings-dialog))
  (define tf (control-for 'st-dialog-string))
  (send tf set-value "typing…")
  (fire! tf 'text-field)
  (check-equal? (setting-ref 'st-dialog-string) "bye" "unchanged: the earlier test's committed value"))

(test-case "a number field parses and applies on Enter"
  (define-values (dlg control-for) (make-settings-dialog))
  (define tf (control-for 'st-dialog-number))
  (send tf set-value "7")
  (fire! tf 'text-field-enter)
  (check-equal? (setting-ref 'st-dialog-number) 7))

(test-case "text that will not parse as a number is reported and not applied; the field reverts"
  (define-values (dlg control-for) (make-settings-dialog))
  (define tf (control-for 'st-dialog-number))
  (define seen #f)
  (send tf set-value "not a number")
  (parameterize ([error-reporter (lambda (who e) (set! seen (list who e)))])
    (fire! tf 'text-field-enter))
  (check-equal? (setting-ref 'st-dialog-number) 7 "unchanged")
  (check-regexp-match #rx"is not a number" (cadr seen))
  (check-equal? (send tf get-value) "7" "the field snaps back to the applied value"))

(test-case "a value that fails the contract is reported (by setting-set!) and not applied"
  (define-values (dlg control-for) (make-settings-dialog))
  (define tf (control-for 'st-dialog-number))
  (define seen #f)
  (send tf set-value "-5")
  (parameterize ([error-reporter (lambda (who e) (set! seen (list who e)))])
    (fire! tf 'text-field-enter))
  (check-equal? (setting-ref 'st-dialog-number) 7 "unchanged")
  (check-regexp-match #rx"does not satisfy its contract" (cadr seen))
  (check-equal? (send tf get-value) "7"))

(test-case "Edit as Code closes the dialog and runs Customize with Code"
  (define-values (dlg control-for) (make-settings-dialog))
  (send dlg show #f)                    ; never actually opened in tests; simulate the click directly
  (define ran #f)
  (define (spy n) (when (eq? n 'customize-with-code) (set! ran #t)))
  (add-hook! 'before-command spy)
  (define btn (find-by-label dlg button% "Edit as Code"))
  (check-not-false btn)
  (fire! btn 'button)
  (remove-hook! 'before-command spy)
  (check-true ran)
  (check-false (send dlg is-shown?)))
