#lang racket/base
;; Encoding and BOM detection through the editor (#87): open a file, edit it, save it, and check
;; the bytes on disk. rackmac/fileio.rkt's decode-file/encode-text are already tested byte-for-byte
;; in isolation in tests/fileio-test.rkt; these tests instead exercise buffer.rkt's load-path!/
;; save-to! wiring, so fixtures are built independently of fileio.rkt's own encoder (Racket's
;; built-in string->bytes/utf-8, and integer->integer-bytes for UTF-16LE code units).
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/class racket/file "../rackmac/editor.rkt")

(define dir (make-temporary-file "rm-encoding~a" 'directory))

(define (utf16le-bytes s)
  (apply bytes-append #"\377\376"
         (for/list ([c (in-string s)]) (integer->integer-bytes (char->integer c) 2 #f #f))))

(test-case "a UTF-8 file without a BOM opens and saves without gaining one"
  (define f (build-path dir "utf8-no-bom.txt"))
  (define original (string->bytes/utf-8 "café naïve €\n"))
  (call-with-output-file f (lambda (o) (write-bytes original o)))
  (define b (open-file! f))
  (check-equal? (send b get-text) "café naïve €\n")
  (check-eq? (send b local-ref 'encoding) 'utf-8)
  (send b save-to! f)
  (check-equal? (file->bytes f) original "byte-identical, still no BOM"))

(test-case "a UTF-8 file with a BOM keeps its BOM through open, edit and save"
  (define f (build-path dir "utf8-bom.txt"))
  (define original (bytes-append #"\357\273\277" (string->bytes/utf-8 "hello world\n")))
  (call-with-output-file f (lambda (o) (write-bytes original o)))
  (define b (open-file! f))
  (check-equal? (send b get-text) "hello world\n" "the BOM itself is not part of the text")
  (check-eq? (send b local-ref 'encoding) 'utf-8-bom)
  (send b save-to! f)
  (check-equal? (file->bytes f) original "unedited: byte-identical, BOM kept")
  (send b insert "!" (send b last-position))
  (send b save-to! f)
  (check-equal? (file->bytes f)
                (bytes-append #"\357\273\277" (string->bytes/utf-8 "hello world\n!"))
                "edited: still re-encoded with its BOM, not silently switched to plain UTF-8"))

(test-case "a UTF-16LE file opens and round-trips through save byte-identical"
  (define f (build-path dir "utf16le.txt"))
  (define original (utf16le-bytes "hello wörld\n"))
  (call-with-output-file f (lambda (o) (write-bytes original o)))
  (define b (open-file! f))
  (check-equal? (send b get-text) "hello wörld\n")
  (check-eq? (send b local-ref 'encoding) 'utf-16le)
  (send b save-to! f)
  (check-equal? (file->bytes f) original "byte-identical, still UTF-16LE with its BOM")
  (send b insert "!" (send b last-position))
  (send b save-to! f)
  (check-equal? (file->bytes f) (utf16le-bytes "hello wörld\n!")
                "edited: re-encoded as UTF-16LE, not silently switched to UTF-8"))
