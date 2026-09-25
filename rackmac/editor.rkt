#lang racket/base
;; Global editor state: the buffer list, the current buffer, the echo area and the
;; Activity log (Emacs: *Messages*), plus small text helpers that user code can call.
(require racket/class racket/list racket/string racket/path
         "buffer.rkt" "hook.rkt" "mode.rkt" "modes.rkt")
(provide current-buffer set-current-buffer! all-buffers visible-buffers messages-buffer?
         reopen-closed-tab! closed-tab-paths
         new-buffer! open-file! kill-buffer! find-buffer-by-path unique-name
         message messages-buffer show-messages!
         ui-parent set-ui-parent!
         buffer-string selection-string insert-text replace-selection! goto-line! buffer-modified?
         unsaved-buffers)

(define buffers '())
(define current #f)
(define parent-window #f)
(define (ui-parent) parent-window)
(define (set-ui-parent! w) (set! parent-window w))

(define (all-buffers) buffers)
(define (visible-buffers) (filter (lambda (b) (send b is-shown?)) buffers))

(define (unique-name base)
  (let loop ([n 1])
    (define candidate (if (= n 1) base (format "~a<~a>" base n)))
    (if (for/or ([b buffers]) (equal? (send b get-name) candidate)) (loop (add1 n)) candidate)))

(define (new-buffer! [name "untitled"] #:mode [mode 'text-mode] #:shown? [shown? #t])
  (define b (new buffer% [name (unique-name name)]))
  ;; Register first: hooks fired by set-mode! (e.g. the status bar) call `current-buffer`,
  ;; which must find this buffer instead of creating another scratch buffer forever.
  (set! buffers (append buffers (list b)))
  (send b set-mode! mode)
  (send b set-shown! shown?)
  (run-hook 'buffers-changed)
  b)

(define (current-buffer)
  (unless current
    (set! current (or (let ([vs (visible-buffers)]) (and (pair? vs) (car vs)))
                      (let ([b (new-buffer! "Scratch Pad" #:mode 'racket-mode)])
                        (send b insert ";; Scratch Pad: a place to try Racket code.\n;; Select some code and press Mod-Enter to run it.\n\n")
                        (send b set-modified #f)
                        b))))
  current)

(define (set-current-buffer! b)
  (set! current b)
  (run-hook 'current-buffer-changed b))

(define (find-buffer-by-path p)
  (for/first ([b buffers] #:when (and (send b get-path) (equal? (send b get-path) p))) b))

(define (open-file! path)
  (define p (simplify-path (path->complete-path path)))
  (or (find-buffer-by-path p)
      (let ([b (new-buffer! (let-values ([(base name dir?) (split-path p)]) (path->string name)))])
        (cond [(file-exists? p)
               (send b load-path! p)
               (define note (send b local-ref 'file-note #f))
               (when note (message "~a: ~a" (send b get-name) note))]
              [else (send b set-mode! (or (mode-for-path p) 'text-mode))])   ; a new file still gets its Language
        (send b set-path! p)
        b)))

;; Paths of closed tabs, most recent first, for Reopen Closed Tab (as in Chrome).
(define closed '())
(define (closed-tab-paths) closed)
(define (reopen-closed-tab!)
  (let loop ()
    (cond [(null? closed) #f]
          [else (define p (car closed))
                (set! closed (cdr closed))
                (if (file-exists? p) (let ([b (open-file! p)]) (set-current-buffer! b) b) (loop))])))

;; Closing picks the nearest visible neighbour, never a hidden buffer. The Activity log is
;; only hidden, never destroyed, so messages keep going somewhere.
(define (kill-buffer! b)
  (cond
    [(messages-buffer? b)
     (send b set-shown! #f)
     (when (eq? b current) (set! current #f) (set-current-buffer! (current-buffer)))]
    [else
     (when (send b get-path) (set! closed (cons (send b get-path) (remove (send b get-path) closed))))
     (define vs (visible-buffers))
     (define i (or (index-of vs b) 0))
     (define rest (remq b vs))
     (set! buffers (remq b buffers))
     (when (eq? b current)
       (set! current (and (pair? rest) (list-ref rest (min i (sub1 (length rest))))))
       (set-current-buffer! (current-buffer)))])       ; makes a Scratch Pad if none are left
  (run-hook 'buffers-changed))

(define (unsaved-buffers)
  (filter (lambda (b) (and (send b is-modified?) (send b is-shown?))) buffers))

;; ---- messages ------------------------------------------------------------

(define messages #f)
(define (messages-buffer? b) (and messages (eq? b messages)))
(define (messages-buffer)
  (unless messages
    (set! messages (new-buffer! "Activity" #:shown? #f)))
  messages)

(define (message fmt . args)
  (define s (apply format fmt args))
  (define mb (messages-buffer))
  (send mb insert (string-append s "\n") (send mb last-position))
  (send mb set-modified #f)
  (run-hook 'echo (let ([lines (string-split s "\n")])
                    (cond [(null? lines) ""]
                          [(null? (cdr lines)) (car lines)]
                          [else (string-append (car lines) " …")]))))

(define (show-messages!)
  (define mb (messages-buffer))
  (send mb set-shown! #t)
  (set-current-buffer! mb))

;; Errors from hooks, commands and the init file land in the Activity log and the echo area.
(error-reporter
 (lambda (who e)
   (message "~a: ~a" who (if (exn? e) (exn-message e) e))))

;; ---- helpers for scripts --------------------------------------------------

(define (buffer-string [b (current-buffer)]) (send b get-text))
(define (selection-string [b (current-buffer)])
  (send b get-text (send b get-start-position) (send b get-end-position)))
(define (insert-text s [b (current-buffer)]) (send b insert s))
(define (replace-selection! s [b (current-buffer)]) (send b insert s))
(define (buffer-modified? [b (current-buffer)]) (send b is-modified?))
(define (goto-line! n [b (current-buffer)])
  (define last (send b last-paragraph))
  (send b set-position (send b paragraph-start-position (max 0 (min last (sub1 n))))))
