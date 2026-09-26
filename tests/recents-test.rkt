#lang racket/base
;; The recent-files store (#274): touch on open/save moves an entry to the front, close only
;; updates its cursor, the store caps at 50, persists across a simulated restart, and stays
;; inert (no disk access) until enable-recent-tracking! is called -- which is what app.rkt
;; does at startup, and what the end-to-end group below does explicitly.
(require "no-front.rkt")   ; first: GUI tests must never take keyboard focus
(require rackunit racket/file racket/list racket/path racket/class
         "../rackmac/library/recents.rkt" "../rackmac/platform.rkt"
         "../rackmac/editor.rkt" "../rackmac/hook.rkt")

(define dir (make-temporary-file "rackmac-recents~a" 'directory))
(void (putenv "RACKMAC_HOME" (path->string dir)))

(define (fake n) (path->string (build-path dir (format "fake-~a.md" n))))
(define (normalized p) (path->string (simplify-path (path->complete-path p))))

;; ---- the store, driven directly -----------------------------------------------------

(test-case "opening a file adds it, most-recent first"
  (clear-recent-files!)
  (record-recent-open! (fake 1) 0)
  (record-recent-open! (fake 2) 0)
  (check-equal? (map recent-entry-path (recent-entries)) (list (fake 2) (fake 1))))

(test-case "touching an existing path moves it to the front instead of duplicating it"
  (clear-recent-files!)
  (record-recent-open! (fake 1) 0)
  (record-recent-open! (fake 2) 0)
  (record-recent-save! (fake 1) 5)
  (check-equal? (map recent-entry-path (recent-entries)) (list (fake 1) (fake 2)))
  (check-equal? (recent-entry-cursor (find-recent (fake 1))) 5))

(test-case "closing a document updates its cursor without reordering or duplicating"
  (clear-recent-files!)
  (record-recent-open! (fake 1) 0)
  (record-recent-open! (fake 2) 0)
  (record-recent-close! (fake 1) 42)
  (check-equal? (map recent-entry-path (recent-entries)) (list (fake 2) (fake 1)) "no reorder")
  (check-equal? (recent-entry-cursor (find-recent (fake 1))) 42))

(test-case "closing a path with no recent entry is a no-op"
  (clear-recent-files!)
  (record-recent-close! (fake 99) 3)
  (check-equal? (recent-entries) '()))

(test-case "reopening a file keeps the cursor a previous close recorded"
  (clear-recent-files!)
  (record-recent-open! (fake 1) 0)
  (record-recent-close! (fake 1) 42)
  (record-recent-open! (fake 1))                 ; no cursor given: opening must not reset it
  (check-equal? (recent-entry-cursor (find-recent (fake 1))) 42)
  (check-equal? (map recent-entry-path (recent-entries)) (list (fake 1)) "still just the one entry"))

(test-case "the view field defaults to #f and is remembered separately from the cursor"
  (clear-recent-files!)
  (record-recent-open! (fake 1) 0)
  (check-false (recent-entry-view (find-recent (fake 1))))
  (set-recent-view! (fake 1) 'source)
  (record-recent-save! (fake 1) 10)               ; a later touch keeps the view
  (check-eq? (recent-entry-view (find-recent (fake 1))) 'source)
  (check-equal? (recent-entry-cursor (find-recent (fake 1))) 10))

(test-case "the store caps at 50, dropping the oldest"
  (clear-recent-files!)
  (for ([i (in-range 55)]) (record-recent-open! (fake i) 0))
  (define es (recent-entries))
  (check-equal? (length es) 50)
  (check-equal? (recent-entry-path (car es)) (fake 54) "most recent first")
  (check-false (find-recent (fake 0)) "the oldest five were dropped"))

(test-case "recent-entries with a limit returns only the first n"
  (clear-recent-files!)
  (for ([i (in-range 5)]) (record-recent-open! (fake i) 0))
  (check-equal? (length (recent-entries 2)) 2)
  (check-equal? (map recent-entry-path (recent-entries 2)) (list (fake 4) (fake 3))))

(test-case "clear empties the store"
  (record-recent-open! (fake 1) 0)
  (clear-recent-files!)
  (check-equal? (recent-entries) '()))

;; ---- persistence: a real disk round trip (#271's put-preferences/get-preference pattern) ---

(test-case "recents survive a simulated restart: written to recents.rktd and read back"
  (clear-recent-files!)
  (record-recent-open! (fake 1) 3)
  (record-recent-open! (fake 2) 7)
  (set-recent-view! (fake 2) 'source)
  (check-true (file-exists? (recents-file-path)))
  (reload-recents!)                              ; drop the in-memory cache: force a real read
  (check-equal? (map recent-entry-path (recent-entries)) (list (fake 2) (fake 1))
                "order survived the round trip through write and read")
  (check-equal? (recent-entry-cursor (find-recent (fake 1))) 3)
  (check-eq? (recent-entry-view (find-recent (fake 2))) 'source))

;; ---- end-to-end: the real hooks (enable-recent-tracking!) -----------------------------

(enable-recent-tracking!)

(test-case "opening and saving through the real editor records recents; closing updates the cursor"
  (clear-recent-files!)
  (define p (build-path dir "e2e.md"))
  (display-to-file "hello" p #:exists 'truncate)
  (define b (open-file! p))
  (set-current-buffer! b)
  (check-equal? (map recent-entry-path (recent-entries)) (list (normalized p)))
  (send b insert " world")
  (send b set-position 3)
  (send b save-to! p)
  (check-equal? (recent-entry-cursor (find-recent (normalized p))) 3)
  (send b set-position 7)
  (kill-buffer! b)
  (check-equal? (recent-entry-cursor (find-recent (normalized p))) 7)
  (check-equal? (map recent-entry-path (recent-entries)) (list (normalized p)) "still just the one entry"))

(test-case "reopening through the real editor after closing keeps the recorded cursor"
  (clear-recent-files!)
  (define p (build-path dir "e2e-reopen.md"))
  (display-to-file "hello world" p #:exists 'truncate)
  (define b1 (open-file! p))
  (set-current-buffer! b1)
  (send b1 set-position 5)
  (kill-buffer! b1)
  (check-equal? (recent-entry-cursor (find-recent (normalized p))) 5)
  (define b2 (open-file! p))                     ; a fresh buffer% (the old one is gone); its
  (set-current-buffer! b2)                        ; own caret starts at 0, but the store must not
  (check-equal? (recent-entry-cursor (find-recent (normalized p))) 5 "not reset to 0 on reopen"))

(test-case "opening a path that is not on disk yet is not recorded"
  (clear-recent-files!)
  (define missing (build-path dir "does-not-exist-yet.md"))
  (define b (open-file! missing))
  (set-current-buffer! b)
  (check-false (find-recent (path->string missing))))
