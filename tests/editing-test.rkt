#lang racket/base
;; Editing commands and key dispatch, driven through the real registry with real
;; text% buffers (no window needed) and synthetic key events.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/gui/base racket/list racket/file
         "../rackmac/editor.rkt" "../rackmac/command.rkt" "../rackmac/commands.rkt"
         "../rackmac/keymap.rkt" "../rackmac/input.rkt" "../rackmac/platform.rkt"
         "../rackmac/mode.rkt" "../rackmac/hook.rkt")

(define (fresh! text #:mode [m 'text-mode] #:sel [sel #f])
  (define b (new-buffer! "t" #:mode m))
  (set-current-buffer! b)
  (send b insert text)
  (if sel (send b set-position (car sel) (cdr sel)) (send b set-position 0))
  b)
(define (text b) (send b get-text))
(define (sel b) (cons (send b get-start-position) (send b get-end-position)))

(test-case "toggle-comment comments, uncomments, respects blank lines"
  (define b (fresh! "a\n\n  b\n" #:mode 'racket-mode #:sel '(0 . 6)))
  (run-command 'toggle-comment)
  (check-equal? (text b) "; a\n\n;   b\n" "comments at the common minimum indent")
  (send b set-position 0 (string-length (text b)))
  (run-command 'toggle-comment)
  (check-equal? (text b) "a\n\n  b\n")
  (send b undo)
  (check-equal? (text b) "; a\n\n;   b\n" "one undo step per command"))

(test-case "toggle-comment without comment syntax says so"
  (define b (fresh! "plain"))
  (run-command 'toggle-comment)
  (check-equal? (text b) "plain"))

(test-case "move-line-down / up keep the selection on the moved line"
  (define b (fresh! "one\ntwo\nthree" #:sel '(1 . 1)))
  (run-command 'move-line-down)
  (check-equal? (text b) "two\none\nthree")
  (check-equal? (sel b) '(5 . 5))
  (run-command 'move-line-down)
  (check-equal? (text b) "two\nthree\none")
  (run-command 'move-line-down)
  (check-equal? (text b) "two\nthree\none" "no-op on the last line")
  (run-command 'move-line-up)
  (run-command 'move-line-up)
  (check-equal? (text b) "one\ntwo\nthree"))

(test-case "duplicate-line and delete-line"
  (define b (fresh! "a\nb\nc" #:sel '(2 . 2)))
  (run-command 'duplicate-line)
  (check-equal? (text b) "a\nb\nb\nc")
  (run-command 'delete-line)
  (check-equal? (text b) "a\nb\nc")
  (send b set-position 4)
  (run-command 'delete-line)
  (check-equal? (text b) "a\nb" "deleting the last line removes the newline before it"))

(test-case "indent, outdent and newline-and-indent"
  (define b (fresh! "a\nb" #:sel '(0 . 3)))
  (run-command 'indent-or-insert)
  (check-equal? (text b) "  a\n  b")
  (run-command 'outdent-lines)
  (check-equal? (text b) "a\nb")
  (define c (fresh! "    x" #:sel '(5 . 5)))
  (run-command 'newline-and-indent)
  (check-equal? (text c) "    x\n    "))

(test-case "word motion and Shift extension"
  (define b (fresh! "hello big world" #:sel '(0 . 0)))
  (run-command 'word-right)
  (check-equal? (sel b) '(5 . 5))
  (parameterize ([extending-selection? #t]) (run-command 'word-right))
  (check-equal? (sel b) '(5 . 9) "Shift keeps the anchor")
  (send b set-position 9)
  (run-command 'delete-word-back)
  (check-equal? (text b) "hello  world"))

(test-case "run-selection runs code in the editor namespace"
  (define b (fresh! "(+ 1 2 3)" #:sel '(0 . 9)))
  (define echoed #f)
  (add-hook! 'echo (lambda (s) (set! echoed s)))
  (run-command 'run-selection)
  (check-equal? echoed "6"))

;; ---- key events ------------------------------------------------------------

;; Synthetic key events. #:cmd and #:alt describe macOS (meta-down = Command, alt-down =
;; Option). For Windows use `wkev`, which builds events the way racket/gui delivers them
;; there: Alt arrives as meta-down, and AltGr as Ctrl+Alt with control+meta-is-altgr set.
(define (kev code #:cmd [cmd #f] #:ctrl [ctrl #f] #:alt [alt #f] #:shift [shift #f]
             #:other-shift [os #f] #:altgr [ag #f])
  (define e (new key-event% [key-code code] [meta-down cmd] [control-down ctrl]
                 [alt-down alt] [shift-down shift]))
  (when os (send e set-other-shift-key-code os))
  (when ag (send e set-other-altgr-key-code ag))
  e)

(define (wkev code #:ctrl [ctrl #f] #:alt [alt #f] #:shift [shift #f] #:other-shift [os #f]
              #:altgr-char? [altgr? #f])
  (define e (new key-event% [key-code code] [control-down (or ctrl altgr?)]
                 [meta-down (or alt altgr?)] [shift-down shift]))
  (when altgr? (send e set-control+meta-is-altgr #t))
  (when os (send e set-other-shift-key-code os))
  e)

(test-case "event->key normalization (macOS)"
  (parameterize ([current-platform 'mac])
    (check-equal? (event->key (kev #\s #:cmd #t)) (key #\s '(cmd)))
    (check-equal? (event->key (kev #\P #:cmd #t #:shift #t #:other-shift #\p)) (key #\p '(shift cmd))
                  "Cmd+Shift+P reports #\\P")
    (check-equal? (event->key (kev #\å #:alt #t #:altgr #\a)) (key #\a '(alt)) "Option+a reports å")
    (check-equal? (event->key (kev 'up #:alt #t)) (key 'up '(alt)))
    (check-equal? (event->key (kev #\return #:cmd #t)) (key 'enter '(cmd)))
    (check-false (event->key (kev 'release)) "release events are ignored")
    (check-false (event->key (kev 'shift)) "bare modifiers are ignored")
    (check-equal? (event->key (kev 'prior)) (key 'pageup '()))))

(test-case "event->key normalization (Windows): Alt arrives as meta-down"
  (parameterize ([current-platform 'windows])
    (check-equal? (event->key (wkev #\z #:ctrl #t)) (key #\z '(ctrl)))
    (check-equal? (event->key (wkev #\| #:ctrl #t #:shift #t #:other-shift #\\)) (key #\\ '(ctrl shift)))
    (check-equal? (event->key (wkev 'up #:alt #t)) (key 'up '(alt)) "Alt+Up is Alt, not Cmd")
    (check-equal? (event->key (wkev #\z #:alt #t)) (key #\z '(alt)))
    (check-equal? (event->key (wkev #\x #:ctrl #t #:alt #t)) (key #\x '(ctrl alt)) "real Ctrl+Alt stays a chord")
    (check-false (event->key (wkev #\@ #:altgr-char? #t)) "AltGr+q types @: not a shortcut")))

(test-case "Windows Alt bindings dispatch (Alt+Down moves the line)"
  (parameterize ([current-platform 'windows])
    (define b (fresh! "one\ntwo" #:sel '(0 . 0)))
    (keymap-bind! global-keymap "Alt-Down" 'move-line-down)
    (check-true (dispatch-key-event b (wkev 'down #:alt #t)))
    (check-equal? (text b) "two\none")))

(test-case "dispatch: a bound key runs its command and is consumed"
  (parameterize ([current-platform 'mac])
    (define b (fresh! "a\nb" #:sel '(0 . 0)))
    (keymap-bind! global-keymap "Mod-Shift-d" 'duplicate-line)
    (check-true (dispatch-key-event b (kev #\D #:cmd #t #:shift #t #:other-shift #\d)))
    (check-equal? (text b) "a\na\nb")))

(test-case "dispatch: shift-extension falls back to the unshifted motion"
  (parameterize ([current-platform 'windows])
    (define b (fresh! "one two" #:sel '(0 . 0)))
    (keymap-bind! global-keymap "Ctrl-Right" 'word-right)
    (check-true (dispatch-key-event b (wkev 'right #:ctrl #t #:shift #t)))
    (check-equal? (sel b) '(0 . 3))))

(test-case "dispatch: plain typing is not consumed"
  (define b (fresh! ""))
  (check-false (dispatch-key-event b (kev #\a)))
  (check-false (dispatch-key-event b (kev #\A #:shift #t #:other-shift #\a))))

(test-case "dispatch: unbound Cmd combos are swallowed on Mac, Ctrl combos pass through"
  (parameterize ([current-platform 'mac])
    (define b (fresh! ""))
    (check-true (dispatch-key-event b (kev #\j #:cmd #t)) "unbound Cmd+J is swallowed")
    (check-false (dispatch-key-event b (kev #\e #:ctrl #t)) "Ctrl+E stays native macOS navigation")))

(test-case "dispatch: unbound Ctrl/Alt combos are swallowed on Windows, AltGr passes"
  (parameterize ([current-platform 'windows])
    (define b (fresh! ""))
    (check-true (dispatch-key-event b (wkev #\j #:ctrl #t)))
    (check-true (dispatch-key-event b (wkev #\j #:alt #t)) "unbound Alt+J is swallowed too")
    (check-false (dispatch-key-event b (wkev #\@ #:altgr-char? #t)) "AltGr+q types @")
    (check-false (dispatch-key-event b (wkev #\{ #:altgr-char? #t)) "AltGr+7 types {")))

(test-case "dispatch: chords wait for the second key and undefined chords are reported"
  (parameterize ([current-platform 'mac])
    (define b (fresh! "x"))
    (define echoed '())
    (define (spy s) (set! echoed (cons s echoed)))
    (add-hook! 'echo spy)
    (keymap-bind! global-keymap "Mod-k Mod-d" 'duplicate-line)
    (check-true (dispatch-key-event b (kev #\k #:cmd #t)))
    (check-equal? (pending-keys) (list (key #\k '(cmd))))
    (check-true (dispatch-key-event b (kev #\d #:cmd #t)))
    (check-equal? (text b) "x\nx")
    (check-equal? (pending-keys) '())
    (check-true (dispatch-key-event b (kev #\k #:cmd #t)))
    (check-true (dispatch-key-event b (kev #\q #:cmd #t)))
    (check-true (and (regexp-match? #rx"undefined" (car echoed)) #t))
    (check-true (dispatch-key-event b (kev #\k #:cmd #t)))
    (check-true (dispatch-key-event b (kev 'escape)))
    (check-equal? (pending-keys) '() "Escape cancels a chord")
    (remove-hook! 'echo spy)))

(test-case "minor-mode keymaps take priority over the major mode and global map"
  (register-mode! 'ct-minor #:kind 'minor)
  (define b (fresh! "x"))
  (define-command (ct-minor-cmd) (send (current-buffer) insert "M"))
  (keymap-bind! (mode-user-keymap 'ct-minor) "Ctrl-F9" 'ct-minor-cmd)
  (parameterize ([current-platform 'windows])
    (check-true (dispatch-key-event b (wkev 'f9 #:ctrl #t)) "unbound: swallowed on Windows")
    (check-false (regexp-match? #rx"M" (text b)) "and the command did not run"))
  (send b enable-minor-mode! 'ct-minor)
  (parameterize ([current-platform 'windows])
    (check-true (dispatch-key-event b (wkev 'f9 #:ctrl #t)))
    (check-true (regexp-match? #rx"M" (text b)))))

(test-case "mode change swaps locals and wrapping"
  (define b (fresh! "x" #:mode 'racket-mode))
  (check-false (send b auto-wrap) "racket-mode does not wrap")
  (send b set-mode! 'text-mode)
  (check-true (send b auto-wrap) "text-mode wraps")
  (check-equal? (send b local-ref 'comment-start #f) #f))

(test-case "buffers: file round trip preserves CRLF, mode detection, unique names"
  (define f (make-temporary-file "rackmac~a.rkt"))
  (call-with-output-file f #:exists 'truncate (lambda (o) (write-bytes #"(define x 1)\r\n; hi\r\n" o)))
  (define b (open-file! f))
  (check-equal? (send b get-mode) 'racket-mode)
  (check-equal? (text b) "(define x 1)\n; hi\n" "CRLF normalized in memory")
  (check-false (send b is-modified?))
  (send b insert "z")
  (check-true (send b is-modified?))
  (send b save-to! f)
  (check-equal? (call-with-input-file f (lambda (i) (read-bytes 100 i))) #"z(define x 1)\r\n; hi\r\n" "CRLF restored on save")
  (check-false (send b is-modified?))
  (check-eq? (open-file! f) b "same file, same buffer")
  (check-not-equal? (send (new-buffer! "dup") get-name) (send (new-buffer! "dup") get-name))
  (delete-file f))
