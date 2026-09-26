#lang racket/base
;; The default toolbar, registered through the same public API extensions use.
(require "api.rkt")

;; #276: the toolbar's "New" button makes a note (New Code File is Tools > New Code File…,
;; for the rare quick script -- see rackmac/library/new-note.rkt and rackmac/commands.rkt).
;; With nothing open (the start screen) the bar shows only New Note, Open and the Command
;; Palette: `#:document? #f` marks the tools that apply without a document.
(add-toolbar-item! 'new-note #:group 'file #:document? #f)
(add-toolbar-item! 'open-file #:group 'file #:document? #f)
(add-toolbar-item! 'save #:group 'file)
(for ([c '(undo redo)]) (add-toolbar-item! c #:group 'history))
(for ([c '(cut copy paste)]) (add-toolbar-item! c #:group 'clipboard))
(add-toolbar-item! 'find #:group 'find)
(add-toolbar-item! 'run-selection #:group 'language #:mode 'racket-mode)   ; Run, for Racket documents
(add-toolbar-item! 'command-palette #:group 'search #:end? #t #:document? #f)
