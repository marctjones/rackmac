#lang racket/base
;; The restyled command palette and the searchable shortcut cheat sheet: picker.rkt dressed
;; up with placement over the top third of the main window, a Category column, a help/alias
;; footer and a helpful empty state (docs/UI-DESIGN.md §2, §7.3; issues #257, #30, #31, #39).
(require racket/class racket/string racket/gui/base
         "../command.rkt" "../editor.rkt" "../picker.rkt" "../cheatsheet.rkt")
(provide dialog-placement command-palette-columns cheat-sheet-columns
         emacs-alias-of palette-pick cheat-sheet-pick)

;; Pure placement math (docs/UI-DESIGN.md §2): center the dialog horizontally on the frame;
;; its top sits 15% of the way down from the frame's top ("over the top third"). Takes plain
;; numbers, not a frame object, so it needs no window to test.
(define (dialog-placement frame-x frame-y frame-w frame-h dialog-w dialog-h)
  (values (+ frame-x (quotient (- frame-w dialog-w) 2))
          (+ frame-y (inexact->exact (round (* frame-h 0.15))))))

;; The impure half: reads the main frame's screen geometry from (ui-parent) and returns
;; (cons x y) for picker.rkt's #:placement, or #f when there is no frame to place it over.
(define (frame-placement dialog-w dialog-h)
  (define f (ui-parent))
  (and (is-a? f frame%)
       (let-values ([(x y) (dialog-placement (send f get-x) (send f get-y)
                                              (send f get-width) (send f get-height)
                                              dialog-w dialog-h)])
         (cons x y))))

;; A dialog% with a parent shows as a Cocoa sheet (and ignores `move`) unless 'no-sheet is in
;; its style; 'no-caption additionally drops the title bar, on the platforms that accept it
;; for dialog% (verified for macOS; see docs/DEVELOPMENT.md and the palette-test.rkt note).
(define (palette-dialog-style)
  (if (eq? (system-type 'os) 'macosx) '(no-sheet no-caption) '(no-sheet)))

(define command-palette-columns (list "Command" "Category" "Shortcut"))
(define cheat-sheet-columns (list "Command" "Category" "macOS" "Windows"))

;; An alias that reads as an Emacs command name: "M-..."/"C-..." forms first (M-x, C-g), else
;; a hyphenated, space-free word (kill-region); a plain word like "yank" only counts once no
;; hyphenated alias exists, so Paste still shows "Emacs: yank".
(define (emacs-alias-of c)
  (define aliases (command-aliases c))
  (or (for/first ([a (in-list aliases)] #:when (regexp-match? #rx"^(M-|C-)" a)) a)
      (for/first ([a (in-list aliases)] #:when (and (regexp-match? #rx"-" a) (not (regexp-match? #rx" " a)))) a)
      (for/first ([a (in-list aliases)] #:when (not (regexp-match? #rx" " a))) a)))

(define hint "↑↓ move · ⏎ run · esc close")

;; item: (list title shortcut name search-fields category), per commands.rkt's palette-items.
(define (command-footer it q)
  (cond
    [(not it) (format "No commands match '~a'. Check the spelling, or open Help > Keyboard Shortcuts." q)]
    [else
     (define c (find-command (caddr it)))
     (define alias (and c (emacs-alias-of c)))
     (string-append (if c (command-help c) "")
                     (if alias (format "   Emacs: ~a" alias) "")
                     "   " hint)]))

;; Used by both the Command Palette and Explain a Command, so both get the restyled columns,
;; placement, footer and empty state (they search the same list: commands.rkt's palette-items).
(define (palette-pick prompt items)
  (pick prompt items
        #:columns command-palette-columns
        #:cells (lambda (it) (list (list-ref it 4) (cadr it)))   ; Category, then Shortcut
        #:style (palette-dialog-style)
        #:placement frame-placement
        #:footer command-footer
        #:no-match (lambda (q) (format "No commands match '~a'" q))))

;; Every default shortcut on both platforms, grouped by category (shortcut-rows is already
;; menu-ranked) and filterable by typing; Enter runs the selected command (RM-039).
(define (cheat-sheet-items)
  (for/list ([row (shortcut-rows)])
    (define menu (car row)) (define title (cadr row))
    (define mac (caddr row)) (define win (cadddr row))
    (define c (for/first ([cc (all-commands)] #:when (string=? (command-title cc) title)) cc))
    (list title menu (and c (command-name c)) (if c (command-aliases c) '()) mac win)))

(define (cheat-sheet-footer it q)
  (cond
    [(not it) (format "No shortcuts match '~a'. Check the spelling, or open Help > Keyboard Shortcuts." q)]
    [else
     (define c (and (caddr it) (find-command (caddr it))))
     (string-append (if c (command-help c) "") "   " hint)]))

(define (cheat-sheet-pick)
  (pick "Keyboard Shortcuts" (cheat-sheet-items)
        #:columns cheat-sheet-columns
        #:cells (lambda (it) (list (cadr it) (list-ref it 4) (list-ref it 5)))  ; Category, macOS, Windows
        #:style (palette-dialog-style)
        #:placement frame-placement
        #:footer cheat-sheet-footer
        #:no-match (lambda (q) (format "No shortcuts match '~a'" q))))
