#lang racket/base
;; #lang rackmac: the module language, extension ownership/unloading, compile-time checks,
;; and the restriction of extensions to the public API.
(require rackunit racket/class racket/file racket/port racket/string racket/list racket/runtime-path
         "../rackmac/command.rkt" "../rackmac/eval.rkt" "../rackmac/commands.rkt"
         "../rackmac/editor.rkt" "../rackmac/keymap.rkt" "../rackmac/hook.rkt"
         "../rackmac/owner.rkt")

(define-runtime-path root "..")
(current-library-collection-paths (cons root (current-library-collection-paths)))
(define private-editor (path->string (build-path root "rackmac" "editor.rkt")))

(define dir (make-temporary-file "rackmac-lang~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))
(define ext-dir (build-path dir "ext"))

(define (write! path . lines) (make-parent-directory* path) (display-to-file (string-append* lines) path #:exists 'truncate))
(define (write-init! . lines) (apply write! (build-path dir "init.rkt") lines))
(define (write-ext! name . lines) (apply write! (build-path ext-dir name) lines))
(define (clean!)
  (when (file-exists? (build-path dir "init.rkt")) (delete-file (build-path dir "init.rkt")))
  (when (directory-exists? ext-dir) (delete-directory/files ext-dir)))

(define last-echo #f)
(add-hook! 'echo (lambda (s) (set! last-echo s)))
(define (reload!) (set! last-echo #f) (load-init!) last-echo)
(define (names) (map extension-name (loaded-extensions)))
(define (key-kind seq)
  (let-values ([(kind name) (lookup-key (list global-keymap) (parse-key-sequence seq))]) kind))

;; A built-in-style command that extensions will override.
(define-command (lt-base) #:title "Base" #:keys ("Ctrl-F3") (void))

(test-case "#lang rackmac needs no require, tracks metadata, and stays quiet"
  (clean!)
  (write-init! "#lang rackmac\n"
               "(extension-info #:name \"Mine\" #:version \"1.2\" #:requires-api 1 #:doc \"hello\")\n"
               "(define-command (lt-hello) #:title \"Hello\" #:keys (\"Ctrl-F8\") (message \"hi\"))\n"
               "(bind-key! \"Ctrl-F7\" 'lt-hello)\n"
               "(add-hook! 'lt-hook void)\n"
               "(+ 1 2)\n"                              ; a stray module-level value
               "(displayln rackmac-api-version)\n")
  (define out (with-output-to-string (lambda () (reload!))))
  (check-equal? (names) '("init.rkt"))
  (check-not-false (find-command 'lt-hello))
  (define e (car (loaded-extensions)))
  (check-equal? (hash-ref (extension-meta e) 'name) "Mine")
  (check-equal? (hash-ref (extension-meta e) 'version) "1.2")
  (check-equal? (hash-ref (extension-counts e) 'command) 1)
  (check-equal? (hash-ref (extension-counts e) 'key) 2)
  (check-equal? (hash-ref (extension-counts e) 'hook) 1)
  (check-equal? out "1\n" "the stray (+ 1 2) is not printed; only the explicit displayln is"))

(test-case "reload replaces instead of duplicating; removing the file unloads everything"
  (clean!)
  (write-init! "#lang rackmac\n"
               "(define-command (lt-once) #:keys (\"Ctrl-F6 Ctrl-F6\") (void))\n"
               "(add-hook! 'lt-fire (lambda () (message \"fired\")))\n")
  (reload!) (reload!) (reload!)
  (define before (length (regexp-match* #rx"fired" (send (messages-buffer) get-text))))
  (run-hook 'lt-fire)
  (check-equal? (- (length (regexp-match* #rx"fired" (send (messages-buffer) get-text))) before) 1
                "the hook fires once after three reloads")
  (check-equal? (key-kind "Ctrl-F6") 'prefix)
  (clean!) (reload!)
  (check-false (find-command 'lt-once) "command removed")
  (check-equal? (key-kind "Ctrl-F6 Ctrl-F6") 'none "chord removed")
  (check-equal? (key-kind "Ctrl-F6") 'none "emptied prefix is not left behind")
  (let ([n (length (regexp-match* #rx"fired" (send (messages-buffer) get-text)))])
    (run-hook 'lt-fire)
    (check-equal? (length (regexp-match* #rx"fired" (send (messages-buffer) get-text))) n "hook removed")))

(test-case "overriding a command is undone on unload, restoring the original"
  (clean!)
  (write-init! "#lang rackmac\n"
               "(define-command (lt-base) #:title \"Override\" #:keys (\"Ctrl-F3\" \"Ctrl-F4\") (void))\n")
  (reload!)
  (check-equal? (command-title (find-command 'lt-base)) "Override")
  (check-equal? (key-kind "Ctrl-F4") 'command)
  (clean!) (reload!)
  (check-equal? (command-title (find-command 'lt-base)) "Base")
  (check-equal? (key-kind "Ctrl-F3") 'command "original binding survives")
  (check-equal? (key-kind "Ctrl-F4") 'none))

(test-case "an API version that is too new is a compile-time error and registers nothing"
  (clean!)
  (write-init! "#lang rackmac\n"
               "(define-command (lt-never) (void))\n"
               "(extension-info #:requires-api 999)\n")
  (check-regexp-match #rx"needs Rackmac API 999" (reload!))
  (check-false (find-command 'lt-never))
  (check-equal? (names) '()))

(test-case "a bad key string is a compile-time error naming the string"
  (clean!)
  (write-init! "#lang rackmac\n(define-command (lt-badkey) #:keys (\"Mod-Bogus\") (void))\n")
  (check-regexp-match #rx"unrecognised key" (reload!))
  (check-false (find-command 'lt-badkey)))

(test-case "a runtime failure unloads what the file had already registered"
  (clean!)
  (write-init! "#lang rackmac\n"
               "(define-command (lt-partial) #:keys (\"Ctrl-F2\") (void))\n"
               "(error 'init \"boom\")\n")
  (check-regexp-match #rx"init.rkt failed: .*boom" (reload!))
  (check-false (find-command 'lt-partial))
  (check-equal? (key-kind "Ctrl-F2") 'none))

(test-case "extensions may use the public API but not private core modules"
  (clean!)
  (write-init! "#lang racket/base\n(require rackmac/api racket/list)\n(define-command (lt-ok) (void))\n")
  (check-regexp-match #rx"Loaded 1" (reload!))
  (check-not-false (find-command 'lt-ok))
  (clean!)
  (write-init! "#lang racket/base\n(require (file \"" private-editor "\"))\n(define-command (lt-sneaky) (void))\n")
  (check-regexp-match #rx"private core module editor.rkt" (reload!))
  (check-false (find-command 'lt-sneaky))
  (clean!)
  (write-init! "#lang racket/base\n(require rackmac/commands)\n")
  (check-regexp-match #rx"private core module commands.rkt" (reload!)))

(test-case "ext/*.rkt loads after init.rkt, in name order, each as its own extension"
  (clean!)
  (write-init! "#lang rackmac\n(extension-info #:name \"main\")\n")
  (write-ext! "b.rkt" "#lang rackmac\n(define-command (lt-b) (void))\n")
  (write-ext! "a.rkt" "#lang rackmac\n(define-command (lt-a) (void))\n")
  (write-ext! "notes.txt" "not racket")
  (check-regexp-match #rx"Loaded 3 extension files" (reload!))
  (check-equal? (names) '("init.rkt" "a.rkt" "b.rkt"))
  (write-ext! "a.rkt" "#lang rackmac\n(error 'a \"broken\")\n")
  (reload!)
  (check-equal? (names) '("init.rkt" "b.rkt") "one broken extension does not stop the rest")
  (check-not-false (find-command 'lt-b)))

(test-case "List Extensions describes what is loaded"
  (clean!)
  (write-init! "#lang rackmac\n(extension-info #:name \"Lister\" #:doc \"listed\")\n(define-command (lt-l) (void))\n")
  (reload!)
  (run-command 'list-extensions)
  (define text (send (current-buffer) get-text))
  (check-regexp-match #rx"Lister" text)
  (check-regexp-match #rx"1 command" text)
  (check-regexp-match #rx"listed" text))

(test-case "the generated init template loads under #lang rackmac and its command works"
  (clean!)
  (run-command 'open-init-file)                   ; writes the template and opens it
  (check-true (file-exists? (build-path dir "init.rkt")))
  (check-regexp-match #rx"^#lang rackmac" (file->string (build-path dir "init.rkt")))
  (check-regexp-match #rx"Loaded 1" (reload!))
  (check-not-false (find-command 'insert-date))
  (define b (new-buffer! "scratch-for-template"))
  (set-current-buffer! b)
  (run-command 'insert-date)
  (check-true (> (send b last-position) 0) "Insert Date inserted something"))

(test-case "the new metadata keywords work from #lang rackmac"
  (clean!)
  (write-init! "#lang rackmac\n"
               "(define-command (lt-meta) #:title \"Meta\" #:aliases (\"frobnicate\" \"twiddle\")\n"
               "  #:help \"Does it.\" #:icon \"play\" #:when (lambda () #t) (void))\n")
  (check-regexp-match #rx"Loaded 1" (reload!))
  (define c (find-command 'lt-meta))
  (check-equal? (command-aliases c) '("frobnicate" "twiddle"))
  (check-equal? (command-help c) "Does it.")
  (check-equal? (command-icon c) "play")
  (check-true (command-enabled? c))
  (clean!) (reload!)
  (check-false (find-command 'lt-meta) "and it unloads with the extension"))
