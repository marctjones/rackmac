#lang racket/base
;; The default toolbar, registered through the same public API extensions use.
(require "api.rkt")

(for ([c '(new-document open-file save)]) (add-toolbar-item! c #:group 'file))
(for ([c '(undo redo)]) (add-toolbar-item! c #:group 'history))
(for ([c '(cut copy paste)]) (add-toolbar-item! c #:group 'clipboard))
(add-toolbar-item! 'find #:group 'find)
(add-toolbar-item! 'run-selection #:group 'language #:mode 'racket-mode)   ; Run, for Racket documents
(add-toolbar-item! 'command-palette #:group 'search #:end? #t)
