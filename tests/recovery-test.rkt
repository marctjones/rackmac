#lang racket/base
;; Recovery store (#74): every check here does a real disk round trip through
;; rackmac/recovery.rkt -- list-snapshots always re-reads recovery/*.rktd from disk, never a
;; cache, so a struct-serialization bug cannot hide behind an in-memory assertion.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/file racket/class racket/path racket/list
         "../rackmac/recovery.rkt" "../rackmac/editor.rkt" "../rackmac/hook.rkt"
         "../rackmac/platform.rkt")

(define dir (make-temporary-file "rackmac-recovery~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))

;; A separate tree, well away from the config dir, standing in for "the user's own folders"
;; (docs/REPLAN.md S3: synced folders must never see the recovery store).
(define docs-dir (build-path dir "notes"))
(make-directory* docs-dir)
(define (doc-path n) (build-path docs-dir (format "note-~a.md" n)))

(define (snapshot-for id) (findf (lambda (s) (equal? (snapshot-id s) id)) (list-snapshots)))
(define (clear-recovery!) (for ([s (list-snapshots)]) (delete-snapshot! (snapshot-id s))))

(define (path-prefix? p base)
  (define ps (explode-path (simplify-path (path->complete-path p))))
  (define bs (explode-path (simplify-path (path->complete-path base))))
  (and (>= (length ps) (length bs)) (equal? (take ps (length bs)) bs)))

(test-case "a snapshot is written under <config dir>/recovery, never under the document's own folder"
  (define b (new-buffer! "untitled"))
  (send b insert "hello world")
  (snapshot-buffer! b)
  (check-true (directory-exists? (recovery-dir)))
  (check-equal? (recovery-dir) (build-path (config-dir) "recovery"))
  (check-true (path-prefix? (recovery-dir) dir) "recovery dir is inside RACKMAC_HOME")
  (for ([p (in-list (directory-list (recovery-dir) #:build? #t))])
    (check-false (path-prefix? p docs-dir) "no recovery file lands in the user's notes folder")))

(test-case "a snapshot round-trips text, path, name, Language and cursor through a real disk read"
  (define p (doc-path 1))
  (display-to-file "line one\nline two" p #:exists 'truncate)
  (define b (open-file! p))
  (send b insert "!" (send b last-position))
  (send b set-position 4)
  (snapshot-buffer! b)
  (define id (buffer-recovery-id b))
  (define s (snapshot-for id))
  (check-not-false s)
  (check-equal? (snapshot-path s) (path->string p))
  (check-equal? (snapshot-mode s) (send b get-mode))
  (check-equal? (snapshot-cursor s) 4)
  (check-equal? (snapshot-text s) (send b get-text))
  (check-regexp-match #rx"line one" (snapshot-text s)))

(test-case "an untitled document's snapshot has no path but keeps its name"
  (define b (new-buffer! "untitled"))
  (send b insert "scratch text")
  (snapshot-buffer! b)
  (define s (snapshot-for (buffer-recovery-id b)))
  (check-false (snapshot-path s))
  (check-equal? (snapshot-name s) (send b get-name)))

(test-case "re-snapshotting the same document overwrites its one file instead of piling up"
  (define b (new-buffer! "untitled"))
  (send b insert "v1")
  (snapshot-buffer! b)
  (define id (buffer-recovery-id b))
  (send b insert " v2")
  (snapshot-buffer! b)
  (check-equal? (buffer-recovery-id b) id "same id reused")
  (check-equal? (length (filter (lambda (s) (equal? (snapshot-id s) id)) (list-snapshots))) 1)
  (check-equal? (snapshot-text (snapshot-for id)) "v1 v2"))

(test-case "a snapshot is plain text on disk, not encrypted (encryption is explicitly not required)"
  (define b (new-buffer! "untitled"))
  (send b insert "plainly readable")
  (snapshot-buffer! b)
  (define bs (file->string (build-path (recovery-dir) (format "~a.rktd" (buffer-recovery-id b)))))
  (check-regexp-match #rx"plainly readable" bs))

(test-case "no stray temp file is left behind after a write (atomic write via temp + rename)"
  (define b (new-buffer! "untitled"))
  (send b insert "atomic")
  (snapshot-buffer! b)
  (for ([p (in-list (directory-list (recovery-dir)))])
    (check-false (regexp-match? #rx"[.]tmp" (path->string p)) (format "leftover temp file ~a" p))))

(test-case "a corrupt recovery file is quarantined and skipped, never fatal to list-snapshots"
  (make-directory* (recovery-dir))
  (define bad (build-path (recovery-dir) "garbage.rktd"))
  (display-to-file "(this is not )) a valid snapshot(" bad #:exists 'truncate)
  (define reports '())
  (parameterize ([error-reporter (lambda (who e) (set! reports (cons (list who e) reports)))])
    (check-false (findf (lambda (s) #f) (list-snapshots)) "list-snapshots itself does not raise"))
  (check-true (pair? reports) "the corruption was reported")
  (check-false (file-exists? bad) "the corrupt file was moved aside")
  (check-true (ormap (lambda (p) (regexp-match? #rx"garbage[.]rktd[.]corrupt-" (path->string p)))
                     (directory-list (recovery-dir)))))
