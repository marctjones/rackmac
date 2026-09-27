#lang racket/base
;; Task checkboxes in the Formatted view (#293 task-checkbox, docs/UI-DESIGN.md §2.2 and §5.3).
;; A task marker `[ ]`, `[x]` (or `[X]`) or `[-]` is swapped, outside undo, for a checkbox snip
;; whose text is those three characters and whose count is 3, so the file, positions, find and
;; the parser see the Markdown unchanged (doc-text.rkt). Its grapheme count is 1, so text%'s
;; arrow keys, Backspace and clicks step over it whole; buffer% keeps every other caret
;; position out of it and makes forward Delete remove it whole.
;;
;; The snips follow the parser: after every restyle (the 'document-restyled hook, run by
;; md-style.rkt for the whole document or for an edit's region) the task markers in the region
;; get snips and snips that are no longer task markers go back to text. The Markdown Source
;; view and other Languages have none. A click, like Mark Done (⇧⌘U), toggles the marker with
;; an ordinary edit, one undo step; the restyle then puts a new snip in.
(require racket/class racket/gui/base racket/list
         "doc-text.rkt" "hook.rkt" "md-style.rkt" "md-view.rkt" "md-doc.rkt" "markdown-lib.rkt"
         (rename-in "ui/tokens.rkt" [token color-token]))
(provide checkbox-snip% checkbox-snip? toggle-task-at! widen-edits-to-snips
         sync-checkboxes! remove-checkboxes! checkbox-size)

(define checkbox-size 14)       ; px, UI-DESIGN §2.2
(define gap 5)                  ; between the box and the space that follows it

(define checkbox-snip-class
  (let ([c (make-object snip-class%)])
    (send c set-classname "rackmac:checkbox")
    (send c set-version 1)
    c))

(define checkbox-snip%
  (class* snip% (clickable-snip<%>)
    (init-field source)                                  ; "[ ]", "[x]", "[X]" or "[-]"
    (super-new)
    (send this set-snipclass checkbox-snip-class)
    (send this set-char-and-grapheme-count 3 1)

    (define/public (get-source) source)
    (define/public (state)
      (case (string-ref source 1) [(#\space) 'open] [(#\-) 'cancelled] [else 'done]))

    ;; ---- text: the source --------------------------------------------------------------
    (define/override (get-text offset num [flattened? #f])
      (substring source (min 3 offset) (min 3 (+ offset (max 0 num)))))
    (define/override (grapheme-position i [end? #f]) (if (<= i 0) 0 3))
    (define/override (position-grapheme i) (if (< i 3) 0 1))
    (define/override (copy)
      (define c (new checkbox-snip% [source source]))
      (send c set-style (send this get-style))
      c)
    ;; Only undo or redo of an edit made before the snip existed reaches inside it; the
    ;; pieces are then plain text, and the next restyle puts a snip back if it is still a task.
    (define/override (split pos first second)
      (set-box! first (make-object string-snip% (substring source 0 pos)))
      (set-box! second (make-object string-snip% (substring source pos))))

    ;; ---- click -------------------------------------------------------------------------
    (define/public (click editor)
      (define pos (send editor get-snip-position this))
      (when pos (toggle-task-at! editor pos)))

    ;; ---- drawing ------------------------------------------------------------------------
    ;; The box sits on the text: centered half an x-height above the baseline, like a Mac
    ;; checkbox beside its label. Metrics come from the snip's style (the markup style).
    (define (metrics dc)
      (define st (send this get-style))
      (define th (send st get-text-height dc))
      (define td (send st get-text-descent dc))
      (define ts (send st get-text-space dc))
      (define lift (* 0.33 (- th td ts)))                ; baseline to the box's center
      (define h (max th (+ td (ceiling (+ lift (/ checkbox-size 2) 1)))))
      (values h td ts lift))

    (define/override (get-extent dc x y [w #f] [h #f] [descent #f] [space #f] [lspace #f] [rspace #f])
      (define-values (hh td ts lift) (metrics dc))
      (when w (set-box! w (+ checkbox-size gap)))
      (when h (set-box! h hh))
      (when descent (set-box! descent td))
      (when space (set-box! space (max 0 (- hh td (+ lift (/ checkbox-size 2) 1)))))
      (when lspace (set-box! lspace 0))
      (when rspace (set-box! rspace 0)))

    (define/override (partial-offset dc x y offset)
      (if (<= offset 0) 0.0 (+ checkbox-size gap 0.0)))

    (define/override (draw dc x y left top right bottom dx dy caret)
      (define-values (h td ts lift) (metrics dc))
      (define baseline (+ y (- h td)))
      (define bx (+ x 0.5))
      (define by (- baseline lift (/ checkbox-size 2)))
      (draw-checkbox dc bx by (state)))))

(define (checkbox-snip? s) (is-a? s checkbox-snip%))

;; The box at (x, y), 14 px: open is an outline in text-2; done is filled with the accent and
;; checked in the surface color; cancelled is an outline in text-disabled with a dash.
(define (draw-checkbox dc x y state)
  (define old-pen (send dc get-pen))
  (define old-brush (send dc get-brush))
  (define old-smoothing (send dc get-smoothing))
  (send dc set-smoothing 'smoothed)
  (define s checkbox-size)
  (case state
    [(done)
     (send dc set-pen (color-token 'accent) 1 'solid)
     (send dc set-brush (color-token 'accent) 'solid)
     (send dc draw-rounded-rectangle x y s s 3)
     (send dc set-pen (new pen% [color (color-token 'surface)] [width 2] [cap 'round] [join 'round]))
     (send dc draw-lines (list (cons (+ x 3.5) (+ y 7.5)) (cons (+ x 6) (+ y 10)) (cons (+ x 10.5) (+ y 4))))]
    [else
     (define ink (color-token (if (eq? state 'cancelled) 'text-disabled 'text-2)))
     (send dc set-pen ink 1 'solid)
     (send dc set-brush (color-token 'surface) 'solid)
     (send dc draw-rounded-rectangle x y s s 3)
     (when (eq? state 'cancelled)
       (send dc set-pen (new pen% [color ink] [width 2] [cap 'round]))
       (send dc draw-line (+ x 4) (+ y (/ s 2)) (+ x (- s 4)) (+ y (/ s 2))))])
  (send dc set-smoothing old-smoothing)
  (send dc set-pen old-pen)
  (send dc set-brush old-brush))

;; ---- toggling ---------------------------------------------------------------------------------

;; Edits that begin or end inside a source snip are widened to the whole snip (its source
;; spliced around the new text), so applying them replaces the snip rather than splitting it.
(define (widen-edits-to-snips b edits)
  (for/list ([e (in-list edits)])
    (define-values (sa pa) (send b source-snip-around (edit-start e)))
    (define-values (sb pb) (send b source-snip-around (edit-end e)))
    (define s (if sa pa (edit-start e)))
    (define z (if sb (+ pb (send sb get-count)) (edit-end e)))
    (if (and (= s (edit-start e)) (= z (edit-end e)))
        e
        (edit s z (string-append (send b document-text s (edit-start e))
                                 (edit-text e)
                                 (send b document-text (edit-end e) z))))))

;; Toggle the task of the list item at `pos` (open -> done, done or cancelled -> open; an item
;; without a marker gets one), as one undo step. Returns the edits applied.
(define (toggle-task-at! b pos)
  (define edits (widen-edits-to-snips b (toggle-task-edits (current-md-document b) pos)))
  (apply-md-edits! b edits)
  edits)

;; ---- keeping the snips in step with the text ----------------------------------------------

(define (formatted? b)
  (and (eq? (send b get-mode) 'markdown-mode) (not (eq? (markdown-view b) 'source))))

;; The checkbox snips in [start, end), as (pos . snip).
(define (checkboxes-in b start end)
  (define bx (box 0))
  (define first (send b find-snip start 'after-or-none bx))
  (let loop ([snip first] [pos (unbox bx)] [acc '()])
    (if (and snip (< pos end))
        (loop (send snip next) (+ pos (send snip get-count))
              (if (and (checkbox-snip? snip) (>= pos start)) (cons (cons pos snip) acc) acc))
        (reverse acc))))

(define (sync-checkboxes! b start end)
  (define doc (and (formatted? b) (not (send b is-locked?)) (markdown-parser-document b)))
  (when doc
    (define last (send b last-position))
    (define s (max 0 (min start last)))
    (define e (max s (min end last)))
    (define markers
      (for/list ([t (in-list (markup-tokens doc #:start s #:end e))]
                 #:when (and (eq? (token-role t) 'task-marker) (<= (token-end t) last)))
        (token-start t)))
    (define have (checkboxes-in b (if (pair? markers) (min s (car markers)) s) (max e (if (pair? markers) (+ 3 (apply max markers)) e))))
    (define stale (filter (lambda (h) (not (memv (car h) markers))) have))
    (define missing (filter (lambda (p) (not (assv p have))) markers))
    (unless (and (null? stale) (null? missing))
      (send b call-as-decoration
            (lambda ()
              (for ([h (in-list stale)]) (unsnip! b (car h) (cdr h)))
              (for ([p (in-list missing)]) (snip! b p)))))))

(define (snip! b p)
  (define src (send b document-text p (+ p 3)))
  (define here (send b find-snip p 'after-or-none))
  (when (and (regexp-match? #rx"^\\[[ xX-]\\]$" src) here (not (source-snip? here))
             (not (source-snip? (send b find-snip (+ p 2) 'after-or-none))))
    (define snip (new checkbox-snip% [source src]))
    (send snip set-style (send here get-style))
    (send b insert snip p (+ p 3) #f)))

(define (unsnip! b p snip)
  (define style (send snip get-style))
  (send b insert (send snip get-source) p (+ p 3) #f)
  (send b change-style style p (+ p 3)))

;; Every checkbox back to its characters (the Source view, another Language).
(define (remove-checkboxes! b)
  (define have (checkboxes-in b 0 (send b last-position)))
  (when (pair? have)
    (send b call-as-decoration
          (lambda () (for ([h (in-list have)]) (unsnip! b (car h) (cdr h)))))))

(add-hook! 'document-restyled sync-checkboxes!)
(add-hook! 'markdown-view-changed (lambda (b) (unless (formatted? b) (remove-checkboxes! b))))
(add-hook! 'mode-changed (lambda (b) (unless (formatted? b) (remove-checkboxes! b))))

;; ---- cancelled items: struck through --------------------------------------------------------
;; style-delta% has no strikethrough, so the line through a cancelled item's text is painted
;; after the text (buffer%'s 'paint-document hook), from the box to the end of its paragraph.
(define (paint-cancelled! b dc left top right bottom dx dy)
  (when (formatted? b)
    (define from (send b line-start-position (send b find-line top)))
    (define to (send b line-end-position (send b find-line bottom)))
    (define spacing (send b get-line-spacing))
    (for ([h (in-list (checkboxes-in b from to))] #:when (eq? (send (cdr h) state) 'cancelled))
      (define start (+ (car h) 3))
      (define para-end (send b paragraph-end-position (send b position-paragraph (car h))))
      (define old-pen (send dc get-pen))
      (send dc set-pen (color-token 'text-disabled) 1 'solid)
      (let loop ([s (min para-end (add1 start))])        ; after the space that follows the box
        (when (< s para-end)
          (define line (send b position-line s))
          (define le (min para-end (send b line-end-position line)))
          (define x0 (box 0.0)) (define y0 (box 0.0)) (define x1 (box 0.0)) (define y1 (box 0.0))
          (send b position-location s x0 y0 #t)
          (send b position-location le x1 y1 #f)
          (define y (+ dy (unbox y0) (* 0.58 (- (unbox y1) (unbox y0) spacing))))
          (send dc draw-line (+ dx (unbox x0)) y (+ dx (unbox x1)) y)
          (unless (= le para-end) (loop (send b line-start-position (add1 line))))))
      (send dc set-pen old-pen))))

(add-hook! 'paint-document paint-cancelled!)
