#lang racket/base
;; The toolbar: registry (grouping, per-Language items, unloading with extensions) and the
;; native button row in the real (hidden) window: buttons run commands, dim from #:when,
;; follow the Language, show hover hints, and the row can be hidden.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/list racket/file
         "../rackmac/toolbar.rkt" "../rackmac/owner.rkt" "../rackmac/mode.rkt"
         "../rackmac/commands.rkt" "../rackmac/toolbar-defaults.rkt" "../rackmac/editor.rkt"
         "../rackmac/frame.rkt" "../rackmac/command.rkt" "../rackmac/hook.rkt")

(define (names groups) (map (lambda (g) (map toolbar-item-command g)) groups))

;; ---- registry ----------------------------------------------------------------------

(test-case "default toolbar: file, history, clipboard, find, then Search commands at the end"
  (check-equal? (names (toolbar-items-for 'text-mode))
                '((new-buffer open-file save) (undo redo) (cut copy paste) (find) (command-palette))))

(test-case "Language items appear only for that Language and its children"
  (check-not-false (member '(eval-selection) (names (toolbar-items-for 'racket-mode))) "Run for Racket")
  (check-false (member '(eval-selection) (names (toolbar-items-for 'markdown-mode))))
  (register-mode! 'tb-child-mode #:parent 'racket-mode)
  (check-not-false (member '(eval-selection) (names (toolbar-items-for 'tb-child-mode))) "inherited"))

(test-case "adding the same command twice does not duplicate it"
  (define ext (make-extension "tb"))
  (parameterize ([current-extension ext])
    (add-toolbar-item! 'zoom-in #:group 'tb-view)
    (add-toolbar-item! 'zoom-in #:group 'tb-view))
  (check-equal? (count (lambda (i) (eq? (toolbar-item-command i) 'zoom-in)) (toolbar-items)) 1)
  (unload-extension! ext))

(test-case "items an extension adds or removes are restored when it unloads"
  (define before (toolbar-items))
  (define ext (make-extension "tb"))
  (parameterize ([current-extension ext])
    (add-toolbar-item! 'zoom-in #:group 'tb-view)
    (remove-toolbar-item! 'find))
  (check-false (member '(find) (names (toolbar-items-for 'text-mode))))
  (unload-extension! ext)
  (check-equal? (toolbar-items) before))

;; ---- the button row in the window ------------------------------------------------------

(define f (make-main-frame))
(define tb (main-toolbar))
(define (doc text mode)
  (define b (new-buffer! "tb"))
  (set-current-buffer! b)
  (send b set-mode! mode)
  (send b insert text)
  (send b set-position 0)
  b)
(define (click name) (send (send tb button-for name) command (new control-event% [event-type 'button])))
(define (enabled? name) (send (send tb button-for name) is-enabled?))

(test-case "the window shows one button per toolbar item, in order"
  (doc "" 'text-mode)
  (check-equal? (send tb button-commands) '(new-buffer open-file save undo redo cut copy paste find command-palette)))

(test-case "switching to a Racket document adds Run; back to text removes it"
  (doc "" 'racket-mode)
  (check-not-false (memq 'eval-selection (send tb button-commands)))
  (doc "" 'text-mode)
  (check-false (memq 'eval-selection (send tb button-commands))))

(test-case "a button runs its command"
  (define b (doc "abc" 'text-mode))
  (click 'new-buffer)
  (check-not-eq? (current-buffer) b "New Document made a new tab"))

(test-case "Cut and Copy dim without a selection and light up with one"
  (define b (doc "some text" 'text-mode))
  (run-hook 'status-changed)
  (check-false (enabled? 'cut))
  (check-false (enabled? 'copy))
  (send b set-position 0 4)                   ; after-set-position fires status-changed
  (check-true (enabled? 'cut))
  (check-true (enabled? 'copy)))

(test-case "Undo lights up after an edit; Save dims once saved"
  (define b (doc "" 'text-mode))
  (send b set-modified #f)
  (run-hook 'status-changed)
  (check-false (enabled? 'undo))
  (send b insert "x")
  (run-hook 'after-command 'self-insert)
  (check-true (enabled? 'undo))
  (define p (make-temporary-file "tb~a.txt"))
  (send b save-to! p)
  (check-false (enabled? 'save) "nothing to save"))

(test-case "hovering a button shows its name and shortcut in the status bar"
  (define echoed #f)
  (define (spy s) (set! echoed s))
  (add-hook! 'echo spy)
  (define btn (send tb button-for 'save))
  (send tb on-subwindow-event btn (new mouse-event% [event-type 'enter]))
  (check-regexp-match #rx"^Save [(].+S[)]$" echoed)
  (send tb on-subwindow-event btn (new mouse-event% [event-type 'leave]))
  (check-equal? echoed "")
  (remove-hook! 'echo spy))

(test-case "View > Show Toolbar hides and shows the row"
  (check-true (toolbar-shown?))
  (run-command 'toggle-toolbar)
  (check-false (memq tb (send f get-children)))
  (run-command 'toggle-toolbar)
  (check-eq? (car (send f get-children)) tb "back on top"))

(test-case "an extension's toolbar item appears in the window and leaves when it unloads"
  (doc "" 'text-mode)
  (define ext (make-extension "tb"))
  (parameterize ([current-extension ext]) (add-toolbar-item! 'zoom-in #:group 'tb-view))
  (check-not-false (memq 'zoom-in (send tb button-commands)))
  (unload-extension! ext)
  (check-false (memq 'zoom-in (send tb button-commands))))
