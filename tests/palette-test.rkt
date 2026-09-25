#lang racket/base
;; Drives the restyled command palette and the shortcut cheat sheet with the same
;; polling-timer technique as picker-test.rkt: no fixed sleeps, and a watchdog closes the
;; modal dialog so a regression fails instead of hanging. docs/UI-DESIGN.md §2, §7.3;
;; issues #257, #30, #31, #39.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/list
         "../rackmac/picker.rkt" "../rackmac/command.rkt" "../rackmac/commands.rkt"
         "../rackmac/editor.rkt" "../rackmac/ui/palette.rkt")

(define (dialog) (for/first ([w (get-top-level-windows)] #:when (is-a? w dialog%)) w))
(define (key code) (new key-event% [key-code code]))

;; Polls until the modal dialog opened by `thunk` is actually up, runs `script` once, and has
;; a watchdog so a regression fails instead of hanging.
(define (run-dialog thunk script)
  (define done? #f)
  (define step
    (new timer% [interval 30]
         [notify-callback (lambda ()
                            (define d (dialog))
                            (when (and d (not done?) (send d is-shown?))
                              (set! done? #t)
                              (send step stop)
                              (script d)))]))
  (define watchdog (new timer% [notify-callback (lambda () (define d (dialog)) (when d (send d show #f)))]))
  (send watchdog start 8000 #t)
  (begin0 (thunk)
          (send step stop)
          (send watchdog stop)))

(define (tf-of d) (car (send d get-children)))
(define (lb-of d) (cadr (send d get-children)))
(define (footer-of d) (caddr (send d get-children)))

(define (type! d q)
  (define tf (tf-of d))
  (send tf set-value q)
  (send tf command (new control-event% [event-type 'text-field])))

;; ---- placement (pure) ------------------------------------------------------

(test-case "palette placement centers horizontally and sits ~15% down from the frame top"
  (let-values ([(x y) (dialog-placement 100 200 1000 700 640 440)])
    (check-equal? x (+ 100 (quotient (- 1000 640) 2)))
    (check-equal? y (+ 200 (inexact->exact (round (* 700 0.15)))))))

;; ---- palette items: columns, category, recents -----------------------------

(test-case "palette items carry title, shortcut, name, search fields and a category"
  (define items (palette-items))
  (define (item-for name) (or (findf (lambda (it) (eq? (caddr it) name)) items) (error 'test "missing ~a" name)))
  (check-equal? (car (item-for 'paste)) "Paste")
  (check-equal? (list-ref (item-for 'paste) 4) "Edit" "category falls back to the command's menu")
  (check-equal? (list-ref (item-for 'command-palette) 4) "View"))

(test-case "category: #:category wins, else the menu, else General"
  (define-command (palette-cat-none) #:help "Test." (void))
  (define-command (palette-cat-menu) #:menu "Tools" #:help "Test." (void))
  (define-command (palette-cat-own) #:category "Custom" #:menu "Tools" #:help "Test." (void))
  (define (cat name) (list-ref (findf (lambda (it) (eq? (caddr it) name)) (palette-items)) 4))
  (check-equal? (cat 'palette-cat-none) "General")
  (check-equal? (cat 'palette-cat-menu) "Tools")
  (check-equal? (cat 'palette-cat-own) "Custom"))

(test-case "recents come first (still true with the 5-field item shape)"
  (run-command 'select-all)
  (check-equal? (caddr (car (palette-items))) 'select-all))

;; ---- Emacs alias detection --------------------------------------------------

(test-case "Emacs alias: a plain word like yank still counts when nothing hyphenated exists"
  (check-equal? (emacs-alias-of (find-command 'paste)) "yank")
  (check-equal? (emacs-alias-of (find-command 'cut)) "kill-region")
  (check-equal? (emacs-alias-of (find-command 'command-palette)) "M-x"))

;; ---- the dialog itself -------------------------------------------------------

(test-case "the palette's columns are Command, Category, Shortcut"
  (check-equal? command-palette-columns (list "Command" "Category" "Shortcut")))

(test-case "the footer shows help text and the Emacs alias, and updates on Down"
  (void
   (run-dialog
    (lambda () (run-command 'command-palette))
    (lambda (d)
      (type! d "paste")
      (check-regexp-match #rx"Insert the clipboard" (send (footer-of d) get-label))
      (check-regexp-match #rx"Emacs: yank" (send (footer-of d) get-label))
      (type! d "zoom")
      (define before (send (footer-of d) get-label))
      (send d on-subwindow-char (tf-of d) (key 'down))
      (define after (send (footer-of d) get-label))
      (check-not-equal? before after "moving the selection changes the footer")
      (send d on-subwindow-char (tf-of d) (key 'escape))))))

(test-case "the footer updates on a mouse selection too"
  (void
   (run-dialog
    (lambda () (run-command 'command-palette))
    (lambda (d)
      (type! d "zoom")
      (define footer (footer-of d))
      (define before (send footer get-label))
      (send (lb-of d) select 1)
      (send (lb-of d) command (new control-event% [event-type 'list-box]))
      (define after (send footer get-label))
      (check-not-equal? before after "a mouse selection change updates the footer too")
      (send d on-subwindow-char (tf-of d) (key 'escape))))))

(test-case "no-results state: a helpful row, and Enter does nothing (returns #f)"
  (check-false
   (run-dialog
    (lambda () (palette-pick "Command Palette" (palette-items)))
    (lambda (d)
      (type! d "zzzzqqqqnomatch")
      (check-regexp-match #rx"No commands match 'zzzzqqqqnomatch'" (send (lb-of d) get-string 0))
      (check-regexp-match #rx"Check the spelling" (send (footer-of d) get-label))
      (send d on-subwindow-char (tf-of d) (key #\return))))))

(test-case "Enter in the palette runs the highlighted command"
  (define b (new-buffer! "palette-enter-test"))
  (set-current-buffer! b)
  (send b insert "hello world")
  (send b set-position 0)
  (run-dialog
   (lambda () (run-command 'command-palette))
   (lambda (d)
     (type! d "select all")
     (send d on-subwindow-char (tf-of d) (key #\return))))
  (check-equal? (send b get-start-position) 0)
  (check-equal? (send b get-end-position) (send b last-position)))

;; ---- existing pick callers still work with the extended picker.rkt ---------

(test-case "the Language picker still works (2 columns, no footer)"
  (void
   (run-dialog
    (lambda () (run-command 'set-major-mode))
    (lambda (d)
      (check-equal? (length (send d get-children)) 2 "no footer widget when #:footer is not given")
      (send d on-subwindow-char (tf-of d) (key 'escape))))))

(test-case "the Line Endings picker still works"
  (void
   (run-dialog
    (lambda () (run-command 'set-line-endings))
    (lambda (d)
      (send d on-subwindow-char (tf-of d) (key 'escape))))))

;; ---- the shortcut cheat sheet (#39) -----------------------------------------

(test-case "the cheat sheet's columns name both platforms"
  (check-equal? cheat-sheet-columns (list "Command" "Category" "macOS" "Windows")))

(test-case "the cheat sheet lists both platforms, grouped, and filters by typing"
  (void
   (run-dialog
    (lambda () (cheat-sheet-pick))
    (lambda (d)
      (define lb (lb-of d))
      (define before (send lb get-number))
      (type! d "paste")
      (check-equal? (send lb get-number) 1)
      (check-equal? (send lb get-string 0) "Paste")
      (check-true (> before 1) "more than one shortcut is listed before filtering")
      (send d on-subwindow-char (tf-of d) (key 'escape))))))

(test-case "Enter in the cheat sheet runs the selected command"
  (check-eq?
   (run-dialog
    (lambda () (cheat-sheet-pick))
    (lambda (d)
      (type! d "select all")
      (send d on-subwindow-char (tf-of d) (key #\return))))
   'select-all))
