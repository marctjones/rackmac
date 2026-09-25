#lang racket/base
;; Reload from Disk, Save All, and the large-file guard.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/file racket/string
         "../rackmac/editor.rkt" "../rackmac/commands.rkt" "../rackmac/command.rkt"
         "../rackmac/buffer.rkt" "../rackmac/hook.rkt")

(define dir (make-temporary-file "rm-files~a" 'directory))
(define (file name content) (define p (build-path dir name)) (display-to-file content p #:exists 'truncate) p)
(define last-echo #f)
(add-hook! 'echo (lambda (s) (set! last-echo s)))

(test-case "Reload from Disk picks up changes made outside, keeping the cursor nearby"
  (define p (file "r.txt" "hello world"))
  (define b (open-file! p))
  (set-current-buffer! b)
  (send b set-position 6)
  (display-to-file "hello there, world" p #:exists 'truncate)
  (run-command 'reload-from-disk)
  (check-equal? (send b get-text) "hello there, world")
  (check-equal? (send b get-start-position) 6)
  (check-false (send b is-modified?))
  (check-regexp-match #rx"Reloaded" last-echo))

(test-case "Reload from Disk asks before discarding unsaved changes"
  (define p (file "ask.txt" "disk"))
  (define b (open-file! p))
  (set-current-buffer! b)
  (send b insert "mine ")
  (parameterize ([confirm-discard-changes (lambda (b) #f)])      ; the user clicks Cancel
    (run-command 'reload-from-disk))
  (check-equal? (send b get-text) "mine disk" "kept")
  (parameterize ([confirm-discard-changes (lambda (b) #t)])      ; the user clicks Reload
    (run-command 'reload-from-disk))
  (check-equal? (send b get-text) "disk"))

(test-case "Reload from Disk explains when there is nothing to reload"
  (define b (new-buffer! "never saved"))
  (set-current-buffer! b)
  (run-command 'reload-from-disk)
  (check-regexp-match #rx"not been saved" last-echo)
  (define p (file "gone.txt" "x"))
  (define g (open-file! p))
  (set-current-buffer! g)
  (delete-file p)
  (run-command 'reload-from-disk)
  (check-regexp-match #rx"no longer exists" last-echo)
  (check-equal? (send g get-text) "x" "text kept"))

(test-case "Save All saves every modified document that has a file"
  (define p1 (file "a.txt" "a")) (define p2 (file "b.txt" "b")) (define p3 (file "c.txt" "c"))
  (define b1 (open-file! p1)) (define b2 (open-file! p2)) (define b3 (open-file! p3))
  (send b1 insert "1") (send b2 insert "2")
  (for ([b (all-buffers)] #:when (and (send b is-modified?) (not (send b get-path))))
    (send b set-modified #f))                                   ; untitled ones would open a dialog
  (run-command 'save-all)
  (check-equal? (file->string p1) "1a")
  (check-equal? (file->string p2) "2b")
  (check-equal? (file->string p3) "c" "unchanged file untouched")
  (check-regexp-match #rx"Saved 2 of 2" last-echo)
  (run-command 'save-all)
  (check-equal? last-echo "Nothing to save."))

(test-case "large files open without syntax coloring, with a message"
  (parameterize ([large-file-threshold 50])
    (define p (file "big.rkt" (string-append "(define x 1) ; " (make-string 100 #\a))))
    (define b (open-file! p))
    (check-true (send b large?))
    (check-regexp-match #rx"large file" last-echo)
    (define (fg pos) (send (send (send (send b find-snip pos 'after) get-style) get-foreground) red))
    (check-equal? (fg 1) (fg 20) "no coloring: 'define' looks like the comment")))

(test-case "small Racket files are colored"
  (define p (file "small.rkt" "(define x 1) ; note"))
  (define b (open-file! p))
  (check-false (send b large?))
  (define (fg pos) (send (send (send (send b find-snip pos 'after) get-style) get-foreground) red))
  (check-not-equal? (fg 2) (fg 16) "keyword and comment differ"))
