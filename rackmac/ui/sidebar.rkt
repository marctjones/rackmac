#lang racket/base
;; The Library sidebar's widgets (#273 lib-sidebar; docs/UI-DESIGN.md S2.1, decision #331 option
;; (a)): the dark `bench`, the same in both appearances, with every surface painted by us --
;; a native list-box% or text-field% would draw the OS's light table or white box on it.
;;
;;   filter-row%      the painted "Find a note ⇧⌘O" row (opens Quick Open; no text field)
;;   section-header%  "Recent" / "Folders" in the ui-small font, a bench-rule above
;;   bench-list%      mrlib/hierlist's hierarchical-list% on the bench: bench-text rows, the
;;                    selected row in bench-heading with a 2 px accent marker (a snip)
;;   rule-column%     the 1 px bench-rule edge next to the tabs
;;
;; Nothing here knows about the Library itself: rackmac/library/sidebar.rkt fills the lists
;; and says what activating a row does. Drawing is split into plain functions over a dc so
;; tests render to a bitmap-dc% (tests/ui-harness.rkt) without ever showing a window.
;;
;; What hierlist does not let us change (for the owner, on #331): its selected-row fill is the OS
;; highlight color, captured once when mrlib/hierlist is instantiated (hierlist-unit.rkt's
;; `black-xor`), and only the *item* object takes a mixin, not the row's text%. So the fill
;; stays the OS's; `show-focus` limits it to a 1 px outline while the list is not focused,
;; the marker snip below supplies the accent, and the selected row's text color is picked for
;; contrast against whichever ground it is actually on.
(require racket/class racket/gui/base racket/list mrlib/hierlist
         "tokens.rkt" "../theme.rkt" "../command.rkt" "context-menu.rkt")
(provide filter-row% section-header% bench-list% rule-column%
         draw-filter-row draw-section-header
         add-bench-row! set-bench-row-label! bench-row-label bench-row-data
         row-font header-font row-text-color selected-row-text-color highlight-hex
         marker-snip% bench-row-marker)

;; ---- fonts and colors ---------------------------------------------------------------------

(define row-font (ui-font normal-control-font))
(define header-font (ui-font small-control-font))
(define (font-face f) (send f get-face))

(define (row-text-color) (token 'bench-text))

;; The OS highlight hierlist fills a focused selection with (see the header comment); the
;; selected text is whichever of bench-heading or bench reads better on it.
(define highlight-hex (color->hex (get-highlight-background-color)))
(define (selected-row-text-color focused?)
  (cond
    [(not focused?) (token 'bench-heading)]     ; unfocused: outline only, the ground is bench
    [(>= (contrast-ratio (token-hex 'bench-heading) highlight-hex)
         (contrast-ratio (token-hex 'bench) highlight-hex))
     (token 'bench-heading)]
    [else (token 'bench)]))

(define (text-extent dc s)
  (define-values (w h d a) (send dc get-text-extent s))
  (values w h))

;; ---- painted rows -------------------------------------------------------------------------

;; The filter row: a 1 px bench-rule box (a field look, without a native field), "Find a
;; note" on the left, the Quick Open shortcut on the right; focused, a 2 px accent marker at
;; the left edge and the label in bench-heading.
(define (draw-filter-row dc w h #:focused? [focused? #f] #:shortcut [shortcut (command-shortcut 'quick-open)])
  (send dc set-smoothing 'aligned)
  (send dc set-pen (token 'bench) 1 'solid)
  (send dc set-brush (token 'bench) 'solid)
  (send dc draw-rectangle 0 0 w h)
  (send dc set-pen (token 'bench-rule) 1 'solid)
  (send dc set-brush (token 'bench) 'transparent)
  (send dc draw-rectangle 8 6 (max 0 (- w 16)) (max 0 (- h 12)))
  (when focused?
    (send dc set-pen (token 'accent) 1 'transparent)
    (send dc set-brush (token 'accent) 'solid)
    (send dc draw-rectangle 0 0 2 h))
  (send dc set-font row-font)
  (define-values (lw lh) (text-extent dc "Find a note"))
  (send dc set-text-foreground (if focused? (token 'bench-heading) (token 'bench-text)))
  (send dc draw-text "Find a note" 16 (/ (- h lh) 2))
  (when shortcut
    (send dc set-font header-font)
    (define-values (sw sh) (text-extent dc shortcut))
    (send dc set-text-foreground (token 'bench-text))
    (send dc draw-text shortcut (max 16 (- w 16 sw)) (/ (- h sh) 2))))

;; A section label in the ui-small font (not uppercase mono: bench-quiet fails contrast), with
;; a bench-rule line above every section but the first.
(define (draw-section-header dc w h label #:rule? [rule? #t] #:collapsed? [collapsed? #f])
  (send dc set-smoothing 'aligned)
  (send dc set-pen (token 'bench) 1 'solid)
  (send dc set-brush (token 'bench) 'solid)
  (send dc draw-rectangle 0 0 w h)
  (when rule?
    (send dc set-pen (token 'bench-rule) 1 'solid)
    (send dc draw-line 0 0 w 0))
  (send dc set-font header-font)
  (define text (if collapsed? (string-append label " (hidden)") label))
  (define-values (tw th) (text-extent dc text))
  (send dc set-text-foreground (token 'bench-text))
  (send dc draw-text text 12 (- h th 4)))

(define filter-row%
  (class canvas%
    (init-field [on-activate void])
    (super-new [min-height 36] [stretchable-height #f])
    (inherit get-client-size get-dc refresh has-focus?)
    (define/override (on-paint)
      (define-values (w h) (get-client-size))
      (draw-filter-row (get-dc) w h #:focused? (has-focus?)))
    (define/override (on-focus on?) (refresh))
    (define/override (on-event e) (when (send e button-up? 'left) (on-activate)))
    (define/override (on-char e)
      (when (memq (send e get-key-code) '(#\return #\newline numpad-enter #\space)) (on-activate)))))

(define section-header%
  (class canvas%
    (init-field label [rule? #t] [on-toggle void])
    (field [collapsed? #f])
    (super-new [style '(no-focus)] [min-height 26] [stretchable-height #f])
    (inherit get-client-size get-dc refresh)
    (define/public (set-collapsed! on?) (set! collapsed? on?) (refresh))
    (define/override (on-paint)
      (define-values (w h) (get-client-size))
      (draw-section-header (get-dc) w h label #:rule? rule? #:collapsed? collapsed?))
    (define/override (on-event e) (when (send e button-up? 'left) (on-toggle)))))

(define rule-column%
  (class canvas%
    (super-new [style '(no-focus)] [min-width 1] [stretchable-width #f])
    (inherit get-client-size get-dc)
    (define/override (on-paint)
      (define-values (w h) (get-client-size))
      (define dc (get-dc))
      (send dc set-pen (token 'bench-rule) 1 'solid)
      (send dc set-brush (token 'bench-rule) 'solid)
      (send dc draw-rectangle 0 0 (max 1 w) h))))

;; ---- the marker snip ----------------------------------------------------------------------
;; The first snip of every row: 2 px of accent when the row is selected, nothing otherwise,
;; plus a little air around the text (its height sets the row height).
(define marker-width 2)
(define marker-gap 6)
(define row-pad 3)
(define marker-snip%
  (class snip%
    (inherit get-admin)
    (field [on? #f])
    (super-new)
    (define/public (set-on! v)
      (unless (eq? on? v)
        (set! on? v)
        (define a (get-admin))
        (when a (send a needs-update this 0 0 (+ marker-width marker-gap) 100))))
    (define/override (get-extent dc x y [w #f] [h #f] [descent #f] [space #f] [lspace #f] [rspace #f])
      (define-values (tw th td ta) (send dc get-text-extent "Xg" row-font))
      (when w (set-box! w (+ marker-width marker-gap)))
      (when h (set-box! h (+ th (* 2 row-pad))))
      (when descent (set-box! descent (+ td row-pad)))
      (when space (set-box! space row-pad))
      (when lspace (set-box! lspace 0))
      (when rspace (set-box! rspace 0)))
    (define/override (draw dc x y left top right bottom dx dy draw-caret)
      (when on?
        (define-values (tw th td ta) (send dc get-text-extent "Xg" row-font))
        (define old-pen (send dc get-pen))
        (define old-brush (send dc get-brush))
        (send dc set-pen (token 'accent) 1 'transparent)
        (send dc set-brush (token 'accent) 'solid)
        (send dc draw-rectangle x y marker-width (+ th (* 2 row-pad)))
        (send dc set-pen old-pen)
        (send dc set-brush old-brush)))
    (define/override (get-text offset num [flattened? #f]) "")   ; not part of the row's label
    (define/override (copy) (new marker-snip%))))

;; ---- rows ---------------------------------------------------------------------------------
;; A row's editor holds [marker-snip][label]. `data` is whatever the Library wants back when
;; the row is activated; `kind` 'folder makes a compound (expandable) row.

(define (row-delta color)
  (define d (new style-delta%))
  (send d set-delta-foreground color)
  (define face (font-face row-font))
  (if face (send d set-delta-face face 'swiss) (send d set-family 'system))
  (send d set-delta 'change-size (inexact->exact (round (send row-font get-size))))
  d)

(define (fill-row-editor! ed label color)
  (send ed begin-edit-sequence)
  (send ed erase)
  (send ed insert (new marker-snip%) 0)
  (send ed insert label (send ed last-position))
  (send ed change-style (row-delta color) 0 (send ed last-position))
  (send ed end-edit-sequence))

(define (bench-row-marker item)
  (define ed (send item get-editor))
  (define s (send ed find-first-snip))
  (and (is-a? s marker-snip%) s))

(define (bench-row-label item)
  (define ed (send item get-editor))
  (send ed get-text 0 (send ed last-position)))   ; the marker contributes no text

(define (bench-row-data item) (let ([d (send item user-data)]) (and d (car d))))
(define (bench-row-text item) (let ([d (send item user-data)]) (and d (cdr d))))

;; `parent`: the bench-list% or a compound (folder) row. Returns the new item.
(define (add-bench-row! parent label data #:folder? [folder? #f] #:selectable? [selectable? #t]
                        #:wrap? [wrap? #f])
  (define item (if folder? (send parent new-list) (send parent new-item)))
  (send item user-data (cons data label))
  (unless selectable? (send item set-allow-selection #f))
  (define ed (send item get-editor))
  (when wrap? (send ed auto-wrap #t))
  (fill-row-editor! ed label (row-text-color))
  item)

(define (set-bench-row-label! item label #:color [color (row-text-color)])
  (send item user-data (cons (bench-row-data item) label))
  (define marker (bench-row-marker item))
  (define on? (and marker (get-field on? marker)))
  (fill-row-editor! (send item get-editor) label color)
  (when on? (send (bench-row-marker item) set-on! #t)))

;; ---- the list -----------------------------------------------------------------------------
;; on-activate: (item how) with how 'click, 'double or 'key -- called for a mouse click that
;; selects a row, a double-click, and Return (the panel calls `activate-selected!`). Arrow keys
;; only move the selection, never open (on-selected: (item-or-#f) hears every change). on-context: (item x y) for a right-click, after the row
;; under the pointer is selected. on-opened: (item) when a folder row is expanded (lazy fill).
(define bench-list%
  (class hierarchical-list%
    (init-field [on-activate void] [on-context void] [on-opened void] [on-closed void] [on-selected void])
    (super-new [style '(no-hscroll)])
    (inherit get-selected set-canvas-background show-focus allow-tab-exit has-focus? get-items
             allow-deselect select)
    (show-focus #t)
    (allow-tab-exit #f)       ; Tab reaches the sidebar panel, which moves focus itself
    (allow-deselect #t)
    (set-canvas-background (token 'bench))
    ;; Row snips inherit this; without it every nested row would paint a white box. (The
    ;; list's own 'transparent style is no use: a transparent canvas shows the panel's OS
    ;; background, not the bench.)
    (send (send this get-editor) set-transparent #t)

    (define mouse-select? #f)       ; #t only while a real left click is being handled
    (define styled #f)              ; the item currently drawn as selected

    (define/public (restyle-selection!)
      (define now (get-selected))
      (when (and styled (not (eq? styled now)))
        (set-bench-row-label! styled (bench-row-text styled))
        (define m (bench-row-marker styled))
        (when m (send m set-on! #f)))
      (set! styled now)
      (when now
        (set-bench-row-label! now (bench-row-text now) #:color (selected-row-text-color (has-focus?)))
        (define m (bench-row-marker now))
        (when m (send m set-on! #t))))

    (define/public (refresh-colors!)
      (set-canvas-background (token 'bench))
      (restyle-selection!))

    (define/override (on-select i)
      (restyle-selection!)
      (on-selected i)
      (when (and i mouse-select?) (on-activate i 'click)))
    (define/override (on-double-select i) (on-activate i 'double))
    (define/override (on-item-opened i) (on-opened i))
    (define/override (on-item-closed i) (on-closed i))
    (define/override (on-focus on?)
      (super on-focus on?)
      (restyle-selection!))

    (define/public (activate-selected!)
      (define i (get-selected))
      (when i (on-activate i 'key)))

    ;; Selects without activating (programmatic: following the current document, or the row
    ;; a right-click landed on).
    (define/public (select-quietly! i)
      (set! mouse-select? #f)
      (if i (select i) (select #f))
      (restyle-selection!))

    ;; What a left click on row `i` does, for tests (a hidden list has no real mouse).
    (define/public (click-row! i)
      (set! mouse-select? #t)
      (select i)
      (set! mouse-select? #f))

    (define/override (on-event e)
      (cond
        [(context-click-event? e)
         ;; Select the row under the pointer the way a click would, but without opening it.
         (define down (new mouse-event% [event-type 'left-down] [x (send e get-x)] [y (send e get-y)]
                           [left-down #t] [time-stamp (send e get-time-stamp)]))
         (set! mouse-select? #f)
         (super on-event down)
         (super on-event (new mouse-event% [event-type 'left-up] [x (send e get-x)] [y (send e get-y)]
                              [time-stamp (send e get-time-stamp)]))
         (on-context (get-selected) (send e get-x) (send e get-y))]
        [else
         (set! mouse-select? (send e button-down? 'left))
         (super on-event e)
         (set! mouse-select? #f)]))

    ;; Every row, depth first, including the contents of open folders.
    (define/public (all-rows)
      (let loop ([items (get-items)])
        (append* (for/list ([i (in-list items)])
                   (cons i (if (and (is-a? i hierarchical-list-compound-item<%>) (send i is-open?))
                               (loop (send i get-items))
                               '()))))))

    (define/public (clear-rows!)
      (select-quietly! #f)
      (set! styled #f)
      (for ([i (in-list (get-items))]) (send this delete-item i)))))
