#lang racket/base
;; Following a link (#338, docs/UI-DESIGN.md §2.2): buffer% runs the 'follow-link hook on ⌘-click
;; (Ctrl+click on Windows); this opens the target. Web and mail links go to the browser or mail
;; app, Markdown files open in Rackmac, other files and folders open in their default app.
;; Relative paths resolve against the note's folder (md-links.rkt).
(require racket/class racket/system racket/gui/base net/sendurl
         "editor.rkt" "hook.rkt" "platform.rkt" "md-links.rkt")
(provide open-externally follow-link!)

;; How a URL or a file is handed to the system: a parameter so tests never launch anything.
;; Called with a URL string or a path.
(define (system-open target)
  (cond
    [(string? target) (send-url target)]
    [(mac?) (void (process* "/usr/bin/open" (path->string target)))]
    [(windows?) (void (shell-execute "open" (path->string target) "" (current-directory) 'sw_shownormal))]
    [else (let ([xdg (find-executable-path "xdg-open")])
            (when xdg (void (process* xdg (path->string target)))))]))
(define open-externally (make-parameter system-open))

(define (follow-link! b target)
  (define-values (kind where) (resolve-link target (send b get-path)))
  (case kind
    [(url) ((open-externally) where) (message "Opening ~a" where)]
    [(note) (set-current-buffer! (open-file! where))]
    [(file) ((open-externally) where) (message "Opening ~a" (path->string where))]
    [(missing) (message (if (send b get-path)
                            (format "Can't find ~a." where)
                            (format "Save this note first, so ~a can be found next to it." where)))]
    [else (message "Rackmac can't open ~a." where)]))

(add-hook! 'follow-link follow-link!)
