#lang racket/base
;; A corruption-safe wrapper around racket/file's get-preference/put-preferences ("settings-
;; store" #271): settings.rktd and recents.rktd are each a plain preference file, one entry
;; per name (docs/REPLAN.md S6: "Zero code to write; human-readable"). put-preferences already
;; writes atomically (temp file + rename, under a lock file); this module adds the one thing it
;; doesn't do -- a file that isn't readable as a preferences file is renamed aside and reported
;; through the Activity log (report-error!, hook.rkt), instead of silently reading as empty
;; (which is all get-preference itself does: it swallows a read error into the Racket logger,
;; never into ours) or being silently overwritten on the next save.
(require racket/file "hook.rkt")
(provide store-ref store-set!)

(define (well-formed-prefs? v)
  (and (list? v) (andmap (lambda (x) (and (list? x) (= (length x) 2) (symbol? (car x)))) v)))

;; #t (and moves `path` aside) when it exists but is not a valid preferences file: unreadable,
;; or readable but the wrong shape. Read once with plain `read`, matching how get-preference
;; and put-preferences read the file internally, so what passes here is what they will accept.
(define (quarantine-if-corrupt! path)
  (when (file-exists? path)
    (define reason
      (with-handlers ([exn:fail? (lambda (e) (format "could not be read: ~a" (exn-message e)))])
        (define v (call-with-input-file path read))
        (and (not (well-formed-prefs? v)) "was not a valid preferences file")))
    (when reason
      (define aside (string->path (format "~a.corrupt-~a" (path->string path) (current-seconds))))
      (with-handlers ([exn:fail? void]) (rename-file-or-directory path aside #t))
      (report-error! (path->string path) (format "~a; moved aside to ~a" reason (path->string aside))))))

;; The value stored for `name` in the preferences file at `path`, or `default` if the file or
;; the entry is missing (or was just quarantined as corrupt). `#t` for refresh-cache? because
;; get-preference's cache keys on file-modify-seconds, which is too coarse to trust across
;; back-to-back writes in the same second.
(define (store-ref path name default)
  (quarantine-if-corrupt! path)
  (with-handlers ([exn:fail? (lambda (e) (report-error! (path->string path) e) default)])
    (get-preference name (lambda () default) #t path)))

;; Merges name -> val into the preferences file at `path` (put-preferences keeps every other
;; name already there). Never raises: a lock held by another process, a permissions error, or
;; anything else from the filesystem is reported instead.
(define (store-set! path name val)
  (quarantine-if-corrupt! path)
  (with-handlers ([exn:fail? (lambda (e) (report-error! (path->string path) e))])
    (put-preferences (list name) (list val) #f path)
    (void)))
