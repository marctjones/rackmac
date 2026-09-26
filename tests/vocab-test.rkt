#lang racket/base
;; The vocabulary layer: friendly titles, office-word aliases, help text, palette search,
;; recents, and Describe. The layer is display-only, so command NAMES are pinned here:
;; a user's init.rkt refers to them (bind-key!, run-command), and must never break.
;; Emacs vocabulary does not belong in this file's aliases or expectations: the default
;; product's default is checked here and in tests/no-emacs-test.rkt; the Emacs preset's own
;; names live only in rackmac/presets/emacs-names.rktd (v0.8, epic E13).
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/list racket/string
         "../rackmac/command.rkt" "../rackmac/commands.rkt" "../rackmac/mode.rkt"
         "../rackmac/keymap.rkt" "../rackmac/editor.rkt" "../rackmac/picker.rkt"
         "../rackmac/ui/settings-dialog.rkt" "../rackmac/tools-menu.rkt"
         "../rackmac/md-view-commands.rkt"
         "../rackmac/md-format.rkt" "../rackmac/md-lists.rkt")

(define golden-names
  '(about close-tab close-other-tabs close-tabs-to-right command-palette copy copy-tab-path
    cut delete-line delete-to-line-start delete-word-back
    delete-word-forward describe-command describe-key doc-end doc-start duplicate-line run-document
    go-to-tab-1 go-to-tab-2 go-to-tab-3 go-to-tab-4 go-to-tab-5 go-to-tab-6 go-to-tab-7 go-to-tab-8 go-to-tab-9
    print-document reopen-closed-tab reveal-in-file-manager toggle-full-screen reload-from-disk save-all toggle-toolbar
    run-selection find find-next find-previous goto-line indent-lines indent-or-insert line-end
    line-start list-extensions list-keybindings move-line-down move-line-up new-document
    newline-and-indent next-tab open-file customize-with-code outdent-lines page-down page-up paste
    previous-tab quick-open quit redo reload-init replace save save-as select-all select-line
    set-line-endings set-language show-cheat-sheet show-encoding show-activity-log
    toggle-comment toggle-theme toggle-word-wrap undo word-left word-right zoom-in zoom-out zoom-reset))

(test-case "built-in command names are stable (relabeling never renames a symbol)"
  (check-equal? (sort builtin-command-names symbol<?) (sort golden-names symbol<?))
  (for ([n golden-names]) (check-not-false (find-command n) (format "~a still resolves" n))))

;; Commands from feature modules (their own files, not commands.rkt): pinned the same way.
(define feature-command-names
  '(toggle-markdown-view                                     ; #269
    toggle-bold toggle-italic toggle-inline-code toggle-strikethrough insert-link              ; #335
    heading-1 heading-2 heading-3 body-text
    toggle-bulleted-list toggle-numbered-list toggle-checklist toggle-quote mark-done
    markdown-enter markdown-indent markdown-outdent))                                          ; #337

(test-case "feature command names are stable, with help and aliases"
  (for ([n feature-command-names])
    (define c (find-command n))
    (check-not-false c (format "~a still resolves" n))
    (check-false (string=? (command-help c) "") (format "~a has help" n))
    (check-true (pair? (command-aliases c)) (format "~a has aliases" n))))

(test-case "the Emacs glossary command is gone from the default product (moved to docs/emacs-glossary.md, #263)"
  (check-false (find-command 'show-glossary))
  (check-false (memq 'show-glossary builtin-command-names)))

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

(test-case "the palette finds commands by office words (the default has no Emacs names)"
  (check-eq? (top "paste") 'paste)
  (check-eq? (top "cut selection") 'cut)
  (check-eq? (top "search") 'find)
  (check-eq? (top "find and replace") 'replace)
  (check-eq? (top "run command") 'command-palette)
  (check-eq? (top "remove line") 'delete-line)
  (check-eq? (top "home") 'line-start)
  (check-eq? (top "dark mode") 'toggle-theme)
  (check-eq? (top "settings") 'open-settings)
  (check-eq? (top "preferences") 'open-settings)
  (check-eq? (top "edit as code") 'customize-with-code)
  (check-eq? (top "scratch pad") 'open-scratch-pad)
  (check-eq? (top "run code") 'run-selection)
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
  (check-regexp-match #rx"Also known as: paste clipboard" text)
  (check-regexp-match #rx"Shortcut: " text))

(test-case "friendly titles for the vocabulary examples"
  (check-equal? (command-title (find-command 'describe-key)) "What Does This Key Do?")
  (check-regexp-match #rx"help key" (string-join (command-aliases (find-command 'describe-key)) " ")))

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
  (for ([p '((run-selection "Run Selection") (run-document "Run Document")
             (show-activity-log "Show Activity Log") (set-language "Set Language…")
             (customize-with-code "Customize with Code") (reload-init "Reload Extensions")
             (show-cheat-sheet "Keyboard Shortcuts") (list-keybindings "Shortcuts as Text")
             (new-document "New Document") (describe-command "Explain a Command…"))])
    (check-equal? (command-title (find-command (car p))) (cadr p)))
  (check-eq? (top "Run Selection") 'run-selection)
  (check-eq? (top "run code") 'run-selection)
  (check-eq? (top "evaluate selection") 'run-selection "the old title still finds it")
  (check-eq? (top "reload init file") 'reload-init)
  (check-eq? (top "show messages") 'show-activity-log)
  (check-eq? (top "explain command") 'describe-command)
  (check-eq? (top "cheat sheet") 'show-cheat-sheet)
  (check-eq? (top "shortcuts as text") 'list-keybindings))

(test-case "buffer display names have no Emacs stars"
  (check-equal? (send (messages-buffer) get-name) "Activity")
  (run-command 'list-keybindings)
  (check-equal? (send (current-buffer) get-name) "Shortcuts as Text"))

(test-case "the default product's aliases carry no Emacs names (the preset restores them from rackmac/presets/emacs-names.rktd)"
  (for ([term '("yank" "kill-region" "isearch" "M-x" "*Messages*" "describe-function"
                "kill-whole-line" "beginning-of-line" "eval-region")])
    (check-equal? (palette-matches term) '() (format "'~a' should not match by default" term))))
