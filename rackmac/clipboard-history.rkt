#lang racket/base
;; Clipboard history (#118, docs/REPLAN.md E7.M1 "Kill ring" -- called clipboard history
;; everywhere in this codebase, per docs/DEVELOPMENT.md's rule against Emacs vocabulary in the
;; default product): every Copy and Cut, across all open documents, is recorded here so #119's
;; Cmd+Shift+V picker has more than the single system clipboard slot to offer, and #120 can add
;; a setting to persist it. Memory-only for now -- nothing here touches disk.
;;
;; Capture point: buffer.rkt's `copy` override (the one place both Copy and Cut end up, since
;; text%'s built-in `cut` calls that overridden `copy` before deleting the selection) runs the
;; `text-copied` hook with the exact text it just put on the system clipboard. That is the only
;; change to existing behavior -- one line there, none in commands.rkt -- so Copy/Cut still work
;; exactly as before and this module just listens in, like recents.rkt listens to
;; `after-open-file`/`after-save`/`before-close-buffer`.
;;
;; Pure data plus hook wiring: requiring this module does nothing until `enable-clipboard-history!`
;; is called (app.rkt does this at startup), so tests that only want the data structure never
;; wire the real hook.
(require racket/list "hook.rkt" "settings.rkt")
(provide (struct-out clip-entry)
         clipboard-history-entries clipboard-history-ref clipboard-history-count
         record-clipboard-text! clear-clipboard-history! enable-clipboard-history!)

;; A size limit is the one acceptance criterion #118 has; 30 is a plain, memorable middle of the
;; "20-50" range a clipboard manager typically offers, configurable like every other numeric knob
;; in this codebase (`autosave-interval`, `recent-files-cap` is a plain constant but this one is
;; user-facing enough -- a picker showing "30 most recent" -- to be worth a setting).
(define-setting clipboard-history-limit
  #:contract (lambda (v) (and (exact-integer? v) (positive? v)))
  #:default 30
  #:doc "How many recent copies and cuts Rackmac remembers. Oldest entries drop off past this count."
  #:category "Editing")

;; text: the plain string that was copied or cut (never styled data -- buffer.rkt's copy already
;; strips that before it reaches the clipboard). time: (current-seconds), for the picker to show
;; "a moment ago" and for #120 to order entries the same way after a restart.
(struct clip-entry (text time) #:transparent)

(define entries '())    ; newest first

;; Newest first, capped at `n` (all of them if `n` is #f) -- the shape #119's picker wants
;; directly: "the current list of history entries, newest first."
(define (clipboard-history-entries [n #f])
  (if n (take-up-to entries n) entries))

(define (take-up-to l n) (if (> (length l) n) (take l n) l))

;; "Get entry N back": 0 is the newest, same indexing as `clipboard-history-entries`. #f past
;; the end rather than an error, so a picker racing a fast eviction never crashes.
(define (clipboard-history-ref n)
  (and (>= n 0) (< n (length entries)) (list-ref entries n)))

(define (clipboard-history-count) (length entries))

;; Recording a copy that repeats the current newest entry's text verbatim (typing Cmd+C twice
;; on the same selection, or copying, then cutting the very same text right after) would just
;; waste a slot on a duplicate and push the picker's list down for no new information -- so a
;; consecutive repeat only refreshes that entry's time instead of adding a new one. A repeat of
;; an *older* entry (not the newest) still gets its own new entry at the front: that is a
;; distinct, meaningful "I copied this again" event, most visible when the picker lets someone
;; grab an old entry and it jumps back to the top, same as a real clipboard manager.
(define (record-clipboard-text! text)
  (when (and (string? text) (positive? (string-length text)))
    (define cap (setting-ref 'clipboard-history-limit))
    (set! entries
          (take-up-to
           (cond
             [(and (pair? entries) (equal? (clip-entry-text (car entries)) text))
              (cons (clip-entry text (current-seconds)) (cdr entries))]
             [else (cons (clip-entry text (current-seconds)) entries)])
           cap))))

(define (clear-clipboard-history!) (set! entries '()))

;; Named procedure (not a fresh lambda) so add-hook!'s own de-duplication keeps this idempotent,
;; matching every other enable-*! in this codebase (recents.rkt, recovery.rkt, spell.rkt).
(define (on-text-copied buf text) (record-clipboard-text! text))

(define (enable-clipboard-history!) (add-hook! 'text-copied on-text-copied))
