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
