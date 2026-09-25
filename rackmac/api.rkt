#lang racket/base
;; The public API: what init files and live-evaluated code get with (require rackmac/api).
(require racket/class
         "command.rkt" "keymap.rkt" "mode.rkt" "hook.rkt" "editor.rkt" "eval.rkt" "theme.rkt"
         "owner.rkt" "version.rkt" "toolbar.rkt" "status.rkt" "picker.rkt")
(provide (all-from-out racket/class)
         define-command run-command find-command all-commands
         define-mode register-mode!
         add-hook! remove-hook! run-hook
         current-buffer set-current-buffer! all-buffers new-buffer! open-file! kill-buffer!
         message log-message buffer-string selection-string insert-text replace-selection! goto-line!
         buffer-modified? show-messages!
         eval-string
         set-theme! toggle-theme! set-font-size!
         bind-key! unbind-key!
         declare-extension! (rename-out [api-version rackmac-api-version])
         ;; toolbar, status bar and UI helpers
         add-toolbar-item! remove-toolbar-item!
         add-status-segment! remove-status-segment!
         command-enabled? command-title command-icon command-help command-shortcut
         ui-parent pick)

;; (bind-key! "Mod-Shift-i" 'insert-date)                    ; everywhere
;; (bind-key! "Mod-b" 'my-command #:mode 'racket-mode)       ; only in one mode
(define (bind-key! seq cmd #:mode [mode-name #f])
  (keymap-bind! (if mode-name (mode-user-keymap mode-name) global-keymap) seq cmd))
(define (unbind-key! seq #:mode [mode-name #f])
  (keymap-unbind! (if mode-name (mode-user-keymap mode-name) global-keymap) seq))
