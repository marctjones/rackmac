#lang racket/base
;; The recent-files store ("recent-files" #274): one entry per document that has been opened,
;; saved or closed, capped at 50, most-recently-touched first. Persisted to recents.rktd (via
;; rackmac/store.rkt, the same get-preference/put-preferences pattern as settings.rktd) so it
;; survives a restart. Feeds the sidebar's Recent section (v0.3 lib-sidebar), the start screen,
;; and File > Open Recent (#275, in rackmac/library/open-recent.rkt).
;;
;; Pure data plus hook wiring: no menu/UI code lives here. Tracking is off until
;; `enable-recent-tracking!` is called (app.rkt does this at startup) so merely requiring this
;; module -- as every test that exercises it must -- never touches the real user's disk.
(require racket/class racket/list racket/path
         "../hook.rkt" "../platform.rkt" "../store.rkt")
(provide (struct-out recent-entry) recent-entry-name
         recent-files-cap recents-file-path
         recent-entries find-recent reload-recents!
         record-recent-open! record-recent-save! record-recent-close! set-recent-view!
         clear-recent-files! enable-recent-tracking!)

(define recent-files-cap 50)

;; path: an absolute path, as a string (plain data -- see the datum note below). last-opened:
;; (current-seconds). cursor: a caret offset, 0 if unknown. view: #f or a symbol
;; ('source/'formatted); room for #269's per-document Markdown view memory
;; (docs/UI-DESIGN.md S2.2.1) -- nothing here sets it yet.
(struct recent-entry (path last-opened cursor view) #:transparent)

(define (recent-entry-name e) (path->string (file-name-from-path (recent-entry-path e))))

(define (recents-file-path) (build-path (config-dir) "recents.rktd"))

;; Entries are written to disk as plain 4-element lists, not struct instances: put-preferences
;; writes under `with-pref-params`, which binds Racket's old `print-struct` parameter to #f --
;; that forces even a #:prefab struct to print as the opaque, unreadable `#<recent-entry>`
;; (verified against racket/file.rkt; nothing about #:prefab or #:transparent avoids it, since
;; print-struct pre-dates both). Converting to/from plain data at the store boundary sidesteps
;; the whole question.
(define (entry->datum e) (list (recent-entry-path e) (recent-entry-last-opened e) (recent-entry-cursor e) (recent-entry-view e)))
(define (valid-datum? d) (and (list? d) (= (length d) 4) (string? (car d)) (exact-integer? (cadr d)) (exact-integer? (caddr d))))
(define (datum->entry d) (apply recent-entry d))

(define entries #f)          ; #f until loaded; a list of recent-entry after that
(define (ensure-loaded!)
  (unless entries
    (define v (store-ref (recents-file-path) 'recents '()))
    (set! entries (if (and (list? v) (andmap valid-datum? v)) (map datum->entry v) '()))))

;; Drops the in-memory cache, so the next access re-reads recents.rktd -- used to prove
;; persistence (a real disk round trip) and by anything that suspects another process wrote
;; the file (there is no such writer yet in v0.3, but it costs nothing to allow for one).
(define (reload-recents!) (set! entries #f))

(define (take-up-to l n) (if (> (length l) n) (take l n) l))
(define (normalize path) (path->string (simplify-path (path->complete-path path))))
(define (save!) (store-set! (recents-file-path) 'recents (map entry->datum entries)))

;; Up to `n` entries (all of them if `n` is #f), most-recently-touched first.
(define (recent-entries [n #f])
  (ensure-loaded!)
  (if n (take-up-to entries n) entries))

(define (find-recent path)
  (ensure-loaded!)
  (define p (normalize path))
  (findf (lambda (e) (equal? (recent-entry-path e) p)) entries))

;; Moves `path` to the front with a fresh last-opened, preserving its `view` if it had one.
;; Used for open and save, which is why both bring a file to the top of Recent (as in
;; Chrome/Word), and adds a new entry if this path has never been seen. `cursor` #f means
;; "leave the cursor as it was" (opening a file should not throw away the position a previous
;; session's close recorded, even though the freshly loaded document's own caret starts at 0);
;; a real save/close position is always given explicitly.
(define (touch! path #:cursor [cursor #f])
  (ensure-loaded!)
  (define p (normalize path))
  (define old (find-recent p))
  (define c (or cursor (and old (recent-entry-cursor old)) 0))
  (define e (recent-entry p (current-seconds) c (and old (recent-entry-view old))))
  (set! entries (take-up-to (cons e (filter (lambda (x) (not (equal? (recent-entry-path x) p))) entries))
                            recent-files-cap))
  (save!))

;; Updates only the cursor of an existing entry, without reordering or bumping last-opened --
;; used when a document closes, so glancing at a file and closing it again does not move it to
;; the top of Recent. A no-op if the path has no entry (nothing to update).
(define (update-cursor-only! path cursor)
  (ensure-loaded!)
  (define p (normalize path))
  (when (find-recent p)
    (set! entries (for/list ([e (in-list entries)])
                    (if (equal? (recent-entry-path e) p) (struct-copy recent-entry e [cursor cursor]) e)))
    (save!)))

;; `cursor` is optional on open (default #f: keep whatever was recorded before, e.g. by a
;; previous close) but required on save, where the current position is always known and real.
(define (record-recent-open! path [cursor #f]) (touch! path #:cursor cursor))
(define (record-recent-save! path cursor) (touch! path #:cursor cursor))
(define (record-recent-close! path cursor) (update-cursor-only! path cursor))

(define (set-recent-view! path view)
  (ensure-loaded!)
  (define p (normalize path))
  (when (find-recent p)
    (set! entries (for/list ([e (in-list entries)])
                    (if (equal? (recent-entry-path e) p) (struct-copy recent-entry e [view view]) e)))
    (save!)))

(define (clear-recent-files!)
  (ensure-loaded!)
  (set! entries '())
  (save!))

;; ---- hooks -----------------------------------------------------------------------------
;; Named procedures (not fresh lambdas) so add-hook!'s own de-duplication makes this idempotent;
;; called from app.rkt at startup, never at load time, so requiring this module for tests never
;; wires anything until a test asks for it.

;; No cursor is passed here: a just-loaded document's caret is always 0 (load-path! puts it
;; there), which is not the position worth remembering -- keeping whatever a previous close
;; recorded is (record-recent-open!'s own #:cursor #f default). Guarded by file-exists? so
;; opening a path that is not on disk yet (e.g. a new file named from the command line) is not
;; listed as something Open Recent can actually open.
(define (on-file-opened b) (when (and (send b get-path) (file-exists? (send b get-path))) (record-recent-open! (send b get-path))))
(define (on-file-saved b) (when (send b get-path) (record-recent-save! (send b get-path) (send b get-start-position))))
(define (on-buffer-closing b) (when (send b get-path) (record-recent-close! (send b get-path) (send b get-start-position))))

(define (enable-recent-tracking!)
  (add-hook! 'after-open-file on-file-opened)
  (add-hook! 'after-save on-file-saved)
  (add-hook! 'before-close-buffer on-buffer-closing))
