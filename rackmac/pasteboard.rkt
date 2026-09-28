#lang racket/base
;; Reading the rich flavors of the system pasteboard (docs/UI-DESIGN.md §2.6). racket/gui's
;; clipboard only ever sees plain text (every other type name is rewritten to
;; `org.racket-lang.<name>`), so the formats other apps put there -- a spreadsheet's or Word's
;; `public.html` -- are read through the Objective-C runtime, as the #282 spike did
;; (docs/spikes/clipboard-objc.rkt). macOS only; elsewhere every rich type reads as absent and
;; paste stays plain text. Nothing here raises: a pasteboard that can't be read is "no rich data".
;;
;; `current-pasteboard-reader` is a parameter so tests supply canned pasteboards anywhere.
(require racket/class racket/gui/base ffi/unsafe ffi/unsafe/objc "platform.rkt")
(provide current-pasteboard-reader pasteboard-data pasteboard-html pasteboard-text
         pasteboard-change-count)

;; `type` (a UTI string such as "public.html") -> its bytes on the general pasteboard, or #f.
(define (read-mac-pasteboard type)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (define NSPasteboard (objc_lookUpClass "NSPasteboard"))
    (define NSString (objc_lookUpClass "NSString"))
    (and NSPasteboard NSString
         (let* ([pb (tell NSPasteboard generalPasteboard)]
                [t (tell (tell NSString alloc) initWithUTF8String: #:type _string type)]
                [data (tell pb dataForType: t)])
           (tell t release)
           (and data
                (let* ([n (tell #:type _uint64 data length)]
                       [p (tell #:type _pointer data bytes)]
                       [b (make-bytes n)])
                  (memcpy b p n)
                  b))))))

(define current-pasteboard-reader
  (make-parameter (lambda (type) (and (mac?) (read-mac-pasteboard type)))))

(define (pasteboard-data type)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    ((current-pasteboard-reader) type)))

;; The HTML flavor as a string, or #f. Spreadsheets and Word write UTF-8; a stray bad byte
;; becomes U+FFFD rather than losing the paste.
(define (pasteboard-html)
  (define b (pasteboard-data "public.html"))
  (and b (positive? (bytes-length b)) (bytes->string/utf-8 b (integer->char #xFFFD))))

;; Plain text comes through racket/gui on every platform: it is what text% itself pastes.
(define (pasteboard-text [time 0])
  (send the-clipboard get-clipboard-string time))

;; The general pasteboard's change count (it goes up whenever any app, this one included,
;; replaces the contents), or #f where it can't be read. Lets a paste tell "what we copied" from
;; "the same text, copied again elsewhere".
(define (pasteboard-change-count)
  (and (mac?)
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (define NSPasteboard (objc_lookUpClass "NSPasteboard"))
         (and NSPasteboard
              (tell #:type _long (tell NSPasteboard generalPasteboard) changeCount)))))
