#lang racket/base
;; A buffer is a `text%` (storage, rendering, undo, selection) plus Emacs-style state:
;; name, file, major/minor modes and buffer-local variables. Keys are routed through
;; the keymap layers before text% sees them.
(require racket/class racket/gui/base racket/string racket/list racket/file
         "keymap.rkt" "mode.rkt" "hook.rkt" "input.rkt" "theme.rkt" "fileio.rkt" "platform.rkt")
(provide buffer% large-file-threshold)

;; Documents longer than this many characters open without syntax coloring (it re-lexes the
;; whole document after edits, which gets slow). A parameter so tests can lower it.
(define large-file-threshold (make-parameter 500000))

;; A word/space/punctuation classifier for word-boundary detection (double-click, RM-058).
(define (word-char? ch) (or (char-alphabetic? ch) (char-numeric? ch) (eqv? ch #\_)))
(define (char-class ch) (cond [(word-char? ch) 'word] [(char-whitespace? ch) 'space] [else 'punct]))

;; A double/triple click's second and third click must land within this many milliseconds
;; of the previous one (racket/gui has no get-double-click-time; this is the OS ballpark).
(define double-click-interval 500)

;; Shown over a link while ⌘ (Ctrl) is held: the click will follow it.
(define hand-cursor (make-object cursor% 'hand))

(define buffer%
  (class text%
    (init [name "untitled"] [path #f])
    (field [buf-name name] [buf-path path] [major 'text-mode] [minors '()]
           [locals (make-hasheq)] [shown? #t] [highlight-timer #f]
           [click-pos -1] [click-time 0] [click-count 0])
    (super-new)
    (send this set-style-list editor-style-list)
    (send this set-max-undo-history 'forever)

    ;; ---- identity --------------------------------------------------------
    (define/public (get-name) buf-name)
    (define/public (set-name! n) (set! buf-name n) (run-hook 'buffers-changed))
    (define/public (get-path) buf-path)
    (define/public (set-path! p) (set! buf-path p) (run-hook 'buffers-changed))
    (define/public (is-shown?) shown?)
    (define/public (set-shown! v) (set! shown? v) (run-hook 'buffers-changed))

    ;; ---- modes and buffer-local variables --------------------------------
    (define/public (get-mode) major)
    (define/public (get-minor-modes) minors)
    (define/public (set-mode! name)
      (define old (find-mode major))
      (when (and old (mode-on-disable old)) ((mode-on-disable old) this))
      (set! major name)
      (define new (find-mode name))
      (when (and new (mode-on-enable new)) ((mode-on-enable new) this))
      (send this auto-wrap (and (local-ref 'wrap-lines #f) #t))
      (send this set-line-spacing (local-ref 'line-spacing 1))
      (restyle-document!)
      (rehighlight!)
      (run-hook 'mode-changed this))
    ;; The Language decides the document's base style: "Prose" (serif) for text-mode and its
    ;; children, "Standard" (monospace) for code. Highlighters reset to it (highlight.rkt).
    ;; (While text% is still being constructed its own style list has no "Prose" yet.)
    (define/override (default-style-name)
      (define name (local-ref 'document-style "Standard"))
      (if (send (send this get-style-list) find-named-style name) name "Standard"))
    ;; Put the whole document back on its base style, outside undo and the modified flag.
    (define/public (restyle-document!)
      (define was-modified? (send this is-modified?))
      (send this begin-edit-sequence #f #f)
      (send this change-style (send (send this get-style-list) find-named-style (default-style-name)) 0 'end)
      (send this end-edit-sequence)
      (send this set-modified was-modified?))
    (define/public (enable-minor-mode! name)
      (unless (memq name minors)
        (set! minors (cons name minors))
        (let ([m (find-mode name)]) (when (and m (mode-on-enable m)) ((mode-on-enable m) this)))
        (run-hook 'mode-changed this)))
    (define/public (disable-minor-mode! name)
      (when (memq name minors)
        (set! minors (remq name minors))
        (let ([m (find-mode name)]) (when (and m (mode-on-disable m)) ((mode-on-disable m) this)))
        (run-hook 'mode-changed this)))
    ;; Keymap layers, highest priority first: minor modes, then the major mode chain.
    (define/public (get-keymaps)
      (append (append-map mode-keymaps minors) (mode-keymaps major) (list global-keymap)))
    (define/public (local-ref var [default #f])
      (hash-ref locals var (lambda () (mode-local major var default))))
    (define/public (local-set! var val) (hash-set! locals var val))
    ;; Drop the document's own value, so the Language's (if any) shows through again.
    (define/public (local-remove! var) (hash-remove! locals var))

    ;; ---- files -----------------------------------------------------------
    (define/public (load-path! p)
      (define-values (text enc eol note) (decode-file (file->bytes p)))
      (local-set! 'encoding enc)
      (local-set! 'eol eol)
      (local-set! 'file-note note)
      (send this lock #f)
      (send this set-max-undo-history 0)
      (send this begin-edit-sequence #f)
      (send this erase)
      (send this insert text)
      (send this end-edit-sequence)
      (send this set-max-undo-history 'forever)
      (send this set-position 0)
      (set! buf-path p)
      (define-values (base fname dir?) (split-path p))
      (set! buf-name (path->string fname))
      (set-mode! (or (mode-for-path p) 'text-mode))
      (when (eq? enc 'binary) (send this lock #t))      ; never write a binary file back
      (send this set-modified #f))
    ;; Encodes first, so an unsavable character aborts the save before anything is written;
    ;; then writes through a temp file and a rename, so a failed save leaves the original.
    (define/public (save-to! p)
      (define bs (encode-text (send this get-text) (local-ref 'encoding 'utf-8) (local-ref 'eol "\n")))
      (safe-write-bytes! p bs)
      (set! buf-path p)
      (define-values (base fname dir?) (split-path p))
      (set! buf-name (path->string fname))
      (send this set-modified #f)
      (run-hook 'buffers-changed)
      (run-hook 'after-save this))

    ;; ---- clipboard ---------------------------------------------------------
    ;; Copy puts the document's characters on the clipboard as plain text, never text%'s own
    ;; styled snips (#334, docs/UI-DESIGN.md §2.2.1): a note's Formatted view is only styling, so
    ;; a colleague gets readable Markdown, and pasting into another document (a code file, the
    ;; other view) carries no heading sizes or fonts; the destination styles it. Snips (later
    ;; checkboxes, rules) contribute their text. text%'s cut calls this copy.
    (define/override (copy [extend? #f] [time 0] [start 'start] [end 'end])
      (define s (if (symbol? start) (send this get-start-position) start))
      (define e (min (if (symbol? end) (send this get-end-position) end) (send this last-position)))
      (when (< s e)
        (define text (send this get-text s e #t))
        (define before (and extend? (send the-clipboard get-clipboard-string time)))
        (send the-clipboard set-clipboard-string (if before (string-append before text) text) time)))

    ;; ---- input -----------------------------------------------------------
    (define/override (on-char ev)
      (unless (dispatch-key-event this ev)
        (super on-char ev)))

    ;; ---- mouse: word/line selection under the pointer ---------------------
    ;; text%'s own on-default-event only ever drags a character-granularity selection: it
    ;; has no double-click-selects-word or triple-click-selects-line behavior (RM-069;
    ;; verified against gui-lib's wxme/text.rkt, which tracks no click count at all). Both
    ;; are implemented here, from the raw click position and event timestamp.
    ;;
    ;; `word-bounds-at` also backs the context menu (RM-058: right-click outside the
    ;; selection selects the word under the pointer). text%'s own find-wordbreak was tried
    ;; first, but both its 'caret and 'selection reasons give wrong answers exactly at a
    ;; word's edge (e.g. right after the last letter, or at the end of the document, where
    ;; 'selection returns an empty range) -- exactly the positions a real click lands on.
    (define/public (word-bounds-at pos)
      (define para (send this position-paragraph pos))
      (define pstart (send this paragraph-start-position para))
      (define pend (send this paragraph-end-position para))
      (define text (send this get-text pstart pend))
      (define len (string-length text))
      (cond
        [(zero? len) (values pos pos)]
        [else
         (define off (- pos pstart))
         (define (class-at i) (and (>= i 0) (< i len) (char-class (string-ref text i))))
         (define left (class-at (sub1 off)))
         (define right (class-at off))
         ;; A word character wins a boundary (clicking right at a word's edge still selects
         ;; it); otherwise prefer the character to the right, as a caret position does.
         (define i (cond [(eq? right 'word) off] [(eq? left 'word) (sub1 off)]
                         [right off] [else (sub1 off)]))
         (define cls (class-at i))
         (define s (let loop ([j i]) (if (eq? (class-at (sub1 j)) cls) (loop (sub1 j)) j)))
         (define e (let loop ([j i]) (if (eq? (class-at (add1 j)) cls) (loop (add1 j)) (add1 j))))
         (values (+ pstart s) (+ pstart e))]))

    (define/public (select-word-at! pos)
      (define-values (s e) (word-bounds-at pos))
      (send this set-position s e))

    (define/public (select-line-at! pos)
      (define p (send this position-paragraph pos))
      (send this set-position (send this paragraph-start-position p)
            (min (send this last-position) (add1 (send this paragraph-end-position p)))))

    ;; Position-based, so tests can drive it without a pixel-accurate canvas: a second click
    ;; at the same position within `double-click-interval` selects the word, a third the
    ;; line; a fourth (or a click that breaks the streak) falls back to a plain caret.
    (define/public (click-at! pos time)
      (set! click-count (if (and (= pos click-pos) (<= (- time click-time) double-click-interval))
                            (add1 click-count) 1))
      (set! click-pos pos)
      (set! click-time time)
      (case click-count
        [(2) (select-word-at! pos)]
        [(3) (select-line-at! pos)]
        [else (void)]))

    (define (event-position ev)
      (define-values (ex ey) (send this dc-location-to-editor-location (send ev get-x) (send ev get-y)))
      (send this find-position ex ey))

    (define/override (on-event ev)
      (cond
        [(and (send ev button-down? 'left) (command-click? ev) (link-click-at! (event-position ev)))
         (void)]                             ; followed a link; the caret stays where it was
        [(send ev button-down? 'left)
         (define pos (event-position ev))
         (super on-event ev)                 ; the normal single click first (caret, drag-select)
         (click-at! pos (send ev get-time-stamp))]
        [(and (send ev moving?) (or hovered-link (local-ref 'link-at #f)))   ; only where links exist
         (link-hover-at! (and (not (send ev dragging?)) (event-position ev)))
         (super on-event ev)]
        [(send ev leaving?) (link-hover-at! #f) (super on-event ev)]
        [else (super on-event ev)]))

    ;; ---- links (#338): ⌘-click follows, hover names the target -------------
    ;; A Language that has links names a procedure in the local `link-at` (document position ->
    ;; target string or #f; Markdown's is md-links.rkt). ⌘-click (Ctrl+click on Windows), Word's
    ;; convention, runs the 'follow-link hook with the target (md-links-open.rkt opens it); a
    ;; plain click only places the caret. Clickbacks (text%'s set-clickback) are not used because
    ;; they fire on a plain click. Position-based, like click-at!, so tests need no pixels.
    (define (command-click? ev) (if (mac?) (send ev get-meta-down) (send ev get-control-down)))
    (define (link-target pos)
      (define f (local-ref 'link-at #f))
      (and f pos (f this pos)))
    (define/public (link-click-at! pos)
      (define target (link-target pos))
      (and target (begin (run-hook 'follow-link this target) #t)))
    (field [hovered-link #f])
    (define/public (link-hover-at! pos)
      (define target (link-target pos))
      (unless (equal? target hovered-link)
        (set! hovered-link target)
        (run-hook 'echo (if target (format "~a  (~a to open)" target (if (mac?) "⌘-click" "Ctrl+click")) ""))))
    (define/override (adjust-cursor ev)
      (if (and (command-click? ev) (link-target (event-position ev)))
          hand-cursor
          (super adjust-cursor ev)))

    ;; RM-058: a right-click (or Ctrl-click on macOS) outside the current selection moves
    ;; the caret there and selects the word under the pointer; inside it, the selection is
    ;; left alone (so Cut/Copy from the context menu act on the whole selection). Called
    ;; from the canvas with device coordinates; `context-click-at!` takes a plain position,
    ;; for tests.
    (define/public (context-click-at! pos)
      (define s (send this get-start-position))
      (define e (send this get-end-position))
      (unless (and (> e s) (>= pos s) (<= pos e))
        (select-word-at! pos)))

    (define/public (context-click! dc-x dc-y)
      (define-values (ex ey) (send this dc-location-to-editor-location dc-x dc-y))
      (context-click-at! (send this find-position ex ey)))

    ;; ---- change notification ---------------------------------------------
    (define/public (large?) (> (send this last-position) (large-file-threshold)))
    (define/public (rehighlight!)
      (define h (find-highlighter major))
      (when (and h (not (large?)))
        (h this)))
    (define (schedule-highlight!)
      (unless highlight-timer
        (set! highlight-timer (new timer% [notify-callback (lambda () (rehighlight!))])))
      (send highlight-timer start 120 #t))

    ;; A Language that restyles only what an edit touched (Markdown, md-style.rkt) names its
    ;; procedures in the locals `restyle-edit` (document start old-end new-length) and
    ;; `restyle-flush` (document, when an edit sequence ends); others recolor the whole document
    ;; shortly after typing stops.
    (define (note-edit! s old-end new-len)
      (define f (local-ref 'restyle-edit #f))
      (if f (f this s old-end new-len) (schedule-highlight!)))
    (define/augment (after-insert s l)
      (note-edit! s s l) (run-hook 'text-changed this) (inner (void) after-insert s l))
    (define/augment (after-delete s l)
      (note-edit! s (+ s l) 0) (run-hook 'text-changed this) (inner (void) after-delete s l))
    (define/augment (after-edit-sequence)
      (define f (local-ref 'restyle-flush #f))
      (when f (f this))
      (inner (void) after-edit-sequence))
    ;; Readable measure: a Language can set the local `measure` (characters per line); when
    ;; wrapping, lines then wrap at that width or the window edge, whichever is narrower.
    (define/public (measure-width)
      (define cols (local-ref 'measure #f))
      (define dc (send this get-dc))
      (and cols dc
           (let-values ([(w h d a) (send dc get-text-extent "0"
                                         (send (send (send this get-style-list) find-named-style (default-style-name)) get-font))])
             (* cols w))))
    (define/augment (on-display-size)
      (when (send this auto-wrap)
        (define w (measure-width))
        (define cur (send this get-max-width))
        (when (and w (real? cur) (> cur w)) (send this set-max-width w)))
      (inner (void) on-display-size))

    (define/augment (after-set-position)
      (run-hook 'status-changed) (inner (void) after-set-position))
    (define/override (set-modified m)
      (super set-modified m)
      (run-hook 'buffer-modified-changed this))))
