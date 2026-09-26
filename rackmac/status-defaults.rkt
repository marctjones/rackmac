#lang racket/base
;; The default status-bar segments: position, word/selection count, encoding, line ending,
;; Language and zoom. Registered through the same registry extensions use (rackmac/status.rkt).
(require racket/class "status.rkt" "editor.rkt" "mode.rkt" "hook.rkt" "theme.rkt" "fileio.rkt")
(provide word-count word-count-scans reset-word-count-scans!)   ; test instrumentation

;; ---- word count: cached per buffer, invalidated on edits ------------------
;; Re-scanning the whole document on every cursor move would make typing feel slow in a
;; large document, so the count is kept until the buffer actually changes.
(define generations (make-weak-hasheq))     ; buffer -> generation, bumped by 'text-changed
(define cache (make-weak-hasheq))           ; buffer -> (cons generation count)
(define scans 0)                            ; how many times the text was actually re-scanned
(define (word-count-scans) scans)
(define (reset-word-count-scans!) (set! scans 0))

(add-hook! 'text-changed (lambda (b) (hash-update! generations b add1 0)))

(define (count-words s)
  (set! scans (add1 scans))
  (length (regexp-match* #px"\\S+" s)))

(define (word-count b)
  (define gen (hash-ref generations b 0))
  (define cached (hash-ref cache b #f))
  (cond [(and cached (= (car cached) gen)) (cdr cached)]
        [else (define n (count-words (send b get-text)))
              (hash-set! cache b (cons gen n))
              n]))

;; A "prose" Language is one whose chain includes text-mode (so Markdown counts, Racket does not).
(define (prose-mode? mode-sym) (and (memq 'text-mode (map mode-name (mode-chain mode-sym))) #t))

;; ---- segments --------------------------------------------------------------

(add-status-segment! 'line-col
  (lambda ()
    (define b (current-buffer))
    (define pos (send b get-start-position))
    (define para (send b position-paragraph pos))
    (define col (- pos (send b paragraph-start-position para)))
    (format "Ln ~a, Col ~a" (add1 para) (add1 col)))
  #:command 'goto-line #:hint "Click to go to a line" #:priority 100)

(add-status-segment! 'words
  (lambda ()
    (define b (current-buffer))
    (define n (- (send b get-end-position) (send b get-start-position)))
    (cond [(> n 0) (format "~a selected" n)]
          [(prose-mode? (send b get-mode)) (format "~a words" (word-count b))]
          [else #f]))
  #:priority 10)

(add-status-segment! 'encoding
  (lambda () (encoding-label (send (current-buffer) local-ref 'encoding 'utf-8)))
  #:command 'show-encoding #:hint "Click to see the file's encoding" #:priority 20)

(add-status-segment! 'eol
  (lambda () (eol-label (send (current-buffer) local-ref 'eol "\n")))
  #:command 'set-line-endings #:hint "Click to change line endings" #:priority 30)

(add-status-segment! 'language
  (lambda () (mode-display-name (send (current-buffer) get-mode)))
  #:command 'set-language #:hint "Click to change the Language" #:priority 70)

(add-status-segment! 'zoom
  (lambda () (format "~a%" (inexact->exact (round (* 100 (/ font-size (default-font-size)))))))
  #:command 'zoom-reset #:hint "Click to reset the zoom" #:priority 50)
