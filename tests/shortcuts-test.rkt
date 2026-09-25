#lang racket/base
;; Default shortcuts follow macOS, Windows, Microsoft Office and Chrome conventions.
;; The expected table below is the contract; the rules after it check EVERY default
;; binding, so a new command with an un-modern shortcut fails here.
(require rackunit racket/list racket/string
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/keymap.rkt"
         "../rackmac/platform.rkt" "../rackmac/cheatsheet.rkt" racket/file racket/runtime-path)
(define-runtime-path readme "../README.md")

(define (keys-on plat name)
  (parameterize ([current-platform plat])
    (map parse-key-sequence (default-key-strings name plat))))
(define (bound? plat str name)
  (parameterize ([current-platform plat])
    (and (member (parse-key-sequence str) (keys-on plat name)) #t)))

;; (key-string command why): Mod = Cmd on macOS, Ctrl on Windows.
(define both
  '(("Mod-n" new-buffer "New (Office, Chrome new window/doc)")
    ("Mod-t" new-buffer "New tab (Chrome)")
    ("Mod-o" open-file "Open (Office)")
    ("Mod-s" save "Save")
    ("Mod-Shift-s" save-as "Save As (macOS)")
    ("Mod-w" close-buffer "Close tab (Chrome, Office)")
    ("Mod-Shift-t" reopen-closed-tab "Reopen closed tab (Chrome)")
    ("Mod-p" print-document "Print (Office, Chrome)")
    ("Mod-z" undo "Undo")
    ("Mod-x" cut "Cut") ("Mod-c" copy "Copy") ("Mod-v" paste "Paste")
    ("Mod-a" select-all "Select all")
    ("Mod-f" find "Find")
    ("Mod-=" zoom-in "Zoom in (Chrome)") ("Mod--" zoom-out "Zoom out") ("Mod-0" zoom-reset "Actual size")
    ("Mod-1" go-to-tab-1 "Tab 1 (Chrome)") ("Mod-9" go-to-tab-9 "Last tab (Chrome)")
    ("Ctrl-Tab" next-buffer "Next tab (Chrome)") ("Ctrl-Shift-Tab" previous-buffer "Previous tab")
    ("Mod-," open-init-file "Preferences/Settings (macOS, Chrome)")))

(define mac-only
  '(("Mod-Shift-z" redo "Redo (macOS)")
    ("Mod-g" find-next "Find next (macOS)") ("Mod-Shift-g" find-previous "Find previous")
    ("Mod-Alt-f" replace "Replace (TextEdit)")
    ("Mod-Alt-Right" next-buffer "Next tab (Chrome, Safari)") ("Mod-Shift-]" next-buffer "Next tab (Chrome, Safari)")
    ("Mod-Shift-[" previous-buffer "Previous tab")
    ("Mod-q" quit "Quit")
    ("Alt-Left" word-left "Word left") ("Alt-Right" word-right "Word right")
    ("Mod-Left" line-start "Line start") ("Mod-Right" line-end "Line end")
    ("Mod-Up" doc-start "Document start") ("Mod-Down" doc-end "Document end")
    ("Alt-Backspace" delete-word-back "Delete word") ("Mod-Backspace" delete-to-line-start "Delete to line start")
    ("Ctrl-Mod-f" toggle-full-screen "Full screen (macOS)")))

(define windows-only
  '(("Ctrl-y" redo "Redo (Office)") ("Ctrl-Shift-z" redo "Redo")
    ("F3" find-next "Find next") ("Shift-F3" find-previous "Find previous")
    ("Ctrl-h" replace "Replace (Office)")
    ("Ctrl-g" goto-line "Go To (Office)")
    ("F12" save-as "Save As (Office)")
    ("Ctrl-F4" close-buffer "Close document (Office)")
    ("Ctrl-PageDown" next-buffer "Next tab (Chrome)") ("Ctrl-PageUp" previous-buffer "Previous tab")
    ("Alt-F4" quit "Close app (Windows)")
    ("F1" show-cheat-sheet "Help (Office)")
    ("Alt-q" command-palette "Search commands (Office Alt+Q)")
    ("F11" toggle-full-screen "Full screen (Chrome, Windows)")
    ("Ctrl-Left" word-left "Word left") ("Ctrl-Right" word-right "Word right")
    ("Home" line-start "Line start") ("End" line-end "Line end")
    ("Ctrl-Home" doc-start "Document start") ("Ctrl-End" doc-end "Document end")
    ("Ctrl-Backspace" delete-word-back "Delete word")))

(test-case "conventional shortcuts on both platforms"
  (for* ([plat '(mac windows)] [row both])
    (check-true (bound? plat (car row) (cadr row)) (format "~a: ~a -> ~a (~a)" plat (car row) (cadr row) (caddr row)))))

(test-case "macOS conventions"
  (for ([row mac-only])
    (check-true (bound? 'mac (car row) (cadr row)) (format "~a -> ~a (~a)" (car row) (cadr row) (caddr row)))))

(test-case "Windows and Office conventions"
  (for ([row windows-only])
    (check-true (bound? 'windows (car row) (cadr row)) (format "~a -> ~a (~a)" (car row) (cadr row) (caddr row)))))

(test-case "VS Code habits that clash with Office/Chrome are not defaults"
  (check-false (bound? 'mac "Mod-p" 'quick-open) "Cmd+P is Print")
  (check-false (bound? 'windows "Ctrl-q" 'quit) "Ctrl+Q is not Quit on Windows")
  (check-equal? (keys-on 'mac 'toggle-word-wrap) '() "Option+Z types a character on macOS"))

;; ---- rules over every default binding ----------------------------------------------

(define (all-defaults plat)
  (parameterize ([current-platform plat])
    (for*/list ([c (all-commands)] [ks (keys-on plat (command-name c))])
      (cons (command-name c) ks))))

(define mac-reserved   ; owned by macOS
  (map (lambda (s) (parameterize ([current-platform 'mac]) (parse-key s)))
       '("Mod-h" "Mod-Alt-h" "Mod-m" "Mod-Tab" "Mod-Space" "Ctrl-Space" "Mod-Alt-Escape" "Mod-Ctrl-q" "Mod-Shift-3" "Mod-Shift-4" "Mod-Shift-5")))
(define windows-reserved   ; owned by Windows
  (map (lambda (s) (parameterize ([current-platform 'windows]) (parse-key s)))
       '("Alt-Tab" "Ctrl-Escape" "Ctrl-Alt-delete" "Alt-Space" "Alt-Escape")))

(test-case "no Emacs-style multi-key chords in the defaults"
  (for* ([plat '(mac windows)] [b (all-defaults plat)])
    (check-equal? (length (cdr b)) 1 (format "~a: ~a uses a key sequence" plat (car b)))))

(test-case "macOS: no Option+character shortcuts (Option+letter types characters)"
  (for ([b (all-defaults 'mac)])
    (define k (cadr b))
    (check-false (and (equal? (key-mods k) '(alt)) (char? (key-base k)))
                 (format "~a is bound to Option+~a" (car b) (key-base k)))))

(test-case "Windows: no Ctrl+Alt+character shortcuts (that is AltGr on many layouts)"
  (for ([b (all-defaults 'windows)])
    (define k (cadr b))
    (check-false (and (memq 'ctrl (key-mods k)) (memq 'alt (key-mods k)) (char? (key-base k)))
                 (format "~a uses Ctrl+Alt+~a" (car b) (key-base k)))))

(test-case "no OS-reserved shortcuts"
  (for ([b (all-defaults 'mac)]) (check-false (member (cadr b) mac-reserved) (format "mac: ~a" (car b))))
  (for ([b (all-defaults 'windows)]) (check-false (member (cadr b) windows-reserved) (format "windows: ~a" (car b)))))

(test-case "no two commands share a default shortcut"
  (for ([plat '(mac windows)])
    (define keys (map cdr (all-defaults plat)))
    (define dups (for/list ([g (group-by values keys)] #:when (> (length g) 1)) (car g)))
    (check-equal? dups '() (format "~a duplicates" plat))))

(test-case "the README shortcut table matches the registry (regenerate from rackmac/cheatsheet.rkt)"
  (check-true (regexp-match? (regexp-quote (shortcuts-markdown)) (file->string readme))))
