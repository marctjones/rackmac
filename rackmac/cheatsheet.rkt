#lang racket/base
;; A shortcut table for both platforms, generated from the command registry. Used for the
;; README (a test keeps them identical) and, later, the in-app cheat sheet.
(require racket/list racket/string "command.rkt" "keymap.rkt" "platform.rkt")
(provide shortcut-rows shortcuts-markdown)

(define menu-order '("File" "Edit" "View" "Tools" "Help" #f))

(define (show plat name)
  (define strs (default-key-strings name plat))
  (if (null? strs)
      "—"
      (parameterize ([current-platform plat])
        (string-join (map (lambda (s) (key-sequence->string (parse-key-sequence s))) strs) ", "))))

;; (list menu title mac-keys windows-keys) for every command that has a default key.
(define (shortcut-rows)
  (define cs (filter (lambda (c) (or (pair? (default-key-strings (command-name c) 'mac))
                                     (pair? (default-key-strings (command-name c) 'windows))))
                     (all-commands)))
  (define (menu-rank c) (or (index-of menu-order (command-menu c)) 99))
  (for/list ([c (sort cs (lambda (a b) (or (< (menu-rank a) (menu-rank b))
                                          (and (= (menu-rank a) (menu-rank b))
                                               (< (command-menu-order a) (command-menu-order b))))))])
    (list (or (command-menu c) "Editing") (command-title c)
          (show 'mac (command-name c)) (show 'windows (command-name c)))))

(define (shortcuts-markdown)
  (string-append
   "| Menu | Command | macOS | Windows |\n|---|---|---|---|\n"
   (string-join (for/list ([r (shortcut-rows)])
                  (format "| ~a | ~a | ~a | ~a |" (first r) (second r) (third r) (fourth r)))
                "\n")
   "\n"))
