#lang racket/base
;; Per-Language publishing settings (#424, rackmac/publish-settings.rkt): the four settings,
;; their defaults, resolution document -> Language -> global, and how the Settings dialog
;; shows them (plain-word labels, choice controls, help text).
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/file racket/list racket/string
         "../rackmac/settings.rkt" "../rackmac/editor.rkt" "../rackmac/hook.rkt"
         "../rackmac/lang-scribble.rkt" "../rackmac/publish-settings.rkt"
         "../rackmac/ui/settings-dialog.rkt")

;; Isolated config dir, as in settings-test.rkt: writes never touch the real settings.rktd.
(void (putenv "RACKMAC_HOME" (path->string (make-temporary-file "rackmac-publish~a" 'directory))))

(define names '(publish-output-folder publish-preview-target publish-refresh-on-save publish-outside-library))

(test-case "defaults: browser preview, refresh off, confirm before building outside the Library"
  (define b (new-buffer! "d.scrbl" #:mode 'scribble-mode))
  (check-equal? (publish-setting 'publish-output-folder b) "")
  (check-eq? (publish-setting 'publish-preview-target b) 'browser)
  (check-false (publish-setting 'publish-refresh-on-save b))
  (check-eq? (publish-setting 'publish-outside-library b) 'confirm))

(test-case "each setting resolves per Language, and a document can override its Language"
  (define scr (new-buffer! "a.scrbl" #:mode 'scribble-mode))
  (define scr2 (new-buffer! "b.scrbl" #:mode 'scribble-mode))
  (define note (new-buffer! "n.md" #:mode 'markdown-mode))
  (setting-set! 'publish-output-folder "Handouts" #:language 'scribble-mode)
  (setting-set! 'publish-refresh-on-save #t #:language 'scribble-mode)
  (setting-set! 'publish-preview-target 'embedded #:language 'scribble-mode)
  (setting-set! 'publish-outside-library 'never #:language 'scribble-mode)
  (for ([b (list scr scr2)])
    (check-equal? (publish-setting 'publish-output-folder b) "Handouts")
    (check-true (publish-setting 'publish-refresh-on-save b))
    (check-eq? (publish-setting 'publish-preview-target b) 'embedded)
    (check-eq? (publish-setting 'publish-outside-library b) 'never))
  (check-equal? (publish-setting 'publish-output-folder note) "" "another Language keeps the global value")
  (setting-set! 'publish-output-folder "Board packet" #:document scr)
  (setting-set! 'publish-refresh-on-save #f #:document scr)
  (check-equal? (publish-setting 'publish-output-folder scr) "Board packet")
  (check-false (publish-setting 'publish-refresh-on-save scr) "an override of #f is still an override")
  (check-equal? (publish-setting 'publish-output-folder scr2) "Handouts" "the other document is unaffected"))

(test-case "a value that does not fit is reported and left alone"
  (define seen '())
  (parameterize ([error-reporter (lambda (who e) (set! seen (cons e seen)))])
    (setting-set! 'publish-preview-target 'holographic #:language 'racket-mode)
    (setting-set! 'publish-refresh-on-save "yes" #:language 'racket-mode)
    (setting-set! 'publish-outside-library 'always #:language 'racket-mode))
  (check-equal? (length seen) 3)
  (define b (new-buffer! "r.rkt" #:mode 'racket-mode))
  (check-eq? (publish-setting 'publish-preview-target b) 'browser))

(define (labels-under root)              ; every message%/control label in the dialog, depth first
  (append*
   (for/list ([c (in-list (send root get-children))])
     (define here (if (or (is-a? c message%) (is-a? c check-box%) (is-a? c choice%) (is-a? c text-field%))
                      (list (send c get-label)) '()))
     (append here (if (is-a? c area-container<%>) (labels-under c) '())))))

(test-case "the Settings dialog shows them under Publishing with plain labels"
  (define-values (dlg control-for) (make-settings-dialog))
  (check-true (is-a? (control-for 'publish-output-folder) text-field%))
  (check-true (is-a? (control-for 'publish-preview-target) choice%))
  (check-true (is-a? (control-for 'publish-refresh-on-save) check-box%))
  (check-true (is-a? (control-for 'publish-outside-library) choice%))
  (define labels (labels-under dlg))
  (for ([l '("Output folder" "Show the preview in" "Refresh the preview when I save"
             "Build files outside the Library")])
    (check-not-false (member l labels) l))
  (check-equal? (send (control-for 'publish-preview-target) get-string-selection) "My web browser")
  (check-equal? (send (control-for 'publish-outside-library) get-string-selection) "Ask me first")
  ;; The help text is not drawn under each control: the dialog is already taller than a laptop
  ;; screen without it (it needs a scroll area first). It must still exist, for Describe and docs.
  (for ([n names])
    (check-not-equal? (setting-doc (find-setting n)) "" (format "~a has help text" n))))

(test-case "no Emacs vocabulary in the labels, help or choices"
  (for ([n names])
    (define s (find-setting n))
    (define text (string-append (or (setting-label s) "") " " (setting-doc s) " "
                                (string-join (map cdr (or (setting-choices s) '())) " ")))
    (check-false (regexp-match? #rx"(?i:buffer|major mode|minibuffer|kill|yank)" text) text)))
