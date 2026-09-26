#lang racket/base
;; Run Selection/Run Document bound in code Languages only (#288 run-code-only): the keys are
;; not merely disabled in a note, they are unbound there -- lookup-key finds nothing at all, so
;; ⌘Return really does nothing (docs/REPLAN.md S8: "⌘Return in a note does nothing"). Toggle
;; Comment and Indent/Outdent Lines are #:when code, and a document with nothing open shows the
;; start screen, never a Racket Scratch Pad.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class
         "../rackmac/commands.rkt" "../rackmac/command.rkt" "../rackmac/keymap.rkt"
         "../rackmac/mode.rkt" "../rackmac/modes.rkt" "../rackmac/editor.rkt"
         "../rackmac/frame.rkt")

(define (lookup b seq)
  (define-values (kind name) (lookup-key (send b get-keymaps) (parse-key-sequence seq)))
  (list kind name))

(test-case "Mod-Enter runs Run Selection in a code Language, and is simply unbound in Markdown"
  (define code (new-buffer! "code.rkt" #:mode 'racket-mode))
  (define note (new-buffer! "note.md" #:mode 'markdown-mode))
  (check-equal? (lookup code "Mod-Enter") '(command run-selection))
  (check-equal? (lookup note "Mod-Enter") '(none #f))
  (check-equal? (lookup code "Mod-Shift-Enter") '(command run-document))
  (check-equal? (lookup note "Mod-Shift-Enter") '(none #f)))

(test-case "the binding is inherited by any child of prog-mode, not just racket-mode"
  (register-mode! 'rco-child-mode #:parent 'prog-mode)
  (define b (new-buffer! "child" #:mode 'rco-child-mode))
  (check-equal? (lookup b "Mod-Enter") '(command run-selection)))

(test-case "Run Selection/Run Document are enabled only for a code Language"
  (define code (new-buffer! "rco-code.rkt" #:mode 'racket-mode))
  (define note (new-buffer! "rco-note.md" #:mode 'markdown-mode))
  (set-current-buffer! code)
  (check-true (command-enabled? (find-command 'run-selection)))
  (check-true (command-enabled? (find-command 'run-document)))
  (set-current-buffer! note)
  (check-false (command-enabled? (find-command 'run-selection)))
  (check-false (command-enabled? (find-command 'run-document))))

(test-case "Toggle Comment and Indent/Outdent Lines are enabled only for a code Language"
  (define code (new-buffer! "rco-code2.rkt" #:mode 'racket-mode))
  (define note (new-buffer! "rco-note2.md" #:mode 'markdown-mode))
  (set-current-buffer! code)
  (check-true (command-enabled? (find-command 'toggle-comment)))
  (check-true (command-enabled? (find-command 'indent-lines)))
  (check-true (command-enabled? (find-command 'outdent-lines)))
  (set-current-buffer! note)
  (check-false (command-enabled? (find-command 'toggle-comment)))
  (check-false (command-enabled? (find-command 'indent-lines)))
  (check-false (command-enabled? (find-command 'outdent-lines))))

(test-case "the declared shortcuts are still documented (cheat sheet, README) though unbound globally"
  (check-equal? (default-key-strings 'run-selection 'mac) '("Mod-Enter"))
  (check-equal? (default-key-strings 'run-document 'mac) '("Mod-Shift-Enter")))

(test-case "opening the app with no files shows the start screen, not a Racket document"
  (for ([b (all-buffers)] #:unless (messages-buffer? b)) (kill-buffer! b))
  (define f (or (main-frame) (make-main-frame)))
  (check-true (no-document-open?))
  (check-false (eq? (send (current-buffer) get-mode) 'racket-mode))
  (check-true (placeholder-buffer? (current-buffer))))
