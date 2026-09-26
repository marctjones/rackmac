#lang racket/base
;; The context-item registry (grouping, per-Language items, unloading with extensions), the
;; popup builder (items, separators, enabled states -- built, never shown), word selection
;; under a right-click outside the selection (RM-058), the tab context menu's commands
;; (RM-071), menu on-demand enabling (RM-065) and double/triple click (RM-069).
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/list racket/file
         "../rackmac/context-menu.rkt" "../rackmac/context-defaults.rkt" "../rackmac/owner.rkt"
         "../rackmac/mode.rkt" "../rackmac/commands.rkt" "../rackmac/editor.rkt"
         "../rackmac/command.rkt" "../rackmac/hook.rkt" "../rackmac/platform.rkt"
         "../rackmac/frame.rkt" "../rackmac/ui/context-menu.rkt")

(define (names groups) (map (lambda (g) (map context-item-command g)) groups))

;; ---- registry ------------------------------------------------------------------------

(test-case "default editor context menu: clipboard, select all, find; no Language items for plain text"
  (check-equal? (names (context-items-for 'text-mode))
                '((cut copy paste) (select-all) (find))))

(test-case "Racket documents add Run Selection and Toggle Comment; Markdown adds neither"
  (check-equal? (names (context-items-for 'racket-mode))
                '((cut copy paste) (select-all) (find) (run-selection toggle-comment)))
  (check-equal? (names (context-items-for 'markdown-mode))
                '((cut copy paste) (select-all) (find))))

(test-case "Toggle Comment is for any code Language, via prog-mode inheritance"
  (register-mode! 'ctx-child-mode #:parent 'prog-mode)
  (check-equal? (context-item-command (last (last (context-items-for 'ctx-child-mode)))) 'toggle-comment))

(test-case "adding the same command twice (for the same mode) does not duplicate it"
  (define ext (make-extension "ctx"))
  (parameterize ([current-extension ext])
    (add-context-item! 'zoom-in #:group 'ctx-view)
    (add-context-item! 'zoom-in #:group 'ctx-view))
  (check-equal? (count (lambda (i) (eq? (context-item-command i) 'zoom-in)) (context-items)) 1)
  (unload-extension! ext))

(test-case "items an extension adds or removes are restored when it unloads"
  (define before (context-items))
  (define ext (make-extension "ctx"))
  (parameterize ([current-extension ext])
    (add-context-item! 'zoom-in #:group 'ctx-view)
    (remove-context-item! 'find))
  (check-false (member '(find) (names (context-items-for 'text-mode))))
  (unload-extension! ext)
  (check-equal? (context-items) before))

(test-case "'context-menu-changed fires when an item is added or removed"
  (define fired 0)
  (define (spy) (set! fired (add1 fired)))
  (add-hook! 'context-menu-changed spy)
  (add-context-item! 'zoom-out #:group 'ctx-scratch)
  (remove-context-item! 'zoom-out #:mode #f)
  (remove-hook! 'context-menu-changed spy)
  (check-equal? fired 2))

;; ---- the popup builder: built, never shown --------------------------------------------

(define (labels menu)
  (for/list ([i (send menu get-items)] #:unless (is-a? i separator-menu-item%)) (send i get-label)))
(define (separators menu) (map (lambda (i) (is-a? i separator-menu-item%)) (send menu get-items)))
(define (enabled-map menu)
  (for/list ([i (send menu get-items)] #:unless (is-a? i separator-menu-item%))
    (send i is-enabled?)))

(test-case "build-popup-menu adds a separator between groups, none inside one"
  (define menu (build-popup-menu '((cut copy paste) (select-all))))
  (check-equal? (separators menu) '(#f #f #f #t #f)))

(test-case "build-popup-menu labels items with the command title (and shortcut, if any)"
  (define menu (build-popup-menu '((select-all))))
  (check-regexp-match #rx"^Select All" (car (labels menu))))

(test-case "empty groups contribute nothing, not even a stray separator"
  (define menu (build-popup-menu '(() (select-all) ())))
  (check-equal? (length (send menu get-items)) 1))

(test-case "a popup item runs its command"
  (define b (new-buffer! "ctx-run"))
  (set-current-buffer! b)
  (send b insert "hello")
  (send b set-position 0)
  (define menu (build-popup-menu '((select-all))))
  (send (car (send menu get-items)) command (new control-event% [event-type 'menu]))
  (check-equal? (send b get-start-position) 0)
  (check-equal? (send b get-end-position) 5))

(test-case "enabled states: a text document with no selection dims Cut/Copy/Paste-needing items"
  (define b (new-buffer! "ctx-enable"))
  (set-current-buffer! b)
  (send b insert "some text")
  (send b set-position 0)
  (run-hook 'status-changed)
  (define menu (build-popup-menu (editor-menu-groups (send b get-mode))))
  ;; order: Cut Copy Paste | Select All | Find
  (check-equal? (enabled-map menu) (list #f #f #t #t #t) "Cut/Copy dim, Paste depends on the clipboard, Select All and Find always apply"))

(test-case "enabled states: with a selection, Cut and Copy light up"
  (define b (new-buffer! "ctx-enable-sel"))
  (set-current-buffer! b)
  (send b insert "some text")
  (send b set-position 0 4)
  (run-hook 'status-changed)
  (define menu (build-popup-menu (editor-menu-groups (send b get-mode))))
  (check-equal? (take (enabled-map menu) 2) (list #t #t)))

(test-case "a Racket document's menu includes Run Selection and Toggle Comment"
  (define b (new-buffer! "ctx-racket"))
  (set-current-buffer! b)
  (send b set-mode! 'racket-mode)
  (send b insert "(+ 1 2)")
  (run-hook 'status-changed)
  (define menu (build-popup-menu (editor-menu-groups (send b get-mode))))
  (check-regexp-match #rx"Toggle Comment" (last (labels menu)))
  (check-regexp-match #rx"Run Selection" (list-ref (labels menu) (sub1 (sub1 (length (labels menu)))))))

;; ---- word selection under a right-click outside the selection (RM-058) ----------------

(test-case "a click outside the selection selects the word under the pointer"
  (define b (new-buffer! "ctx-word"))
  (send b insert "hello world foo")
  (send b set-position 0)                          ; no selection
  (send b context-click-at! 7)                     ; inside "world"
  (check-equal? (send b get-start-position) 6)
  (check-equal? (send b get-end-position) 11)
  (check-equal? (send b get-text 6 11) "world"))

(test-case "a click right at a word's edge still selects that word"
  (define b (new-buffer! "ctx-word-edge"))
  (send b insert "hello world foo")
  (send b context-click-at! 11)                    ; right after "world", before the space
  (check-equal? (send b get-text (send b get-start-position) (send b get-end-position)) "world")
  (send b context-click-at! 15)                    ; end of the document, right after "foo"
  (check-equal? (send b get-text (send b get-start-position) (send b get-end-position)) "foo"))

(test-case "a click inside the current selection leaves it alone"
  (define b (new-buffer! "ctx-word-keep"))
  (send b insert "hello world foo")
  (send b set-position 0 5)                        ; "hello" selected
  (send b context-click-at! 2)                     ; inside the selection
  (check-equal? (send b get-start-position) 0)
  (check-equal? (send b get-end-position) 5))

(test-case "a click outside the current selection replaces it with the word under the pointer"
  (define b (new-buffer! "ctx-word-replace"))
  (send b insert "hello world foo")
  (send b set-position 0 5)                        ; "hello" selected
  (send b context-click-at! 13)                    ; outside, inside "foo"
  (check-equal? (send b get-text (send b get-start-position) (send b get-end-position)) "foo"))

(test-case "context-click! converts device coordinates the same way (RM-058 through the canvas)"
  (define f (new frame% [label "ctx"] [width 300] [height 200]))
  (define b (new-buffer! "ctx-device"))
  (send b insert "hello world foo")
  (define c (new editor-canvas% [parent f] [editor b]))
  (send f reflow-container)
  (define xb (box 0)) (define yb (box 0))
  (send b position-location 8 xb yb #t)
  (define-values (dx dy) (send b editor-location-to-dc-location (unbox xb) (unbox yb)))
  (send b set-position 0)
  (send b context-click! dx (+ dy 2))
  (check-equal? (send b get-text (send b get-start-position) (send b get-end-position)) "world"))

;; ---- context-click-event?: right-click, and Ctrl-click on macOS only ------------------

(test-case "context-click-event? recognizes a right-click on every platform"
  (check-true (context-click-event? (new mouse-event% [event-type 'right-down]))))

(test-case "context-click-event?: Ctrl-click opens it on macOS, not on Windows"
  (define e (new mouse-event% [event-type 'left-down] [control-down #t]))
  (parameterize ([current-platform 'mac]) (check-true (context-click-event? e)))
  (parameterize ([current-platform 'windows]) (check-false (context-click-event? e))))

(test-case "a plain left-click is never a context click"
  (check-false (context-click-event? (new mouse-event% [event-type 'left-down]))))

;; ---- double- and triple-click (RM-069) -------------------------------------------------

(test-case "text% has no built-in double/triple-click selection (why buffer.rkt implements it)"
  (define t (new text%))
  (send t insert "hello world")
  (send t on-event (new mouse-event% [event-type 'left-down] [x 40] [y 10] [time-stamp 0]))
  (send t on-event (new mouse-event% [event-type 'left-up] [x 40] [y 10] [time-stamp 5]))
  (send t on-event (new mouse-event% [event-type 'left-down] [x 40] [y 10] [time-stamp 20]))
  (send t on-event (new mouse-event% [event-type 'left-up] [x 40] [y 10] [time-stamp 25]))
  (check-equal? (send t get-start-position) (send t get-end-position) "plain text%: no word gets selected"))

(test-case "a second click at the same position selects the word; a third selects the line"
  (define b (new-buffer! "click-word"))
  (send b insert "hello world foo\nsecond line")
  (send b click-at! 8 1000)                        ; inside "world"
  (check-equal? (send b get-start-position) (send b get-end-position) "first click: just a caret")
  (send b click-at! 8 1050)
  (check-equal? (send b get-text (send b get-start-position) (send b get-end-position)) "world" "second click: the word")
  (send b click-at! 8 1090)
  (check-equal? (send b get-text (send b get-start-position) (send b get-end-position))
                "hello world foo\n" "third click: the whole line"))

(test-case "clicks too far apart in time do not chain into a double-click"
  (define b (new-buffer! "click-slow"))
  (send b insert "hello world")
  (send b click-at! 8 0)
  (send b click-at! 8 900)                         ; well past double-click-interval
  (check-equal? (send b get-start-position) (send b get-end-position)))

(test-case "clicking a different position resets the streak"
  (define b (new-buffer! "click-move"))
  (send b insert "hello world")
  (send b click-at! 2 0)
  (send b click-at! 8 20)                          ; different position: back to a single click
  (check-equal? (send b get-start-position) (send b get-end-position)))

(test-case "double-click through the real (hidden) editor canvas selects the word"
  (define f (make-main-frame))
  (define canvas (main-canvas))
  (define b (new-buffer! "click-canvas"))
  (set-current-buffer! b)
  (send b insert "hello world foo")
  (send b set-position 0)
  (define xb (box 0)) (define yb (box 0))
  (send b position-location 8 xb yb #t)
  (define-values (dx dy) (send b editor-location-to-dc-location (unbox xb) (unbox yb)))
  (define (click! t) (send canvas on-event (new mouse-event% [event-type 'left-down] [x dx] [y (+ dy 2)] [time-stamp t]))
                     (send canvas on-event (new mouse-event% [event-type 'left-up] [x dx] [y (+ dy 2)] [time-stamp (+ t 5)])))
  (click! 1000)
  (click! 1040)
  (check-equal? (send b get-text (send b get-start-position) (send b get-end-position)) "world"))

;; ---- the tab context menu's commands (RM-071) ------------------------------------------

(test-case "tab-context-menu-groups: Close/Close Others/Close Right, then Copy Path/Reveal"
  (check-equal? (tab-context-menu-groups)
                '((close-tab close-other-tabs close-tabs-to-right) (copy-tab-path reveal-in-file-manager))))

(define (fresh-tabs names)
  (define bs (for/list ([n names]) (new-buffer! n)))
  (for ([b (all-buffers)] #:unless (or (memq b bs) (messages-buffer? b))) (kill-buffer! b))
  (set-current-buffer! (car bs))
  bs)

(test-case "Close Others closes every tab but the current one"
  (define bs (fresh-tabs '("keep" "a" "b")))
  (run-command 'close-other-tabs)
  (check-equal? (map (lambda (b) (send b get-name)) (visible-buffers)) '("keep")))

(test-case "Close Others is disabled when this is the only tab"
  (fresh-tabs '("solo"))
  (check-false (command-enabled? (find-command 'close-other-tabs))))

(test-case "Close Tabs to the Right closes only what is after this tab"
  (define bs (fresh-tabs '("a" "b" "c" "d")))
  (set-current-buffer! (cadr bs))                  ; "b"
  (run-command 'close-tabs-to-right)
  (check-equal? (map (lambda (b) (send b get-name)) (visible-buffers)) '("a" "b")))

(test-case "Close Tabs to the Right is disabled on the last tab"
  (define bs (fresh-tabs '("a" "b")))
  (set-current-buffer! (last bs))
  (check-false (command-enabled? (find-command 'close-tabs-to-right))))

(test-case "Copy Path puts the file's path on the clipboard"
  (define p (make-temporary-file "ctx-copy-path~a.txt"))
  (define b (open-file! p))
  (set-current-buffer! b)
  (run-command 'copy-tab-path)
  (check-equal? (send the-clipboard get-clipboard-string 0) (path->string p))
  (delete-file p))

(test-case "Copy Path and Reveal are disabled for an untitled (unsaved) document"
  (fresh-tabs '("untitled-ish"))
  (check-false (command-enabled? (find-command 'copy-tab-path)))
  (check-false (command-enabled? (find-command 'reveal-in-file-manager))))

(test-case "Reveal in Finder/Explorer builds the argv without running anything"
  (define p (build-path (find-system-path 'home-dir) "notes.txt"))
  (check-equal? (parameterize ([current-platform 'mac]) (reveal-argv p)) (list "open" "-R" (path->string p)))
  (check-equal? (parameterize ([current-platform 'windows]) (reveal-argv p))
                (list "explorer" (format "/select,~a" (path->string p)))))

(test-case "launch! actually runs an argv (with a harmless one, proving the subprocess arity)"
  (check-true (launch! '("true")))
  (check-false (launch! '("no-such-rackmac-test-executable"))))

;; ---- menu on-demand enabling (RM-065) ---------------------------------------------------

(test-case "opening the Edit menu enables Cut/Copy only when there is a selection"
  (define b (new-buffer! "menu-enable"))
  (set-current-buffer! b)
  (send b insert "some text")
  (send b set-position 0)
  (run-hook 'status-changed)
  (send (menu-for-title "Edit") on-demand)
  (check-false (send (menu-item-for 'cut) is-enabled?))
  (send b set-position 0 4)
  (run-hook 'status-changed)
  (send (menu-for-title "Edit") on-demand)
  (check-true (send (menu-item-for 'cut) is-enabled?))
  (check-true (send (menu-item-for 'copy) is-enabled?)))

(test-case "File > Save disables once there is nothing to save"
  (define b (new-buffer! "menu-save"))
  (set-current-buffer! b)
  (send b insert "x")
  (run-hook 'status-changed)
  (send (menu-for-title "File") on-demand)
  (check-true (send (menu-item-for 'save) is-enabled?))
  (define p (make-temporary-file "menu-save~a.txt"))
  (send b save-to! p)
  (send (menu-for-title "File") on-demand)
  (check-false (send (menu-item-for 'save) is-enabled?))
  (delete-file p))
