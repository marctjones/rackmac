#lang racket/base
;; One picker for everything: command palette, quick open, buffer switcher, mode chooser,
;; the shortcut cheat sheet. Type to fuzzy-filter, Up/Down to move, Enter to choose, Esc to
;; cancel. Extended per docs/UI-DESIGN.md §2/§7.3 with extra columns, a footer message% that
;; tracks the highlighted row, a helpful empty state, and custom placement; callers that use
;; none of that (Quick Open, Language, Line Endings) are unaffected.
(require racket/class racket/gui/base racket/list "fuzzy.rkt" "editor.rkt")
(provide pick pick-item-fields)

;; items: list of (list label detail value [extras]). Returns the chosen value, or #f.
;; `extras` is a string or a list of strings (the palette puts the command name and its
;; aliases there). Each of label, detail and extras is scored on its own; the best one counts.
(define (pick-item-fields it)
  (define extra (if (> (length it) 3) (cadddr it) '()))
  (list* (car it) (cadr it) (if (list? extra) extra (list extra))))

(define (pick prompt items
              #:detail-heading [detail-heading ""]
              #:columns [columns (list "Name" detail-heading)]
              #:cells [cells (lambda (it) (list (cadr it)))]  ; item -> strings for columns 1..N-1
              #:initial [initial ""]
              #:width [width 640]
              #:height [height 440]
              #:style [extra-style '()]
              #:footer [footer #f]                ; (item-or-#f query) -> string, shown under the list
              #:no-match [no-match #f]             ; query -> string, the empty-state row's label
              #:placement [placement #f]           ; (dialog-w dialog-h) -> (cons x y), or #f to center
              ;; query items -> items, best first: the default is plain best-field fuzzy
              ;; matching; lib-quick-open (#290) supplies one that ranks a title match over a
              ;; path-only match, which no single per-field score can express.
              #:rank [rank (lambda (q its) (fuzzy-filter* q its pick-item-fields))])
  (define result #f)
  (define shown '())
  (define ncols (length columns))
  (define lb #f)
  (define tf #f)
  (define footer-msg #f)

  (define (update-footer!)
    (when footer-msg
      (define q (send tf get-value))
      (define sel (and (pair? shown) (send lb get-selection)))
      (define it (and sel (< sel (length shown)) (list-ref shown sel)))
      (send footer-msg set-label (footer it q))))

  (define (refresh!)
    (define q (send tf get-value))
    (set! shown
          (if (string=? q "")
              (if (> (length items) 200) (take items 200) items)
              (rank q items)))
    (cond
      [(and (null? shown) no-match)
       (define blanks (cons (list (no-match q)) (build-list (sub1 ncols) (lambda (_) (list "")))))
       (send/apply lb set (car blanks) (cdr blanks))
       (with-handlers ([exn:fail? void]) (send lb select 0 #f))]
      [else
       (define col-lists (cons (map car shown) (for/list ([_ (in-range 1 ncols)] [k (in-naturals)])
                                                  (map (lambda (it) (list-ref (cells it) k)) shown))))
       (send/apply lb set (car col-lists) (cdr col-lists))
       (when (pair? shown) (send lb select 0))])
    (update-footer!))

  (define (move! delta)
    (when (pair? shown)
      (define cur (or (send lb get-selection) 0))
      (define n (max 0 (min (sub1 (length shown)) (+ cur delta))))
      (send lb select n)
      (send lb set-first-visible-item (max 0 (- n 8))))
    (update-footer!))

  (define (accept!)
    (define sel (send lb get-selection))
    (when (and sel (pair? shown) (< sel (length shown)))
      (set! result (caddr (list-ref shown sel))))
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
         [label prompt] [parent (ui-parent)] [width width] [height height] [style extra-style]))

  (cond [(and placement (placement width height)) => (lambda (pos) (send dlg move (car pos) (cdr pos)))]
        [placement (send dlg center)])

  (set! tf (new text-field% [parent dlg] [label #f] [init-value initial]
                [callback (lambda (t e) (refresh!))]))
  (set! lb (new list-box% [parent dlg] [label #f] [choices '()]
                [columns columns]
                [style '(single column-headers)]
                [callback (lambda (l e)
                            (if (eq? (send e get-event-type) 'list-box-dclick) (accept!) (update-footer!)))]))
  (cond
    [(= ncols 2)
     (send lb set-column-width 0 440 100 900)
     (send lb set-column-width 1 160 60 400)]
    [else
     (send lb set-column-width 0 300 150 900)
     (for ([k (in-range 1 ncols)]) (send lb set-column-width k 120 60 300))])
  (when footer
    (set! footer-msg (new message% [parent dlg] [label ""] [stretchable-width #t])))
  (refresh!)
  (send tf focus)
  (send dlg show #t)
  result)
