#lang racket/base
;; Recovery store, autosave timer, save/close cleanup, and restore on launch
;; (#74, #75, #76, #77): every check here does a real disk round trip through
;; rackmac/recovery.rkt -- list-snapshots always re-reads recovery/*.rktd from disk, never a
;; cache, so a struct-serialization bug cannot hide behind an in-memory assertion. #78's
;; crash-and-kill test lives in crash-test.rkt, which drives a real subprocess.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/file racket/class racket/path racket/list racket/gui/base racket/os
         "../rackmac/recovery.rkt" "../rackmac/editor.rkt" "../rackmac/hook.rkt"
         "../rackmac/settings.rkt" "../rackmac/platform.rkt" "../rackmac/commands.rkt"
         "../rackmac/command.rkt")

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

(test-case "answering Don't Save (on close or on quit) discards the snapshot, as in Word and Pages"
  (define b (new-buffer! "untitled"))
  (send b insert "changes the user chose to throw away")
  (snapshot-buffer! b)
  (define id (buffer-recovery-id b))
  (check-not-false (snapshot-for id))
  (parameterize ([confirm-save-changes (lambda (doc) 'discard)])
    (check-true (confirm-quit?)))
  (check-false (snapshot-for id) "no recovery offer next launch for text the user discarded"))

;; Quit asks about each unsaved document in turn; `answers` maps a document to its answer and
;; everything else (leftovers from earlier tests) to Don't Save.
(define (quit-answering answers)
  (parameterize ([confirm-save-changes (lambda (doc) (cond [(assq doc answers) => cdr] [else 'discard]))])
    (confirm-quit?)))

(test-case "quit: Don't Save on one document then Cancel on another keeps the first one's snapshot"
  (for ([order (in-list '(discard-first cancel-first))])
    (define keep (new-buffer! "untitled"))
    (send keep insert "discard me, then change my mind")
    (snapshot-buffer! keep)
    (define other (new-buffer! "untitled"))
    (send other insert "the one whose question gets Cancel")
    (snapshot-buffer! other)
    (define-values (first second) (if (eq? order 'discard-first) (values keep other) (values other keep)))
    ;; Put the two documents at the front of the quit's order, in `order`.
    (set-tab-order! (append (list first second) (remq first (remq second (visible-buffers)))))
    (define asked '())
    (parameterize ([confirm-save-changes
                    (lambda (doc) (set! asked (cons doc asked))
                      (cond [(eq? doc keep) 'discard] [(eq? doc other) 'cancel] [else 'discard]))])
      (check-false (confirm-quit?) (format "~a: the quit was cancelled" order)))
    (check-not-false (memq first asked))
    (check-true (send keep is-modified?) "the document is still open and modified")
    (check-not-false (snapshot-for (buffer-recovery-id keep))
                     (format "~a: its snapshot survives the cancelled quit" order))
    (check-not-false (snapshot-for (buffer-recovery-id other)))
    ;; Now quit for real, answering Don't Save everywhere: only then do the snapshots go.
    (check-true (quit-answering '()))
    (check-false (snapshot-for (buffer-recovery-id keep)))
    (check-false (snapshot-for (buffer-recovery-id other)))
    (for ([b (list keep other)]) (send b set-modified #f) (kill-buffer! b))))

(test-case "close tab: Don't Save still discards the snapshot at once"
  (define b (new-buffer! "untitled"))
  (send b insert "close me")
  (snapshot-buffer! b)
  (define id (buffer-recovery-id b))
  (parameterize ([confirm-save-changes (lambda (doc) 'discard)])
    (set-current-buffer! b)
    (run-command 'close-tab))
  (check-false (memq b (all-buffers)) "the tab closed")
  (check-false (snapshot-for id)))

(test-case "a document closed while modified without a Don't Save answer keeps its snapshot (safe default)"
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
  (kill-buffer! b2)   ; as after a crash: the file is no longer open, its snapshot remains

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

;; ---- adversarial review fixes (E3.M1) ------------------------------------------------------

(define (activity-since before)
  (define now (send (messages-buffer) get-text))
  (substring now (min (string-length before) (string-length now))))

(test-case "a failed autosave is reported once in the Activity log and never claims a backup exists"
  (setting-set! 'autosave-interval 30)
  (define b (new-buffer! "untitled"))
  (send b insert "text with nowhere to go")
  (make-directory* (recovery-dir))
  (define before (send (messages-buffer) get-text))
  (dynamic-wind
   (lambda () (file-or-directory-permissions (recovery-dir) #o500))   ; unwritable
   (lambda ()
     (autosave-buffer! b)
     (autosave-buffer! b)
     (autosave-buffer! b))
   (lambda () (file-or-directory-permissions (recovery-dir) #o700)))
  (define log (activity-since before))
  (check-equal? (length (regexp-match* #rx"Could not save an automatic backup" log)) 1
                "reported once, not once per tick")
  (check-false (buffer-recovery-id b) "no id: nothing was written")
  (autosave-buffer! b)                          ; the folder is writable again
  (define id (buffer-recovery-id b))
  (check-not-false id)
  (check-equal? (snapshot-text (snapshot-for id)) "text with nowhere to go")
  ;; A new failure after a success is reported again.
  (define before2 (send (messages-buffer) get-text))
  (dynamic-wind
   (lambda () (file-or-directory-permissions (recovery-dir) #o500))
   (lambda () (autosave-buffer! b))
   (lambda () (file-or-directory-permissions (recovery-dir) #o700)))
  (check-regexp-match #rx"Could not save an automatic backup" (activity-since before2)))

(test-case "the recovery folder is private (0700) and every snapshot file is 0600"
  (clear-recovery!)
  (delete-directory/files (recovery-dir))
  (define b (new-buffer! "untitled"))
  (send b insert "private notes")
  (snapshot-buffer! b)
  (check-equal? (file-or-directory-permissions (recovery-dir) 'bits) #o700)
  (define f (build-path (recovery-dir) (format "~a.rktd" (buffer-recovery-id b))))
  (check-equal? (file-or-directory-permissions f 'bits) #o600)
  ;; A snapshot and folder left world-readable by an older version are tightened on rewrite.
  (file-or-directory-permissions f #o644)
  (file-or-directory-permissions (recovery-dir) #o755)
  (send b insert "!")
  (snapshot-buffer! b)
  (check-equal? (file-or-directory-permissions (recovery-dir) 'bits) #o700)
  (check-equal? (file-or-directory-permissions f 'bits) #o600))

(test-case "quarantined snapshots older than 30 days are pruned; newer ones are kept"
  (make-directory* (recovery-dir))
  (define old (build-path (recovery-dir) (format "x.rktd.corrupt-~a" (- (current-seconds) (* 31 24 60 60)))))
  (define recent (build-path (recovery-dir) (format "y.rktd.corrupt-~a" (- (current-seconds) (* 2 24 60 60)))))
  (for ([p (list old recent)]) (display-to-file "junk" p #:exists 'truncate))
  (list-snapshots)
  (check-false (file-exists? old))
  (check-true (file-exists? recent))
  (delete-file recent))

;; Restores just `id` (and discards every other snapshot on disk), returning the document the
;; restore made current.
(define (restore-only! id)
  (parameterize ([recovery-decide!
                  (lambda (snaps)
                    (for/list ([s snaps]) (cons (snapshot-id s) (if (equal? (snapshot-id s) id) 'restore 'discard))))])
    (recover-on-launch!))
  (current-buffer))

;; Edits the file at `p` (created with `bytes` first), snapshots it and closes it unsaved, as a
;; crash would leave it. Returns the snapshot id.
(define (crash-with-edits! p bytes edit)
  (call-with-output-file p #:exists 'truncate (lambda (o) (write-bytes bytes o)))
  (define b (open-file! p))
  (send b insert edit (send b last-position))
  (snapshot-buffer! b)
  (define id (buffer-recovery-id b))
  (kill-buffer! b)
  id)

(define (write-raw-snapshot! id . fields)
  (make-directory* (recovery-dir))
  (with-output-to-file (build-path (recovery-dir) (format "~a.rktd" id)) #:exists 'truncate
    (lambda () (write (apply make-prefab-struct 'snapshot id fields)))))

(define (buffers-for p) (filter (lambda (b) (equal? (send b get-path) p)) (all-buffers)))

(test-case "restore keeps a Latin-1 CRLF file's encoding and line endings: Save writes them back"
  (clear-recovery!)
  (define p (doc-path 10))
  (define id (crash-with-edits! p #"caf\351\r\nsecond line\r\n" "déjà vu\n"))
  (define r (restore-only! id))
  (check-equal? (send r get-path) p)
  (check-equal? (send r local-ref 'encoding) 'latin-1)
  (check-equal? (send r local-ref 'eol) "\r\n")
  (check-true (send r is-modified?))
  (check-true (save-buffer! r))
  (check-equal? (file->bytes p) #"caf\351\r\nsecond line\r\nd\351j\340 vu\r\n" "bytes on disk, not UTF-8/LF")
  (check-false (snapshot-for id) "saving discarded the snapshot"))

(test-case "restore detaches the file when it was changed elsewhere since the backup, so Save cannot overwrite it"
  (clear-recovery!)
  (define p (doc-path 11))
  (define id (crash-with-edits! p #"original" " and my edits"))
  (define before (send (messages-buffer) get-text))
  (display-to-file "edited in another app" p #:exists 'truncate)
  (file-or-directory-modify-seconds p (+ (file-or-directory-modify-seconds p) 60))
  (define r (restore-only! id))
  (check-equal? (send r get-text) "original and my edits" "the recovered text is kept")
  (check-false (send r get-path) "no file: Save will ask Save As")
  (check-true (send r is-modified?))
  (check-regexp-match #rx"changed since.*Save As" (activity-since before))
  (check-equal? (file->string p) "edited in another app" "the other app's changes are untouched"))

(test-case "restore detaches the file when it has been moved or deleted since the backup"
  (clear-recovery!)
  (define p (doc-path 12))
  (define id (crash-with-edits! p #"here" " then gone"))
  (delete-file p)
  (define r (restore-only! id))
  (check-equal? (send r get-text) "here then gone")
  (check-false (send r get-path)))

(test-case "a document whose file never existed on disk keeps its path"
  (clear-recovery!)
  (define p (doc-path 13))
  (when (file-exists? p) (delete-file p))
  (define b (open-file! p))
  (send b insert "brand new")
  (snapshot-buffer! b)
  (define id (buffer-recovery-id b))
  (kill-buffer! b)
  (define r (restore-only! id))
  (check-equal? (send r get-path) p)
  (check-equal? (send r get-text) "brand new"))

(test-case "snapshots from before file-mtime/owner existed are still read and restored"
  (clear-recovery!)
  (define p (doc-path 14))
  (display-to-file "old format" p #:exists 'truncate)
  (define mtime (file-or-directory-modify-seconds p))
  ;; 7 fields: id path name mode cursor saved-at text. Backup taken after the file's last change.
  (write-raw-snapshot! "1-1" (path->string p) "note-14.md" 'markdown-mode 2 (+ mtime 100) "old format, edited")
  (write-raw-snapshot! "1-2" #f "untitled" 'text-mode 0 (current-seconds) "old untitled")
  (check-equal? (length (list-snapshots)) 2 "neither is quarantined")
  (check-equal? (snapshot-file-mtime (snapshot-for "1-1")) 'unknown)
  (define r (restore-only! "1-1"))
  (check-equal? (send r get-text) "old format, edited")
  (check-equal? (send r get-path) p "file unchanged since the backup: path kept")
  (send r set-modified #f) (kill-buffer! r)
  ;; The same old snapshot, but the file was modified after the backup: detached.
  (write-raw-snapshot! "1-3" (path->string p) "note-14.md" 'markdown-mode 0 (- mtime 100) "older backup")
  (define r2 (restore-only! "1-3"))
  (check-equal? (send r2 get-text) "older backup")
  (check-false (send r2 get-path)))

(test-case "a file already open (from the command line) is reused, not opened a second time"
  (clear-recovery!)
  (define p (doc-path 15))
  (define id (crash-with-edits! p #"disk text" " + recovered"))
  (define opened (open-file! p))                 ; as main.rkt does before recover-on-launch!
  (check-false (send opened is-modified?))
  (define r (restore-only! id))
  (check-eq? r opened "the recovered text went into the open document")
  (check-equal? (length (buffers-for p)) 1 "one document for the file")
  (check-equal? (send r get-text) "disk text + recovered")
  (check-true (send r is-modified?)))

(test-case "a snapshot with a wrong field type or a bad id is quarantined; the valid ones still restore"
  (clear-recovery!)
  (define before (send (messages-buffer) get-text))
  (write-raw-snapshot! "2-1" #f "untitled" 'text-mode 0 (current-seconds) 42 #f #f)       ; text = 42
  (write-raw-snapshot! "2-2" "relative/path" "x" 'text-mode 0 (current-seconds) "t" #f #f) ; relative path
  (with-output-to-file (build-path (recovery-dir) "2-3.rktd") #:exists 'truncate        ; id is a path
    (lambda () (write (make-prefab-struct 'snapshot "../../escape" #f "x" 'text-mode 0 0 "t" #f #f))))
  (write-raw-snapshot! "2-4" #f "untitled" 'no-such-language 0 (current-seconds) "the good one" #f #f)
  (define offered #f)
  (parameterize ([recovery-decide! (lambda (snaps) (set! offered (map snapshot-id snaps))
                                     (for/list ([s snaps]) (cons (snapshot-id s) 'restore)))])
    (recover-on-launch!))
  (check-equal? offered '("2-4"))
  (check-equal? (send (current-buffer) get-text) "the good one")
  (check-eq? (send (current-buffer) get-mode) 'text-mode "an unknown Language falls back")
  (for ([id '("2-1" "2-2" "2-3")])
    (check-false (file-exists? (build-path (recovery-dir) (format "~a.rktd" id))))
    (check-true (for/or ([f (directory-list (recovery-dir))])
                  (regexp-match? (regexp (format "^~a[.]rktd[.]corrupt-" id)) (path->string f)))
                (format "~a moved aside" id)))
  (check-regexp-match #rx"not a valid recovery snapshot" (activity-since before)))

(test-case "one snapshot that fails to restore is moved aside and reported; the others still restore"
  (clear-recovery!)
  (define p (doc-path 16))
  (define bad-id (crash-with-edits! p #"unreadable" " soon"))
  (define ok (new-buffer! "untitled"))
  (send ok insert "restore me anyway")
  (snapshot-buffer! ok)
  (define ok-id (buffer-recovery-id ok))
  (kill-buffer! ok)                       ; still modified: its snapshot stays
  (define before (send (messages-buffer) get-text))
  (dynamic-wind
   (lambda () (file-or-directory-permissions p #o000))   ; opening the file now raises
   (lambda ()
     (parameterize ([recovery-decide! (lambda (snaps) (for/list ([s snaps]) (cons (snapshot-id s) 'restore)))])
       (recover-on-launch!)))
   (lambda () (file-or-directory-permissions p #o644)))
  (check-not-false (findf (lambda (b) (equal? (send b get-text) "restore me anyway")) (all-buffers)))
  (check-false (snapshot-for bad-id) "the failing one is no longer offered")
  (check-true (for/or ([f (directory-list (recovery-dir))])
                (regexp-match? (regexp (format "^~a[.]rktd[.]corrupt-" bad-id)) (path->string f))))
  (check-regexp-match #rx"could not be restored" (activity-since before))
  (check-not-false (snapshot-for ok-id)))

(test-case "a second Rackmac leaves a running one's snapshots alone; once it has exited they are offered"
  (clear-recovery!)
  (define-values (sp o i e) (subprocess #f #f #f (string->path "/bin/sleep") "60"))  ; a live process
  (for ([port (list o i e)]) (if (input-port? port) (close-input-port port) (close-output-port port)))
  (define-values (done o2 i2 e2) (subprocess #f #f #f (string->path "/usr/bin/true")))
  (subprocess-wait done)                                                            ; an exited one
  (for ([port (list o2 i2 e2)]) (if (input-port? port) (close-input-port port) (close-output-port port)))
  (write-raw-snapshot! "3-1" #f "untitled" 'text-mode 0 (current-seconds) "live elsewhere" #f (subprocess-pid sp))
  (write-raw-snapshot! "3-2" #f "untitled" 'text-mode 0 (current-seconds) "owner crashed" #f (subprocess-pid done))
  (write-raw-snapshot! "3-3" #f "untitled" 'text-mode 0 (current-seconds) "ours" #f (getpid))
  (define (offered-ids)
    (define seen '())
    (parameterize ([recovery-decide! (lambda (snaps) (set! seen (sort (map snapshot-id snaps) string<?))
                                       (for/list ([s snaps]) (cons (snapshot-id s) 'discard)))])
      (recover-on-launch!))
    seen)
  (dynamic-wind
   void
   (lambda ()
     (check-equal? (offered-ids) '("3-2" "3-3") "the running process's snapshot is not offered")
     (check-not-false (snapshot-for "3-1") "and Discard on the others did not delete it"))
   (lambda () (subprocess-kill sp #t) (subprocess-wait sp)))
  (check-equal? (offered-ids) '("3-1") "its owner has exited: offered now")
  (check-false (snapshot-for "3-1")))
