#lang racket/base
;; Settings… (#291, settings-dialog-min): a dialog% generated from the define-setting registry
;; (rackmac/settings.rkt), one row per registered setting, grouped by category. Rows apply their
;; setting live through setting-set!, whose own contract check reports (and refuses) a bad value
;; -- so a bad text-field entry is simply left unapplied and the field snaps back to the current
;; value, never raised. An "Edit as Code" button runs the existing `customize-with-code` command
;; (⌘, moves here from that command; see rackmac/commands.rkt).
;;
;; `make-settings-dialog` builds the dialog% but never shows it (same convention as
;; `make-main-frame`), so tests can inspect and drive its controls headless; the `open-settings`
;; command below is the only caller that shows it for real.
(require racket/class racket/gui/base racket/list racket/string
         "../settings.rkt" "../command.rkt" "../editor.rkt" "../hook.rkt" "layout.rkt")
(provide make-settings-dialog)

(define (friendly-title name) (default-title name))

;; A setting's current value formatted for a text-field%.
(define (format-value v) (if (string? v) v (format "~a" v)))

;; Parses a text field's committed text back into a value to try against setting-set!. A numeric
;; default means the field holds a number; anything else is taken as a plain string. A string
;; that will not parse as a number is reported directly (setting-set! never even sees it), the
;; same "reported, not applied" outcome as a value that fails the contract.
(define (commit-text! s field)
  (define name (setting-name s))
  (define raw (send field get-value))
  (cond
    [(number? (setting-default s))
     (define n (string->number raw))
     (if n
         (setting-set! name n)
         (report-error! name (format "~a: ~v is not a number" name raw)))]
    [else (setting-set! name raw)])
  (send field set-value (format-value (setting-ref name))))

;; One control for `s`, added to `parent`, and recorded in `controls` under the setting's name.
(define (add-row! parent controls s)
  (define name (setting-name s))
  (define label (friendly-title name))
  (define control
    (cond
      ;; A finite set of values (e.g. editor-theme): a choice%, its friendly labels from #:choices.
      [(setting-choices s)
       (define pairs (setting-choices s))
       (define values* (map car pairs))
       (define idx (or (index-of values* (setting-ref name)) 0))
       (new choice% [label label] [parent parent] [choices (map cdr pairs)] [selection idx]
            [callback (lambda (c e) (setting-set! name (list-ref values* (send c get-selection))))])]
      ;; A plain boolean: a check-box%.
      [(eq? (setting-contract s) boolean?)
       (new check-box% [label label] [parent parent] [value (and (setting-ref name) #t)]
            [callback (lambda (c e) (setting-set! name (send c get-value)))])]
      ;; Everything else (strings, numbers, anything with its own predicate): a text-field%,
      ;; applied when the user presses Return so a half-typed number is never reported as invalid.
      [else
       (new text-field% [label label] [parent parent] [init-value (format-value (setting-ref name))]
            [callback (lambda (t e) (when (eq? (send e get-event-type) 'text-field-enter)
                                      (commit-text! s t)))])]))
  (hash-set! controls name control))

;; Builds the dialog, unshown. Returns (values dialog control-for), where (control-for name) is
;; the check-box%/choice%/text-field% for that registered setting (or #f).
(define (make-settings-dialog)
  (define controls (make-hasheq))
  (define dlg (new dialog% [label "Settings…"] [parent (ui-parent)]
                   [width 480] [style '(resize-border)]))
  (define body (new vertical-panel% [parent dlg] [border dialog-border] [spacing dialog-spacing]
                    [alignment '(left top)]))
  (define categories (sort (remove-duplicates (map setting-category (all-settings))) string<?))
  (for ([category (in-list categories)])
    (define box (new group-box-panel% [label category] [parent body] [alignment '(left top)]
                     [stretchable-height #f]))
    (for ([s (in-list (all-settings))] #:when (equal? (setting-category s) category))
      (add-row! box controls s)))
  (define buttons (new horizontal-panel% [parent dlg] [alignment '(right center)] [stretchable-height #f]))
  (new button% [label "Edit as Code"] [parent buttons]
       [callback (lambda (b e) (send dlg show #f) (run-command/safe 'customize-with-code))])
  (new button% [label "Close"] [parent buttons] [style '(border)]
       [callback (lambda (b e) (send dlg show #f))])
  (values dlg (lambda (name) (hash-ref controls name #f))))

(define-command (open-settings)
  #:icon "settings"
  #:aliases ("settings" "preferences" "options" "settings dialog")
  #:help "Open the Settings dialog."
  #:title "Settings…" #:menu "File" #:menu-order 40 #:keys ("Mod-,")
  #:doc "Open the Settings dialog, generated from every registered setting."
  (define-values (dlg control-for) (make-settings-dialog))
  (send dlg show #t))
