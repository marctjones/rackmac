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
;; pattern; when it fires, a still-modified document's snapshot is (re)written.
(require racket/class racket/gui/base racket/file
         "hook.rkt" "settings.rkt" "platform.rkt" "fileio.rkt" "editor.rkt")
(provide (struct-out snapshot) recovery-dir list-snapshots delete-snapshot!
         enable-autosave-recovery! snapshot-buffer! forget-buffer-snapshot! buffer-recovery-id)

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
(struct snapshot (id path name mode cursor saved-at text) #:prefab)

(define (recovery-dir) (build-path (config-dir) "recovery"))
(define (snapshot-file-path id) (build-path (recovery-dir) (format "~a.rktd" id)))

(define id-counter 0)
(define (fresh-id!)
  (set! id-counter (add1 id-counter))
  (format "~a-~a" (current-milliseconds) id-counter))

;; A document keeps the same recovery id for its whole life (a weak table: a closed document's
;; id does not keep it alive), so repeated autosaves overwrite one file instead of piling up.
(define ids (make-weak-hasheq))
(define (buffer-recovery-id b) (hash-ref ids b #f))
(define (ensure-recovery-id! b) (or (hash-ref ids b #f) (let ([id (fresh-id!)]) (hash-set! ids b id) id)))

(define (write-snapshot! s)
  (make-directory* (recovery-dir))
  (define out (open-output-bytes))
  (write s out)
  (safe-write-bytes! (snapshot-file-path (snapshot-id s)) (get-output-bytes out)))

(define (delete-snapshot! id)
  (define p (snapshot-file-path id))
  (when (file-exists? p)
    (with-handlers ([exn:fail? (lambda (e) (report-error! 'recovery e))]) (delete-file p))))

;; #f (after quarantining the file, in the spirit of store.rkt's corruption handling) when `p`
;; is not a readable snapshot -- a half-written or hand-edited file must never crash startup.
(define (read-snapshot p)
  (define v (with-handlers ([exn:fail? (lambda (e) e)]) (call-with-input-file p read)))
  (cond
    [(snapshot? v) v]
    [else
     (define aside (string->path (format "~a.corrupt-~a" (path->string p) (current-seconds))))
     (with-handlers ([exn:fail? void]) (rename-file-or-directory p aside #t))
     (report-error! 'recovery (format "~a: not a valid recovery snapshot; moved aside to ~a"
                                      (path->string p) (path->string aside)))
     #f]))

(define (list-snapshots)
  (cond
    [(directory-exists? (recovery-dir))
     (filter values
             (for/list ([p (in-list (directory-list (recovery-dir) #:build? #t))]
                        #:when (regexp-match? #rx"[.]rktd$" (path->string p)))
               (read-snapshot p)))]
    [else '()]))

;; ---- writing snapshots for live documents -----------------------------------------------

(define (snapshot-buffer! b)
  (write-snapshot!
   (snapshot (ensure-recovery-id! b)
             (and (send b get-path) (path->string (send b get-path)))
             (send b get-name) (send b get-mode)
             (send b get-start-position) (current-seconds) (send b get-text))))

(define (forget-buffer-snapshot! b)
  (define id (buffer-recovery-id b))
  (when id (delete-snapshot! id)))

;; ---- autosave timer (#75): debounced, only while modified ---------------------------------

(define timers (make-weak-hasheq))  ; document -> timer%, mirrors buffer.rkt's highlight-timer

(define (do-autosave! b)
  (when (and (setting-ref 'autosave-interval) (send b is-modified?)) (snapshot-buffer! b)))

;; Restarted on every edit (racket/gui's timer% start replaces a pending one-shot), so a burst
;; of keystrokes writes one snapshot after things go quiet, not one per keystroke.
(define (schedule-autosave! b)
  (define secs (setting-ref 'autosave-interval))
  (when secs
    (define t (or (hash-ref timers b #f)
                  (let ([t (new timer% [notify-callback (lambda () (do-autosave! b))])])
                    (hash-set! timers b t) t)))
    (send t start (inexact->exact (round (* secs 1000))) #t)))

(define (on-text-changed b) (schedule-autosave! b))

(define (enable-autosave-recovery!) (add-hook! 'text-changed on-text-changed))
