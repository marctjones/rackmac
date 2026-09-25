#lang racket/base
;; Files must round-trip byte-for-byte when nothing was edited, whatever their encoding
;; and line endings, and saving must never corrupt or half-write a file.
(require rackunit racket/file racket/class racket/string "../rackmac/fileio.rkt")

(define (round-trip bs)
  (define-values (text enc eol note) (decode-file bs))
  (encode-text text enc eol))

(define samples
  (list #"plain ascii\n"
        #"line one\r\nline two\r\n"
        #"classic mac\rline two\r"
        #"caf\303\251 na\303\257ve \342\202\254\n"             ; UTF-8
        #"\357\273\277bom first\n"                              ; UTF-8 with BOM
        #"caf\351 cr\350me\n"                                   ; Latin-1 (invalid UTF-8)
        #"\377\376h\0i\0\n\0"                                   ; UTF-16 LE with BOM
        #"\376\377\0h\0i\0\n"                                   ; UTF-16 BE with BOM
        #"\377\376=\330\0\336\n\0"                              ; UTF-16 LE surrogate pair (U+1F600)
        #""
        #"no trailing newline"))

(test-case "unedited files round-trip byte-for-byte"
  (for ([bs samples]) (check-equal? (round-trip bs) bs (format "~s" bs))))

(test-case "detection: encoding, line ending, and the note shown to the user"
  (define (info bs) (call-with-values (lambda () (decode-file bs)) list))
  (check-equal? (cadr (info #"caf\303\251")) 'utf-8)
  (check-equal? (cadr (info #"caf\351")) 'latin-1)
  (check-regexp-match #rx"not valid UTF-8" (list-ref (info #"caf\351") 3))
  (check-equal? (cadr (info #"\357\273\277x")) 'utf-8-bom)
  (check-equal? (caddr (info #"a\r\nb")) "\r\n")
  (check-equal? (caddr (info #"a\rb")) "\r")
  (check-equal? (car (info #"a\r\nb\rc\n")) "a\nb\nc\n" "the text always uses \\n")
  (check-regexp-match #rx"mixes line endings" (list-ref (info #"a\r\nb\r\nc\n") 3))
  (check-equal? (caddr (info #"a\r\nb\r\nc\n")) "\r\n" "the majority wins")
  (check-false (list-ref (info #"plain\n") 3) "no note for an ordinary file"))

(test-case "binary files are recognised and cannot be encoded back"
  (define-values (text enc eol note) (decode-file #"PK\3\4\0\0binary"))
  (check-eq? enc 'binary)
  (check-regexp-match #rx"read-only" note)
  (check-exn exn:fail:rackmac-encoding? (lambda () (encode-text text enc eol))))

(test-case "a character Latin-1 cannot hold stops the save with a clear message"
  (check-exn (lambda (e) (and (exn:fail:rackmac-encoding? e) (regexp-match? #rx"€.*Latin-1" (exn-message e))))
             (lambda () (encode-text "price 5€" 'latin-1 "\n")))
  (check-equal? (encode-text "café" 'latin-1 "\n") #"caf\351"))

(test-case "edits keep the file's encoding and line endings"
  (define-values (text enc eol note) (decode-file #"a\r\nb\r\n"))
  (check-equal? (encode-text (string-append text "c\n") enc eol) #"a\r\nb\r\nc\r\n"))

(test-case "safe-write-bytes! replaces atomically and keeps permissions"
  (define dir (make-temporary-file "rm-io~a" 'directory))
  (define f (build-path dir "doc.txt"))
  (display-to-file "old" f)
  (file-or-directory-permissions f #o640)
  (safe-write-bytes! f #"new")
  (check-equal? (file->bytes f) #"new")
  (check-equal? (bitwise-and (file-or-directory-permissions f 'bits) #o777) #o640 "permissions kept")
  (check-equal? (map path->string (directory-list dir)) '("doc.txt") "no temp files left behind")
  (delete-directory/files dir))

(test-case "safe-write-bytes! writes through a symlink, leaving the link in place"
  (define dir (make-temporary-file "rm-io~a" 'directory))
  (define real (build-path dir "real.txt"))
  (define link (build-path dir "link.txt"))
  (display-to-file "old" real)
  (make-file-or-directory-link real link)
  (safe-write-bytes! link #"via link")
  (check-true (link-exists? link) "still a link")
  (check-equal? (file->bytes real) #"via link")
  (delete-directory/files dir))

(test-case "a failed write leaves the original untouched"
  (define dir (make-temporary-file "rm-io~a" 'directory))
  (define f (build-path dir "doc.txt"))
  (display-to-file "original" f)
  (file-or-directory-permissions dir #o500)                 ; the folder is read-only: no temp file possible
  (check-exn exn:fail? (lambda () (safe-write-bytes! f #"new")))
  (file-or-directory-permissions dir #o700)
  (check-equal? (file->string f) "original")
  (delete-directory/files dir))
