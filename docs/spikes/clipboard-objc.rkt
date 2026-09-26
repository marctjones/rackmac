#lang racket/base
;; Spike (#282): read rich pasteboard flavours directly through the Objective-C runtime.
(require ffi/unsafe ffi/unsafe/objc racket/gui/base)
(import-class NSPasteboard NSString)
(define (nsstring s) (tell (tell NSString alloc) initWithUTF8String: #:type _string s))
(define pb (tell NSPasteboard generalPasteboard))
(define (read-type t)
  (define data (tell pb dataForType: (nsstring t)))
  (and data
       (let* ([n (tell #:type _uint64 data length)]
              [p (tell #:type _pointer data bytes)])
         (make-sized-byte-string-copy p n))))
(define (make-sized-byte-string-copy p n) (let ([b (make-bytes n)]) (memcpy b p n) b))
(for ([t '("public.html" "public.rtf" "public.utf8-plain-text")])
  (define b (read-type t))
  (printf "~a: ~a bytes ~s\n" t (and b (bytes-length b)) (and b (subbytes b 0 (min 60 (bytes-length b))))))
