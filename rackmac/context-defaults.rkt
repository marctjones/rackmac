#lang racket/base
;; The default editor context menu, registered through the same public API extensions use.
;; Cut/Copy/Paste, then Select All, then Find; Racket documents add Run Selection, and any
;; code Language (prog-mode and its children) adds Toggle Comment.
(require "api.rkt")

(for ([c '(cut copy paste)]) (add-context-item! c #:group 'clipboard))
(add-context-item! 'select-all #:group 'select)
(add-context-item! 'find #:group 'find)
(add-context-item! 'run-selection #:group 'language #:mode 'racket-mode)
(add-context-item! 'toggle-comment #:group 'language #:mode 'prog-mode)
