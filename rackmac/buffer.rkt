#lang racket/base
;; A buffer is a `text%` (storage, rendering, undo, selection) plus Emacs-style state:
;; name, file, major/minor modes and buffer-local variables. Keys are routed through
;; the keymap layers before text% sees them.
(require racket/class racket/gui/base racket/string racket/list racket/file
         "keymap.rkt" "mode.rkt" "hook.rkt" "input.rkt" "theme.rkt" "fileio.rkt")
(provide buffer%)

(define buffer%
  (class text%
    (init [name "untitled"] [path #f])
    (field [buf-name name] [buf-path path] [major 'text-mode] [minors '()]
           [locals (make-hasheq)] [shown? #t] [highlight-timer #f])
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
      (rehighlight!)
      (run-hook 'mode-changed this))
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

    ;; ---- input -----------------------------------------------------------
    (define/override (on-char ev)
      (unless (dispatch-key-event this ev)
        (super on-char ev)))

    ;; ---- change notification ---------------------------------------------
    (define/public (rehighlight!)
      (define h (find-highlighter major))
      (when (and h (< (send this last-position) 300000))
        (h this)))
    (define (schedule-highlight!)
      (unless highlight-timer
        (set! highlight-timer (new timer% [notify-callback (lambda () (rehighlight!))])))
      (send highlight-timer start 120 #t))

    (define/augment (after-insert s l)
      (schedule-highlight!) (inner (void) after-insert s l))
    (define/augment (after-delete s l)
      (schedule-highlight!) (inner (void) after-delete s l))
    (define/augment (after-set-position)
      (run-hook 'status-changed) (inner (void) after-set-position))
    (define/override (set-modified m)
      (super set-modified m)
      (run-hook 'buffer-modified-changed this))))
