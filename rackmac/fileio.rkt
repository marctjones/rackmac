#lang racket/base
;; Turning file bytes into editor text and back, without losing anything. Pure (no GUI).
;;
;; decode-file: bytes -> (values text encoding eol note)
;;   encoding: 'utf-8, 'utf-8-bom, 'utf-16le, 'utf-16be, 'latin-1 or 'binary
;;   eol:      "\n", "\r\n" or "\r"  (the text itself always uses "\n")
;;   note:     #f, or a sentence to show the user (fallback encoding, mixed endings, binary)
;; encode-text: text encoding eol -> bytes, raising exn:fail:rackmac-encoding when a
;;   character cannot be represented (e.g. "€" in a Latin-1 file), instead of writing junk.
;; safe-write-bytes!: temp file in the same folder, same permissions, then rename over.
(require racket/string racket/file racket/list racket/path)
(provide decode-file encode-text safe-write-bytes! encoding-label eol-label
         (struct-out exn:fail:rackmac-encoding))

(struct exn:fail:rackmac-encoding exn:fail ())

(define (encoding-label e)
  (case e [(utf-8) "UTF-8"] [(utf-8-bom) "UTF-8 with BOM"] [(utf-16le) "UTF-16 LE"]
    [(utf-16be) "UTF-16 BE"] [(latin-1) "Latin-1"] [(binary) "Binary"] [else (format "~a" e)]))

;; The status bar's line-ending segment and the Line Endings… command share this label.
(define (eol-label e) (cond [(equal? e "\n") "LF"] [(equal? e "\r\n") "CRLF"] [(equal? e "\r") "CR"] [else (format "~a" e)]))

;; ---- UTF-16 (done by hand so it works the same everywhere) -----------------

(define (utf-16->string bs big?)
  (define n (quotient (bytes-length bs) 2))
  (define (unit i) (if big?
                       (+ (* 256 (bytes-ref bs (* 2 i))) (bytes-ref bs (add1 (* 2 i))))
                       (+ (bytes-ref bs (* 2 i)) (* 256 (bytes-ref bs (add1 (* 2 i)))))))
  (define out (open-output-string))
  (let loop ([i 0])
    (when (< i n)
      (define u (unit i))
      (cond
        [(and (<= #xD800 u #xDBFF) (< (add1 i) n) (<= #xDC00 (unit (add1 i)) #xDFFF))
         (write-char (integer->char (+ #x10000 (* (- u #xD800) #x400) (- (unit (add1 i)) #xDC00))) out)
         (loop (+ i 2))]
        [(<= #xD800 u #xDFFF) (raise (exn:fail:rackmac-encoding "unpaired UTF-16 surrogate" (current-continuation-marks)))]
        [else (write-char (integer->char u) out) (loop (add1 i))])))
  (get-output-string out))

(define (string->utf-16 s big?)
  (define out (open-output-bytes))
  (define (put u) (if big?
                      (write-bytes (bytes (quotient u 256) (remainder u 256)) out)
                      (write-bytes (bytes (remainder u 256) (quotient u 256)) out)))
  (for ([c (in-string s)])
    (define cp (char->integer c))
    (cond [(< cp #x10000) (put cp)]
          [else (define v (- cp #x10000))
                (put (+ #xD800 (quotient v #x400))) (put (+ #xDC00 (remainder v #x400)))]))
  (get-output-bytes out))

;; ---- line endings -------------------------------------------------------

(define (detect-eol s)
  (define crlf (length (regexp-match-positions* #rx"\r\n" s)))
  (define cr (- (length (regexp-match-positions* #rx"\r" s)) crlf))
  (define lf (- (length (regexp-match-positions* #rx"\n" s)) crlf))
  (define kinds (filter (lambda (p) (> (cdr p) 0)) (list (cons "\n" lf) (cons "\r\n" crlf) (cons "\r" cr))))
  (cond [(null? kinds) (values "\n" #f)]
        [(null? (cdr kinds)) (values (car (car kinds)) #f)]
        [else (define winner (car (argmax cdr kinds)))
              (values winner (format "This file mixes line endings; they will be saved as ~a."
                                     (case winner [("\n") "LF"] [("\r\n") "CRLF"] [else "CR"])))]))

(define (normalize-eol s) (regexp-replace* #rx"\r\n?" s "\n"))

;; ---- decode / encode ------------------------------------------------------

(define (decode-file bs)
  (define (finish text enc note)
    (define-values (eol mixed) (detect-eol text))
    (values (normalize-eol text) enc eol (or note mixed)))
  (cond
    [(and (>= (bytes-length bs) 3) (equal? (subbytes bs 0 3) #"\357\273\277"))
     (finish (bytes->string/utf-8 (subbytes bs 3) #\uFFFD) 'utf-8-bom #f)]
    [(and (>= (bytes-length bs) 2) (equal? (subbytes bs 0 2) #"\377\376"))
     (finish (utf-16->string (subbytes bs 2) #f) 'utf-16le #f)]
    [(and (>= (bytes-length bs) 2) (equal? (subbytes bs 0 2) #"\376\377"))
     (finish (utf-16->string (subbytes bs 2) #t) 'utf-16be #f)]
    [(for/or ([b (in-bytes bs)]) (zero? b))
     (values (bytes->string/latin-1 bs) 'binary "\n"
             "This looks like a binary file, so it is open read-only.")]
    [(with-handlers ([exn:fail:contract? (lambda (e) #f)]) (bytes->string/utf-8 bs))
     => (lambda (s) (finish s 'utf-8 #f))]
    [else
     (finish (bytes->string/latin-1 bs) 'latin-1
             "This file is not valid UTF-8, so it was opened as Latin-1 and will be saved that way.")]))

(define (encode-text text enc eol)
  (define s (if (equal? eol "\n") text (string-replace text "\n" eol)))
  (case enc
    [(utf-8) (string->bytes/utf-8 s)]
    [(utf-8-bom) (bytes-append #"\357\273\277" (string->bytes/utf-8 s))]
    [(utf-16le) (bytes-append #"\377\376" (string->utf-16 s #f))]
    [(utf-16be) (bytes-append #"\376\377" (string->utf-16 s #t))]
    [(latin-1)
     (define bad (for/first ([c (in-string s)] #:when (> (char->integer c) 255)) c))
     (when bad
       (raise (exn:fail:rackmac-encoding
               (format "\"~a\" cannot be saved in a Latin-1 file. Remove it, or save a copy as UTF-8." bad)
               (current-continuation-marks))))
     (string->bytes/latin-1 s)]
    [(binary) (raise (exn:fail:rackmac-encoding "Binary files are read-only in Rackmac." (current-continuation-marks)))]
    [else (error 'encode-text "unknown encoding ~a" enc)]))

;; ---- safe write ------------------------------------------------------------

(define (safe-write-bytes! path bs)
  ;; Write through a symlink to its target, so the link itself survives.
  (define target (if (link-exists? path) (normalize-path path) path))
  (define-values (dir name _d) (split-path (path->complete-path target)))
  (define tmp (make-temporary-file (string-append "." (path->string name) ".~a.tmp") #f dir))
  (with-handlers ([(lambda (e) #t) (lambda (e) (when (file-exists? tmp) (delete-file tmp)) (raise e))])
    (call-with-output-file tmp #:exists 'truncate (lambda (o) (write-bytes bs o)))
    (when (file-exists? target)
      (file-or-directory-permissions tmp (file-or-directory-permissions target 'bits)))
    (rename-file-or-directory tmp target #t)))
