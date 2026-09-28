#lang racket/base
;; Paste converters: what Paste inserts when the clipboard holds more than plain text. Paste
;; (text%'s own, through `buffer%`'s `do-paste`) asks each registered converter, highest
;; priority first, for the text to insert; the first that answers wins, and when none does,
;; the clipboard's plain text is pasted exactly as before. Converters read the clipboard
;; through rackmac/pasteboard.rkt.
;;
;; A converter is (lambda (buffer pos) ...) -> string or #f, where `pos` is where the paste
;; lands (the selection is already gone). It runs inside Paste's edit sequence, so whatever it
;; returns is one undo step. Registered so far: spreadsheet ranges to a Markdown table (#416,
;; rackmac/paste-table.rkt, priority 100). Rich text from Word (#307) belongs below it, so a
;; copied range never reaches a general HTML conversion.
(require "owner.rkt" "hook.rkt")
(provide add-paste-converter! remove-paste-converter! convert-paste)

(define converters '())   ; (priority . proc), highest priority first

(define (add-paste-converter! proc #:priority [priority 0])
  (remove-paste-converter! proc)
  (set! converters (sort (cons (cons priority proc) converters) > #:key car))
  (register-undo! 'paste-converter (lambda () (remove-paste-converter! proc))))

(define (remove-paste-converter! proc)
  (set! converters (filter (lambda (p) (not (eq? (cdr p) proc))) converters)))

;; A converter that fails is reported and skipped: a broken one must never lose a paste.
(define (convert-paste buffer pos)
  (for/or ([p (in-list converters)])
    (with-handlers ([exn:fail? (lambda (e) (report-error! 'paste-converter e) #f)])
      (define s ((cdr p) buffer pos))
      (and (string? s) s))))
