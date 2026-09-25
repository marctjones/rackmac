#lang racket/base
;; Regressions for the must-fix items from the code review (Fable, 2026-09-25).
(require rackunit racket/class racket/gui/base racket/file racket/list
         "../rackmac/editor.rkt" "../rackmac/commands.rkt" "../rackmac/command.rkt"
         "../rackmac/keymap.rkt" "../rackmac/mode.rkt" "../rackmac/owner.rkt"
         "../rackmac/platform.rkt" "../rackmac/fileio.rkt")

;; ---- files through the editor --------------------------------------------------

(define dir (make-temporary-file "rm-p0~a" 'directory))

(test-case "a Latin-1 file survives open, edit and save (no U+FFFD corruption)"
  (define f (build-path dir "latin.txt"))
  (call-with-output-file f (lambda (o) (write-bytes #"caf\351\r\n" o)))
  (define b (open-file! f))
  (check-equal? (send b get-text) "café\n")
  (check-eq? (send b local-ref 'encoding) 'latin-1)
  (send b insert "!" (send b last-position))
  (send b save-to! f)
  (check-equal? (file->bytes f) #"caf\351\r\n!"))

(test-case "a binary file opens read-only and cannot be saved"
  (define f (build-path dir "blob.bin"))
  (call-with-output-file f (lambda (o) (write-bytes #"\0\1\2abc" o)))
  (define b (open-file! f))
  (check-true (send b is-locked?))
  (check-exn exn:fail:rackmac-encoding? (lambda () (send b save-to! f)))
  (check-equal? (file->bytes f) #"\0\1\2abc" "file untouched"))

(test-case "opening a path that does not exist yet still picks its Language"
  (define b (open-file! (build-path dir "new-file.rkt")))
  (check-eq? (send b get-mode) 'racket-mode))

;; ---- closing tabs ----------------------------------------------------------------

(test-case "closing a tab moves to the nearest visible tab, never the hidden Activity log"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (define a (new-buffer! "A"))
  (void (messages-buffer))                       ; hidden, and earlier in the list than B and C
  (define bb (new-buffer! "B"))
  (define c (new-buffer! "C"))
  (set-current-buffer! bb)
  (kill-buffer! bb)
  (check-eq? (current-buffer) c "the right-hand neighbour")
  (kill-buffer! c)
  (check-eq? (current-buffer) a)
  (check-true (send (current-buffer) is-shown?))
  (kill-buffer! a)
  (check-equal? (send (current-buffer) get-name) "Scratch Pad" "a fresh Scratch Pad when nothing is left")
  (check-false (messages-buffer? (current-buffer))))

(test-case "closing the Activity log hides it; later messages are still recorded"
  (show-messages!)
  (define m (current-buffer))
  (check-true (messages-buffer? m))
  (kill-buffer! m)
  (check-false (send m is-shown?))
  (check-not-eq? (current-buffer) m)
  (message "after close")
  (check-regexp-match #rx"after close" (send (messages-buffer) get-text))
  (check-eq? (messages-buffer) m "the same log, not a new one"))

;; ---- modes -------------------------------------------------------------------------

(test-case "a child mode can turn off a setting its parent turned on"
  (register-mode! 'p0-nowrap-mode #:parent 'text-mode #:locals '((wrap-lines . #f)))
  (check-false (mode-local 'p0-nowrap-mode 'wrap-lines #t))
  (define b (new-buffer! "nowrap" #:mode 'p0-nowrap-mode))
  (check-false (send b auto-wrap))
  (check-true (mode-local 'text-mode 'wrap-lines #f) "the parent is unchanged"))

;; ---- keymap undo and layering -----------------------------------------------------------

(define (kind kms seq) (let-values ([(k n) (lookup-key kms (parse-key-sequence seq))]) (list k n)))

(test-case "unloading restores a command that an extension turned into a chord prefix"
  (define km (make-keymap))
  (keymap-bind! km "Ctrl-F5" 'original)
  (define ext (make-extension "p0"))
  (parameterize ([current-extension ext]) (keymap-bind! km "Ctrl-F5 Ctrl-a" 'chord))
  (check-equal? (kind (list km) "Ctrl-F5") '(prefix #f))
  (unload-extension! ext)
  (check-equal? (kind (list km) "Ctrl-F5") '(command original)))

(test-case "unbind-key! from an extension is undone on unload"
  (define km (make-keymap))
  (keymap-bind! km "Ctrl-F6" 'keep-me)
  (define ext (make-extension "p0"))
  (parameterize ([current-extension ext]) (keymap-unbind! km "Ctrl-F6"))
  (check-equal? (kind (list km) "Ctrl-F6") '(none #f))
  (unload-extension! ext)
  (check-equal? (kind (list km) "Ctrl-F6") '(command keep-me)))

(test-case "a higher layer's chord prefix is not hidden by a lower layer's command"
  (define minor (make-keymap 'minor))
  (define global (make-keymap 'global))
  (keymap-bind! global "Ctrl-F7" 'global-cmd)
  (keymap-bind! minor "Ctrl-F7 Ctrl-x" 'minor-chord)
  (check-equal? (kind (list minor global) "Ctrl-F7") '(prefix #f))
  (check-equal? (kind (list minor global) "Ctrl-F7 Ctrl-x") '(command minor-chord))
  (check-equal? (kind (list global) "Ctrl-F7") '(command global-cmd) "without the minor mode"))

(test-case "Reopen Closed Tab brings back the most recently closed file (Chrome's Cmd/Ctrl+Shift+T)"
  (define f1 (build-path dir "one.txt")) (define f2 (build-path dir "two.txt"))
  (display-to-file "1" f1 #:exists 'truncate) (display-to-file "2" f2 #:exists 'truncate)
  (define b1 (open-file! f1)) (define b2 (open-file! f2))
  (kill-buffer! b1) (kill-buffer! b2)
  (run-command 'reopen-closed-tab)
  (check-equal? (send (current-buffer) get-text) "2" "most recent first")
  (run-command 'reopen-closed-tab)
  (check-equal? (send (current-buffer) get-text) "1"))

(test-case "Go to Tab N and Go to Last Tab"
  (define bs (for/list ([n '("t1" "t2" "t3")]) (new-buffer! n)))
  (for ([b (all-buffers)] #:unless (or (memq b bs) (messages-buffer? b))) (kill-buffer! b))
  (check-equal? (visible-buffers) bs)
  (run-command 'go-to-tab-2)
  (check-eq? (current-buffer) (cadr bs))
  (run-command 'go-to-tab-9)
  (check-eq? (current-buffer) (last bs))
  (run-command 'go-to-tab-7)
  (check-eq? (current-buffer) (last bs) "past the end goes to the last tab"))
