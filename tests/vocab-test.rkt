#lang racket/base
;; The vocabulary layer: friendly titles, Emacs-name aliases, help text, palette search,
;; recents, and Describe. The layer is display-only, so command NAMES are pinned here:
;; a user's init.rkt refers to them (bind-key!, run-command), and must never break.
(require rackunit racket/class racket/list racket/string
         "../rackmac/command.rkt" "../rackmac/commands.rkt" "../rackmac/mode.rkt"
         "../rackmac/keymap.rkt" "../rackmac/editor.rkt" "../rackmac/picker.rkt"
         "../rackmac/glossary.rkt" racket/file racket/runtime-path)
(define-runtime-path readme "../README.md")

(define golden-names
  '(about close-buffer close-other-tabs close-tabs-to-right command-palette copy copy-tab-path
    cut delete-line delete-to-line-start delete-word-back
    delete-word-forward describe-command describe-key doc-end doc-start duplicate-line eval-buffer
    go-to-tab-1 go-to-tab-2 go-to-tab-3 go-to-tab-4 go-to-tab-5 go-to-tab-6 go-to-tab-7 go-to-tab-8 go-to-tab-9
    print-document reopen-closed-tab reveal-in-file-manager toggle-full-screen reload-from-disk save-all toggle-toolbar
    eval-selection find find-next find-previous goto-line indent-lines indent-or-insert line-end
    line-start list-extensions list-keybindings move-line-down move-line-up new-buffer
    newline-and-indent next-buffer open-file open-init-file outdent-lines page-down page-up paste
    previous-buffer quick-open quit redo reload-init replace save save-as select-all select-line
    set-line-endings set-major-mode show-encoding show-glossary show-messages toggle-comment toggle-theme
    toggle-word-wrap undo word-left word-right zoom-in zoom-out zoom-reset))

(test-case "built-in command names are stable (relabeling never renames a symbol)"
  (check-equal? (sort builtin-command-names symbol<?) (sort golden-names symbol<?))
  (for ([n golden-names]) (check-not-false (find-command n) (format "~a still resolves" n))))

(test-case "every built-in command has help text and at least one alias"
  (for ([n builtin-command-names])
    (define c (find-command n))
    (check-false (string=? (command-help c) "") (format "~a has help" n))
    (check-true (pair? (command-aliases c)) (format "~a has aliases" n))
    (check-true (string? (command-title c)))
    (check-false (regexp-match? #rx"-mode$|^[*]" (command-title c)) (format "~a title has no Emacs jargon" n))))

(test-case "help is one plain sentence"
  (for ([n builtin-command-names])
    (define h (command-help (find-command n)))
    (check-true (regexp-match? #rx"[.]$" h) (format "~a help ends with a period" n))
    (check-true (< (string-length h) 100) (format "~a help is short" n))))

(define (top q) (let ([m (palette-matches q)]) (and (pair? m) (car m))))

(test-case "the palette finds commands by Emacs names and office words"
  (check-eq? (top "yank") 'paste)
  (check-eq? (top "kill-region") 'cut)
  (check-eq? (top "isearch") 'find)
  (check-eq? (top "query-replace") 'replace)
  (check-eq? (top "M-x") 'command-palette)
  (check-eq? (top "kill-whole-line") 'delete-line)
  (check-eq? (top "beginning-of-line") 'line-start)
  (check-eq? (top "dark mode") 'toggle-theme)
  (check-eq? (top "init.el") 'open-init-file)
  (check-not-false (memq 'paste (palette-matches "paste")) "the ordinary word still works")
  (check-equal? (palette-matches "zzzzqqq") '() "no match gives an empty list"))

(test-case "recents come first when the box is empty"
  (define b (new-buffer! "vocab"))
  (set-current-buffer! b)
  (send b insert "x")
  (run-command 'select-all)
  (run-command 'copy)
  (run-command 'select-all)                 ; repeated: moves to the front, no duplicates
  (define names (map caddr (palette-items)))
  (check-equal? (take names 2) '(select-all copy))
  (check-equal? (length names) (length (remove-duplicates names)))
  (check-equal? (recent-commands) '(select-all copy))
  (check-exn exn:fail? (lambda () (run-command 'command-palette-never)))
  (check-false (memq 'command-palette-never (recent-commands)) "a failed lookup is not recorded"))

(test-case "the palette itself is not recorded as a recent command"
  (check-false (memq 'command-palette (recent-commands))))

(test-case "Describe shows both names, aliases, shortcut and help"
  (define text (command-description 'paste))
  (check-regexp-match #rx"^Paste  [(]paste[)]" text)
  (check-regexp-match #rx"Insert the clipboard contents" text)
  (check-regexp-match #rx"Also known as: yank" text)
  (check-regexp-match #rx"Shortcut: " text))

(test-case "friendly titles for the vocabulary examples"
  (check-equal? (command-title (find-command 'describe-key)) "What Does This Key Do?")
  (check-regexp-match #rx"describe-key" (string-join (command-aliases (find-command 'describe-key)) " ")))

(test-case "modes have display labels"
  (check-equal? (mode-display-name 'racket-mode) "Racket")
  (check-equal? (mode-display-name 'text-mode) "Plain Text")
  (check-equal? (mode-display-name 'markdown-mode) "Markdown")
  (check-equal? (mode-display-name 'prog-mode) "Code")
  (register-mode! 'vocab-fancy-mode)
  (check-equal? (mode-display-name 'vocab-fancy-mode) "Vocab Fancy" "default: strip -mode and title-case")
  (check-equal? (mode-display-name 'never-registered-mode) "Never Registered"))

(test-case "#:when decides whether a command applies, and a failing predicate counts as enabled"
  (define on? #f)
  (define-command (vocab-when) #:when (lambda () on?) (void))
  (define-command (vocab-when-bad) #:when (lambda () (error "boom")) (void))
  (define-command (vocab-when-none) (void))
  (check-false (command-enabled? (find-command 'vocab-when)))
  (set! on? #t)
  (check-true (command-enabled? (find-command 'vocab-when)))
  (check-true (command-enabled? (find-command 'vocab-when-bad)))
  (check-true (command-enabled? (find-command 'vocab-when-none))))

(test-case "new metadata keywords are stored and searchable"
  (define-command (vocab-meta) #:title "Vocab Meta" #:aliases ("frobnicate" "twiddle")
    #:help "Does a thing." #:icon "play" (void))
  (define c (find-command 'vocab-meta))
  (check-equal? (command-aliases c) '("frobnicate" "twiddle"))
  (check-equal? (command-help c) "Does a thing.")
  (check-equal? (command-icon c) "play")
  (check-regexp-match #rx"frobnicate" (command-search-text c))
  (check-eq? (top "twiddle") 'vocab-meta))

(test-case "renamed titles (display only) and old names still find them"
  (for ([p '((eval-selection "Run Selection") (eval-buffer "Run Document")
             (show-messages "Show Activity Log") (set-major-mode "Set Language…")
             (open-init-file "Customize with Code") (reload-init "Reload Extensions")
             (list-keybindings "Keyboard Shortcuts") (new-buffer "New Document")
             (describe-command "Explain a Command…"))])
    (check-equal? (command-title (find-command (car p))) (cadr p)))
  (check-eq? (top "Run Selection") 'eval-selection)
  (check-eq? (top "eval-region") 'eval-selection)
  (check-eq? (top "evaluate selection") 'eval-selection "the old title still finds it")
  (check-eq? (top "reload init file") 'reload-init)
  (check-eq? (top "*Messages*") 'show-messages)
  (check-eq? (top "describe-function") 'describe-command)
  (check-eq? (top "glossary") 'show-glossary))

(test-case "buffer display names have no Emacs stars"
  (check-equal? (send (messages-buffer) get-name) "Activity")
  (run-command 'list-keybindings)
  (check-equal? (send (current-buffer) get-name) "Keyboard Shortcuts")
  (run-command 'show-glossary)
  (check-equal? (send (current-buffer) get-name) "Glossary")
  (check-regexp-match #rx"kill ring +Clipboard History" (send (current-buffer) get-text)))

(test-case "the README glossary table matches the code"
  (check-true (regexp-match? (regexp-quote (glossary-markdown)) (file->string readme))
              "regenerate the README table from rackmac/glossary.rkt"))

(test-case "Emacs terms for commands that exist find them in the palette (kill ring waits for Clipboard History)"
  (for ([g glossary] #:when (member (car g) '("kill / yank" "M-x" "describe-key" "describe-function" "*Messages*")))
    (check-true (pair? (palette-matches (car (regexp-split #rx" / |, " (car g))))) (car g))))
