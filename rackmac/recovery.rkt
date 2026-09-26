#lang racket/base
;; Recovery store (#74): a snapshot of every modified document's text plus enough metadata to
;; reopen it (original path or its display name, the time, its Language and its cursor), kept
;; under <config dir>/recovery/ -- never next to the user's own files, so a folder synced by
;; iCloud/Dropbox never picks it up (docs/REPLAN.md S3, "the recovery store lives in the
;; config dir"). Written atomically (temp file, then rename, via fileio.rkt's
;; safe-write-bytes!, the same mechanism a real Save uses).
;;
;; An autosave timer (#75) debounces per document: each edit restarts a one-shot timer at the
;; `autosave-interval` setting (off when #f), matching buffer.rkt's own highlight-timer
;; pattern; when it fires, a still-modified document's snapshot is (re)written. Saving, or
;; closing a document that is no longer modified, deletes its snapshot (#76); closing WITHOUT
;; saving (Don't Save) leaves the snapshot in place -- that unsaved text is exactly what
;; recovery exists for.
;;
;; On launch (#77), any snapshots left behind (a crash, `kill -9`, or a previous Don't Save)
;; are offered back through `recover-on-launch!`, which asks `recovery-decide!` (a parameter,
;; like commands.rkt's confirm-* dialogs) what to do with each one, so tests and scripts can
;; answer without the real window.
(require racket/class racket/gui/base racket/path racket/file racket/os racket/list racket/port racket/system
         "hook.rkt" "settings.rkt" "platform.rkt" "fileio.rkt" "editor.rkt" "mode.rkt")
(provide (struct-out snapshot) recovery-dir list-snapshots delete-snapshot!
         recovery-decide! recover-on-launch! enable-autosave-recovery!
         snapshot-buffer! autosave-buffer! forget-buffer-snapshot! buffer-recovery-id)

(define-setting autosave-interval
  #:contract (lambda (v) (or (not v) (and (real? v) (positive? v))))
  #:default 30
  #:doc "How often Rackmac saves an automatic backup of a document's unsaved changes, in seconds. Off (#f) turns autosave off."
  #:category "Files")

;; ---- the store on disk -----------------------------------------------------------------

;; path/name/mode/cursor mirror a document's identity closely enough to reopen it: `path` is
;; #f for a document that has never been saved (an "untitled" tab); `name` is always set, so
;; an untitled document still has something to show in the recovery list. `#:prefab` so `write`
;; and `read` round-trip it directly, with no custom (de)serializer to keep in sync.
;;
;; `file-mtime` is the file's modify-seconds when the snapshot was taken (#f when there was no
;; file on disk yet), so a restore can tell whether the file was changed elsewhere since and
;; must not be overwritten by Save. `owner` is the process id of the Rackmac that wrote it, so
;; a second running Rackmac never offers (or discards) the first one's live backups.
;; Snapshots written before these two fields existed have 7 fields; read-snapshot upgrades them
;; with file-mtime 'unknown and owner #f (see stale-reason for what 'unknown means).
(struct snapshot (id path name mode cursor saved-at text file-mtime owner) #:prefab)

(define (recovery-dir) (build-path (config-dir) "recovery"))
(define (snapshot-file-path id) (build-path (recovery-dir) (format "~a.rktd" id)))

(define id-counter 0)
(define (fresh-id!)
  (set! id-counter (add1 id-counter))
  (format "~a-~a" (current-milliseconds) id-counter))

;; A document keeps the same recovery id for its whole life (a weak table: a closed document's
;; id does not keep it alive), so repeated autosaves overwrite one file instead of piling up.
(define ids (make-weak-hasheq))
;; A document has an id only once a snapshot of it has actually been written, so the id is
;; also the proof that a backup exists on disk (recovery-worker.rkt waits on it).
(define (buffer-recovery-id b) (hash-ref ids b #f))

;; Snapshots hold whatever the user typed, so the store is private to them: the folder is 0700
;; and each file 0600, whatever the umask. A folder that already exists only ever loses
;; group/other bits here, never gains any.
(define (ensure-recovery-dir!)
  (define d (recovery-dir))
  (unless (directory-exists? d) (make-directory* d))
  (define bits (file-or-directory-permissions d 'bits))
  (unless (zero? (bitwise-and bits #o077))
    (file-or-directory-permissions d (bitwise-and bits #o700))))

(define (write-snapshot! s)
  (ensure-recovery-dir!)
  (define out (open-output-bytes))
  (write s out)
  (safe-write-bytes! (snapshot-file-path (snapshot-id s)) (get-output-bytes out) #:permissions #o600))

(define (delete-snapshot! id)
  (define p (snapshot-file-path id))
  (when (file-exists? p)
    (with-handlers ([exn:fail? (lambda (e) (report-error! 'recovery e))]) (delete-file p))))

;; Moves a snapshot file aside (never deletes it: it may still hold text worth digging out by
;; hand) and says so in the Activity log.
(define (quarantine! p why)
  (define aside (string->path (format "~a.corrupt-~a" (path->string p) (current-seconds))))
  (with-handlers ([exn:fail? void]) (rename-file-or-directory p aside #t))
  (report-error! 'recovery (format "~a: ~a; moved aside to ~a" (path->string p) why (path->string aside))))

;; The id names the snapshot's own file (delete-snapshot! builds a path from it), so it must be
;; exactly that file's name: never a path of its own.
(define (valid-snapshot-fields? p id path name mode cursor saved-at text file-mtime owner)
  (and (string? id) (regexp-match? #px"^[A-Za-z0-9_-]+$" id)
       (equal? (path->string (file-name-from-path p)) (format "~a.rktd" id))
       (or (not path) (and (string? path) (absolute-path? path)))
       (string? name) (symbol? mode) (exact-nonnegative-integer? cursor) (real? saved-at)
       (string? text)
       (or (not file-mtime) (eq? file-mtime 'unknown) (exact-integer? file-mtime))
       (or (not owner) (exact-positive-integer? owner))))

;; A snapshot read from `p`, or #f (after quarantining the file, in the spirit of store.rkt's
;; corruption handling) when it is not a readable snapshot with fields of the right types -- a
;; half-written or hand-edited file must never crash startup.
(define (read-snapshot p)
  (define v (with-handlers ([exn:fail? (lambda (e) e)]) (call-with-input-file p read)))
  (define fields (and (eq? (prefab-struct-key v) 'snapshot) (cdr (vector->list (struct->vector v)))))
  (define all-fields
    (and fields (case (length fields)
                  [(9) fields]
                  [(7) (append fields (list 'unknown #f))]   ; written before file-mtime/owner
                  [else #f])))
  (cond
    [(and all-fields (apply valid-snapshot-fields? p all-fields)) (apply snapshot all-fields)]
    [else (quarantine! p "not a valid recovery snapshot") #f]))

;; Quarantined files are kept for a while in case someone wants to dig text out of them by
;; hand, then removed, so the private store does not grow forever. The age comes from the
;; seconds in the name (when it was moved aside), not the file's own time.
(define corrupt-keep-seconds (* 30 24 60 60))
(define (prune-corrupt-files!)
  (define cutoff (- (current-seconds) corrupt-keep-seconds))
  (for ([p (in-list (directory-list (recovery-dir) #:build? #t))])
    (define m (regexp-match #rx"[.]corrupt-([0-9]+)$" (path->string p)))
    (when (and m (< (string->number (cadr m)) cutoff))
      (with-handlers ([exn:fail? (lambda (e) (report-error! 'recovery e))]) (delete-file p)))))

(define (list-snapshots)
  (cond
    [(directory-exists? (recovery-dir))
     (prune-corrupt-files!)
     (filter values
             (for/list ([p (in-list (directory-list (recovery-dir) #:build? #t))]
                        #:when (regexp-match? #rx"[.]rktd$" (path->string p)))
               (read-snapshot p)))]
    [else '()]))

;; ---- writing snapshots for live documents -----------------------------------------------

;; Raises if the write fails, leaving the document without an id (or with its old one, whose
;; file still holds the previous snapshot).
(define (snapshot-buffer! b)
  (define id (or (buffer-recovery-id b) (fresh-id!)))
  (define p (send b get-path))
  (write-snapshot!
   (snapshot id (and p (path->string p)) (send b get-name) (send b get-mode)
             (send b get-start-position) (current-seconds) (send b get-text)
             (and p (file-seconds p)) (getpid)))
  (hash-set! ids b id))

;; #f when there is no file at `p`.
(define (file-seconds p)
  (with-handlers ([exn:fail:filesystem? (lambda (e) #f)])
    (and (file-exists? p) (file-or-directory-modify-seconds p))))

(define (forget-buffer-snapshot! b)
  (define id (buffer-recovery-id b))
  (when id (delete-snapshot! id)))

;; ---- autosave timer (#75): debounced, only while modified ---------------------------------

(define timers (make-weak-hasheq))  ; document -> timer%, mirrors buffer.rkt's highlight-timer

;; A failed autosave (full disk, unwritable folder) goes to the Activity log once, not every
;; tick; after a write succeeds again, the next failure is reported afresh.
(define failure-reported? #f)
(define (autosave-buffer! b)
  (when (and (setting-ref 'autosave-interval) (send b is-modified?))
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (unless failure-reported?
                         (set! failure-reported? #t)
                         (report-error! 'autosave
                                        (format "Could not save an automatic backup of ~a: ~a"
                                                (send b get-name) (exn-message e)))))])
      (snapshot-buffer! b)
      (set! failure-reported? #f))))

;; Restarted on every edit (racket/gui's timer% start replaces a pending one-shot), so a burst
;; of keystrokes writes one snapshot after things go quiet, not one per keystroke.
(define (schedule-autosave! b)
  (define secs (setting-ref 'autosave-interval))
  (when secs
    (define t (or (hash-ref timers b #f)
                  (let ([t (new timer% [notify-callback (lambda () (autosave-buffer! b))])])
                    (hash-set! timers b t) t)))
    (send t start (inexact->exact (round (* secs 1000))) #t)))

;; ---- save/close (#76) ----------------------------------------------------------------------

(define (on-text-changed b) (schedule-autosave! b))
(define (on-after-save b) (forget-buffer-snapshot! b))
;; Don't Save (on close or on quit) announces 'changes-discarded, and the snapshot goes with the
;; changes, as in Word and Pages. A document closed while still modified without that answer
;; (never through the UI today) keeps its snapshot, the safe default.
(define (on-before-close b) (unless (send b is-modified?) (forget-buffer-snapshot! b)))
(define (on-changes-discarded b) (forget-buffer-snapshot! b))

(define (enable-autosave-recovery!)
  (add-hook! 'text-changed on-text-changed)
  (add-hook! 'after-save on-after-save)
  (add-hook! 'before-close-buffer on-before-close)
  (add-hook! 'changes-discarded on-changes-discarded))

;; ---- restore on launch (#77) ----------------------------------------------------------------

(define (snapshot-display-name s)
  (or (and (snapshot-path s) (path->string (file-name-from-path (string->path (snapshot-path s)))))
      (snapshot-name s)))

;; A Language this Rackmac no longer has (an extension since removed) falls back to the one
;; the file name suggests.
(define (snapshot-language s)
  (define m (snapshot-mode s))
  (cond [(find-mode m) m]
        [(snapshot-path s) (or (mode-for-path (string->path (snapshot-path s))) 'text-mode)]
        [else 'text-mode]))

;; Why the snapshot's file must not be written over by Save any more, or #f when it is safe to
;; keep the path. For a snapshot from before file-mtime existed ('unknown) the only clue is the
;; backup's own time: a file modified after that was certainly changed elsewhere; one that is
;; gone cannot be told apart from one that was moved or deleted on purpose, so both detach.
(define (stale-reason s p)
  (define now (file-seconds p))
  (define then (snapshot-file-mtime s))
  (cond
    [(not now) (and then "its file has been moved or deleted since")]
    [(not then) "a file with its name was created since"]
    [(eq? then 'unknown) (and (> now (snapshot-saved-at s)) "its file was changed since")]
    [(= now then) #f]
    [else "its file was changed since"]))

;; Puts the snapshot's text back. With a trustworthy file, the document is (re)opened from it
;; first -- or reused, if the file was already opened from the command line -- so its encoding
;; and line endings come from the file and Save writes them back unchanged; then the text is
;; replaced by the backup's. Otherwise the text goes into a new document with no file, so Save
;; asks where to put it instead of silently overwriting someone else's changes.
(define (restore-snapshot! s)
  (define p (and (snapshot-path s) (string->path (snapshot-path s))))
  (define open (and p (find-buffer-by-path p)))
  (define why (and p (or (stale-reason s p)
                         (and open (send open is-modified?) "it is already open with other unsaved changes"))))
  (define b (if (and p (not why))
                (open-file! p)
                (new-buffer! (snapshot-display-name s) #:mode (snapshot-language s))))
  (unless (eq? (send b get-mode) (snapshot-language s)) (send b set-mode! (snapshot-language s)))
  (hash-set! ids b (snapshot-id s))          ; keep autosaving to the file it came from
  (send b begin-edit-sequence)
  (send b erase)
  (send b insert (snapshot-text s))
  (send b end-edit-sequence)
  (send b set-position (min (snapshot-cursor s) (send b last-position)))
  (send b set-modified #t)
  (set-current-buffer! b)
  (if why
      (message "Restored ~a from an automatic backup as a document with no file, because ~a. Use Save As to keep it."
               (send b get-name) why)
      (message "Restored ~a from an automatic backup." (send b get-name))))

;; A real dialog: one row per recovered document, a checkbox defaulting to Restore, one OK
;; button that applies every row's current choice.
(define (recovery-dialog snaps)
  (define decisions (make-hash (for/list ([s (in-list snaps)]) (cons (snapshot-id s) 'restore))))
  (define dlg (new dialog% [label "Recover Documents"] [parent (ui-parent)] [width 460]))
  (new message% [parent dlg]
       [label (if (= (length snaps) 1)
                 "Rackmac closed before this document was saved:"
                 "Rackmac closed before these documents were saved:")])
  (for ([s (in-list snaps)])
    (define row (new horizontal-panel% [parent dlg] [alignment '(left center)] [stretchable-height #f]))
    (new message% [parent row]
         [label (format "~a — ~a" (snapshot-display-name s) (mode-display-name (snapshot-language s)))])
    (new check-box% [parent row] [label "Restore"] [value #t]
         [callback (lambda (cb e) (hash-set! decisions (snapshot-id s) (if (send cb get-value) 'restore 'discard)))]))
  (define buttons (new horizontal-panel% [parent dlg] [alignment '(right center)] [stretchable-height #f]))
  (new button% [parent buttons] [label "OK"] [callback (lambda (b e) (send dlg show #f))])
  (send dlg show #t)
  (hash-map decisions cons))

;; "Restore or Discard each" (#77's acceptance criterion), as a parameter so tests and scripts
;; can answer without the real dialog -- (listof snapshot) -> (listof (cons id 'restore/'discard)).
(define recovery-decide! (make-parameter recovery-dialog))

;; #t when process `pid` exists. macOS/Linux: `kill -0` (sends nothing, only checks). Where
;; that cannot be run (Windows, deferred) the answer is #f, so snapshots are still offered as
;; before: skipping them there would turn recovery off entirely. A pid reused by an unrelated
;; process after a reboot makes a snapshot wait (hidden, not deleted) until that process ends.
(define kill-program
  (for/or ([p (list "/bin/kill" "/usr/bin/kill")]) (and (file-exists? p) p)))
(define (process-running? pid)
  (and kill-program
       (with-handlers ([exn:fail? (lambda (e) #f)])
         (parameterize ([current-output-port (open-output-nowhere)]
                        [current-error-port (open-output-nowhere)])
           (system* kill-program "-0" (number->string pid))))))

;; A snapshot another Rackmac is still keeping up to date: not ours to offer, nor to discard.
(define (owned-by-running-instance? s)
  (define owner (snapshot-owner s))
  (and owner (not (= owner (getpid))) (process-running? owner)))

(define (recover-on-launch!)
  (define-values (live snaps) (partition owned-by-running-instance? (list-snapshots)))
  (when (pair? live)
    (log-message "Left ~a automatic backup~a alone: ~a to another copy of Rackmac that is still running."
                 (length live) (if (= (length live) 1) "" "s") (if (= (length live) 1) "it belongs" "they belong")))
  (when (pair? snaps)
    (define decisions ((recovery-decide!) snaps))
    ;; One snapshot that cannot be restored is moved aside and reported; the rest still are.
    (for ([s (in-list snaps)])
      (with-handlers ([exn:fail? (lambda (e)
                                   (quarantine! (snapshot-file-path (snapshot-id s))
                                                (format "could not be restored (~a)" (exn-message e))))])
        (case (cond [(assoc (snapshot-id s) decisions) => cdr] [else 'discard])
          [(restore) (restore-snapshot! s)]
          [(discard) (delete-snapshot! (snapshot-id s))])))))
