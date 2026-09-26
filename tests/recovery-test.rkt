#lang racket/base
;; Recovery store, autosave timer, save/close cleanup, and restore on launch
;; (#74, #75, #76, #77): every check here does a real disk round trip through
;; rackmac/recovery.rkt -- list-snapshots always re-reads recovery/*.rktd from disk, never a
;; cache, so a struct-serialization bug cannot hide behind an in-memory assertion. #78's
;; crash-and-kill test lives in crash-test.rkt, which drives a real subprocess.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/file racket/class racket/path racket/list racket/gui/base
         "../rackmac/recovery.rkt" "../rackmac/editor.rkt" "../rackmac/hook.rkt"
         "../rackmac/settings.rkt" "../rackmac/platform.rkt")

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

;; ---- #75: autosave timer --------------------------------------------------------------------

(enable-autosave-recovery!)

(test-case "autosave writes a snapshot only while the document is modified, after the interval"
  (setting-set! 'autosave-interval 0.2)
  (define b (new-buffer! "untitled"))
  (check-false (buffer-recovery-id b) "nothing snapshotted yet")
  (send b insert "autosave me")
  (sleep/yield 0.4)
  (define id (buffer-recovery-id b))
  (check-not-false id "the debounce timer fired and wrote a snapshot")
  (check-equal? (snapshot-text (snapshot-for id)) "autosave me"))

(test-case "an unmodified document is never autosaved"
  (setting-set! 'autosave-interval 0.15)
  (define p (doc-path 2))
  (display-to-file "saved already" p #:exists 'truncate)
  (define b (open-file! p))              ; load-path! leaves it unmodified
  (sleep/yield 0.35)
  (check-false (buffer-recovery-id b) "no snapshot: is-modified? was #f the whole time"))

(test-case "autosave is off when the interval setting is #f"
  (setting-set! 'autosave-interval #f)
  (define b (new-buffer! "untitled"))
  (send b insert "should not be saved")
  (sleep/yield 0.3)
  (check-false (buffer-recovery-id b)))

(test-case "the autosave timer is debounced: a fresh edit restarts the wait instead of firing on schedule"
  (setting-set! 'autosave-interval 0.6)
  (define b (new-buffer! "untitled"))
  (send b insert "a")                     ; t=0: would fire at t=0.6 if NOT debounced
  (sleep/yield 0.3)
  (send b insert "b")                     ; t=0.3: restarts the timer to fire at t=0.9
  (sleep/yield 0.45)                      ; now at t=0.75: past the un-debounced deadline (0.6),
  (check-false (buffer-recovery-id b)     ; still before the debounced one (0.9)
              "no snapshot yet: the second edit reset the debounce window")
  (sleep/yield 0.35)                            ; now at t=1.10: past the debounced deadline
  (define id (buffer-recovery-id b))
  (check-not-false id)
  (check-equal? (snapshot-text (snapshot-for id)) "ab" "one write, with the final text"))

;; ---- #76: delete on save and close -----------------------------------------------------------

(test-case "saving a document deletes its recovery snapshot"
  (define p (doc-path 3))
  (display-to-file "v1" p #:exists 'truncate)
  (define b (open-file! p))
  (send b insert "!" (send b last-position))
  (snapshot-buffer! b)
  (define id (buffer-recovery-id b))
  (check-not-false (snapshot-for id) "the snapshot exists before save")
  (send b save-to! p)
  (check-false (snapshot-for id) "save-to! ran the after-save hook, which deleted it"))

(test-case "closing a document that is no longer modified deletes its snapshot"
  (define b (new-buffer! "untitled"))
  (send b insert "temp")
  (snapshot-buffer! b)
  (define id (buffer-recovery-id b))
  (check-not-false (snapshot-for id))
  (send b set-modified #f)                ; as if it had just been saved
  (kill-buffer! b)
  (check-false (snapshot-for id) "before-close-buffer deleted it because it was not modified"))

(test-case "closing WITHOUT saving preserves the snapshot for recovery"
  (define b (new-buffer! "untitled"))
  (send b insert "unsaved work")
  (snapshot-buffer! b)
  (define id (buffer-recovery-id b))
  (check-true (send b is-modified?))
  (kill-buffer! b)                        ; Don't Save: still modified when it closes
  (check-not-false (snapshot-for id) "the snapshot survives so the text can be recovered"))

;; ---- #77: restore on next launch --------------------------------------------------------------

(clear-recovery!)   ; only the snapshots this section creates should be on disk to count

(test-case "recover-on-launch! lists every snapshot and applies Restore/Discard per document"
  (define b1 (new-buffer! "untitled"))
  (send b1 insert "restore this text")
  (send b1 set-position 3)
  (snapshot-buffer! b1)
  (define id1 (buffer-recovery-id b1))

  (define p2 (doc-path 4))
  (display-to-file "on disk" p2 #:exists 'truncate)
  (define b2 (open-file! p2))
  (send b2 insert " plus edits" (send b2 last-position))
  (send b2 set-position 5)
  (snapshot-buffer! b2)
  (define id2 (buffer-recovery-id b2))

  ;; id1 (untitled, text-mode) is discarded and id2 (a .md file, markdown-mode) is restored --
  ;; distinct Languages, so a restore that ignored snapshot-mode entirely would still be caught.
  (define before-count (length (visible-buffers)))   ; excludes the hidden Activity log
  (define seen #f)
  (parameterize ([recovery-decide!
                  (lambda (snaps)
                    (set! seen snaps)
                    (for/list ([s snaps]) (cons (snapshot-id s) (if (equal? (snapshot-id s) id2) 'restore 'discard))))])
    (recover-on-launch!))

  (check-equal? (length seen) 2 "both documents were offered")
  (check-false (snapshot-for id1) "the discarded one is gone from disk")
  (check-not-false (snapshot-for id2) "the restored one keeps its file (still unsaved)")
  (check-equal? (length (visible-buffers)) (add1 before-count) "exactly one new document was opened")

  (define restored (findf (lambda (b) (and (not (memq b (list b1 b2))) (send b is-modified?)
                                           (regexp-match? #rx"on disk plus edits" (send b get-text))))
                          (all-buffers)))
  (check-not-false restored)
  (check-true (send restored is-modified?))
  (check-eq? (send restored get-mode) 'markdown-mode "Language restored, not just copied from a coincidentally-matching default")
  (check-equal? (send restored get-path) (send b2 get-path) "original path restored")
  (check-equal? (send restored get-start-position) 5 "cursor restored"))

(test-case "when the decision function omits a snapshot, it is discarded"
  (define b (new-buffer! "untitled"))
  (send b insert "leftover")
  (snapshot-buffer! b)
  (define id (buffer-recovery-id b))
  (parameterize ([recovery-decide! (lambda (snaps) '())])
    (recover-on-launch!))
  (check-false (snapshot-for id)))

(test-case "nothing happens when there is nothing to recover"
  (for ([s (list-snapshots)]) (delete-snapshot! (snapshot-id s)))
  (define called? #f)
  (parameterize ([recovery-decide! (lambda (snaps) (set! called? #t) '())])
    (recover-on-launch!))
  (check-false called? "recovery-decide! is never asked when there are no snapshots"))
