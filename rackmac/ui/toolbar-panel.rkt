#lang racket/base
;; The toolbar row: native button%s with vector icon bitmaps, built from the toolbar
;; registry for the current document's Language. Buttons dim when their command's #:when
;; says it does not apply; hovering shows the command and its shortcut in the status bar.
(require racket/class racket/gui/base racket/list racket/string
         "../toolbar.rkt" "../command.rkt" "../hook.rkt" "icons.rkt" "layout.rkt" "context-menu.rkt")
(provide toolbar-panel% toolbar-hint)

(define (toolbar-hint name)
  (define c (find-command name))
  (define s (command-shortcut name))
  (if c (if s (format "~a (~a)" (command-title c) s) (command-title c)) ""))

(define toolbar-panel%
  (class horizontal-panel%
    (init-field [mode-getter (lambda () 'text-mode)])
    (super-new [stretchable-height #f] [border grid])
    ;; Each rebuild makes a fresh inner row and swaps it in: spacer panes cannot be removed
    ;; from a panel one by one, but a whole panel can be.
    (define row #f)
    (define buttons (make-hasheq))          ; button% -> command name
    (define shown-mode #f)

    (define/public (button-commands)        ; in display order, for tests and overflow
      (if row (for/list ([b (send row get-children)] #:when (hash-ref buttons b #f)) (hash-ref buttons b)) '()))
    (define/public (button-for name)
      (for/first ([(b n) (in-hash buttons)] #:when (eq? n name)) b))

    ;; `tile` overrides the letter tile a plain command would otherwise get from its own title
    ;; (colliding titles, e.g. "Bold" and "Bulleted List" both start with B, #336/#332), and
    ;; always wins over the command's own #:icon: a command can need a real icon for #:menu
    ;; (icons-test.rkt) while its toolbar button still shows a plain letter, as Bold and Italic
    ;; do (decision #332).
    (define (icon-for c [name (command-icon c)] #:tile [tile #f])
      (define scale (or (get-display-backing-scale) 1.0))
      (define color (get-label-foreground-color))
      (cond
        [tile (letter-tile-bitmap tile #:scale scale #:color color)]
        [(and name (icon-name? name)) (icon-bitmap name #:scale scale #:color color)]
        [else (letter-tile-bitmap (substring (command-title c) 0 1) #:scale scale #:color color)]))

    ;; #333: while a command's #:checked state is on, its button shows #:checked-title and
    ;; #:checked-icon instead (button% has no pressed state; a swapped label is the native way).
    (define shown-checked (make-hasheq))     ; button% -> the checked state its label shows
    (define (icon-name-for c on?) (or (and on? (command-checked-icon c)) (command-icon c)))
    (define (title-for c on?) (or (and on? (command-checked-title c)) (command-title c)))
    (define (label-for c end? on? tile)
      (define icon (icon-for c (icon-name-for c on?) #:tile tile))
      (if end? (list icon (string-trim (title-for c on?) "…") 'left) icon))

    ;; A toolbar item can name several other commands instead of running one itself (#336's
    ;; Heading button: Heading 1-3, Body Text; Export: Word, PDF): its click opens a popup-menu%
    ;; below the button (ui/context-menu.rkt, the same one the editor's right-click menu uses)
    ;; rather than running `name`, which then serves only as the button's title, hover hint and
    ;; #:when. Picking an item runs its command through run-command/safe, as a plain button
    ;; does, and hands the keyboard back to the document. The menu pops up on the window, below
    ;; the button, as the tab strip's menu does (frame.rkt), once the click has been handled,
    ;; and stays referenced here: `popup-menu` may return while the menu is still up.
    (define popups (make-hasheq))            ; command name -> its popup's command names
    (define shown-popup #f)
    (define/public (popup-for name)          ; a fresh popup-menu% for the button, or #f
      (define entries (hash-ref popups name #f))
      (and entries
           (build-popup-menu
            (list (for/list ([n (in-list entries)] #:when (find-command n))
                    (cons (command-menu-label n)
                          (and (command-enabled? (find-command n))
                               (lambda () (run-command/safe n) (run-hook 'focus-editor)))))))))
    (define (make-button it end?)
      (define name (toolbar-item-command it))
      (define c (find-command name))
      (and c
           (let* ([popup (toolbar-item-items it)]
                  [on? (and (not popup) (command-checked? c))]
                  [b (new button% [parent row] [label (label-for c end? on? (toolbar-item-label it))]
                          [callback (lambda (btn e)
                                      (cond
                                        [popup
                                         (queue-callback
                                          (lambda ()
                                            (define top (send btn get-top-level-window))
                                            (define-values (sx sy) (send btn client->screen 0 (send btn get-height)))
                                            (define-values (x y) (send top screen->client sx sy))
                                            (set! shown-popup (popup-for name))
                                            (popup-menu-at! top shown-popup x y)))]
                                        [else (run-command/safe name) (run-hook 'focus-editor)]))])])
             (when popup (hash-set! popups name popup))
             (hash-set! buttons b name)
             (hash-set! shown-checked b (cons on? end?))
             b)))

    ;; Rebuild the buttons for `mode` (Language items appear and disappear with it).
    (define/public (rebuild! [mode (mode-getter)])
      (set! shown-mode mode)
      (hash-clear! buttons)
      (hash-clear! popups)
      (define new-row (new horizontal-panel% [parent this] [style '(deleted)] [spacing toolbar-spacing]
                           [alignment '(left center)] [stretchable-height #f]))
      (set! row new-row)
      (define groups (toolbar-items-for mode))
      (for ([g groups] [i (in-naturals)])
        (define end? (toolbar-item-end? (car g)))
        (when (and (> i 0) (not end?)) (new pane% [parent row] [min-width toolbar-group-gap] [stretchable-width #f]))
        (when end? (new pane% [parent row] [stretchable-width #t]))           ; push to the right
        (for ([it g]) (make-button it end?)))
      (send this change-children (lambda (cs) (list new-row)))
      (refresh-enabled!))

    (define/public (ensure-mode! mode) (unless (eq? mode shown-mode) (rebuild! mode)))

    (define/public (refresh-enabled!)
      (define stale? #f)
      (for ([(b name) (in-hash buttons)])
        (define c (find-command name))
        (define on? (and c (command-enabled? c)))
        (unless (eq? on? (send b is-enabled?)) (send b enable on?))
        (when (and c (command-checked c)
                   (not (eq? (command-checked? c) (car (hash-ref shown-checked b (cons #f #f))))))
          (set! stale? #t)))
      ;; A checked state flipped: rebuild the row rather than relabel in place, because
      ;; set-label can't take the icon-and-title form that titled buttons use. rebuild!
      ;; records the new states, so this settles in one pass.
      (when stale? (rebuild! shown-mode)))

    ;; For tests: the label state a command's button shows (#t checked, #f not, or no button).
    (define/public (button-shows-checked? name)
      (define b (button-for name))
      (and b (car (hash-ref shown-checked b (cons #f #f)))))

    ;; Hover hint: the command and its shortcut in the status bar (there is no tooltip API).
    (define/override (on-subwindow-event receiver e)
      (define name (hash-ref buttons receiver #f))
      (when name
        (case (send e get-event-type)
          [(enter) (run-hook 'echo (toolbar-hint name))]
          [(leave) (run-hook 'echo "")]
          [else (void)]))
      (super on-subwindow-event receiver e))))
