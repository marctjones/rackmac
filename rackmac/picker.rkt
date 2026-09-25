#lang racket/base
;; One picker for everything: command palette, quick open, buffer switcher, mode chooser.
;; Type to fuzzy-filter, Up/Down to move, Enter to choose, Esc to cancel.
(require racket/class racket/gui/base racket/list "fuzzy.rkt" "editor.rkt")
(provide pick pick-item-fields)

;; items: list of (list label detail value [extras]). Returns the chosen value, or #f.
;; `extras` is a string or a list of strings (the palette puts the command name and its
;; aliases there). Each of label, detail and extras is scored on its own; the best one counts.
(define (pick-item-fields it)
  (define extra (if (> (length it) 3) (cadddr it) '()))
  (list* (car it) (cadr it) (if (list? extra) extra (list extra))))

(define (pick prompt items #:detail-heading [detail-heading ""] #:initial [initial ""])
  (define result #f)
  (define shown '())
  (define lb #f)
  (define tf #f)

  (define (refresh!)
    (define q (send tf get-value))
    (set! shown
          (if (string=? q "")
              (if (> (length items) 200) (take items 200) items)
              (fuzzy-filter* q items pick-item-fields)))
    (send lb set (map car shown) (map cadr shown))
    (when (pair? shown) (send lb select 0)))

  (define (move! delta)
    (when (pair? shown)
      (define cur (or (send lb get-selection) 0))
      (define n (max 0 (min (sub1 (length shown)) (+ cur delta))))
      (send lb select n)
      (send lb set-first-visible-item (max 0 (- n 8)))))

  (define (accept!)
    (define sel (send lb get-selection))
    (when sel (set! result (caddr (list-ref shown sel))))
    (send dlg show #f))

  (define dlg
    (new (class dialog%
           (define/override (on-subwindow-char receiver ev)
             (case (send ev get-key-code)
               [(escape) (send this show #f) #t]
               [(down) (move! 1) #t]
               [(up) (move! -1) #t]
               [(#\return #\newline numpad-enter) (accept!) #t]
               [else (super on-subwindow-char receiver ev)]))
           (super-new))
         [label prompt] [parent (ui-parent)] [width 680] [height 440]))

  (set! tf (new text-field% [parent dlg] [label #f] [init-value initial]
                [callback (lambda (t e) (refresh!))]))
  (set! lb (new list-box% [parent dlg] [label #f] [choices '()]
                [columns (list "Name" detail-heading)]
                [style '(single column-headers)]
                [callback (lambda (l e)
                            (when (eq? (send e get-event-type) 'list-box-dclick) (accept!)))]))
  (send lb set-column-width 0 440 100 900)
  (send lb set-column-width 1 160 60 400)
  (refresh!)
  (send tf focus)
  (send dlg show #t)
  result)
